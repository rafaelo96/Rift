import Foundation

public let warpShadersMSL = """
#include <metal_stdlib>
using namespace metal;

struct WarpUniforms {
    uint  width;
    uint  height;
    uint  gridW;
    uint  gridH;
    uint  blockSize;
    float t;
    float occThresh; // px, err > thresh => occluded
};

struct UpscaleUniforms {
    uint srcW;
    uint srcH;
    uint outW;
    uint outH;
    uint fmt10; // 1 = 10-bit (work-plane luma already >>6, write <<6 back), 0 = 8-bit
};

static inline float4 sampleBilinearU16(texture2d<uint, access::read> tex, float2 p, int w, int h) {
    // clamp
    p = clamp(p, float2(0,0), float2(float(w-1), float(h-1)));
    int2 i0 = int2(floor(p));
    float2 f = fract(p);
    i0 = clamp(i0, int2(0,0), int2(w-2, h-2));
    int2 i1 = i0 + int2(1,0);
    int2 i2 = i0 + int2(0,1);
    int2 i3 = i0 + int2(1,1);
    uint s00 = tex.read(uint2(uint(i0.x), uint(i0.y))).x;
    uint s10 = tex.read(uint2(uint(i1.x), uint(i1.y))).x;
    uint s01 = tex.read(uint2(uint(i2.x), uint(i2.y))).x;
    uint s11 = tex.read(uint2(uint(i3.x), uint(i3.y))).x;
    float v0 = mix(float(s00), float(s10), f.x);
    float v1 = mix(float(s01), float(s11), f.x);
    float v = mix(v0, v1, f.y);
    return float4(v, 0, 0, 0);
}

static inline float2 sampleMVBilinear(device const int2 *mv, float2 p, uint gridW, uint gridH, uint bs) {
    // p in pixel coords, mv grid is blockSize-spaced. Bilinear between block centers.
    float gx = p.x / float(bs);
    float gy = p.y / float(bs);
    int x0 = clamp(int(floor(gx)), 0, int(gridW)-1);
    int y0 = clamp(int(floor(gy)), 0, int(gridH)-1);
    int x1 = clamp(x0 + 1, 0, int(gridW)-1);
    int y1 = clamp(y0 + 1, 0, int(gridH)-1);
    float fx = fract(gx);
    float fy = fract(gy);
    float2 m00 = float2(float(mv[y0*gridW + x0].x), float(mv[y0*gridW + x0].y)) * 0.5;
    float2 m10 = float2(float(mv[y0*gridW + x1].x), float(mv[y0*gridW + x1].y)) * 0.5;
    float2 m01 = float2(float(mv[y1*gridW + x0].x), float(mv[y1*gridW + x0].y)) * 0.5;
    float2 m11 = float2(float(mv[y1*gridW + x1].x), float(mv[y1*gridW + x1].y)) * 0.5;
    float2 m0 = mix(m00, m10, fx);
    float2 m1 = mix(m01, m11, fx);
    return mix(m0, m1, fy);
}

kernel void warpBlend(
    texture2d<uint, access::read>  tex0   [[texture(0)]],
    texture2d<uint, access::read>  tex1   [[texture(1)]],
    device const int2 *mv             [[buffer(0)]],
    texture2d<uint, access::write> outTex [[texture(2)]],
    constant WarpUniforms &u          [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;
    const uint bs = u.blockSize;

    // Static bypass (symmetric, format-agnostic): when the two inputs agree at
    // the SAME pixel, there is no motion to compensate — copy I0 exactly
    // instead of warping. This nails static content (logos, thin text) even
    // when the ME field carries spurious vectors there (self-similar strokes,
    // sub-pel dither), which previously twisted thin glyphs. The relative
    // threshold (~6% of local level, no absolute floor) auto-scales to any bit
    // depth and covers edge compression noise; fades and real motion exceed it,
    // so blending proceeds untouched. Dark levels fall back to the warp (safe:
    // no visible edges there anyway).
    const float aS = float(tex0.read(gid).x);
    const float bS = float(tex1.read(gid).x);
    const float adS = fabs(aS - bS);
    if (adS * 16.0 <= (aS + bS)) {
        outTex.write(uint(aS + 0.5), gid);
        return;
    }

    float2 flow = sampleMVBilinear(mv, float2(float(gid.x), float(gid.y)), u.gridW, u.gridH, bs);

    // backward warp positions
    float2 p = float2(float(gid.x), float(gid.y));
    float2 p0 = p - u.t * flow;
    float2 p1 = p + (1.0 - u.t) * flow;

    float v0 = sampleBilinearU16(tex0, p0, int(u.width), int(u.height)).x;
    float v1 = sampleBilinearU16(tex1, p1, int(u.width), int(u.height)).x;

    // occlusion via forward-backward consistency, approx bw = -fw
    // err = |fw(p) + bw(p+fw)| = |flow(p) - flow(p+flow)| ; flow sampled bilinearly
    float2 pp = clamp(p + flow, float2(0,0), float2(float(u.width-1), float(u.height-1)));
    float2 flow1 = sampleMVBilinear(mv, pp, u.gridW, u.gridH, bs);
    float err = length(flow - flow1);
    float occ = err > u.occThresh ? 1.0 : 0.0;
    // simple split: occF = occ, occB = occ (symmetric approx)
    float wF = (1.0 - u.t) * (1.0 - occ);
    float wB = u.t * (1.0 - occ);
    float sum = wF + wB;
    float out;
    if (sum < 1e-4) {
        out = 0.5 * (v0 + v1);
    } else {
        out = (wF * v0 + wB * v1) / sum;
    }
    // Incoherent-flow zones whose inputs still agree are spurious twists, not
    // occlusions (self-similar strokes / dither on static content): snap to I0.
    // Real occlusions disagree in the inputs, so they keep the blended result.
    // The loose bound (~12% of local level) is safe here because occ already
    // gates it — well-matched motion never reaches this branch with occ == 1.
    if (occ > 0.5 && adS * 8.0 <= (aS + bS)) {
        out = aS;
    }
    // also handle single-side occlusion more explicitly: if err large, prefer the sample with smaller err direction?
    // v1 approx is sufficient for v1 prototype; OBMC omitted.
    outTex.write(uint(out + 0.5), gid);
}

// Bilinear upscale of the work-plane warp result to full resolution.
// srcTex = work-plane luma texture (values 0..1023 for 10-bit, or 8-bit in high
// byte for 8-bit — matches scaledLuma), outTex = full-res luma of the output
// CVPixelBuffer. Output scalar is re-packed to the target bit depth.
kernel void upscaleLuma(
    texture2d<uint, access::read>  srcTex [[texture(0)]],
    texture2d<uint, access::write> outTex [[texture(1)]],
    constant UpscaleUniforms &u     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.outW || gid.y >= u.outH) return;

    float2 p = float2(float(gid.x) + 0.5, float(gid.y) + 0.5)
             * float2(float(u.srcW), float(u.srcH))
             / float2(float(u.outW), float(u.outH));
    p -= 0.5;
    p = clamp(p, float2(0,0), float2(float(u.srcW-1), float(u.srcH-1)));

    int2 i0 = int2(floor(p));
    i0 = clamp(i0, int2(0,0), int2(int(u.srcW)-1, int(u.srcH)-1));
    int2 i1 = min(i0 + int2(1,0), int2(int(u.srcW)-1, int(u.srcH)-1));
    int2 i2 = min(i0 + int2(0,1), int2(int(u.srcW)-1, int(u.srcH)-1));
    int2 i3 = min(i0 + int2(1,1), int2(int(u.srcW)-1, int(u.srcH)-1));
    float2 f = fract(p);

    float v00 = float(srcTex.read(uint2(uint(i0.x), uint(i0.y))).x);
    float v10 = float(srcTex.read(uint2(uint(i1.x), uint(i1.y))).x);
    float v01 = float(srcTex.read(uint2(uint(i2.x), uint(i2.y))).x);
    float v11 = float(srcTex.read(uint2(uint(i3.x), uint(i3.y))).x);
    float v0 = mix(v00, v10, f.x);
    float v1 = mix(v01, v11, f.x);
    float v = mix(v0, v1, f.y);

    uint outVal = uint(v + 0.5);
    if (u.fmt10) {
        outVal = outVal << 6; // work-plane value 0..1023 -> 10-bit in high bits
    } else {
        // 8-bit vive en el byte alto del r16Uint uniforme (value<<8): extraerlo.
        outVal = outVal >> 8;
    }
    outTex.write(outVal, gid);
}

// ---------------------------------------------------------------------------
// Chroma (CbCr interleaved) warp. The luma decoupled path previously copied
// plane 1 verbatim from I0, so the intermediate frame had motion-compensated
// luma but chroma stuck at t=0 -> colored moving objects showed their old
// position's color (fringing / double-image), perceived as worse than native.
// These kernels warp BOTH chroma planes with the SAME MV field (half the spatial
// scale thanks to 4:2:0), through a work plane at (workWidth/2 × workHeight/2)
// and a bilinear upscale back to full chroma res. MV units stay in work-plane
// pixels; a chroma work texel maps to luma coord (2x, 2y) and the displacement
// at chroma scale is luma flow * 0.5.
// ---------------------------------------------------------------------------

// 2-channel bilinear fetch (rg16Uint work plane, integer normalized like luma).
static inline float2 sampleBilinear2xU16(texture2d<uint, access::read> tex, float2 p, int w, int h) {
    p = clamp(p, float2(0, 0), float2(float(w - 1), float(h - 1)));
    int2 i0 = int2(floor(p));
    float2 f = fract(p);
    i0 = clamp(i0, int2(0, 0), int2(w - 2, h - 2));
    int2 i1 = i0 + int2(1, 0);
    int2 i2 = i0 + int2(0, 1);
    int2 i3 = i0 + int2(1, 1);
    uint2 s00 = tex.read(uint2(uint(i0.x), uint(i0.y))).xy;
    uint2 s10 = tex.read(uint2(uint(i1.x), uint(i1.y))).xy;
    uint2 s01 = tex.read(uint2(uint(i2.x), uint(i2.y))).xy;
    uint2 s11 = tex.read(uint2(uint(i3.x), uint(i3.y))).xy;
    float2 v0 = mix(float2(s00), float2(s10), f.x);
    float2 v1 = mix(float2(s01), float2(s11), f.x);
    return mix(v0, v1, f.y);
}

// Full chroma res (W/2 × H/2) -> chroma work plane (workW/2 × workH/2).
// inTex is rg8Uint (8-bit, values 0..255) or rg16Uint (10-bit, <<6 in words);
// outTex is always rg16Uint. fmt10=0 promotes 8-bit to the work scale (<<8).
kernel void chromaDownscale2(
    texture2d<uint, access::read>  inTex  [[texture(0)]],
    texture2d<uint, access::write> outTex [[texture(1)]],
    constant UpscaleUniforms &u     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.outW || gid.y >= u.outH) return;
    float2 p = clamp((float2(float(gid.x), float(gid.y)) + 0.5)
                     * float2(float(u.srcW), float(u.srcH))
                     / float2(float(u.outW), float(u.outH)) - 0.5,
                     float2(0, 0), float2(float(u.srcW - 1), float(u.srcH - 1)));
    int2 i0 = int2(floor(p));
    i0 = clamp(i0, int2(0, 0), int2(int(u.srcW) - 1, int(u.srcH) - 1));
    int2 i1 = min(i0 + int2(1, 0), int2(int(u.srcW) - 1, int(u.srcH) - 1));
    int2 i2 = min(i0 + int2(0, 1), int2(int(u.srcW) - 1, int(u.srcH) - 1));
    int2 i3 = min(i0 + int2(1, 1), int2(int(u.srcW) - 1, int(u.srcH) - 1));
    float2 f = fract(p);
    uint2 v00 = inTex.read(uint2(uint(i0.x), uint(i0.y))).xy;
    uint2 v10 = inTex.read(uint2(uint(i1.x), uint(i1.y))).xy;
    uint2 v01 = inTex.read(uint2(uint(i2.x), uint(i2.y))).xy;
    uint2 v11 = inTex.read(uint2(uint(i3.x), uint(i3.y))).xy;
    float2 v0 = mix(float2(v00), float2(v10), f.x);
    float2 v1 = mix(float2(v01), float2(v11), f.x);
    float2 v = mix(v0, v1, f.y);
    uint2 outVal = uint2(v + 0.5);
    if (u.fmt10 == 0) { outVal = outVal << 8; } // 8-bit -> work scale (value<<8)
    outTex.write(uint4(outVal.x, outVal.y, 0, 0), gid);
}

// Motion-compensated chroma warp on the work plane, mirroring warpBlend:
// static bypass, backward warps from both inputs weighted by t, occlusion via
// forward-backward MV consistency. Operates on 2 channels (rg16Uint).
// u.width/height are the CHROMA work dims; grid/blockSize stay the luma ones.
kernel void warpBlendChroma2(
    texture2d<uint, access::read>  tex0   [[texture(0)]],
    texture2d<uint, access::read>  tex1   [[texture(1)]],
    device const int2 *mv             [[buffer(0)]],
    texture2d<uint, access::write> outTex [[texture(2)]],
    constant WarpUniforms &u          [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.width || gid.y >= u.height) return;

    const uint2 c0 = tex0.read(gid).xy;
    const uint2 c1 = tex1.read(gid).xy;
    const float2 aS = float2(c0);
    const float2 bS = float2(c1);
    const float adS = fabs(aS.x - bS.x) + fabs(aS.y - bS.y);
    const float sm = aS.x + aS.y + bS.x + bS.y;
    if (adS * 16.0 <= sm) { // static: inputs agree -> copy I0 exactly
        outTex.write(uint4(c0.x, c0.y, 0, 0), gid);
        return;
    }

    // Flow at the luma coord this chroma texel represents (x2 + half-pel site),
    // re-scaled to chroma work scale (*0.5).
    float2 flow = sampleMVBilinear(mv, float2(float(gid.x) * 2.0 + 1.0, float(gid.y) * 2.0 + 1.0),
                                   u.gridW, u.gridH, u.blockSize) * 0.5;

    float2 p = float2(float(gid.x), float(gid.y));
    float2 p0 = p - u.t * flow;
    float2 p1 = p + (1.0 - u.t) * flow;

    float2 v0 = sampleBilinear2xU16(tex0, p0, int(u.width), int(u.height));
    float2 v1 = sampleBilinear2xU16(tex1, p1, int(u.width), int(u.height));

    float2 pp = clamp(p + flow, float2(0, 0), float2(float(u.width - 1), float(u.height - 1)));
    float2 flow1 = sampleMVBilinear(mv, float2(pp.x * 2.0 + 1.0, pp.y * 2.0 + 1.0),
                                    u.gridW, u.gridH, u.blockSize) * 0.5;
    float err = length(flow - flow1);
    float occ = err > u.occThresh ? 1.0 : 0.0;
    float wF = (1.0 - u.t) * (1.0 - occ);
    float wB = u.t * (1.0 - occ);
    float sum = wF + wB;
    float2 out;
    if (sum < 1e-4) {
        out = 0.5 * (v0 + v1);
    } else {
        out = (wF * v0 + wB * v1) / sum;
    }
    if (occ > 0.5 && adS * 8.0 <= sm) { // incoherent but agreeing -> I0
        out = aS;
    }
    outTex.write(uint4(uint(out.x + 0.5), uint(out.y + 0.5), 0, 0), gid);
}

// Chroma work plane -> full chroma res, repacking the scale to the plane layout.
// fmt10=0 (8-bit): work value (v<<8) -> low byte of the output word (plane bytes).
kernel void upscaleChroma2(
    texture2d<uint, access::read>  srcTex [[texture(0)]],
    texture2d<uint, access::write> outTex [[texture(1)]],
    constant UpscaleUniforms &u     [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.outW || gid.y >= u.outH) return;
    float2 p = clamp((float2(float(gid.x), float(gid.y)) + 0.5)
                     * float2(float(u.srcW), float(u.srcH))
                     / float2(float(u.outW), float(u.outH)) - 0.5,
                     float2(0, 0), float2(float(u.srcW - 1), float(u.srcH - 1)));
    int2 i0 = int2(floor(p));
    i0 = clamp(i0, int2(0, 0), int2(int(u.srcW) - 1, int(u.srcH) - 1));
    int2 i1 = min(i0 + int2(1, 0), int2(int(u.srcW) - 1, int(u.srcH) - 1));
    int2 i2 = min(i0 + int2(0, 1), int2(int(u.srcW) - 1, int(u.srcH) - 1));
    int2 i3 = min(i0 + int2(1, 1), int2(int(u.srcW) - 1, int(u.srcH) - 1));
    float2 f = fract(p);
    uint2 v00 = srcTex.read(uint2(uint(i0.x), uint(i0.y))).xy;
    uint2 v10 = srcTex.read(uint2(uint(i1.x), uint(i1.y))).xy;
    uint2 v01 = srcTex.read(uint2(uint(i2.x), uint(i2.y))).xy;
    uint2 v11 = srcTex.read(uint2(uint(i3.x), uint(i3.y))).xy;
    float2 v0 = mix(float2(v00), float2(v10), f.x);
    float2 v1 = mix(float2(v01), float2(v11), f.x);
    float2 v = mix(v0, v1, f.y);
    uint2 outVal = uint2(v + 0.5);
    if (u.fmt10 == 0) { outVal = outVal >> 8; } // work value (<<8) -> byte in low bits
    outTex.write(uint4(outVal.x, outVal.y, 0, 0), gid);
}
"""
