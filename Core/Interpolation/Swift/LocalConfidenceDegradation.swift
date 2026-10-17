import Metal

// State belongs to the same serial owner as DenseMotionPrototype; resets never race an active pair.
final class LocalConfidenceDegradation {
    let map: MTLTexture
    private let states: [MTLTexture],pipelines: [String:MTLComputePipelineState],calibration: MTLBuffer,spans: MTLBuffer
    private let width: Int,height: Int
    private var slot=0
    init(device: MTLDevice,width: Int,height: Int) throws {
        self.width=width;self.height=height
        func texture(_ w: Int,_ h: Int) throws -> MTLTexture {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,width: w,height: h,mipmapped: false);d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite]
            guard let t=device.makeTexture(descriptor: d) else {throw MotionSearchEngine.EngineError.pipeline("Local confidence texture")};return t
        }
        map=try texture(width,height);states=try [texture((width+7)/8,(height+7)/8),texture((width+7)/8,(height+7)/8)]
        guard let calibration=E2Calibration.values.withUnsafeBytes({device.makeBuffer(bytes: $0.baseAddress!,length: $0.count,options: .storageModeShared)}),let spans=E2Calibration.spans.withUnsafeBytes({device.makeBuffer(bytes: $0.baseAddress!,length: $0.count,options: .storageModeShared)}) else {throw MotionSearchEngine.EngineError.pipeline("Confidence calibration allocation")}
        self.calibration=calibration;self.spans=spans
        let source=denseMotionMSL+"""
        float confidenceCDF(float x,uint feature,device const float2 *table,device const uint2 *ranges) {
            uint2 r=ranges[feature];uint lo=0,hi=r.y-1;
            if(x<table[r.x].x) return 0;if(x>table[r.x+hi].x) return 1;
            while(hi-lo>1) {uint mid=(lo+hi)/2;if(table[r.x+mid].x<=x) lo=mid;else hi=mid;}
            float2 a=table[r.x+lo],b=table[r.x+hi];return mix(a.y,b.y,clamp((x-a.x)/max(b.x-a.x,1e-30f),0.0f,1.0f));
        }
        kernel void localConfidenceUpdate(device const float4 *signals [[buffer(0)]],device const float2 *table [[buffer(1)]],device const uint2 *ranges [[buffer(2)]],constant float2 &geometry [[buffer(3)]],texture2d<float,access::sample> old [[texture(0)]],texture2d<float,access::write> next [[texture(1)]],texture2d<float,access::sample> forward [[texture(2)]],uint2 p [[thread_position_in_grid]]) {
            if(p.x>=next.get_width()||p.y>=next.get_height()) return;
            uint k=2*(p.y*next.get_width()+p.x);float4 a=signals[k],b=signals[k+1];
            float values[6]={a.x*geometry.x,a.y,a.z,a.w*geometry.x,b.x*geometry.x,b.y};float score=0,n=0;
            for(uint i=0;i<6;++i) if(isfinite(values[i])) {score+=confidenceCDF(values[i],i,table,ranges);n+=1;}
            score/=max(n,1.0f);
            float2 motion=denseRead(forward,float2(p)*8+4).xy;
            float4 previous=denseRead(old,float2(p)-geometry.y*motion/8);
            bool active=score>=0.905458547f || (previous.w>0.5f && score>0.844213010f);
            float target=active ? smoothstep(0.905458547f,0.943918959f,score) : 0;
            float weight=mix(previous.x,target,target>previous.x ? 0.35f : 0.15f);
            weight*=smoothstep(0.844213010f,0.905458547f,score);
            if(weight<1.0f/1023) weight=0;
            float mode=mix(previous.y,smoothstep(0.01f,0.03f,b.y),0.3f);
            next.write(float4(weight,mode,score,active ? 1 : 0),p);
        }
        kernel void localConfidenceFeather(texture2d<float,access::sample> state [[texture(0)]],texture2d<float,access::write> result [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
            if(p.x>=result.get_width()||p.y>=result.get_height()) return;
            uint2 cell=min(p/8,uint2(state.get_width()-1,state.get_height()-1));float4 center=state.read(cell);
            if(center.x==0) {result.write(float4(0),p);return;}
            float4 value=denseRead(state,(float2(p)+0.5f)/8-0.5f);
            float fade=1;float2 f=float2(p%8)+0.5f;
            if(cell.x>0 && state.read(cell-uint2(1,0)).x==0) fade*=smoothstep(0.0f,2.0f,f.x);
            if(cell.x+1<state.get_width() && state.read(cell+uint2(1,0)).x==0) fade*=smoothstep(0.0f,2.0f,8-f.x);
            if(cell.y>0 && state.read(cell-uint2(0,1)).x==0) fade*=smoothstep(0.0f,2.0f,f.y);
            if(cell.y+1<state.get_height() && state.read(cell+uint2(0,1)).x==0) fade*=smoothstep(0.0f,2.0f,8-f.y);
            result.write(float4(clamp(value.x*fade,0.0f,1.0f),clamp(value.y,0.0f,1.0f),center.z,center.w),p);
        }
        kernel void localConfidenceLuma(texture2d<float,access::read> first [[texture(0)]],texture2d<float,access::read> last [[texture(1)]],texture2d<uint,access::read_write> output [[texture(2)]],texture2d<float,access::read> confidence [[texture(3)]],constant float &t [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
            if(p.x>=output.get_width()||p.y>=output.get_height()||t==0||t==1) return;
            float2 local=confidence.read(p).xy;if(local.x==0) return;
            float a=first.read(p).r,b=last.read(p).r;
            float fallback=mix(mix(a,b,t),t<0.5f ? a : b,local.y);
            output.write(uint4(uint(clamp(round(mix(float(output.read(p).r),fallback*1023,local.x)),0.0f,1023.0f))),p);
        }
        """
        let library=try device.makeLibrary(source: source,options: nil)
        var functions=[String:MTLComputePipelineState]()
        for name in ["localConfidenceUpdate","localConfidenceFeather","localConfidenceLuma"] {functions[name]=try device.makeComputePipelineState(function: library.makeFunction(name: name)!)}
        pipelines=functions;reset()
    }
    func reset() {
        for state in states {let values=[SIMD4<Float>](repeating: .zero,count: state.width*state.height);values.withUnsafeBytes {state.replace(region: MTLRegionMake2D(0,0,state.width,state.height),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: state.width*16)}}
        slot=0
    }
    func prepare(command: MTLCommandBuffer,signals: MTLBuffer,forward: MTLTexture,step: Float) throws {
        guard step.isFinite,step>=0,step<=4 else {throw MotionSearchEngine.EngineError.pipeline("Confidence history step")}
        let next=1-slot
        let e=command.makeComputeCommandEncoder()!;e.setComputePipelineState(pipelines["localConfidenceUpdate"]!)
        e.setBuffer(signals,offset: 0,index: 0);e.setBuffer(calibration,offset: 0,index: 1);e.setBuffer(spans,offset: 0,index: 2)
        var geometry=SIMD2<Float>(sqrt(Float(1152*480)/Float(width*height)),step);e.setBytes(&geometry,length: 8,index: 3)
        for (i,t) in [states[slot],states[next],forward].enumerated() {e.setTexture(t,index: i)}
        e.dispatchThreads(MTLSize(width: states[next].width,height: states[next].height,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1));e.endEncoding()
        let f=command.makeComputeCommandEncoder()!;f.setComputePipelineState(pipelines["localConfidenceFeather"]!);f.setTexture(states[next],index: 0);f.setTexture(map,index: 1);f.dispatchThreads(MTLSize(width: width,height: height,depth: 1),threadsPerThreadgroup: MTLSize(width: 16,height: 8,depth: 1));f.endEncoding();slot=next
    }
    func apply(command: MTLCommandBuffer,images: [MTLTexture],output: MTLTexture,time: Float) {
        let e=command.makeComputeCommandEncoder()!;e.setComputePipelineState(pipelines["localConfidenceLuma"]!)
        for (i,t) in [images[0],images[1],output,map].enumerated() {e.setTexture(t,index: i)}
        var t=time;e.setBytes(&t,length: 4,index: 0);e.dispatchThreads(MTLSize(width: width,height: height,depth: 1),threadsPerThreadgroup: MTLSize(width: 16,height: 8,depth: 1));e.endEncoding()
    }
}
