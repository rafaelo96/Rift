import Foundation

// Experimental midpoint objective. Original search and production synthesis
// remain unchanged. Half-pixel vectors use the same sign as motionSearchEPZS.
let centeredRefinementMSL = """
#include <metal_stdlib>
using namespace metal;
float centeredSample(texture2d<uint, access::read> image, float2 p) {
    p = clamp(p, float2(0), float2(image.get_width()-1, image.get_height()-1));
    uint2 a = uint2(floor(p));
    uint2 b = min(a+1, uint2(image.get_width()-1, image.get_height()-1));
    float2 f = fract(p);
    return mix(mix(float(image.read(a).r), float(image.read(uint2(b.x,a.y)).r), f.x),
               mix(float(image.read(uint2(a.x,b.y)).r), float(image.read(b).r), f.x), f.y);
}
float centeredCost(texture2d<uint, access::read> a, texture2d<uint, access::read> b,
                   uint2 origin, uint block, int2 v) {
    float cost = 0;
    for (uint y=0; y<block && origin.y+y<a.get_height(); ++y)
        for (uint x=0; x<block && origin.x+x<a.get_width(); ++x) {
            float2 p = float2(origin+uint2(x,y));
            float2 d = float2(v)*0.25f;
            cost += abs(centeredSample(a,p-d)-centeredSample(b,p+d));
        }
    return cost;
}
float predictorPenalty(int2 candidate, int2 predictor, uint block, uint weight) {
    int2 delta=abs(candidate-predictor);
    return float(block*block*weight)*float(max(delta.x,delta.y))*0.5f;
}
kernel void centeredRefine(texture2d<uint, access::read> a [[texture(0)]],
                           texture2d<uint, access::read> b [[texture(1)]],
                           device const int2 *input [[buffer(0)]],
                           device int2 *output [[buffer(1)]],
                           constant uint4 &u [[buffer(2)]],
                           device const int2 *previous [[buffer(3)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x>=u.x || gid.y>=u.y) return;
    uint index=gid.y*u.x+gid.x;
    int2 original=input[index], best=original;
    uint2 origin=gid*u.z;
    float bestCost=centeredCost(a,b,origin,u.z,best);
    // Evaluate neighbors against immutable input, then a local +/-2px search.
    for (int y=-1; y<=1; ++y) for (int x=-1; x<=1; ++x) {
        int2 cell=clamp(int2(gid)+int2(x,y),int2(0),int2(u.xy)-1);
        int2 candidate=input[uint(cell.y)*u.x+uint(cell.x)];
        float cost=centeredCost(a,b,origin,u.z,candidate)+predictorPenalty(candidate,original,u.z,u.w);
        if (cost<bestCost) { best=candidate; bestCost=cost; }
    }
    for (int y=-4; y<=4; y+=2) for (int x=-4; x<=4; x+=2) {
        int2 candidate=original+int2(x,y);
        float cost=centeredCost(a,b,origin,u.z,candidate)+predictorPenalty(candidate,original,u.z,u.w);
        if (cost<bestCost) { best=candidate; bestCost=cost; }
    }
    float zeroCost=centeredCost(a,b,origin,u.z,int2(0))+predictorPenalty(int2(0),original,u.z,u.w);
    if (zeroCost<bestCost) { best=int2(0); bestCost=zeroCost; }
    int2 temporal=previous[index];
    float temporalCost=centeredCost(a,b,origin,u.z,temporal)+predictorPenalty(temporal,original,u.z,u.w);
    output[index]=temporalCost<bestCost ? temporal : best;
}
"""

let fourFrameRefinementMSL: String = {
    let helper = """
    float fourCost(texture2d<uint, access::read> a, texture2d<uint, access::read> b,
                   texture2d<uint, access::read> before, texture2d<uint, access::read> after,
                   uint2 origin, uint block, int2 vector) {
        float cost=0;
        float2 d=float2(vector)*0.25f;
        for (uint y=0;y<block && origin.y+y<a.get_height();++y)
            for (uint x=0;x<block && origin.x+x<a.get_width();++x) {
                float2 p=float2(origin+uint2(x,y));
                float v0=centeredSample(a,p-d), v1=centeredSample(b,p+d);
                cost+=abs(v0-v1)+abs(centeredSample(before,p-3*d)-v0)+abs(centeredSample(after,p+3*d)-v1);
            }
        return cost;
    }

    """
    precondition(centeredRefinementMSL.contains("kernel void centeredRefine"))
    return centeredRefinementMSL
        .replacingOccurrences(of: "kernel void centeredRefine",with: helper+"kernel void fourRefine")
        .replacingOccurrences(of: "texture2d<uint, access::read> b [[texture(1)]],",with: "texture2d<uint, access::read> b [[texture(1)]], texture2d<uint, access::read> before [[texture(2)]], texture2d<uint, access::read> after [[texture(3)]],")
        .replacingOccurrences(of: "centeredCost(a,b,origin,u.z,",with: "fourCost(a,b,before,after,origin,u.z,")
}()
