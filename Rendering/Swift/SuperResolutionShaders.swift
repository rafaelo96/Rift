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

static inline float cubicWeight(float x) {
    x = abs(x);
    if (x < 1.0) return 1.5 * x * x * x - 2.5 * x * x + 1.0;
    if (x < 2.0) return -0.5 * x * x * x + 2.5 * x * x - 4.0 * x + 2.0;
    return 0.0;
}

static inline float bicubic1(texture2d<uint, access::read> tex, float2 p, int w, int h) {
    p = clamp(p, float2(0), float2(float(w - 1), float(h - 1)));
    int2 origin = int2(floor(p));
    float2 f = fract(p);
    float result = 0.0;
    float weightSum = 0.0;
    for (int y = -1; y <= 2; ++y) {
        float wy = cubicWeight(float(y) - f.y);
        for (int x = -1; x <= 2; ++x) {
            float weight = cubicWeight(float(x) - f.x) * wy;
            result += sample1(tex, origin + int2(x, y), w, h) * weight;
            weightSum += weight;
        }
    }
    return result / max(weightSum, 0.0001);
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
    float base = bicubic1(input, p, int(u.srcW), int(u.srcH));
    int2 c = int2(round(p));
    float center = sample1(input, c, int(u.srcW), int(u.srcH));
    float left = sample1(input, c + int2(-1, 0), int(u.srcW), int(u.srcH));
    float right = sample1(input, c + int2(1, 0), int(u.srcW), int(u.srcH));
    float up = sample1(input, c + int2(0, -1), int(u.srcW), int(u.srcH));
    float down = sample1(input, c + int2(0, 1), int(u.srcW), int(u.srcH));
    float localMin = min(center, min(min(left, right), min(up, down)));
    float localMax = max(center, max(max(left, right), max(up, down)));
    float highPass = center - (left + right + up + down) * 0.25;
    float contrast = localMax - localMin;
    float horizontalGradient = abs(right - left);
    float verticalGradient = abs(down - up);
    float directionalEdge = 1.0 - min(horizontalGradient, verticalGradient)
                          / max(1.0, max(horizontalGradient, verticalGradient));
    float detailGate = smoothstep(2.0, 12.0, contrast);
    float adaptiveGain = u.detail * mix(0.65, 1.15, directionalEdge);
    float reconstructed = clamp(base + highPass * adaptiveGain * detailGate, localMin, localMax);
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
