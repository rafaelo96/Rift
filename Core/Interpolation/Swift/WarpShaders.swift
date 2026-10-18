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

#if RIFT_NATIVE_HARDWARE
#define DENSE_NATIVE_INPUT texture2d<float,access::sample>
#else
#define DENSE_NATIVE_INPUT texture2d<uint,access::read>
#endif
static inline float4 denseNativeSample(DENSE_NATIVE_INPUT image,float2 p,float maximum) {
#if RIFT_NATIVE_HARDWARE
    constexpr sampler linear(coord::pixel,address::clamp_to_edge,filter::linear);
    return image.sample(linear,p+0.5f)*maximum;
#else
    uint2 size=uint2(image.get_width(),image.get_height());
    p=clamp(p,float2(0),float2(size-1));
    uint2 lo=uint2(floor(p)),hi=min(lo+1,size-1); float2 f=fract(p);
    return mix(mix(float4(image.read(lo)),float4(image.read(uint2(hi.x,lo.y))),f.x),mix(float4(image.read(uint2(lo.x,hi.y))),float4(image.read(hi)),f.x),f.y);
#endif
}
kernel void denseNativeRender(DENSE_NATIVE_INPUT first [[texture(0)]],DENSE_NATIVE_INPUT last [[texture(1)]],texture2d<uint,access::write> output [[texture(2)]],texture2d<float,access::read> coordinates [[texture(3)]],texture2d<float,access::read> blend [[texture(4)]],constant uint &tenBit [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    float2 scale=float2(coordinates.get_width(),coordinates.get_height())/float2(output.get_width(),output.get_height());
    float2 work=(float2(p)+0.5f)*scale-0.5f;
    uint maxCoordX=coordinates.get_width()-1;
    uint maxCoordY=coordinates.get_height()-1;
    uint2 cell=uint2(clamp(round(work),float2(0),float2(maxCoordX,maxCoordY)));
    float4 motion=coordinates.read(cell); float alpha=clamp(blend.read(cell).r,0.0f,1.0f);
    float2 clampedWork=clamp(work,float2(0),float2(maxCoordX,maxCoordY));
    int2 i0=int2(floor(clampedWork));
    int2 i1=min(i0+1,int2(maxCoordX,maxCoordY));
    float2 f=fract(clampedWork);
    float4 m00=coordinates.read(uint2(i0.x,i0.y));
    float4 m10=coordinates.read(uint2(i1.x,i0.y));
    float4 m01=coordinates.read(uint2(i0.x,i1.y));
    float4 m11=coordinates.read(uint2(i1.x,i1.y));
    bool smoothSurface=length(m00.xy-m10.xy)<1.5f && length(m00.xy-m01.xy)<1.5f && length(m00.xy-m11.xy)<1.5f
                     && length(m00.zw-m10.zw)<1.5f && length(m00.zw-m01.zw)<1.5f && length(m00.zw-m11.zw)<1.5f;
    if(smoothSurface) {
        motion=mix(mix(m00,m10,f.x),mix(m01,m11,f.x),f.y);
        float a00=blend.read(uint2(i0.x,i0.y)).r;
        float a10=blend.read(uint2(i1.x,i0.y)).r;
        float a01=blend.read(uint2(i0.x,i1.y)).r;
        float a11=blend.read(uint2(i1.x,i1.y)).r;
        alpha=clamp(mix(mix(a00,a10,f.x),mix(a01,a11,f.x),f.y),0.0f,1.0f);
    }
    float maximum=tenBit!=0 ? 65535.0f : 255.0f;
    float4 value;
    if(alpha<=0) value=denseNativeSample(first,float2(p)+motion.xy/scale,maximum);
    else if(alpha>=1) value=denseNativeSample(last,float2(p)+motion.zw/scale,maximum);
    else value=mix(denseNativeSample(first,float2(p)+motion.xy/scale,maximum),denseNativeSample(last,float2(p)+motion.zw/scale,maximum),alpha);
    float unit=tenBit!=0 ? 64.0f : 1.0f;
    output.write(uint4(clamp(round(value/unit)*unit,float4(0),float4(tenBit!=0 ? 65472.0f : 255.0f))),p);
}
#undef DENSE_NATIVE_INPUT

struct NativeWarpUniforms {
    uint outW;
    uint outH;
    uint workW;
    uint workH;
    uint gridW;
    uint gridH;
    uint blockSize;
    uint fmt10;
    uint chromaSubsampleY;
    float t;
    float occThresh;
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
    // Block samples are centered at (bs-1)/2, not at the block's origin.
    float gx = clamp((p.x + 0.5f) / float(bs) - 0.5f, 0.0f, float(gridW - 1));
    float gy = clamp((p.y + 0.5f) / float(bs) - 0.5f, 0.0f, float(gridH - 1));
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

static inline float2 sampleBilinearNative2(texture2d<uint, access::read> tex,
                                            float2 p, int w, int h) {
    p = clamp(p, float2(0), float2(float(w - 1), float(h - 1)));
    int2 i0 = clamp(int2(floor(p)), int2(0), int2(w - 2, h - 2));
    float2 f = fract(p);
    int2 i1 = i0 + int2(1, 0), i2 = i0 + int2(0, 1), i3 = i0 + int2(1, 1);
    float2 v0 = mix(float2(tex.read(uint2(i0)).xy), float2(tex.read(uint2(i1)).xy), f.x);
    float2 v1 = mix(float2(tex.read(uint2(i2)).xy), float2(tex.read(uint2(i3)).xy), f.x);
    return mix(v0, v1, f.y);
}

// Full-resolution synthesis driven by a motion field measured on the smaller
// work plane. Image samples always come from the native decoded planes; only
// motion estimation is resolution-adaptive.
kernel void warpBlendNative(
    texture2d<uint, access::read>  tex0   [[texture(0)]],
    texture2d<uint, access::read>  tex1   [[texture(1)]],
    device const int2 *mv                  [[buffer(0)]],
    texture2d<uint, access::write> outTex [[texture(2)]],
    constant NativeWarpUniforms &u         [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.outW || gid.y >= u.outH) return;

    const float aS = float(tex0.read(gid).x);
    const float bS = float(tex1.read(gid).x);
    const float adS = fabs(aS - bS);
    float2 nativeP = float2(gid);
    float2 nativeToWork = float2(float(u.workW) / float(u.outW),
                                 float(u.workH) / float(u.outH));
    float2 workP = (nativeP + 0.5) * nativeToWork - 0.5;
    float2 flowWork = sampleMVBilinear(mv, workP, u.gridW, u.gridH, u.blockSize);
    float2 flowNative = flowWork / nativeToWork;
    float2 p0 = nativeP - u.t * flowNative;
    float2 p1 = nativeP + (1.0 - u.t) * flowNative;

    float v0 = sampleBilinearU16(tex0, p0, int(u.outW), int(u.outH)).x;
    float v1 = sampleBilinearU16(tex1, p1, int(u.outW), int(u.outH)).x;
    bool staticSupport = false;
    if (adS * 8.0 <= (aS + bS)) {
        float other0 = sampleBilinearU16(tex1, p0, int(u.outW), int(u.outH)).x;
        float other1 = sampleBilinearU16(tex0, p1, int(u.outW), int(u.outH)).x;
        staticSupport = fabs(v0-other0)*16.0 <= v0+other0 && fabs(v1-other1)*16.0 <= v1+other1;
    }
    if (staticSupport && adS * 16.0 <= (aS + bS)) { outTex.write(uint(aS+0.5), gid); return; }

    float2 nextWork = clamp(workP + flowWork, float2(0),
                            float2(float(u.workW - 1), float(u.workH - 1)));
    float2 flow1 = sampleMVBilinear(mv, nextWork, u.gridW, u.gridH, u.blockSize);
    float err = length(flowWork - flow1);
    float occ = smoothstep(u.occThresh, u.occThresh * 2.0 + 1e-3, err);
    float wF = (1.0 - u.t) * (1.0 - occ);
    float wB = u.t * (1.0 - occ);
    float dom = (u.t < 0.5) ? v0 : v1;
    float out = (wF * v0 + wB * v1 + occ * dom) / max(wF + wB + occ, 1e-4);
    if (occ > 0.5 && staticSupport) out = aS;
    outTex.write(uint(out + 0.5), gid);
}

kernel void warpBlendChromaNative(
    texture2d<uint, access::read>  tex0   [[texture(0)]],
    texture2d<uint, access::read>  tex1   [[texture(1)]],
    device const int2 *mv                  [[buffer(0)]],
    texture2d<uint, access::write> outTex [[texture(2)]],
    constant NativeWarpUniforms &u         [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.outW || gid.y >= u.outH) return;
    uint2 c0 = tex0.read(gid).xy;
    uint2 c1 = tex1.read(gid).xy;
    float2 aS = float2(c0), bS = float2(c1);
    float adS = fabs(aS.x - bS.x) + fabs(aS.y - bS.y);
    float sumLevels = aS.x + aS.y + bS.x + bS.y;
    // One chroma texel represents 2x2 native-luma pixels for 4:2:0 and 2x1
    // for 4:2:2. The vertical factor is supplied by the source plane geometry.
    float2 chromaP = float2(gid);
    float chromaScaleY = float(max(u.chromaSubsampleY, 1u));
    float2 chromaToLuma = float2(2.0, chromaScaleY);
    float2 nativeLumaP = chromaP * chromaToLuma + 0.5;
    float2 nativeLumaSize = float2(float(u.outW * 2), float(u.outH) * chromaScaleY);
    float2 nativeToWork = float2(float(u.workW), float(u.workH)) / nativeLumaSize;
    float2 workP = (nativeLumaP + 0.5) * nativeToWork - 0.5;
    float2 flowWork = sampleMVBilinear(mv, workP, u.gridW, u.gridH, u.blockSize);
    float2 flowChroma = (flowWork / nativeToWork) / chromaToLuma;
    float2 p0 = chromaP - u.t * flowChroma;
    float2 p1 = chromaP + (1.0 - u.t) * flowChroma;
    float2 v0 = sampleBilinearNative2(tex0, p0, int(u.outW), int(u.outH));
    float2 v1 = sampleBilinearNative2(tex1, p1, int(u.outW), int(u.outH));
    bool staticSupport = false;
    if (adS * 8.0 <= sumLevels) {
        float2 other0 = sampleBilinearNative2(tex1, p0, int(u.outW), int(u.outH));
        float2 other1 = sampleBilinearNative2(tex0, p1, int(u.outW), int(u.outH));
        staticSupport = dot(abs(v0-other0),float2(1))*16.0 <= dot(v0+other0,float2(1)) && dot(abs(v1-other1),float2(1))*16.0 <= dot(v1+other1,float2(1));
    }
    if (staticSupport && adS * 16.0 <= sumLevels) { outTex.write(uint4(c0.x,c0.y,0,0), gid); return; }

    float2 nextWork = clamp(workP + flowWork, float2(0),
                            float2(float(u.workW - 1), float(u.workH - 1)));
    float2 flow1 = sampleMVBilinear(mv, nextWork, u.gridW, u.gridH, u.blockSize);
    float err = length(flowWork - flow1);
    float occ = smoothstep(u.occThresh, u.occThresh * 2.0 + 1e-3, err);
    float wF = (1.0 - u.t) * (1.0 - occ);
    float wB = u.t * (1.0 - occ);
    float2 dom = (u.t < 0.5) ? v0 : v1;
    float2 out = (wF * v0 + wB * v1 + occ * dom) / max(wF + wB + occ, 1e-4);
    if (occ > 0.5 && staticSupport) out = aS;
    outTex.write(uint4(uint(out.x + 0.5), uint(out.y + 0.5), 0, 0), gid);
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

    // Agreement at the destination alone can erase moving objects passing
    // through it; static protection also requires agreement along transport.
    const float aS = float(tex0.read(gid).x);
    const float bS = float(tex1.read(gid).x);
    const float adS = fabs(aS - bS);
    float2 flow = sampleMVBilinear(mv, float2(float(gid.x), float(gid.y)), u.gridW, u.gridH, bs);

    // backward warp positions
    float2 p = float2(float(gid.x), float(gid.y));
    float2 p0 = p - u.t * flow;
    float2 p1 = p + (1.0 - u.t) * flow;

    float v0 = sampleBilinearU16(tex0, p0, int(u.width), int(u.height)).x;
    float v1 = sampleBilinearU16(tex1, p1, int(u.width), int(u.height)).x;
    bool staticSupport = false;
    if (adS * 8.0 <= (aS + bS)) {
        float other0 = sampleBilinearU16(tex1, p0, int(u.width), int(u.height)).x;
        float other1 = sampleBilinearU16(tex0, p1, int(u.width), int(u.height)).x;
        staticSupport = fabs(v0-other0)*16.0 <= v0+other0 && fabs(v1-other1)*16.0 <= v1+other1;
    }
    if (staticSupport && adS * 16.0 <= (aS + bS)) { outTex.write(uint(aS+0.5), gid); return; }

    // occlusion via forward-backward consistency, approx bw = -fw
    // err = |fw(p) + bw(p+fw)| = |flow(p) - flow(p+flow)| ; flow sampled bilinearly
    float2 pp = clamp(p + flow, float2(0,0), float2(float(u.width-1), float(u.height-1)));
    float2 flow1 = sampleMVBilinear(mv, pp, u.gridW, u.gridH, bs);
    float err = length(flow - flow1);
    // Soft occlusion: smoothstep over [thresh, 2*thresh] instead of a hard
    // 0/1 step, so silhouette borders blend instead of popping. Under full
    // occlusion the 50/50 fallback (literal ghosting of two incompatible
    // positions) is replaced by the dominant (foreground-guess) side by t.
    float occHi = u.occThresh * 2.0 + 1e-3;
    float occ = smoothstep(u.occThresh, occHi, err);
    // simple split: occF = occ, occB = occ (symmetric approx)
    float wF = (1.0 - u.t) * (1.0 - occ);
    float wB = u.t * (1.0 - occ);
    float wDom = occ;
    float dom = (u.t < 0.5) ? v0 : v1;
    float sum = wF + wB + wDom;
    float out = (wF * v0 + wB * v1 + wDom * dom) / max(sum, 1e-4);
    // Incoherent flow may snap only when transport also supports static content.
    if (occ > 0.5 && staticSupport) {
        out = aS;
    }
    // Single-side occlusion is handled above via the dominant-side pick;
    // OBMC omitted.
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
// static bypass, backward warps from both inputs weighted by t, and the same
// soft occlusion/dominant-side policy as luma. Operates on 2 channels (rg16Uint).
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
    float2 flow = sampleMVBilinear(mv, float2(float(gid.x) * 2.0 + 1.0, float(gid.y) * 2.0 + 1.0),
                                    u.gridW, u.gridH, u.blockSize) * 0.5;

    float2 p = float2(float(gid.x), float(gid.y));
    float2 p0 = p - u.t * flow;
    float2 p1 = p + (1.0 - u.t) * flow;

    bool oob0 = (p0.x < 0.0 || p0.x > float(u.width - 1) || p0.y < 0.0 || p0.y > float(u.height - 1));
    bool oob1 = (p1.x < 0.0 || p1.x > float(u.width - 1) || p1.y < 0.0 || p1.y > float(u.height - 1));
    if (oob0 && oob1) {
        outTex.write(uint4(c0.x, c0.y, 0, 0), gid);
        return;
    }

    float2 v0 = oob0 ? aS : sampleBilinear2xU16(tex0, p0, int(u.width), int(u.height));
    float2 v1 = oob1 ? bS : sampleBilinear2xU16(tex1, p1, int(u.width), int(u.height));
    bool staticSupport = false;
    if (adS * 8.0 <= sm) {
        float2 other0 = sampleBilinear2xU16(tex1, p0, int(u.width), int(u.height));
        float2 other1 = sampleBilinear2xU16(tex0, p1, int(u.width), int(u.height));
        staticSupport = dot(abs(v0-other0),float2(1))*16.0 <= dot(v0+other0,float2(1)) && dot(abs(v1-other1),float2(1))*16.0 <= dot(v1+other1,float2(1));
    }
    if (staticSupport && adS * 16.0 <= sm) { outTex.write(uint4(c0.x,c0.y,0,0), gid); return; }

    float2 pp = clamp(p + flow, float2(0, 0), float2(float(u.width - 1), float(u.height - 1)));
    float2 flow1 = sampleMVBilinear(mv, float2(pp.x * 2.0 + 1.0, pp.y * 2.0 + 1.0),
                                    u.gridW, u.gridH, u.blockSize) * 0.5;
    float err = length(flow - flow1);
    // Match luma exactly: a hard chroma-only cut caused color contours to
    // stick to I0 while luma already transitioned to I1 near an occlusion.
    float occHi = u.occThresh * 2.0 + 1e-3;
    float occ = smoothstep(u.occThresh, occHi, err);
    float wF = (1.0 - u.t) * (1.0 - occ);
    float wB = u.t * (1.0 - occ);
    float wDom = occ;
    float2 dom = (u.t < 0.5) ? v0 : v1;
    float sum = wF + wB + wDom;
    float2 out = (wF * v0 + wB * v1 + wDom * dom) / max(sum, 1e-4);
    if (occ > 0.5 && staticSupport) {
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

// Zero-copy variant for 8-bit planes: writes packed CbCr into the output
// buffer's chroma plane (wrapped as .rg8Uint) directly, so the host-side
// compaction in writeChromaPlane (per-pixel Swift loop, ~40ms per t in debug)
// is eliminated. Same bilinear math as upscaleChroma2 with fmt10=0.
kernel void upscaleChroma2Packed8(
    texture2d<uint, access::read>   srcTex [[texture(0)]],
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
    uint2 outVal = uint2(v + 0.5) >> 8; // work scale (<<8) -> 8-bit byte
    outTex.write(uint4(outVal.x, outVal.y, 0, 0), gid);
}
"""
