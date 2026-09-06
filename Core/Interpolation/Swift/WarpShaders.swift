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
    // also handle single-side occlusion more explicitly: if err large, prefer the sample with smaller err direction?
    // v1 approx is sufficient for v1 prototype; OBMC omitted.
    outTex.write(uint(out + 0.5), gid);
}
"""
