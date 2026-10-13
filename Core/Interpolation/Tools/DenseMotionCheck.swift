import Foundation
import Metal
import Interpolation

func checkLargeMotionSearch() throws {
    let width=512,height=128,shift=160
    let source: [UInt16]=(0..<width*height).map { i in UInt16(100+(i%width*43+i/width*67+(i%width)*(i/width)*7)%800) }
    let target: [UInt16]=(0..<width*height).map { i in source[(i/width)*width+max(0,i%width-shift)] }
    func data(_ pixels: [UInt16]) -> Data { pixels.withUnsafeBytes { Data($0) } }
    func spec(_ extended: Bool) -> [LevelSpec] {
        var levels=[
            LevelSpec(width: width,height: height,blockSize: 8,searchHalfPel: 8,halfPelRefine: false,inheritFactor: 2),
            LevelSpec(width: 256,height: 64,blockSize: 8,searchHalfPel: 8,halfPelRefine: false,inheritFactor: 2),
            LevelSpec(width: 128,height: 32,blockSize: 8,searchHalfPel: 8,halfPelRefine: false,inheritFactor: 2),
            LevelSpec(width: 64,height: 16,blockSize: 8,searchHalfPel: 8,halfPelRefine: false,inheritFactor: 2)
        ]
        if extended { levels.append(LevelSpec(width: 32,height: 8,blockSize: 8,searchHalfPel: 32,halfPelRefine: false,inheritFactor: 1)) }
        return levels
    }
    var errors: [Double]=[]
    for extended in [false,true] {
        let engine=try MotionSearchEngine(msl: motionShadersMSL,spec: spec(extended),lambdaPx: 0,smoothL0: false,gateL0: false)
        let timing=engine.runPair(cur: data(source),ref: data(target))
        precondition(timing.stages.count==SEStage.allCases.count && timing.stages.allSatisfy { $0.isFinite && $0>=0 },"Extended hierarchy broke timing buckets")
        let field=engine.downloadMV(level: 0)
        // Only fully visible coarse blocks: do not score regions transported out of frame.
        let indices=(2..<14).flatMap { y in (4..<28).map { y*64+$0 } }
        let error=indices.reduce(0.0) { $0+Double(abs(Int(field[$1].x)-shift*2)+abs(Int(field[$1].y)))/2 }/Double(indices.count)
        errors.append(error)
        print("LARGE SEARCH: extended=\(extended), translation vector MAE=\(error)px")
    }
    precondition(errors[0]>50 && errors[1]<1,"Extended hierarchy did not recover known out-of-range motion")
    let single=try MotionSearchEngine(msl: motionShadersMSL,spec: [spec(false)[0]],lambdaPx: 0,smoothL0: false,gateL0: false)
    let singleTiming=single.runPair(cur: data(source),ref: data(source))
    precondition(singleTiming.stages[SEStage.searchL0.rawValue]>0 && singleTiming.stages[SEStage.searchL3.rawValue]==0,"Single-level search was reported as a coarse stage")
}

private func denseLayerScene(_ offset: Int) -> [UInt16] {
    (0..<64*48).map { i in
        let x=i%64,y=i/64
        if x>=20+offset && x<36+offset && y>=16 && y<32 { return UInt16(700+((x-offset)*17+y*31)%250) }
        return UInt16(64+(x*13+y*19)%150)
    }
}

private func denseCollisionScene(_ offset: Int,origin: Int=12) -> [UInt16] {
    (0..<64*48).map { i in
        let x=i%64,y=i/64
        if x>=origin+offset && x<origin+4+offset && y>=16 && y<32 { return UInt16(700+((x-offset)*17+y*31)%250) }
        return UInt16(64+(x*13+y*19)%150)
    }
}

private func denseStationaryForegroundScene(_ offset: Int) -> [UInt16] {
    (0..<64*48).map { i in
        let x=i%64,y=i/64
        if x>=20 && x<28 && y>=16 && y<32 { return UInt16(700+(x*17+y*31)%250) }
        return UInt16(64+(((x-offset)*13+y*19)%150+150)%150)
    }
}

func checkDenseVisibility(collision: Bool=false,stationaryForeground: Bool=false,borderCrossing: Int=0) throws {
    let origin=borderCrossing==1 ? -4 : (borderCrossing==2 ? 48 : (collision ? 12 : 20))
    let narrow=collision || borderCrossing != 0
    let scene: (Int)->[UInt16]=stationaryForeground ? denseStationaryForegroundScene : (narrow ? { denseCollisionScene($0,origin: origin) } : denseLayerScene)
    let displacement=narrow || stationaryForeground ? 16 : 8,extent=stationaryForeground ? 8 : (narrow ? 4 : 16)
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw MotionSearchEngine.EngineError.deviceUnavailable }
    let library=try device.makeLibrary(source: denseMotionMSL,options: nil)
    guard let function=library.makeFunction(name: "denseSynthesize") else { throw MotionSearchEngine.EngineError.pipeline("Visibility shader missing") }
    let pipeline=try device.makeComputePipelineState(function: function)
    guard let projectFunction=library.makeFunction(name: "denseProject"),
          let ownership0=device.makeBuffer(length: 64*48*4,options: .storageModeShared),
          let ownership1=device.makeBuffer(length: 64*48*4,options: .storageModeShared) else { throw MotionSearchEngine.EngineError.pipeline("Ownership oracle allocation failed") }
    let projectPipeline=try device.makeComputePipelineState(function: projectFunction)
    func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: 64,height: 48,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.shaderWrite]
        guard let result=device.makeTexture(descriptor: descriptor) else { throw MotionSearchEngine.EngineError.pipeline("Visibility texture allocation failed") }
        return result
    }
    let a=try texture(.r32Float),b=try texture(.r32Float),forward=try texture(.rgba32Float),backward=try texture(.rgba32Float)
    let output=try texture(.r16Uint),confidence=try texture(.r32Float),mapping=try texture(.rg32Float)
    let region=MTLRegionMake2D(0,0,64,48)
    for (image,offset) in [(a,0),(b,displacement)] {
        let pixels=scene(offset).map { Float($0)/1023 }
        pixels.withUnsafeBytes { image.replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*4) }
    }
    for (image,offset,direction) in [(forward,0,Float(displacement)),(backward,displacement,Float(-displacement))] {
        let field: [SIMD4<Float>] = (0..<64*48).map { i in
            let x=i%64,y=i/64
            if stationaryForeground {
                let own=x>=20 && x<28 && y>=16 && y<32
                let hidden = !own && Float(x)+direction>=20 && Float(x)+direction<28 && y>=16 && y<32
                return SIMD4<Float>(own ? 0 : direction,0,1,hidden ? -1 : 0)
            }
            let own=x>=origin+offset && x<origin+extent+offset && y>=16 && y<32
            let otherOffset=displacement-offset
            let hidden = !own && x>=origin+otherOffset && x<origin+extent+otherOffset && y>=16 && y<32
            let outside=own && (Float(x)+direction<0 || Float(x)+direction>=64)
            return SIMD4<Float>(own ? direction : 0,0,1,hidden || outside ? -1 : 0)
        }
        field.withUnsafeBytes { image.replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*16) }
    }
    for time: Float in [0.25,0.5,0.75] {
        guard let command=queue.makeCommandBuffer() else { throw MotionSearchEngine.EngineError.pipeline("Visibility command allocation failed") }
        var bits: UInt32=12
        for (direction,buffer) in [ownership0,ownership1].enumerated() {
            _=buffer.contents().initializeMemory(as: UInt32.self,repeating: 0,count: 64*48)
            guard let project=command.makeComputeCommandEncoder() else { throw MotionSearchEngine.EngineError.pipeline("Projection oracle encoder failed") }
            project.setComputePipelineState(projectPipeline)
            let textures=direction==0 ? [a,b,forward,backward] : [b,a,backward,forward]
            for (i,image) in textures.enumerated() { project.setTexture(image,index: i) }
            var amount=direction==0 ? time : 1-time
            project.setBuffer(buffer,offset: 0,index: 0)
            project.setBytes(&bits,length: 4,index: 1)
            project.setBytes(&amount,length: 4,index: 2)
            project.dispatchThreads(MTLSize(width: 64,height: 48,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
            project.endEncoding()
        }
        guard let encoder=command.makeComputeCommandEncoder() else { throw MotionSearchEngine.EngineError.pipeline("Visibility synthesis encoder failed") }
        encoder.setComputePipelineState(pipeline)
        for (i,image) in [a,b,forward,backward,output,confidence,mapping].enumerated() { encoder.setTexture(image,index: i) }
        var t=time
        encoder.setBytes(&t,length: 4,index: 0)
        var projection=SIMD2<UInt32>(bits,1)
        encoder.setBytes(&projection,length: 8,index: 1)
        encoder.setBuffer(ownership0,offset: 0,index: 2)
        encoder.setBuffer(ownership1,offset: 0,index: 3)
        encoder.dispatchThreads(MTLSize(width: 64,height: 48,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Visibility GPU failure") }
        var pixels=[UInt16](repeating: 0,count: 64*48)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: 64*2,from: region,mipmapLevel: 0) }
        let truth=scene(Int(time*Float(displacement)))
        let error=zip(pixels,truth).reduce(0.0) { $0+Double(abs(Int($1.0)-Int($1.1))) }/Double(pixels.count)
        print("DENSE VISIBILITY ORACLE: collision=\(collision), stationaryForeground=\(stationaryForeground), border=\(borderCrossing), t=\(time), MAE=\(error)")
        let failures=pixels.indices.filter { abs(Int(pixels[$0])-Int(truth[$0]))>10 }
        print("Visibility mismatches: \(failures.count), first: \(failures.prefix(12).map { "\($0%64),\($0/64):\(pixels[$0])/\(truth[$0])" })")
        precondition(error<1,"Visible source selection failed with known exact flows")
    }
}

private func checkDenseInverse() throws {
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw MotionSearchEngine.EngineError.deviceUnavailable }
    let source=denseMotionMSL+"""
    kernel void checkInverse(texture2d<float,access::sample> flow [[texture(0)]],device const float2 *points [[buffer(0)]],device float4 *result [[buffer(1)]],uint i [[thread_position_in_grid]]) {
        float2 p=points[i],old=p;
        for(int j=0;j<3;++j) old=p-0.5f*denseRead(flow,old).xy;
        float2 q=denseInverse(flow,p,0.5f);
        result[i]=float4(q,length(p-old-0.5f*denseRead(flow,old).xy),length(p-q-0.5f*denseRead(flow,q).xy));
    }
    kernel void checkMembership(texture2d<float,access::sample> flow [[texture(0)]],device float4 *result [[buffer(0)]],uint i [[thread_position_in_grid]]) {
        float2 q=float2(10.49f,15.2f),v=float2(3*q.x,0.5f*q.y);
        result[i]=float4(length(denseRead(flow,round(q)).xy-v),denseSurfaceMembership(flow,q,v)?1:0,0,0);
    }
    """
    let library=try device.makeLibrary(source: source,options: nil)
    guard let function=library.makeFunction(name: "checkInverse") else { throw MotionSearchEngine.EngineError.pipeline("Inverse check missing") }
    let pipeline=try device.makeComputePipelineState(function: function)
    let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,width: 64,height: 48,mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    guard let texture=device.makeTexture(descriptor: descriptor) else { throw MotionSearchEngine.EngineError.pipeline("Inverse texture allocation failed") }
    let field: [SIMD4<Float>] = (0..<64*48).map { i in SIMD4<Float>(1.5*Float(i%64),0.5*Float(i/64),1,0) }
    field.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*16) }
    let points: [SIMD2<Float>] = [SIMD2(20,20),SIMD2(40,12),SIMD2(10,16)]
    guard let positions=device.makeBuffer(bytes: points,length: points.count*8),let output=device.makeBuffer(length: points.count*16),let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { throw MotionSearchEngine.EngineError.pipeline("Inverse check allocation failed") }
    encoder.setComputePipelineState(pipeline)
    encoder.setTexture(texture,index: 0)
    encoder.setBuffer(positions,offset: 0,index: 0)
    encoder.setBuffer(output,offset: 0,index: 1)
    encoder.dispatchThreads(MTLSize(width: points.count,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 1,height: 1,depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Inverse check GPU failed") }
    let values=output.contents().bindMemory(to: SIMD4<Float>.self,capacity: points.count)
    for i in points.indices {
        precondition(abs(values[i].x-points[i].x/1.75)<0.001 && abs(values[i].y-points[i].y/1.25)<0.001)
        // Texture interpolation has finite subtexel precision.
        precondition(values[i].z>1 && values[i].w<0.002,"Transport inversion did not improve known affine field")
    }
    print("DENSE INVERSE: affine ground truth passed; old fixed-point residual exceeds 1px")
    let affine: [SIMD4<Float>]=(0..<64*48).map { i in SIMD4(3*Float(i%64),0.5*Float(i/64),1,0) }
    affine.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*16) }
    guard let membership=library.makeFunction(name: "checkMembership"),let command2=queue.makeCommandBuffer(),let encoder2=command2.makeComputeCommandEncoder() else { throw MotionSearchEngine.EngineError.pipeline("Membership check allocation failed") }
    encoder2.setComputePipelineState(try device.makeComputePipelineState(function: membership))
    encoder2.setTexture(texture,index: 0); encoder2.setBuffer(output,offset: 0,index: 0)
    encoder2.dispatchThreads(MTLSize(width: 1,height: 1,depth: 1),threadsPerThreadgroup: MTLSize(width: 1,height: 1,depth: 1))
    encoder2.endEncoding(); command2.commit(); command2.waitUntilCompleted()
    guard command2.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Membership check GPU failure") }
    precondition(values[0].x>1 && values[0].y==1,"Continuous affine surface was mistaken for a motion discontinuity")
}

private func checkDenseTemporalEvidence() throws {
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw MotionSearchEngine.EngineError.deviceUnavailable }
    let library=try device.makeLibrary(source: denseMotionMSL,options: nil)
    guard let function=library.makeFunction(name: "denseTemporalAssess") else { throw MotionSearchEngine.EngineError.pipeline("Temporal check shader missing") }
    let pipeline=try device.makeComputePipelineState(function: function)
    func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: 64,height: 48,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.shaderWrite]
        guard let result=device.makeTexture(descriptor: descriptor) else { throw MotionSearchEngine.EngineError.pipeline("Temporal check allocation failed") }
        return result
    }
    let source=try texture(.r32Float),before=try texture(.r32Float),after=try texture(.r32Float),input=try texture(.rgba32Float),output=try texture(.rgba32Float)
    let region=MTLRegionMake2D(0,0,64,48)
    for (image,offset) in [(source,0),(before,-8),(after,16)] {
        let pixels=denseLayerScene(offset).map { Float($0)/1023 }
        pixels.withUnsafeBytes { image.replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*4) }
    }
    var field=[SIMD4<Float>](repeating: SIMD4(0,0,1,-1),count: 64*48)
    field[8*64+10]=SIMD4(8,0,1,-1) // Incorrect moving trajectory on static background.
    field[20*64+30]=SIMD4(8,0,1,-1) // Correct foreground trajectory.
    field.withUnsafeBytes { input.replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*16) }
    guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { throw MotionSearchEngine.EngineError.pipeline("Temporal check command failed") }
    encoder.setComputePipelineState(pipeline)
    for (i,image) in [source,before,after,input,output].enumerated() { encoder.setTexture(image,index: i) }
    var intervals=SIMD2<Float>(-1,2)
    encoder.setBytes(&intervals,length: 8,index: 0)
    encoder.dispatchThreads(MTLSize(width: 64,height: 48,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Temporal check GPU failure") }
    var assessed=[SIMD4<Float>](repeating: .zero,count: field.count)
    assessed.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: 64*16,from: region,mipmapLevel: 0) }
    precondition(assessed[8*64+10].w>=0 && assessed[8*64+10].z<0.3,"False occlusion retained despite both neighbors contradicting it")
    precondition(assessed[20*64+30].w<0 && assessed[20*64+30].z>0.99,"Known temporal trajectory lost support")
    precondition(assessed[8*64+5].w<0 && assessed[8*64+5].z>0.99,"Static visible background lost support")
    print("DENSE FOUR: false occlusion rejected, moving and static trajectories retain temporal evidence")
}

func checkDenseMotion(variational: Bool=false,finestIterations: Int=8) throws {
    for invalid in [0,9] {
        do {
            _=try DenseMotionPrototype(width: 64,height: 48,finestIterations: invalid)
            preconditionFailure("Invalid refinement count accepted")
        } catch MotionSearchEngine.EngineError.pipeline { }
    }
    try checkDenseInverse()
    try checkDenseVisibility()
    try checkDenseVisibility(collision: true)
    try checkDenseVisibility(stationaryForeground: true)
    try checkDenseVisibility(borderCrossing: 1)
    try checkDenseVisibility(borderCrossing: 2)
    try checkDenseTemporalEvidence()
    let w=64,h=48,gw=8,gh=6
    func data(_ pixels: [UInt16]) -> Data { pixels.withUnsafeBytes { Data($0) } }
    func error(_ a: [UInt16],_ b: [UInt16]) -> Double { zip(a,b).reduce(0.0) { $0+Double(abs(Int($1.0)-Int($1.1))) }/Double(a.count) }
    let dense=try DenseMotionPrototype(width: w,height: h,variational: variational,finestIterations: finestIterations)
    let warp=try WarpEngine(msl: warpShadersMSL)
    let first=denseLayerScene(0),last=denseLayerScene(8)
    func field(_ offset: Int,_ direction: Int32) -> [SIMD2<Int32>] {
        (0..<gw*gh).map { i in
            let x=(i%gw)*8+4,y=(i/gw)*8+4
            return x>=20+offset && x<36+offset && y>=16 && y<32 ? SIMD2<Int32>(direction,0) : .zero
        }
    }
    let forward=field(0,16),backward=field(8,-16)
    var baselineError=0.0,denseError=0.0
    for time: Float in [0.25,0.5,0.75] {
        let result=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: time)
        let baseline=warp.interpolate(I0: first,I1: last,mv: forward,width: w,height: h,gridW: gw,gridH: gh,blockSize: 8,t: time).0
        let truth=denseLayerScene(Int(time*8))
        let a=error(baseline,truth),b=error(result.pixels,truth)
        baselineError+=a; denseError+=b
        precondition(result.reliability.allSatisfy { $0>=0 && $0<=1 })
        print("DENSE LAYERS: t=\(time), baseline MAE=\(a), dense MAE=\(b), ms=\(result.milliseconds)")
    }
    precondition(denseError<baselineError,"Dense motion did not improve known layered sequence")
    let context=DenseMotionPrototype.TemporalContext(before: data(denseLayerScene(-8)),after: data(denseLayerScene(16)),beforeInterval: 1,afterInterval: 1)
    let four=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,times: [0,0.5,1],context: context)
    precondition(four[0].pixels==first && four[2].pixels==last)
    print("DENSE FOUR LAYERS: MAE=\(error(four[1].pixels,denseLayerScene(4)))")
    let noContext=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: 0.5)
    let fresh=try DenseMotionPrototype(width: w,height: h,variational: variational,finestIterations: finestIterations).interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: 0.5)
    precondition(noContext.pixels==fresh.pixels && noContext.forward==fresh.forward && noContext.backward==fresh.backward,"Neighbor textures leaked into the next context-free pair")
    for invalid in [DenseMotionPrototype.TemporalContext(before: Data(),after: data(last),beforeInterval: 1,afterInterval: 1),DenseMotionPrototype.TemporalContext(before: data(first),after: data(last),beforeInterval: .nan,afterInterval: 1)] {
        do {
            _=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: 0.5,context: invalid)
            preconditionFailure("Invalid temporal context accepted")
        } catch MotionSearchEngine.EngineError.pipeline { }
    }
    for time: Float in [0,1] {
        let result=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: time)
        precondition(result.pixels==(time==0 ? first : last),"Dense endpoint changed")
    }
    let still=try dense.interpolate(first: data(first),last: data(first),forward: forward,backward: backward,time: 0.5)
    precondition(still.pixels==first,"Dense static protection regressed")
    let staticContext=DenseMotionPrototype.TemporalContext(before: data(first),after: data(first),beforeInterval: 1,afterInterval: 1)
    let fourStill=try dense.interpolate(first: data(first),last: data(first),forward: forward,backward: backward,time: 0.5,context: staticContext)
    precondition(fourStill.pixels==first,"Four-frame static protection regressed")
    let repeated=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: 0.5)
    let batch=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,times: [0,0.5,1,0.5])
    precondition(batch[0].pixels==first && batch[2].pixels==last && batch[1].pixels==repeated.pixels && batch[3].pixels==repeated.pixels,"Shared flow changed temporal samples")
    for times: [Float] in [[],[0,0.25,0.5,0.75,1],[.nan]] {
        do {
            _=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,times: times)
            preconditionFailure("Invalid dense batch accepted")
        } catch MotionSearchEngine.EngineError.pipeline { }
    }
    let again=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: 0.5)
    precondition(repeated.pixels==again.pixels && repeated.forward==again.forward && repeated.backward==again.backward,"Dense output is nondeterministic")
    do {
        _=try dense.interpolate(first: Data(),last: Data(),forward: forward,backward: backward,time: .nan)
        preconditionFailure("Invalid dense inputs accepted")
    } catch MotionSearchEngine.EngineError.pipeline { }
    do {
        _=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: .nan)
        preconditionFailure("NaN time accepted")
    } catch MotionSearchEngine.EngineError.pipeline { }
    do {
        _=try dense.interpolate(first: data(first),last: data(last),forward: [],backward: backward,time: 0.5)
        preconditionFailure("Wrong dense seed grid accepted")
    } catch MotionSearchEngine.EngineError.pipeline { }
    var unnormalized=first
    unnormalized[0]=UInt16.max
    do {
        _=try dense.interpolate(first: data(unnormalized),last: data(last),forward: forward,backward: backward,time: 0.5)
        preconditionFailure("Unnormalized luma accepted")
    } catch MotionSearchEngine.EngineError.pipeline { }
    let texture: [UInt16]=(0..<w*h).map { i in UInt16(((i%w)*43+(i/w)*67+((i%w)*(i/w))*7)%700+150) }
    let translated: [UInt16]=(0..<w*h).map { i in texture[(i/w)*w+max(0,i%w-4)] }
    let seed=[SIMD2<Int32>](repeating: SIMD2(6,0),count: gw*gh)
    let reverse=[SIMD2<Int32>](repeating: SIMD2(-6,0),count: gw*gh)
    let translation=try dense.interpolate(first: data(texture),last: data(translated),forward: seed,backward: reverse,time: 0.5)
    let interior=(8..<h-8).flatMap { y in (8..<w-8).map { y*w+$0 } }
    let residual=interior.reduce(0.0) { $0+Double(abs(translation.forward[$1].x-4)+abs(translation.forward[$1].y)) }/Double(interior.count)
    print("DENSE TRANSLATION: mean vector error=\(residual) px")
    precondition(residual<0.75,"Dense refinement failed known translation from imperfect seed")
    let pixelError=interior.reduce(0.0) { sum,index in sum+Double(abs(Int(translation.pixels[index])-Int(texture[(index/w)*w+index%w-2]))) }/Double(interior.count)
    print("DENSE TRANSLATION: original-detail pixel MAE=\(pixelError)")
    precondition(pixelError<5,"Dense reconstruction lost known translated detail")
    let past: [UInt16]=(0..<w*h).map { i in texture[(i/w)*w+min(w-1,i%w+4)] }
    let future: [UInt16]=(0..<w*h).map { i in texture[(i/w)*w+max(0,i%w-8)] }
    let trajectory=DenseMotionPrototype.TemporalContext(before: data(past),after: data(future),beforeInterval: 1,afterInterval: 1)
    let fourTranslation=try dense.interpolate(first: data(texture),last: data(translated),forward: seed,backward: reverse,time: 0.5,context: trajectory)
    let fourPixelError=interior.reduce(0.0) { sum,index in sum+Double(abs(Int(fourTranslation.pixels[index])-Int(texture[(index/w)*w+index%w-2]))) }/Double(interior.count)
    precondition(fourPixelError<5,"Four-frame transport lost known translated detail")
    print("DENSE FOUR TRANSLATION: pixel MAE=\(fourPixelError)")
    // Held neighboring drawings must not force constant velocity outside the central pair.
    let held=DenseMotionPrototype.TemporalContext(before: data(texture),after: data(translated),beforeInterval: 1,afterInterval: 1)
    let heldTranslation=try dense.interpolate(first: data(texture),last: data(translated),forward: seed,backward: reverse,time: 0.5,context: held)
    let heldError=interior.reduce(0.0) { sum,index in sum+Double(abs(Int(heldTranslation.pixels[index])-Int(texture[(index/w)*w+index%w-2]))) }/Double(interior.count)
    print("DENSE HELD NEIGHBORS: midpoint pixel MAE=\(heldError), two-frame MAE=\(pixelError)")
    precondition(heldTranslation.pixels==translation.pixels,"Repeated neighbors corrupted central-pair motion")
    let noisyFirst=texture.enumerated().map { UInt16(Int($0.element)+($0.offset%2==0 ? 1 : -1)) }
    let noisyLast=translated.enumerated().map { UInt16(Int($0.element)+($0.offset%2==0 ? -1 : 1)) }
    let noisyHeld=DenseMotionPrototype.TemporalContext(before: data(noisyFirst),after: data(noisyLast),beforeInterval: 1,afterInterval: 1)
    let noisyTranslation=try dense.interpolate(first: data(texture),last: data(translated),forward: seed,backward: reverse,time: 0.5,context: noisyHeld)
    let noisyError=interior.reduce(0.0) { sum,index in sum+Double(abs(Int(noisyTranslation.pixels[index])-Int(texture[(index/w)*w+index%w-2]))) }/Double(interior.count)
    print("DENSE NOISY HELD: midpoint pixel MAE=\(noisyError)")
    let odd=try DenseMotionPrototype(width: 65,height: 49,variational: variational,finestIterations: finestIterations)
    let oddPixels: [UInt16]=(0..<65*49).map { UInt16(($0*9)%1000) }
    let oddSeeds=[SIMD2<Int32>](repeating: .zero,count: 9*7)
    let oddResult=try odd.interpolate(first: data(oddPixels),last: data(oddPixels),forward: oddSeeds,backward: oddSeeds,time: 0.5)
    precondition(oddResult.pixels==oddPixels,"Odd geometry lost border pixels")
    print("OK — dense layered sequence, endpoints, static, deterministic output, invalid input and translation checks")
}
