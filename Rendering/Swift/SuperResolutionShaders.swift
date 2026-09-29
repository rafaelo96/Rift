import Foundation

let superResolutionShadersMSL = """
#include <metal_stdlib>
using namespace metal;

struct SRUniforms {
    uint srcW;
    uint srcH;
    uint dstW;
    uint dstH;
    float detail;
};

static inline float sample1(texture2d<uint, access::read> tex, int2 p, int w, int h) {
    p = clamp(p, int2(0), int2(w - 1, h - 1));
    return float(tex.read(uint2(p)).x);
}

static inline float bilinear1(texture2d<uint, access::read> tex, float2 p, int w, int h) {
    p = clamp(p, float2(0), float2(float(w - 1), float(h - 1)));
    int2 i = int2(floor(p));
    float2 f = fract(p);
    float a = mix(sample1(tex, i, w, h), sample1(tex, i + int2(1, 0), w, h), f.x);
    float b = mix(sample1(tex, i + int2(0, 1), w, h), sample1(tex, i + int2(1, 1), w, h), f.x);
    return mix(a, b, f.y);
}

kernel void superResolveLuma(
    texture2d<uint, access::read> input [[texture(0)]],
    texture2d<uint, access::write> output [[texture(1)]],
    constant SRUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.dstW || gid.y >= u.dstH) return;
    float2 p = (float2(gid) + 0.5) * float2(float(u.srcW), float(u.srcH))
             / float2(float(u.dstW), float(u.dstH)) - 0.5;
    float base = bilinear1(input, p, int(u.srcW), int(u.srcH));
    int2 c = int2(round(p));
    float center = sample1(input, c, int(u.srcW), int(u.srcH));
    float left = sample1(input, c + int2(-1, 0), int(u.srcW), int(u.srcH));
    float right = sample1(input, c + int2(1, 0), int(u.srcW), int(u.srcH));
    float up = sample1(input, c + int2(0, -1), int(u.srcW), int(u.srcH));
    float down = sample1(input, c + int2(0, 1), int(u.srcW), int(u.srcH));
    float localMin = min(center, min(min(left, right), min(up, down)));
    float localMax = max(center, max(max(left, right), max(up, down)));
    float highPass = center - (left + right + up + down) * 0.25;
    float detailGate = smoothstep(1.0, max(2.0, localMax - localMin), localMax - localMin);
    float reconstructed = clamp(base + highPass * u.detail * detailGate, localMin, localMax);
    output.write(uint(reconstructed + 0.5), gid);
}

static inline float2 sample2(texture2d<uint, access::read> tex, int2 p, int w, int h) {
    p = clamp(p, int2(0), int2(w - 1, h - 1));
    return float2(tex.read(uint2(p)).xy);
}

kernel void superResolveChroma(
    texture2d<uint, access::read> input [[texture(0)]],
    texture2d<uint, access::write> output [[texture(1)]],
    constant SRUniforms &u [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.dstW || gid.y >= u.dstH) return;
    float2 p = (float2(gid) + 0.5) * float2(float(u.srcW), float(u.srcH))
             / float2(float(u.dstW), float(u.dstH)) - 0.5;
    p = clamp(p, float2(0), float2(float(u.srcW - 1), float(u.srcH - 1)));
    int2 i = int2(floor(p));
    float2 f = fract(p);
    float2 a = mix(sample2(input, i, int(u.srcW), int(u.srcH)),
                   sample2(input, i + int2(1, 0), int(u.srcW), int(u.srcH)), f.x);
    float2 b = mix(sample2(input, i + int2(0, 1), int(u.srcW), int(u.srcH)),
                   sample2(input, i + int2(1, 1), int(u.srcW), int(u.srcH)), f.x);
    uint2 value = uint2(mix(a, b, f.y) + 0.5);
    output.write(uint4(value.x, value.y, 0, 0), gid);
}
"""
