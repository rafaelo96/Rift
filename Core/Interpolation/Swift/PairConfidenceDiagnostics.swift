import Metal

// Read-only diagnostics. Canonical midpoint coordinates make the record reusable across subframes.
final class PairConfidenceDiagnostics {
    let output: MTLBuffer,temporal: MTLBuffer,pipeline: MTLComputePipelineState
    let width: Int,height: Int
    init(device: MTLDevice,width: Int,height: Int) throws {
        self.width=(width+7)/8;self.height=(height+7)/8
        guard let output=device.makeBuffer(length: self.width*self.height*32,options: .storageModeShared),let temporal=device.makeBuffer(length: self.width*self.height*16,options: .storageModeShared) else {throw MotionSearchEngine.EngineError.pipeline("Pair diagnostic allocation")}
        self.output=output;self.temporal=temporal
        let source=denseMotionMSL+"""
        float diagnosticDet(texture2d<float,access::sample> flow,float2 q) {
            float2 gx=(denseRead(flow,q+float2(1,0)).xy-denseRead(flow,q-float2(1,0)).xy)*0.25f;
            float2 gy=(denseRead(flow,q+float2(0,1)).xy-denseRead(flow,q-float2(0,1)).xy)*0.25f;
            return (1+gx.x)*(1+gy.y)-gy.x*gx.y;
        }
        kernel void pairConfidence(texture2d<float,access::sample> a [[texture(0)]],texture2d<float,access::sample> b [[texture(1)]],texture2d<float,access::sample> f [[texture(2)]],texture2d<float,access::sample> r [[texture(3)]],device float4 *out [[buffer(0)]],device const float4 *temporal [[buffer(1)]],constant float &offset [[buffer(2)]],uint2 block [[thread_position_in_grid]]) {
            uint w=a.get_width(),h=a.get_height(),gw=(w+7)/8,gh=(h+7)/8;
            if(block.x>=gw || block.y>=gh) return;
            float2 p=min(float2(block*8+4),float2(w-1,h-1));
            float2 q0=denseInverse(f,p,0.5f),q1=denseInverse(r,p,0.5f);
            float4 v=denseRead(f,q0),u=denseRead(r,q1);
            float fb=(length(v.xy+denseRead(r,q0+v.xy).xy)+length(u.xy+denseRead(f,q1+u.xy).xy))*0.5f;
            float inversion=(length(q0+0.5f*v.xy-p)+length(q1+0.5f*u.xy-p))*0.5f;
            float folds=0;
            float2 probes[5]={float2(0),float2(-3,-3),float2(3,-3),float2(-3,3),float2(3,3)};
            for(uint j=0;j<5;++j) folds+=diagnosticDet(f,q0+probes[j])<=0.05f || diagnosticDet(r,q1+probes[j])<=0.05f ? 0.2f : 0;
            float sad=0,ab=0,mean=0,m2=0,count=0;
            for(int y=0;y<8;++y) for(int x=0;x<8;++x) {
                uint2 pixel=block*8+uint2(x,y);if(pixel.x>=w || pixel.y>=h) continue;
                float2 d=float2(pixel)-p;float av=denseRead(a,q0+d).r,bv=denseRead(b,q1+d).r;
                sad+=abs(av-bv+offset);ab+=abs(denseRead(a,float2(pixel)).r-denseRead(b,float2(pixel)).r);count+=1;float delta=av-mean;mean+=delta/count;m2+=delta*(av-mean);
            }
            float texture=sqrt(max(0.0f,m2/count));
            int2 c0=clamp(int2(q0)/8,int2(0),int2(gw-1,gh-1)),c1=clamp(int2(q1)/8,int2(0),int2(gw-1,gh-1));
            float2 t0=temporal[c0.y*gw+c0.x].xy,t1=temporal[c1.y*gw+c1.x].zw;
            float disagreement=(length(v.xy-t0)+length(u.xy-t1))*0.5f;
            uint k=2*(block.y*gw+block.x);
            out[k]=float4(fb,(sad/count)/(texture+1.0f/1023),folds,inversion);
            out[k+1]=float4(disagreement,ab/count,texture,1-(v.z+u.z)*0.5f);
        }
        """
        let library=try device.makeLibrary(source: source,options: nil)
        pipeline=try device.makeComputePipelineState(function: library.makeFunction(name: "pairConfidence")!)
    }
    func encode(command: MTLCommandBuffer,images: [MTLTexture],fields: [MTLTexture],vectors: [SIMD4<Float>]?,offset: Float) throws {
        let n=width*height
        if let vectors {guard vectors.count==n,vectors.allSatisfy({[$0.x,$0.y,$0.z,$0.w].allSatisfy {$0.isFinite || $0.isNaN}}) else {throw MotionSearchEngine.EngineError.pipeline("Invalid diagnostic temporal vectors")}}
        let values=vectors ?? Array(repeating: SIMD4<Float>(repeating: .nan),count: n)
        values.withUnsafeBytes {memcpy(temporal.contents(),$0.baseAddress!,$0.count)}
        guard let e=command.makeComputeCommandEncoder() else {throw MotionSearchEngine.EngineError.pipeline("Pair diagnostic encoder")}
        e.setComputePipelineState(pipeline)
        for (i,t) in (Array(images.prefix(2))+fields).enumerated() {e.setTexture(t,index: i)}
        e.setBuffer(output,offset: 0,index: 0);e.setBuffer(temporal,offset: 0,index: 1);var offset=offset;e.setBytes(&offset,length: 4,index: 2)
        e.dispatchThreads(MTLSize(width: width,height: height,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1));e.endEncoding()
    }
    func read() -> [SIMD4<Float>] {Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self),count: width*height*2))}
}
