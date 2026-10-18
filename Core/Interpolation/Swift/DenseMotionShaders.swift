import Foundation

// Classical iterative LK; pixel coordinates address texel centers explicitly.
public let denseMotionMSL = """
#include <metal_stdlib>
using namespace metal;
// Diagnostic variant records evaluated proposals, including rejected ones. Compiles away by default.
#ifdef DENSE_CANDIDATES
#define TRACE_ARG , device float4 *trace [[buffer(10)]]
#define TRACE(slot, vector, cost, admitted) trace[(p.y*patchWidth+p.x)*16+(slot)]=float4(vector,cost,admitted)
#else
#define TRACE_ARG
#define TRACE(slot, vector, cost, admitted)
#endif
constexpr sampler linearPixel(coord::pixel,address::clamp_to_edge,filter::linear);
float4 denseRead(texture2d<float,access::sample> image,float2 p) { return image.sample(linearPixel,p+0.5f); }
kernel void denseUpload(texture2d<uint,access::read> input [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    output.write(float(input.read(p).r)/1023.0f,p);
}
kernel void denseDown(texture2d<float,access::sample> input [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    float2 q=float2(p)*2+0.5f;
    const float weights[5]={1,4,6,4,1};
    float v=0;
    for(int y=-2;y<=2;++y) for(int x=-2;x<=2;++x) v+=weights[x+2]*weights[y+2]*denseRead(input,q+float2(x,y)).r/256;
    output.write(v,p);
}
kernel void denseAnalysisBlur(texture2d<float,access::sample> input [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],constant float &offset [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    const float weights[5]={1,4,6,4,1};
    float value=0;
    for(int y=-2;y<=2;++y) for(int x=-2;x<=2;++x) value+=weights[x+2]*weights[y+2]*denseRead(input,float2(p)+float2(x,y)).r/256;
    output.write(value-offset,p);
}
kernel void denseSeed(device const int2 *mv [[buffer(0)]],constant uint4 &u [[buffer(1)]],texture2d<float,access::write> output [[texture(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    uint2 cell=min(uint2((float2(p)+0.5f)*float(u.w)/float(u.z)),u.xy-1);
    output.write(float4(float2(mv[cell.y*u.x+cell.x])/(2.0f*float(u.w)),0,0),p);
}
float densePatchCost(texture2d<float,access::sample> a,texture2d<float,access::sample> b,float2 center,float2 v) {
    float cost=0;
    for(int y=-4;y<4;++y) for(int x=-4;x<4;++x) {
        float2 q=center+float2(x,y); float error=denseRead(a,q).r-denseRead(b,q+v).r;
        cost+=error*error;
    }
    return cost/64;
}
kernel void densePatchSearch(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> seed [[texture(2)]],texture2d<float,access::write> patches [[texture(3)]],uint2 p [[thread_position_in_grid]] TRACE_ARG) {
    if(p.x>=patches.get_width()||p.y>=patches.get_height()) return;
    uint patchWidth=patches.get_width();
    float2 center=float2(p)*4,v=denseRead(seed,center).xy;
    float best=densePatchCost(a,b,center,v);
    TRACE(0,v,best,1);
    const float2 neighbors[5]={float2(-4,0),float2(4,0),float2(0,-4),float2(0,4),float2(0)};
    for(int i=0;i<5;++i) {
        float2 candidate=i==4 ? float2(0) : denseRead(seed,center+neighbors[i]).xy;
        float cost=densePatchCost(a,b,center,candidate);
        TRACE(i+1,candidate,cost,1);
        if(cost<best) { best=cost; v=candidate; }
    }
    float values[64]; float2 gradients[64]; float hxx=0,hxy=0,hyy=0;
    for(int y=-4;y<4;++y) for(int x=-4;x<4;++x) {
        int k=(y+4)*8+x+4; float2 q=center+float2(x,y);
        values[k]=denseRead(a,q).r;
        float2 g=float2(denseRead(a,q+float2(1,0)).r-denseRead(a,q-float2(1,0)).r,denseRead(a,q+float2(0,1)).r-denseRead(a,q-float2(0,1)).r)*0.5f;
        gradients[k]=g; hxx+=g.x*g.x; hxy+=g.x*g.y; hyy+=g.y*g.y;
    }
    float det=hxx*hyy-hxy*hxy;
    if(det>1e-8f) for(int iteration=0;iteration<8;++iteration) {
        float2 rhs=0;
        for(int y=-4;y<4;++y) for(int x=-4;x<4;++x) {
            int k=(y+4)*8+x+4;
            rhs+=gradients[k]*(values[k]-denseRead(b,center+float2(x,y)+v).r);
        }
        float2 step=float2(hyy*rhs.x-hxy*rhs.y,hxx*rhs.y-hxy*rhs.x)/det;
        step/=max(1.0f,length(step)/2.0f);
        float2 candidate=v+step; float cost=densePatchCost(a,b,center,candidate);
        TRACE(iteration+6,candidate,cost,1);
        if(cost>=best) break;
        best=cost; v=candidate;
        if(dot(step,step)<1e-5f) break;
    }
    patches.write(float4(v,exp(-20*sqrt(best)),best),p);
}
kernel void densePatchPropagate(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> input [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],uint2 p [[thread_position_in_grid]] TRACE_ARG) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    uint patchWidth=output.get_width();
    float2 center=float2(p)*4,v=denseRead(input,float2(p)).xy;
    float best=densePatchCost(a,b,center,v);
    TRACE(0,v,best,1);
    const float2 neighbors[4]={float2(-1,0),float2(1,0),float2(0,-1),float2(0,1)};
    for(int i=0;i<4;++i) {
        float2 candidate=denseRead(input,float2(p)+neighbors[i]).xy;
        float cost=densePatchCost(a,b,center,candidate);
        TRACE(i+1,candidate,cost,1);
        if(cost<best) { best=cost; v=candidate; }
    }
    output.write(float4(v,exp(-20*sqrt(best)),best),p);
}
kernel void densePatchAffine(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> input [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],texture2d<float,access::write> jacobian [[texture(4)]],texture2d<float,access::sample> detailA [[texture(5)]],texture2d<float,access::sample> detailB [[texture(6)]],device const int2 *seeds [[buffer(0)]],constant uint4 &geometry [[buffer(1)]],constant float &exposure [[buffer(2)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    float4 selected=denseRead(input,float2(p)),gradient=0;
    float2 center=float2(p)*4;
    if(all(geometry.xy>=3u)) {
        uint2 anchor=clamp(uint2((center+0.5f)*float(geometry.w)/float(geometry.z)),uint2(1),geometry.xy-2);
        float2 mean=0,gx=0,gy=0;
        for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
            uint2 q=uint2(int2(anchor)+int2(x,y)); float2 v=float2(seeds[q.y*geometry.x+q.x])*0.5f;
            mean+=v/9; gx+=float(x)*v/6; gy+=float(y)*v/6;
        }
        float residual=0;
        for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
            uint2 q=uint2(int2(anchor)+int2(x,y)); float2 v=float2(seeds[q.y*geometry.x+q.x])*0.5f;
            residual=max(residual,length(v-mean-float(x)*gx-float(y)*gy));
        }
        if(residual<=1) {
            float2 delta=(center+0.5f)*float(geometry.w)/float(geometry.z)-0.5f-float2(anchor);
            float2 v=(mean+delta.x*gx+delta.y*gy)/float(geometry.w);
            float2 dx=gx/float(geometry.z),dy=gy/float(geometry.z);
            float cost=0;
            for(int y=-4;y<4;++y) for(int x=-4;x<4;++x) {
                float2 offset=float2(x,y),q=center+offset;
                float error=denseRead(a,q).r-denseRead(b,q+v+float(x)*dx+float(y)*dy).r;
                cost+=error*error/64;
            }
            if(cost<densePatchCost(a,b,center,selected.xy)) {
                float oldDetail=0,newDetail=0,scale=float(geometry.w);
                for(int y=-4;y<4;++y) for(int x=-4;x<4;++x) {
                    float2 q=(center+float2(x,y)+0.5f)*scale-0.5f;
                    float value=denseRead(detailA,q).r;
                    float oldError=value-denseRead(detailB,q+selected.xy*scale).r+exposure;
                    float newError=value-denseRead(detailB,q+(v+float(x)*dx+float(y)*dy)*scale).r+exposure;
                    oldDetail+=oldError*oldError;newDetail+=newError*newError;
                }
                if(newDetail<oldDetail) { selected=float4(v,exp(-20*sqrt(cost)),cost); gradient=float4(dx,dy); }
            }
        }
    }
    output.write(selected,p); jacobian.write(gradient,p);
}
float denseTemporalPatchCost(texture2d<float,access::sample> a,texture2d<float,access::sample> b,texture2d<float,access::sample> before,texture2d<float,access::sample> after,float2 center,float2 v,float2 intervals) {
    float cost=densePatchCost(a,b,center,v),evidence=0,weight=0;
    for(int neighbor=0;neighbor<2;++neighbor) {
        float interval=intervals[neighbor];
        if(interval==0) continue;
        float residual=0,count=0;
        for(int y=-4;y<4;++y) for(int x=-4;x<4;++x) {
            float2 q=center+float2(x,y),r=q+interval*v;
            if(any(r<0)||r.x>float(a.get_width()-1)||r.y>float(a.get_height()-1)) continue;
            float target=neighbor==0 ? denseRead(before,r).r : denseRead(after,r).r;
            float error=denseRead(a,q).r-target;
            residual+=min(error*error,0.01f); count+=1;
        }
        if(count>0) {
            float w=1/max(1.0f,abs(interval));
            evidence+=w*residual/count; weight+=w;
        }
    }
    return cost+(weight>0 ? 0.5f*evidence/weight : 0);
}
kernel void densePatchTemporalSelect(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> input [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],texture2d<float,access::sample> before [[texture(4)]],texture2d<float,access::sample> after [[texture(5)]],constant float2 &intervals [[buffer(0)]],uint2 p [[thread_position_in_grid]] TRACE_ARG) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    uint patchWidth=output.get_width();
    float2 center=float2(p)*4,v=denseRead(input,float2(p)).xy;
    float central=densePatchCost(a,b,center,v);
    float best=denseTemporalPatchCost(a,b,before,after,center,v,intervals);
    TRACE(0,v,best,1);
    const float2 neighbors[4]={float2(-1,0),float2(1,0),float2(0,-1),float2(0,1)};
    for(int i=0;i<4;++i) {
        float2 candidate=denseRead(input,float2(p)+neighbors[i]).xy;
        float cc=densePatchCost(a,b,center,candidate);
        TRACE(i+1,candidate,cc,cc<=central+4.0f/(1023.0f*1023.0f) ? 1 : -1);
        if(cc>central+4.0f/(1023.0f*1023.0f)) continue;
        float cost=denseTemporalPatchCost(a,b,before,after,center,candidate,intervals);
        if(cost<best) { best=cost; v=candidate; }
    }
    output.write(float4(v,exp(-20*sqrt(best)),best),p);
}
float4 denseAggregatePatch(texture2d<float,access::sample> a,texture2d<float,access::sample> b,texture2d<float,access::sample> patches,texture2d<float,access::sample> jacobian,bool affine,uint2 p) {
    float2 sum=0; float total=0;
    uint2 base=p/4;
    float2 winner=0; float best=INFINITY;
    float source[9];
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) source[(y+1)*3+x+1]=denseRead(a,float2(p)+float2(x,y)).r;
    float4 candidates[4]; float errors[4];
    for(uint y=0;y<2;++y) for(uint x=0;x<2;++x) {
        float4 patch=denseRead(patches,float2(base+uint2(x,y)));
        if(affine) {
            float4 g=denseRead(jacobian,float2(base+uint2(x,y)));
            float2 delta=float2(p)-float2(base+uint2(x,y))*4;
            patch.xy+=delta.x*g.xy+delta.y*g.zw;
        }
        float residual=0;
        for(int yy=-1;yy<=1;++yy) for(int xx=-1;xx<=1;++xx) residual+=abs(source[(yy+1)*3+xx+1]-denseRead(b,float2(p)+patch.xy+float2(xx,yy)).r);
        residual/=9;
        candidates[y*2+x]=patch; errors[y*2+x]=residual;
        float error=residual+sqrt(max(0.0f,patch.w));
        if(error<best) { best=error; winner=patch.xy; }
    }
    for(uint y=0;y<2;++y) for(uint x=0;x<2;++x) {
        float4 patch=candidates[y*2+x];
        // Aggregate only one velocity hypothesis; a layer boundary is not an intermediate motion.
        if(length(patch.xy-winner)>=1) continue;
        float error=errors[y*2+x];
        float weight=1/max(0.01f,error);
        sum+=weight*patch.xy; total+=weight;
    }
    return float4(sum/total,1,0);
}
kernel void densePatchAggregate(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> patches [[texture(2)]],texture2d<float,access::write> field [[texture(3)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=field.get_width()||p.y>=field.get_height()) return;
    field.write(denseAggregatePatch(a,b,patches,patches,false,p),p);
}
kernel void densePatchAggregateAffine(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> patches [[texture(2)]],texture2d<float,access::write> field [[texture(3)]],texture2d<float,access::sample> jacobian [[texture(4)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=field.get_width()||p.y>=field.get_height()) return;
    field.write(denseAggregatePatch(a,b,patches,jacobian,true,p),p);
}
kernel void denseExpand(texture2d<float,access::sample> coarse [[texture(0)]],texture2d<float,access::write> fine [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=fine.get_width()||p.y>=fine.get_height()) return;
    // Nearest propagation avoids inventing a velocity between two layers.
    float2 q=floor(float2(p)*0.5f);
    float4 value=denseRead(coarse,q);
    fine.write(float4(value.xy*2,value.zw),p);
}
kernel void denseLK(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> input [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],texture2d<float,access::sample> before [[texture(4)]],texture2d<float,access::sample> after [[texture(5)]],constant float2 &intervals [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    float2 center=float2(p),v=denseRead(input,center).xy;
    float level=denseRead(a,center).r;
    float hxx=0,hxy=0,hyy=0,bx=0,by=0,residual=0,total=0;
    for(int y=-2;y<=2;++y) for(int x=-2;x<=2;++x) {
        float2 q=center+float2(x,y),r=q+v;
        float av=denseRead(a,q).r,bv=denseRead(b,r).r;
        float gx=(denseRead(b,r+float2(1,0)).r-denseRead(b,r-float2(1,0)).r)*0.5f;
        float gy=(denseRead(b,r+float2(0,1)).r-denseRead(b,r-float2(0,1)).r)*0.5f;
        float e=av-bv;
        float w=exp(-10.0f*abs(av-level))/max(0.02f,abs(e));
        hxx+=w*gx*gx; hxy+=w*gx*gy; hyy+=w*gy*gy;
        bx+=w*gx*e; by+=w*gy*e;
        residual+=w*abs(e); total+=w;
        if(intervals.x!=0) {
            for(int neighbor=0;neighbor<2;++neighbor) {
                float scale=intervals[neighbor]; float2 s=q+scale*v;
                uint width=a.get_width(),height=a.get_height();
                if(s.x<1||s.y<1||s.x>=float(width-1)||s.y>=float(height-1)) continue;
                float nv=neighbor==0 ? denseRead(before,s).r : denseRead(after,s).r;
                // A retained neighbor belongs to its nearest endpoint, not always to the source.
                float heldScale=scale<0 ? 0.0f : 1.0f;
                float2 heldPosition=q+heldScale*v;
                float held=neighbor==0 ? denseRead(before,heldPosition).r : denseRead(after,heldPosition).r;
                if(abs(av-held)<abs(av-nv)) continue;
                float nx=neighbor==0 ? denseRead(before,s+float2(1,0)).r-denseRead(before,s-float2(1,0)).r : denseRead(after,s+float2(1,0)).r-denseRead(after,s-float2(1,0)).r;
                float ny=neighbor==0 ? denseRead(before,s+float2(0,1)).r-denseRead(before,s-float2(0,1)).r : denseRead(after,s+float2(0,1)).r-denseRead(after,s-float2(0,1)).r;
                float error=av-nv;
                float weight=0.5f*exp(-10*abs(av-level)-20*abs(error))/max(0.02f,abs(error));
                nx*=0.5f*scale; ny*=0.5f*scale;
                hxx+=weight*nx*nx; hxy+=weight*nx*ny; hyy+=weight*ny*ny;
                bx+=weight*nx*error; by+=weight*ny*error;
            }
        }
    }
    float trace=hxx+hyy,det=hxx*hyy-hxy*hxy;
    float2 update=0;
    if(det>1e-8f) {
        float damping=1e-4f;
        float den=(hxx+damping)*(hyy+damping)-hxy*hxy;
        update=float2((hyy+damping)*bx-hxy*by,(hxx+damping)*by-hxy*bx)/den;
        update/=max(1.0f,length(update));
    }
    float eigen=(trace-sqrt(max(0.0f,(hxx-hyy)*(hxx-hyy)+4*hxy*hxy)))*0.5f;
    float confidence=det>1e-8f ? clamp(2*eigen/max(trace,1e-8f),0.0f,1.0f) : 0;
    output.write(float4(v+update,confidence,residual/max(total,1e-8f)),p);
}
kernel void denseRegularize(texture2d<float,access::sample> guide [[texture(0)]],texture2d<float,access::sample> input [[texture(1)]],texture2d<float,access::write> output [[texture(2)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    float2 center=float2(p);
    float level=denseRead(guide,center).r;
    float4 current=denseRead(input,center);
    float2 sum=0; float total=0;
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        float2 q=center+float2(x,y);
        float4 candidate=denseRead(input,q);
        float weight=exp(-20*abs(denseRead(guide,q).r-level))*(0.05f+candidate.z);
        sum+=weight*candidate.xy; total+=weight;
    }
    output.write(float4(sum/max(total,1e-8f),current.zw),p);
}
// Independently implemented TV-L1 proximal data step and dual TV projection.
kernel void denseTVReset(texture2d<float,access::write> output [[texture(0)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x<output.get_width()&&p.y<output.get_height()) output.write(float4(0),p);
}
kernel void denseTVLinearize(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> flow [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],texture2d<float,access::sample> opposite [[texture(4)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    float2 v=denseRead(flow,float2(p)).xy,q=float2(p)+v;
    if(q.x<0||q.y<0||q.x>float(b.get_width()-1)||q.y>float(b.get_height()-1)) { output.write(float4(0),p); return; }
    float closure=length(v+denseRead(opposite,q).xy);
    if(closure>2.0f) { output.write(float4(0),p); return; } // Inpaint hidden correspondences, do not force a false photometric match.
    float2 g=float2(denseRead(b,q+float2(1,0)).r-denseRead(b,q-float2(1,0)).r,denseRead(b,q+float2(0,1)).r-denseRead(b,q-float2(0,1)).r)*0.5f;
    float rho=denseRead(b,q).r-denseRead(a,float2(p)).r-dot(g,v);
    output.write(float4(g,rho,dot(g,g)),p);
}
kernel void denseTVPrimal(texture2d<float,access::sample> input [[texture(0)]],texture2d<float,access::read> dual [[texture(1)]],texture2d<float,access::read> linear [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    float4 old=denseRead(input,float2(p)),l=linear.read(p),here=dual.read(p);
    float4 left=p.x>0 ? dual.read(p-uint2(1,0)) : float4(0);
    float4 up=p.y>0 ? dual.read(p-uint2(0,1)) : float4(0);
    float2 div=float2(here.x-left.x+here.y-up.y,here.z-left.z+here.w-up.w);
    float2 provisional=old.xy+0.3f*div;
    float rho=l.z+dot(l.xy,provisional);
    // Images normalized to 0...1: lambda=.15*255, theta=.3.
    float factor=l.w>1e-10f ? clamp(-rho/l.w,-11.475f,11.475f) : 0;
    output.write(float4(provisional+factor*l.xy,old.zw),p);
}
kernel void denseTVDual(texture2d<float,access::read> flow [[texture(0)]],texture2d<float,access::read> input [[texture(1)]],texture2d<float,access::sample> guide [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],texture2d<float,access::read> previous [[texture(4)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    float2 v=2*flow.read(p).xy-previous.read(p).xy;
    float2 dx=p.x+1<output.get_width() ? 2*flow.read(p+uint2(1,0)).xy-previous.read(p+uint2(1,0)).xy-v : float2(0);
    float2 dy=p.y+1<output.get_height() ? 2*flow.read(p+uint2(0,1)).xy-previous.read(p+uint2(0,1)).xy-v : float2(0);
    float4 old=input.read(p);
    float2 p0=old.xy+(0.1f/0.3f)*float2(dx.x,dy.x);
    float2 p1=old.zw+(0.1f/0.3f)*float2(dx.y,dy.y);
    float a=denseRead(guide,float2(p)).r;
    float edge=abs(denseRead(guide,float2(p)+float2(1,0)).r-a)+abs(denseRead(guide,float2(p)+float2(0,1)).r-a);
    float radius=max(0.05f,exp(-10*edge));
    p0/=max(1.0f,length(p0)/radius); p1/=max(1.0f,length(p1)/radius);
    if(p.x+1==output.get_width()) { p0.x=0; p1.x=0; }
    if(p.y+1==output.get_height()) { p0.y=0; p1.y=0; }
    output.write(float4(p0,p1),p);
}
kernel void denseTVAssess(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> input [[texture(2)]],texture2d<float,access::write> output [[texture(3)]],texture2d<float,access::sample> opposite [[texture(4)]],uint2 p [[thread_position_in_grid]]) {
    if(p.x>=output.get_width()||p.y>=output.get_height()) return;
    float2 v=denseRead(input,float2(p)).xy;
    float residual=0;
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) { float2 q=float2(p)+float2(x,y); residual+=abs(denseRead(a,q).r-denseRead(b,q+v).r); }
    residual/=9;
    bool hidden=length(v+denseRead(opposite,float2(p)+v).xy)>2.0f;
    float variance=0,total=0,level=denseRead(a,float2(p)).r;
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        float2 q=float2(p)+float2(x,y),delta=denseRead(input,q).xy-v;
        float weight=exp(-20*abs(denseRead(a,q).r-level));
        variance+=weight*dot(delta,delta); total+=weight;
    }
    float prior=exp(-variance/max(total*(0.25f+0.01f*dot(v,v)),1e-8f));
    // Negative w marks a hidden counterpart; z is spatial support in that case.
    output.write(float4(v,hidden ? prior : exp(-20*residual),hidden ? -1-residual : residual),p);
}
bool denseInside(float2 p,uint w,uint h) { return all(p>=0)&&p.x<=float(w-1)&&p.y<=float(h-1); }
kernel void denseTemporalAssess(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::sample> before [[texture(1)]],texture2d<float,access::sample> after [[texture(2)]],texture2d<float,access::sample> input [[texture(3)]],texture2d<float,access::write> output [[texture(4)]],constant float2 &intervals [[buffer(0)]],constant float2 &exposure [[buffer(1)]],uint2 gid [[thread_position_in_grid]]) {
    uint w=output.get_width(),h=output.get_height();
    if(gid.x>=w||gid.y>=h) return;
    float2 p=float2(gid); float4 field=denseRead(input,p);
    float2 q0=p+intervals.x*field.xy,q1=p+intervals.y*field.xy;
    float e0=0,e1=0,held0=0,held1=0;
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        float2 d=float2(x,y); float a=denseRead(source,p+d).r;
        e0+=abs(a-denseRead(before,q0+d).r+exposure.x); e1+=abs(a-denseRead(after,q1+d).r+exposure.y);
        held0+=abs(a-denseRead(before,p+d+(intervals.x<0 ? 0.0f : 1.0f)*field.xy).r);
        held1+=abs(a-denseRead(after,p+d+(intervals.y<0 ? 0.0f : 1.0f)*field.xy).r);
    }
    e0=denseInside(q0,w,h) ? e0/9 : 1;
    e1=denseInside(q1,w,h) ? e1/9 : 1;
    if(field.w>=0 && held0/9<e0 && held1/9<e1) { e0=held0/9; e1=held1/9; }
    // One neighbor may be occluded too; require evidence from at least one.
    float evidence=min(e0,e1);
    field.z*=exp(-20*evidence);
    // Failed central closure alone is insufficient evidence of a visible surface.
    if(field.w<0 && evidence>0.03f) field.w=-1-field.w;
    output.write(field,gid);
}
float2 denseInverse(texture2d<float,access::sample> flow,float2 p,float amount) {
    float2 q=p-amount*denseRead(flow,p).xy;
    for(int iteration=0;iteration<6;++iteration) {
        float2 v=denseRead(flow,q).xy;
        float2 error=p-q-amount*v;
        if(dot(error,error)<1e-6f) break;
        float2 gx=(denseRead(flow,q+float2(1,0)).xy-denseRead(flow,q-float2(1,0)).xy)*0.5f;
        float2 gy=(denseRead(flow,q+float2(0,1)).xy-denseRead(flow,q-float2(0,1)).xy)*0.5f;
        float a=1+amount*gx.x,b=amount*gy.x,c=amount*gx.y,d=1+amount*gy.y;
        float det=a*d-b*c;
        if(det<=0.05f) break; // Folded mappings do not certify a visible surface.
        float2 step=float2(d*error.x-b*error.y,a*error.y-c*error.x)/det;
        step/=max(1.0f,length(step)/4.0f);
        bool accepted=false;
        for(int line=0;line<3;++line) {
            float2 candidate=q+step;
            float2 residual=p-candidate-amount*denseRead(flow,candidate).xy;
            if(dot(residual,residual)<dot(error,error)) { q=candidate; accepted=true; break; }
            step*=0.5f;
        }
        if(!accepted) break;
    }
    return q;
}
float denseMatch(texture2d<float,access::sample> a,texture2d<float,access::sample> b,float2 q0,float2 q1,float offset=0) {
    float cost=0;
    for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) { float2 d=float2(x,y); cost+=abs(denseRead(a,q0+d).r-denseRead(b,q1+d).r+offset); }
    return cost/9;
}
float denseStaticPatchCost(texture2d<float,access::sample> a,texture2d<float,access::sample> b,float2 q0,float2 q1) {
    float cost=0;
    for(int y=-4;y<4;++y) for(int x=-4;x<4;++x) {
        float2 d=float2(x,y); cost+=abs(denseRead(a,q0+d).r-denseRead(b,q1+d).r);
    }
    return cost/64;
}
bool denseSurfaceMembership(texture2d<float,access::sample> flow,float2 q,float2 velocity) {
    float2 anchor=round(q),center=denseRead(flow,anchor).xy;
    if(length(center-velocity)<1) return true;
    // Continuous affine motion belongs to one surface, unlike a blended jump.
    float2 gx=(denseRead(flow,anchor+float2(1,0)).xy-denseRead(flow,anchor-float2(1,0)).xy)*0.5f;
    float2 gy=(denseRead(flow,anchor+float2(0,1)).xy-denseRead(flow,anchor-float2(0,1)).xy)*0.5f;
    float2 delta=q-anchor;
    return length(center+delta.x*gx+delta.y*gy-velocity)<1;
}
kernel void denseProject(texture2d<float,access::sample> source [[texture(0)]],texture2d<float,access::sample> target [[texture(1)]],texture2d<float,access::sample> flow [[texture(2)]],texture2d<float,access::sample> opposite [[texture(3)]],device atomic_uint *ownership [[buffer(0)]],constant uint &indexBits [[buffer(1)]],constant float &amount [[buffer(2)]],constant float &offset [[buffer(3)]],uint2 gid [[thread_position_in_grid]]) {
    uint w=source.get_width(),h=source.get_height();
    if(gid.x>=w||gid.y>=h) return;
    float2 q=float2(gid); float4 f=denseRead(flow,q);
    float2 end=q+f.xy;
    if(f.z<=0.02f) return;
    bool paired=denseInside(end,w,h);
    if(!paired && f.w>=0) return;
    float4 reverse=denseRead(opposite,end);
    if(paired && (length(f.xy+reverse.xy)>=1 || reverse.z<=0.02f)) return;
    // A consistent surface covers/unveils a different, hidden trajectory.
    float4 covered=denseRead(flow,end),uncovered=denseRead(opposite,q);
    bool foreground=(paired && covered.w<0 && length(covered.xy-f.xy)>1) || (uncovered.w<0 && length(uncovered.xy+f.xy)>1);
    if(!foreground) return;
    float cost=paired ? denseMatch(source,target,q,end,offset) : 0;
    if(cost>=0.08f) return;
    uint band=((1u<<(32-indexBits))-1u)/4u;
    float quality=(paired ? min(f.z,reverse.z) : f.z)*exp(-20*cost);
    float2 projected=q+amount*f.xy,base=floor(projected),fraction=projected-base;
    for(uint y=0;y<2;++y) for(uint x=0;x<2;++x) {
        float2 p=base+float2(x,y);
        if(!denseInside(p,w,h)) continue;
        float coverage=(x==0 ? 1-fraction.x : fraction.x)*(y==0 ? 1-fraction.y : fraction.y);
        if(coverage<=0) continue;
        uint score=(paired?3u:2u)*band+uint(float(band-1)*quality*coverage);
        uint key=(score<<indexBits)|(gid.y*w+gid.x+1u);
        // Integer max makes the winner independent of thread scheduling.
        atomic_fetch_max_explicit(&ownership[uint(p.y)*w+uint(p.x)],key,memory_order_relaxed);
    }
}
kernel void denseSynthesize(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> forward [[texture(2)]],texture2d<float,access::sample> backward [[texture(3)]],texture2d<uint,access::write> output [[texture(4)]],texture2d<float,access::write> reliability [[texture(5)]],texture2d<float,access::write> mappingResidual [[texture(6)]],texture2d<float,access::write> coordinates [[texture(7)]],texture2d<float,access::write> blend [[texture(8)]],constant float &t [[buffer(0)]],constant uint2 &projection [[buffer(1)]],device const uint *ownership0 [[buffer(2)]],device const uint *ownership1 [[buffer(3)]],constant float &offset [[buffer(4)]],uint2 gid [[thread_position_in_grid]] TRACE_ARG) {
    uint w=output.get_width(),h=output.get_height();
    if(gid.x>=w||gid.y>=h) return;
    float2 p=float2(gid);
    float av=denseRead(a,p).r,bv=denseRead(b,p).r;
    #ifdef DENSE_CANDIDATES
    trace[2*(gid.y*w+gid.x)]=float4(0);
    trace[2*(gid.y*w+gid.x)+1]=float4(0);
#endif
    if(t==0 || t==1) { output.write(uint((t==0?av:bv)*1023+0.5f),gid); reliability.write(1.0f,gid); mappingResidual.write(float4(0),gid); coordinates.write(float4(0),gid); blend.write(t,gid); return; }
    float2 q0=denseInverse(forward,p,t),q1=denseInverse(backward,p,1-t);
    const float2 initialQ0=q0,initialQ1=q1;
#ifdef DENSE_CANDIDATES
    trace[2*(gid.y*w+gid.x)]=float4(q0-p,q1-p);
#endif
    float2 initial0=denseRead(forward,q0).xy,initial1=-denseRead(backward,q1).xy;
    bool owned=false; float ownerValue=0,ownerConfidence=0,ownerAlpha=0;
    // Bilinear flow at a layer boundary can hide a large motion discontinuity.
    // Inspect ownership whenever the inverses fail to describe the same path.
    float initialClosure0=length(initial0+denseRead(backward,q0+initial0).xy);
    float initialClosure1=length(initial1-denseRead(forward,q1-initial1).xy);
    if(length(initial0-initial1)>0.5f || initialClosure0>1 || initialClosure1>1) {
        float best=denseMatch(a,b,q0,q1,offset); int rank=0;
        const float2 offsets[5]={float2(0),float2(-2,0),float2(2,0),float2(0,-2),float2(0,2)};
        for(int i=0;i<10;++i) {
            float2 velocity=i<5 ? denseRead(forward,initialQ0+offsets[i]).xy : -denseRead(backward,initialQ1+offsets[i-5]).xy;
            float2 a0=p-t*velocity,b1=p+(1-t)*velocity;
            float4 fa=denseRead(forward,a0),fb=denseRead(backward,b1);
            bool has0=denseInside(a0,w,h)&&length(fa.xy-velocity)<1.0f&&fa.z>0.02f;
            bool has1=denseInside(b1,w,h)&&length(fb.xy+velocity)<1.0f&&fb.z>0.02f;
            // A bilinear mixture at a motion boundary is not a new surface.
            bool surface0=has0&&denseSurfaceMembership(forward,a0,velocity);
            bool surface1=has1&&denseSurfaceMembership(backward,b1,-velocity);
            if(has0&&has1) {
                float cost=denseMatch(a,b,a0,b1,offset);
                if(cost<0.08f && (rank<2 || cost<best)) {
                    rank=2; best=cost; owned=true;
                    ownerValue=(1-t)*denseRead(a,a0).r+t*denseRead(b,b1).r;
                    ownerConfidence=min(fa.z,fb.z); ownerAlpha=t; q0=a0; q1=b1;
                }
            } else if(rank<2 && ((surface0&&fa.w<0)||(surface1&&fb.w<0))) {
                bool fromFirst=surface0&&fa.w<0;
                float confidence=fromFirst ? fa.z : fb.z;
                if(rank==0 || confidence>ownerConfidence) {
                    rank=1; owned=true; ownerConfidence=confidence;
                    ownerValue=fromFirst ? denseRead(a,a0).r : denseRead(b,b1).r; ownerAlpha=fromFirst ? 0 : 1;
                    q0=a0; q1=b1;
                }
            }
        }
    }
    if(projection.y!=0) {
        uint band=((1u<<(32-projection.x))-1u)/4u,mask=(1u<<projection.x)-1u,bestScore=0;
        for(uint direction=0;direction<2;++direction) {
            uint key=direction==0 ? ownership0[gid.y*w+gid.x] : ownership1[gid.y*w+gid.x];
            uint score=key>>projection.x,encoded=key&mask;
            if(encoded==0 || score<2u*band || score<=bestScore) continue;
            uint index=encoded-1u;
            float2 source=float2(index%w,index/w);
            float2 velocity=direction==0 ? denseRead(forward,source).xy : -denseRead(backward,source).xy;
            float2 a0=p-t*velocity,b1=p+(1-t)*velocity;
            bool visible0=denseInside(a0,w,h),visible1=denseInside(b1,w,h);
            if(!visible0&&!visible1) continue;
            bestScore=score; owned=true; ownerAlpha=visible0&&visible1 ? t : (visible0 ? 0 : 1);
            ownerValue=visible0&&visible1 ? (1-t)*denseRead(a,a0).r+t*denseRead(b,b1).r : (visible0 ? denseRead(a,a0).r : denseRead(b,b1).r);
            ownerConfidence=direction==0 ? denseRead(forward,source).z : denseRead(backward,source).z;
            q0=a0; q1=b1;
        }
    }
    float4 f=denseRead(forward,q0),r=denseRead(backward,q1);
    float error0=length(p-q0-t*f.xy),error1=length(p-q1-(1-t)*r.xy);
    mappingResidual.write(float4(error0,error1,0,0),gid);
    float v0=denseRead(a,q0).r,v1=denseRead(b,q1).r;
    float closure0=length(f.xy+denseRead(backward,q0+f.xy).xy);
    float closure1=length(r.xy+denseRead(forward,q1+r.xy).xy);
    float c0=denseInside(q0,w,h)&&denseInside(q0+f.xy,w,h) ? f.z*exp(-0.5f*(closure0*closure0+error0*error0)-5.0f*max(f.w,0.0f)) : 0;
    float c1=denseInside(q1,w,h)&&denseInside(q1+r.xy,w,h) ? r.z*exp(-0.5f*(closure1*closure1+error1*error1)-5.0f*max(r.w,0.0f)) : 0;
    // A surface leaving the crop still exists in its visible source frame.
    if(denseInside(q0,w,h)&&!denseInside(q0+f.xy,w,h)&&denseSurfaceMembership(forward,q0,f.xy)) c0=f.z*exp(-0.5f*error0*error0);
    if(denseInside(q1,w,h)&&!denseInside(q1+r.xy,w,h)&&denseSurfaceMembership(backward,q1,r.xy)) c1=r.z*exp(-0.5f*error1*error1);
    // Static protection requires agreement along both transport paths.
    bool still=abs(av-bv+offset)*16<=av+bv && abs(v0-denseRead(b,q0).r+offset)*16<=v0+denseRead(b,q0).r && abs(v1-denseRead(a,q1).r-offset)*16<=v1+denseRead(a,q1).r;
    // A near-periodic moving texture can look static at the original pixel.
    // Do not freeze it when compensation gives a clearly better correspondence.
    still=still && abs(av-bv+offset)<=2*abs(v0-v1+offset)+1.0f/1023.0f;
    // Verified moving patches with reciprocal flow must never be overridden by point-wise static protection.
    if(length(f.xy)>0.5f && length(r.xy)>0.5f && closure0<1.5f && closure1<1.5f && f.z>0.3f && r.z>0.3f) still=false;
    if(still && length(f.xy)>1 && length(r.xy)>1 && closure0<1 && closure1<1 && f.z>0.5f && r.z>0.5f) {
        if(denseStaticPatchCost(a,b,q0,q1)<0.8f*denseStaticPatchCost(a,b,p,p)) still=false;
    }
    float weights=(1-t)*c0+t*c1;
    float alpha=weights>1e-4f ? t*c1/weights : t;
    float value=weights>1e-4f ? ((1-t)*c0*v0+t*c1*v1)/weights : ((1-t)*v0+t*v1);
    if(owned) { value=ownerValue; weights=ownerConfidence; alpha=ownerAlpha; }
    if(still) { value=av+t*offset; q0=p; q1=p; alpha=offset!=0 ? t : 0; }
    #ifdef DENSE_CANDIDATES
    trace[2*(gid.y*w+gid.x)+1]=float4(still ? 1 : 0,weights,owned ? 1 : 0,alpha);
#endif
    coordinates.write(float4(q0-p,q1-p),gid); blend.write(alpha,gid);
    output.write(uint(clamp(value,0.0f,1.0f)*1023+0.5f),gid);
    reliability.write(still?1.0f:weights,gid);
}
"""
