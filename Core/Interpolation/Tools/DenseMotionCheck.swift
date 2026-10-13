import Foundation
import Metal
import Interpolation

private func denseLayerScene(_ offset: Int) -> [UInt16] {
    (0..<64*48).map { i in
        let x=i%64,y=i/64
        if x>=20+offset && x<36+offset && y>=16 && y<32 { return UInt16(700+((x-offset)*17+y*31)%250) }
        return UInt16(64+(x*13+y*19)%150)
    }
}

private func checkDenseVisibility() throws {
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw MotionSearchEngine.EngineError.deviceUnavailable }
    let library=try device.makeLibrary(source: denseMotionMSL,options: nil)
    guard let function=library.makeFunction(name: "denseSynthesize") else { throw MotionSearchEngine.EngineError.pipeline("Visibility shader missing") }
    let pipeline=try device.makeComputePipelineState(function: function)
    func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: 64,height: 48,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.shaderWrite]
        guard let result=device.makeTexture(descriptor: descriptor) else { throw MotionSearchEngine.EngineError.pipeline("Visibility texture allocation failed") }
        return result
    }
    let a=try texture(.r32Float),b=try texture(.r32Float),forward=try texture(.rgba32Float),backward=try texture(.rgba32Float)
    let output=try texture(.r16Uint),confidence=try texture(.r32Float),mapping=try texture(.rg32Float)
    let region=MTLRegionMake2D(0,0,64,48)
    for (image,offset) in [(a,0),(b,8)] {
        let pixels=denseLayerScene(offset).map { Float($0)/1023 }
        pixels.withUnsafeBytes { image.replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*4) }
    }
    for (image,offset,direction) in [(forward,0,Float(8)),(backward,8,Float(-8))] {
        let field: [SIMD4<Float>] = (0..<64*48).map { i in
            let x=i%64,y=i/64
            let own=x>=20+offset && x<36+offset && y>=16 && y<32
            let otherOffset=8-offset
            let hidden = !own && x>=20+otherOffset && x<36+otherOffset && y>=16 && y<32
            return SIMD4<Float>(own ? direction : 0,0,1,hidden ? -1 : 0)
        }
        field.withUnsafeBytes { image.replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*16) }
    }
    for time: Float in [0.25,0.5,0.75] {
        guard let command=queue.makeCommandBuffer(),let encoder=command.makeComputeCommandEncoder() else { throw MotionSearchEngine.EngineError.pipeline("Visibility command allocation failed") }
        encoder.setComputePipelineState(pipeline)
        for (i,image) in [a,b,forward,backward,output,confidence,mapping].enumerated() { encoder.setTexture(image,index: i) }
        var t=time
        encoder.setBytes(&t,length: 4,index: 0)
        encoder.dispatchThreads(MTLSize(width: 64,height: 48,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Visibility GPU failure") }
        var pixels=[UInt16](repeating: 0,count: 64*48)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: 64*2,from: region,mipmapLevel: 0) }
        let truth=denseLayerScene(Int(time*8))
        let error=zip(pixels,truth).reduce(0.0) { $0+Double(abs(Int($1.0)-Int($1.1))) }/Double(pixels.count)
        print("DENSE VISIBILITY ORACLE: t=\(time), MAE=\(error)")
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
}

func checkDenseMotion(variational: Bool=false) throws {
    try checkDenseInverse()
    try checkDenseVisibility()
    let w=64,h=48,gw=8,gh=6
    func data(_ pixels: [UInt16]) -> Data { pixels.withUnsafeBytes { Data($0) } }
    func error(_ a: [UInt16],_ b: [UInt16]) -> Double { zip(a,b).reduce(0.0) { $0+Double(abs(Int($1.0)-Int($1.1))) }/Double(a.count) }
    let dense=try DenseMotionPrototype(width: w,height: h,variational: variational)
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
    for time: Float in [0,1] {
        let result=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: time)
        precondition(result.pixels==(time==0 ? first : last),"Dense endpoint changed")
    }
    let still=try dense.interpolate(first: data(first),last: data(first),forward: forward,backward: backward,time: 0.5)
    precondition(still.pixels==first,"Dense static protection regressed")
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
    let odd=try DenseMotionPrototype(width: 65,height: 49,variational: variational)
    let oddPixels: [UInt16]=(0..<65*49).map { UInt16(($0*9)%1000) }
    let oddSeeds=[SIMD2<Int32>](repeating: .zero,count: 9*7)
    let oddResult=try odd.interpolate(first: data(oddPixels),last: data(oddPixels),forward: oddSeeds,backward: oddSeeds,time: 0.5)
    precondition(oddResult.pixels==oddPixels,"Odd geometry lost border pixels")
    print("OK — dense layered sequence, endpoints, static, deterministic output, invalid input and translation checks")
}
