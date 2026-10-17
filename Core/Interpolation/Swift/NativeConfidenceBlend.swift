import Metal

// Post-process the actual native synthesis, preserving every native pixel whose work weight is zero.
let nativeConfidenceBlendMSL = """
#include <metal_stdlib>
using namespace metal;
kernel void nativeConfidenceBlend(texture2d<float,access::read> first [[texture(0)]],texture2d<float,access::read> last [[texture(1)]],texture2d<uint,access::read_write> output [[texture(2)]],texture2d<float,access::read> confidence [[texture(3)]],constant float &t [[buffer(0)]],constant uint &tenBit [[buffer(1)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()||t==0||t==1) return;
    uint2 cell=min(uint2((float2(p)+0.5f)*float2(confidence.get_width(),confidence.get_height())/float2(output.get_width(),output.get_height())),uint2(confidence.get_width()-1,confidence.get_height()-1));
    float2 local=confidence.read(cell).xy;if(local.x==0) return;
    float maximum=tenBit!=0 ? 65535.0f : 255.0f,unit=tenBit!=0 ? 64.0f : 1.0f;
    float4 a=first.read(p)*maximum,b=last.read(p)*maximum;
    float4 fallback=mix(mix(a,b,t),t<0.5f ? a : b,local.y);
    float4 value=mix(float4(output.read(p)),fallback,local.x);
    output.write(uint4(clamp(round(value/unit)*unit,float4(0),float4(tenBit!=0 ? 65472.0f : 255.0f))),p);
}
"""
