import Foundation
import Metal
import CoreVideo
import Interpolation

func checkBatchedMotionSearch() throws {
    let w=128,h=64
    let source: [UInt16]=(0..<w*h).map { i in
        let x=i%w,y=i/w
        return UInt16((x*43+y*67+x*y*7)%700+100)
    }
    let target=(0..<w*h).map { i in source[(i/w)*w+max(0,i%w-4)] }
    func data(_ pixels: [UInt16]) -> Data { pixels.withUnsafeBytes { Data($0) } }
    let levels=(0..<4).map { level in LevelSpec(width: w>>level,height: h>>level,blockSize: 8,searchHalfPel: 8,halfPelRefine: level==0,inheritFactor: 2) }
    for count in [1,4] {
        let engine=try MotionSearchEngine(msl: motionShadersMSL,spec: Array(levels.prefix(count)),lambdaPx: 1,smoothL0: true,gateL0: true,temporalGatePx: 0)
        _=engine.runPair(cur: data(source),ref: data(target))
        let expected=(0..<count).map { engine.downloadMV(level: $0,smoothed: false) }
        let smooth=engine.downloadMV(level: 0,smoothed: true)
        _=try engine.runPairBatched(cur: data(source),ref: data(target))
        for level in 0..<count { precondition(expected[level]==engine.downloadMV(level: level,smoothed: false),"Batched search changed raw vectors") }
        precondition(smooth==engine.downloadMV(level: 0,smoothed: true),"Batched search changed median/dead-zone vectors")
        print("BATCHED SEARCH: \(count) levels, raw and filtered vectors identical")
    }
}

func checkNativePatchIntegration() throws {
    try checkBatchedMotionSearch()
    for tenBit in [false,true] {
        let format=tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        func buffer(_ shift: Int,_ last: Bool) -> CVPixelBuffer {
            var result: CVPixelBuffer?
            let attributes=[kCVPixelBufferIOSurfacePropertiesKey as String: [:],kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
            precondition(CVPixelBufferCreate(nil,64,48,format,attributes,&result)==kCVReturnSuccess)
            let image=result!
            CVPixelBufferLockBaseAddress(image,[])
            for plane in 0..<2 {
                let w=CVPixelBufferGetWidthOfPlane(image,plane),h=CVPixelBufferGetHeightOfPlane(image,plane)
                let base=CVPixelBufferGetBaseAddressOfPlane(image,plane)!,stride=CVPixelBufferGetBytesPerRowOfPlane(image,plane)
                for y in 0..<h { for x in 0..<w {
                    let q=max(0,x-shift)
                    let values=plane==0 ? [80+(q*13+y*17+q*y*7)%100] : [last ? 112 : 96,last ? 144 : 160]
                    for (channel,value) in values.enumerated() {
                        let k=x*values.count+channel
                        if tenBit { base.advanced(by: y*stride).assumingMemoryBound(to: UInt16.self)[k]=UInt16(value*4)<<6 }
                        else { base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self)[k]=UInt8(value) }
                    }
                } }
            }
            CVPixelBufferUnlockBaseAddress(image,[])
            CVBufferSetAttachment(image,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_2020,.shouldPropagate)
            return image
        }
        let first=buffer(0,false),last=buffer(4,true)
        let engine=try MotionCompensator(config: InterpolationConfig(workWidth: 64,workHeight: 48,temporalGatePx: 0))
        let result=engine.interpolatePair(I0: first,I1: last,tValues: [0,0.5,1])
        precondition(result.pixelBuffers.count==3,"Native patch batch did not complete")
        precondition(result.pixelBuffers[0] === first && result.pixelBuffers[2] === last,"Native patch endpoints changed source buffers")
        let mid=result.pixelBuffers[1]
        precondition(mid !== first && mid !== last && CVPixelBufferGetPixelFormatType(mid)==format && CVPixelBufferGetWidth(mid)==64 && CVPixelBufferGetHeight(mid)==48)
        precondition(CVBufferGetAttachment(mid,kCVImageBufferColorPrimariesKey,nil) != nil,"Native patch output lost color metadata")
        CVPixelBufferLockBaseAddress(mid,.readOnly)
        let base=CVPixelBufferGetBaseAddressOfPlane(mid,1)!,stride=CVPixelBufferGetBytesPerRowOfPlane(mid,1)
        for y in 0..<24 { for x in 0..<32 { for channel in 0..<2 {
            let value=tenBit ? Int(base.advanced(by: y*stride).assumingMemoryBound(to: UInt16.self)[2*x+channel]>>6)/4 : Int(base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self)[2*x+channel])
            precondition(channel==0 ? (96...112).contains(value) : (144...160).contains(value),"Native patch chroma channels lost or mixed")
        } } }
        CVPixelBufferUnlockBaseAddress(mid,.readOnly)
        func payload(_ image: CVPixelBuffer) -> Data {
            CVPixelBufferLockBaseAddress(image,.readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image,.readOnly) }
            var bytes=Data()
            for plane in 0..<2 {
                let base=CVPixelBufferGetBaseAddressOfPlane(image,plane)!,stride=CVPixelBufferGetBytesPerRowOfPlane(image,plane)
                let rowBytes=CVPixelBufferGetWidthOfPlane(image,plane)*(plane==0 ? 1 : 2)*(tenBit ? 2 : 1)
                for y in 0..<CVPixelBufferGetHeightOfPlane(image,plane) { bytes.append(base.advanced(by: y*stride).assumingMemoryBound(to: UInt8.self),count: rowBytes) }
            }
            return bytes
        }
        let reference=payload(mid)
        for _ in 0..<3 {
            let batch=engine.interpolatePair(I0: first,I1: last,tValues: [0.25,0.5,0.75]).pixelBuffers
            precondition(batch.count==3 && payload(batch[1])==reference,"Shared submission or concurrent scaling changed the midpoint")
            precondition(payload(mid)==reference,"Later synthesis overwrote an earlier output")
        }
        let held=InterpolationTemporalContext(before: first,after: last,beforeInterval: 1,afterInterval: 1)
        let contextual=engine.interpolatePair(I0: first,I1: last,tValues: [0,0.5,1],context: held)
        precondition(contextual.pixelBuffers.count==3 && payload(contextual.pixelBuffers[1])==reference,"Held temporal neighbors changed native output")
        let moving=InterpolationTemporalContext(before: buffer(-4,false),after: buffer(8,true),beforeInterval: 1,afterInterval: 1)
        let temporalResult=engine.interpolatePair(I0: first,I1: last,tValues: [0.25,0.5,0.75],context: moving)
        precondition(temporalResult.pixelBuffers.count==3 && temporalResult.pixelBuffers.allSatisfy { CVPixelBufferGetPixelFormatType($0)==format && CVBufferGetAttachment($0,kCVImageBufferColorPrimariesKey,nil) != nil },"Moving context lost native outputs or metadata")
        let invalid=InterpolationTemporalContext(before: first,after: last,beforeInterval: .nan,afterInterval: 1)
        let recovered=engine.interpolatePair(I0: first,I1: last,tValues: [0.5],context: invalid)
        precondition(recovered.pixelBuffers.count==1 && payload(recovered.pixelBuffers[0])==reference,"Invalid context did not fall back to two-frame interpolation")
        precondition(engine.interpolatePair(I0: first,I1: last,tValues: [.nan]).pixelBuffers.isEmpty)
        print("NATIVE PATCH: \(tenBit ? 10 : 8)-bit format, chroma, endpoints and metadata passed; total=\(result.meMS+result.warpMS)ms")
    }
}

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
    let coordinates=try texture(.rgba32Float),blend=try texture(.r32Float)
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
            var exposure: Float=0
            project.setBytes(&exposure,length: 4,index: 3)
            project.dispatchThreads(MTLSize(width: 64,height: 48,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
            project.endEncoding()
        }
        guard let encoder=command.makeComputeCommandEncoder() else { throw MotionSearchEngine.EngineError.pipeline("Visibility synthesis encoder failed") }
        encoder.setComputePipelineState(pipeline)
        for (i,image) in [a,b,forward,backward,output,confidence,mapping,coordinates,blend].enumerated() { encoder.setTexture(image,index: i) }
        var t=time
        encoder.setBytes(&t,length: 4,index: 0)
        var projection=SIMD2<UInt32>(bits,1)
        encoder.setBytes(&projection,length: 8,index: 1)
        encoder.setBuffer(ownership0,offset: 0,index: 2)
        encoder.setBuffer(ownership1,offset: 0,index: 3)
        var offset: Float=0
        encoder.setBytes(&offset,length: 4,index: 4)
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
    var exposure=SIMD2<Float>.zero
    encoder.setBytes(&exposure,length: 8,index: 1)
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

func checkDenseLighting() throws {
    let w=64,h=48
    let source=(0..<w*h).map { UInt16((($0%w)*43+($0/w)*67+($0%w)*($0/w)*7)%700+100) }
    let target=(0..<w*h).map { source[($0/w)*w+max(0,$0%w-4)]+120 }
    let seed=[SIMD2<Int32>](repeating: SIMD2(6,0),count: 8*6)
    let reverse=[SIMD2<Int32>](repeating: SIMD2(-6,0),count: 8*6)
    func data(_ pixels: [UInt16]) -> Data { pixels.withUnsafeBytes { Data($0) } }
    let engine=try DenseMotionPrototype(width: w,height: h,inverseSearch: true)
    let result=try engine.interpolate(first: data(source),last: data(target),forward: seed,backward: reverse,time: 0.5)
    var vectorError=0.0,pixelError=0.0,count=0
    for y in 8..<h-8 { for x in 8..<w-8 {
        let k=y*w+x
        vectorError+=hypot(Double(result.forward[k].x)-4,Double(result.forward[k].y))
        pixelError+=Double(abs(Int(result.pixels[k])-Int(source[y*w+x-2])-60)); count+=1
    } }
    print("DENSE LIGHTING: shift=4px, brightnessDelta=120, vectorMAE=\(vectorError/Double(count))px, midpointMAE=\(pixelError/Double(count))")
    let bad=(8..<h-8).flatMap { y in (8..<w-8).map { y*w+$0 } }.filter { abs(Int(result.pixels[$0])-Int(source[$0-2])-60)>20 }
    for k in bad.prefix(5) { print("LIGHTING PIXEL: index=\(k), actual=\(result.pixels[k]), expected=\(Int(source[k-2])+60), source=\(source[k]), mv=\(result.forward[k]), confidence=\(result.reliability[k]), inverse=\(result.mappingResidual[k])") }
    precondition(vectorError/Double(count)<0.1 && pixelError/Double(count)<5,"Illumination corrupted known moving detail")
    let bright=source.map { $0+120 }
    let stationary=try engine.interpolate(first: data(source),last: data(bright),forward: seed,backward: reverse,time: 0.5)
    precondition(zip(stationary.pixels,source).allSatisfy { Int($0.0)==Int($0.1)+60 },"Static illumination change acquired false motion")
    let past=(0..<w*h).map { source[($0/w)*w+min(w-1,$0%w+4)] }
    let future=(0..<w*h).map { source[($0/w)*w+max(0,$0%w-8)]+120 }
    let context=DenseMotionPrototype.TemporalContext(before: data(past),after: data(future),beforeInterval: 1,afterInterval: 1)
    let four=try engine.interpolate(first: data(source),last: data(target),forward: seed,backward: reverse,time: 0.5,context: context)
    let indices=(8..<h-8).flatMap { y in (8..<w-8).map { y*w+$0 } }
    let fourError=indices.reduce(0.0) { $0+Double(abs(Int(four.pixels[$1])-Int(source[$1-2])-60)) }/Double(indices.count)
    print("DENSE LIGHTING FOUR: midpointMAE=\(fourError)")
    precondition(fourError<5,"Temporal illumination corrupted known moving detail")
    for delta in [-60,60] {
        let changed=target.map { UInt16(Int($0)-120+delta) }
        let sample=try engine.interpolate(first: data(source),last: data(changed),forward: seed,backward: reverse,time: 0.5)
        let error=indices.reduce(0.0) { $0+Double(abs(Int(sample.pixels[$1])-Int(source[$1-2])-delta/2)) }/Double(indices.count)
        print("DENSE LIGHTING VARIANT: brightnessDelta=\(delta), midpointMAE=\(error)")
        precondition(error<5,"Illumination sign or amplitude corrupted moving detail")
    }
}

func checkDenseRotation() throws {
    let large=ProcessInfo.processInfo.environment["MV_ROTATION_LARGE"] == "1"
    let w=large ? 384 : 96,h=large ? 256 : 96,angle=large ? 0.5 : 0.2,c=cos(angle),s=sin(angle)
    let displacement=SIMD2<Double>(large ? -96 : 0,large ? -24 : 0)
    let center=SIMD2<Double>(Double(w-1)/2,Double(h-1)/2)
    func texture(_ p: SIMD2<Double>) -> UInt16 {
        UInt16(clamping: Int((500+160*sin(p.x*0.21)+140*cos(p.y*0.19)+100*sin((p.x+p.y)*0.13)).rounded()))
    }
    func rotate(_ p: SIMD2<Double>,_ sign: Double) -> SIMD2<Double> {
        let q=p-center-(sign<0 ? displacement : .zero)
        return center+SIMD2(c*q.x-sign*s*q.y,sign*s*q.x+c*q.y)+(sign>0 ? displacement : .zero)
    }
    let first=(0..<w*h).map { texture(SIMD2(Double($0%w),Double($0/w))) }
    let last=(0..<w*h).map { texture(rotate(SIMD2(Double($0%w),Double($0/w)),-1)) }
    let a=(1+c)/2,b=s/2,den=a*a+b*b
    let truth=(0..<w*h).map { i -> UInt16 in
        let q=SIMD2(Double(i%w),Double(i/w))-center-displacement*0.5
        return texture(center+SIMD2((a*q.x+b*q.y)/den,(-b*q.x+a*q.y)/den))
    }
    func seeds(_ sign: Double) -> [SIMD2<Int32>] {
        (0..<(w/8)*(h/8)).map { i in
            let p=SIMD2(Double(i%(w/8)*8)+3.5,Double(i/(w/8)*8)+3.5)
            let v=2*(rotate(p,sign)-p)
            return SIMD2(Int32(v.x.rounded()),Int32(v.y.rounded()))
        }
    }
    func data(_ pixels: [UInt16]) -> Data { pixels.withUnsafeBytes { Data($0) } }
    for patch in [false,true] {
        let engine=try DenseMotionPrototype(width: w,height: h,inverseSearch: patch)
        let result=try engine.interpolate(first: data(first),last: data(last),forward: seeds(1),backward: seeds(-1),time: 0.5)
        var vectorError=0.0,pixelError=0.0,count=0
        for y in 12..<h-12 { for x in 12..<w-12 {
            let p=SIMD2(Double(x),Double(y)),end=rotate(p,1),v=end-p,k=y*w+x
            let q=p-center-displacement*0.5
            let midSource=center+SIMD2((a*q.x+b*q.y)/den,(-b*q.x+a*q.y)/den)
            let midTarget=rotate(midSource,1)
            guard end.x>=12,end.x<Double(w-12),end.y>=12,end.y<Double(h-12),
                  midSource.x>=12,midSource.x<Double(w-12),midSource.y>=12,midSource.y<Double(h-12),
                  midTarget.x>=12,midTarget.x<Double(w-12),midTarget.y>=12,midTarget.y<Double(h-12) else { continue }
            vectorError+=hypot(Double(result.forward[k].x)-v.x,Double(result.forward[k].y)-v.y)
            pixelError+=Double(abs(Int(result.pixels[k])-Int(truth[k]))); count+=1
        } }
        print("DENSE ROTATION: patches=\(patch), radians=\(angle), displacement=\(displacement), vectorMAE=\(vectorError/Double(count))px, midpointMAE=\(pixelError/Double(count)), ms=\(result.milliseconds)")
        precondition(vectorError.isFinite && pixelError.isFinite)
        if large && patch { precondition(vectorError/Double(count)<3,"Patch refinement lost accurate supplied motion in a known affine scene") }
    }
}

func checkTemporalPatchSelection() throws {
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw MotionSearchEngine.EngineError.deviceUnavailable }
    let library=try device.makeLibrary(source: denseMotionMSL,options: nil)
    let pipeline=try device.makeComputePipelineState(function: library.makeFunction(name: "densePatchSearch")!)
    func texture(_ format: MTLPixelFormat,_ w: Int,_ h: Int) -> MTLTexture {
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: w,height: h,mipmapped: false)
        d.storageMode = .shared; d.usage = [.shaderRead,.shaderWrite]
        return device.makeTexture(descriptor: d)!
    }
    let a=texture(.r32Float,64,48),b=texture(.r32Float,64,48),before=texture(.r32Float,64,48),after=texture(.r32Float,64,48)
    let seed=texture(.rgba32Float,64,48),patches=texture(.rgba32Float,17,13),selected=texture(.rgba32Float,17,13)
    func frame(_ centers: [Int]) -> [Float] {
        var pixels=[Float](repeating: 0.1,count: 64*48)
        for center in centers { for y in 20..<28 { for x in center-4..<center+4 {
            pixels[y*64+x]=0.25+Float(((x-center+4)*37+(y-20)*61)%100)/200
        } } }
        return pixels
    }
    for (image,centers) in [(a,[24,40]),(b,[32,40]),(before,[16,40]),(after,[40])] {
        frame(centers).withUnsafeBytes { image.replace(region: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*4) }
    }
    var vectors=[SIMD4<Float>](repeating: SIMD4(16,0,1,0),count: 64*48)
    for y in 0..<48 { vectors[y*64+20]=SIMD4(8,0,1,0) }
    vectors.withUnsafeBytes { seed.replace(region: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*16) }
    let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    for (i,image) in [a,b,seed,patches,before,after].enumerated() { encoder.setTexture(image,index: i) }
    var intervals=SIMD2<Float>(-1,2)
    encoder.setBytes(&intervals,length: MemoryLayout<SIMD2<Float>>.stride,index: 0)
    encoder.dispatchThreads(MTLSize(width: 17,height: 13,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
    encoder.endEncoding()
    let selection=command.makeComputeCommandEncoder()!
    selection.setComputePipelineState(try device.makeComputePipelineState(function: library.makeFunction(name: "densePatchTemporalSelect")!))
    for (i,image) in [a,b,patches,selected,before,after].enumerated() { selection.setTexture(image,index: i) }
    selection.setBytes(&intervals,length: MemoryLayout<SIMD2<Float>>.stride,index: 0)
    selection.dispatchThreads(MTLSize(width: 17,height: 13,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
    selection.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Temporal patch selection GPU failure") }
    var result=[SIMD4<Float>](repeating: .zero,count: 17*13)
    result.withUnsafeMutableBytes { selected.getBytes($0.baseAddress!,bytesPerRow: 17*16,from: MTLRegionMake2D(0,0,17,13),mipmapLevel: 0) }
    FileHandle.standardOutput.write(Data("TEMPORAL PATCH: two central matches 8/16px; selected=\(result[6*17+6].x)px, expected=8px\n".utf8))
    precondition(abs(result[6*17+6].x-8)<0.01,"The central pair chose the wrong identical surface despite temporal evidence")
    // A neighbor trajectory must not replace a better central correspondence.
    var changed=frame([32,40])
    for y in 20..<28 { for x in 36..<44 { changed[y*64+x]+=0.02 } }
    changed.withUnsafeBytes { b.replace(region: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*4) }
    for (image,centers) in [(before,[8,40]),(after,[40,56])] {
        frame(centers).withUnsafeBytes { image.replace(region: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*4) }
    }
    var candidates=[SIMD4<Float>](repeating: SIMD4(16,0,1,0),count: 17*13)
    candidates[6*17+6]=SIMD4(8,0,1,0)
    candidates.withUnsafeBytes { patches.replace(region: MTLRegionMake2D(0,0,17,13),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 17*16) }
    let guardedCommand=queue.makeCommandBuffer()!,guardedEncoder=guardedCommand.makeComputeCommandEncoder()!
    guardedEncoder.setComputePipelineState(try device.makeComputePipelineState(function: library.makeFunction(name: "densePatchTemporalSelect")!))
    for (i,image) in [a,b,patches,selected,before,after].enumerated() { guardedEncoder.setTexture(image,index: i) }
    guardedEncoder.setBytes(&intervals,length: MemoryLayout<SIMD2<Float>>.stride,index: 0)
    guardedEncoder.dispatchThreads(MTLSize(width: 17,height: 13,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
    guardedEncoder.endEncoding(); guardedCommand.commit(); guardedCommand.waitUntilCompleted()
    guard guardedCommand.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Temporal central-fit check GPU failure") }
    result.withUnsafeMutableBytes { selected.getBytes($0.baseAddress!,bytesPerRow: 17*16,from: MTLRegionMake2D(0,0,17,13),mipmapLevel: 0) }
    precondition(abs(result[6*17+6].x-8)<0.01,"Temporal evidence replaced a better central match")
    print("TEMPORAL PATCH: central correspondence protected against misleading neighbors")
}

func checkPatchPropagation() throws {
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw MotionSearchEngine.EngineError.deviceUnavailable }
    let library=try device.makeLibrary(source: denseMotionMSL,options: nil)
    let pipeline=try device.makeComputePipelineState(function: library.makeFunction(name: "densePatchPropagate")!)
    func texture(_ format: MTLPixelFormat,_ w: Int,_ h: Int) -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: w,height: h,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.shaderWrite]
        return device.makeTexture(descriptor: descriptor)!
    }
    let a=texture(.r32Float,64,48),b=texture(.r32Float,64,48),input=texture(.rgba32Float,17,13),output=texture(.rgba32Float,17,13)
    let source: [Float]=(0..<64*48).map { i in
        let x=i%64,y=i/64
        let value=(x*43+y*67+x*y*7)%700+100
        return Float(value)/1023
    }
    let target: [Float]=(0..<64*48).map { i in source[(i/64)*64+max(0,i%64-4)] }
    for (image,pixels) in [(a,source),(b,target)] { pixels.withUnsafeBytes { image.replace(region: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*4) } }
    var candidates=[SIMD4<Float>](repeating: .zero,count: 17*13)
    candidates[6*17+7]=SIMD4(4,0,1,0)
    candidates.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0,0,17,13),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 17*16) }
    let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    for (i,image) in [a,b,input,output].enumerated() { encoder.setTexture(image,index: i) }
    encoder.dispatchThreads(MTLSize(width: 17,height: 13,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Patch propagation GPU failure") }
    var result=[SIMD4<Float>](repeating: .zero,count: 17*13)
    result.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: 17*16,from: MTLRegionMake2D(0,0,17,13),mipmapLevel: 0) }
    precondition(candidates[6*17+8].x==0 && result[6*17+8].x==4,"Verified neighbor did not recover incorrect correspondence")
    precondition(result[6*17+7].x==4 && result[6*17+8].w<1e-6,"Propagation corrupted a verified trajectory")
    print("PATCH PROPAGATION: wrong 0px candidate recovered as verified 4px neighbor")
}

func checkPatchSurfaceAggregation() throws {
    guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw MotionSearchEngine.EngineError.deviceUnavailable }
    let library=try device.makeLibrary(source: denseMotionMSL,options: nil)
    let pipeline=try device.makeComputePipelineState(function: library.makeFunction(name: "densePatchAggregate")!)
    func texture(_ format: MTLPixelFormat,_ w: Int,_ h: Int) -> MTLTexture {
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: w,height: h,mipmapped: false)
        descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.shaderWrite]
        return device.makeTexture(descriptor: descriptor)!
    }
    let a=texture(.r32Float,64,48),b=texture(.r32Float,64,48),patches=texture(.rgba32Float,17,13),output=texture(.rgba32Float,64,48)
    let pixels=[Float](repeating: 0.4,count: 64*48)
    for image in [a,b] { pixels.withUnsafeBytes { image.replace(region: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*4) } }
    let candidates=(0..<17*13).map { SIMD4<Float>(($0%17+$0/17)%2==0 ? 0 : 8,0,1,0) }
    candidates.withUnsafeBytes { patches.replace(region: MTLRegionMake2D(0,0,17,13),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 17*16) }
    let command=queue.makeCommandBuffer()!,encoder=command.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    for (i,image) in [a,b,patches,output].enumerated() { encoder.setTexture(image,index: i) }
    encoder.dispatchThreads(MTLSize(width: 64,height: 48,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
    encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
    guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Patch aggregation GPU failure") }
    var field=[SIMD4<Float>](repeating: .zero,count: 64*48)
    field.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: 64*16,from: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0) }
    let v=field[24*64+32].x
    print("PATCH SURFACES: candidates 0/8px, selected=\(v)px")
    precondition(v==0 || v==8,"Patch aggregation invented a trajectory between separate surfaces")
    let coherent=candidates.map { SIMD4<Float>($0.x/16,0,1,0) }
    coherent.withUnsafeBytes { patches.replace(region: MTLRegionMake2D(0,0,17,13),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 17*16) }
    let second=queue.makeCommandBuffer()!,secondEncoder=second.makeComputeCommandEncoder()!
    secondEncoder.setComputePipelineState(pipeline)
    for (i,image) in [a,b,patches,output].enumerated() { secondEncoder.setTexture(image,index: i) }
    secondEncoder.dispatchThreads(MTLSize(width: 64,height: 48,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
    secondEncoder.endEncoding(); second.commit(); second.waitUntilCompleted()
    guard second.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Coherent patch aggregation GPU failure") }
    field.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: 64*16,from: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0) }
    precondition(abs(field[24*64+32].x-0.25)<1e-6,"Compatible subpixel trajectories lost aggregation")

    // Both trajectories match the center; only +8 matches its surrounding texture.
    let textured: [Float]=(0..<3072).map { i in
        let x=i%64,y=i/64
        let value=(x*43+y*67+x*y*7)%700+100
        return Float(value)/1023
    }
    var shifted: [Float]=(0..<3072).map { i in
        let row=(i/64)*64,column=max(0,i%64-8)
        return textured[row+column]
    }
    shifted[24*64+32]=textured[24*64+32]
    for (image,values) in [(a,textured),(b,shifted)] { values.withUnsafeBytes { image.replace(region: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 64*4) } }
    candidates.withUnsafeBytes { patches.replace(region: MTLRegionMake2D(0,0,17,13),mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: 17*16) }
    let third=queue.makeCommandBuffer()!,thirdEncoder=third.makeComputeCommandEncoder()!
    thirdEncoder.setComputePipelineState(pipeline)
    for (i,image) in [a,b,patches,output].enumerated() { thirdEncoder.setTexture(image,index: i) }
    thirdEncoder.dispatchThreads(MTLSize(width: 64,height: 48,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
    thirdEncoder.endEncoding(); third.commit(); third.waitUntilCompleted()
    guard third.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Ambiguous patch aggregation GPU failure") }
    field.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: 64*16,from: MTLRegionMake2D(0,0,64,48),mipmapLevel: 0) }
    print("PATCH SURFACE AMBIGUITY: selected=\(field[24*64+32].x)px, expected=8px")
    precondition(field[24*64+32].x==8,"An isolated matching pixel defeated the correct textured surface")
}

func checkDenseMotion(variational: Bool=false,finestIterations: Int=8,inverseSearch: Bool=false) throws {
    if inverseSearch { try checkPatchPropagation(); try checkPatchSurfaceAggregation() }
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
    let dense=try DenseMotionPrototype(width: w,height: h,variational: variational,finestIterations: finestIterations,inverseSearch: inverseSearch)
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
    var snapshots=0
    dense.diagnosticObserver={ name,width,height,field in
        precondition(!name.isEmpty && field.count==width*height)
        precondition(field.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
        snapshots+=1
    }
    let traced=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,times: [0,0.5,1],context: context)
    dense.diagnosticObserver=nil
    precondition(snapshots>0 && traced.map(\.pixels)==four.map(\.pixels) && traced[1].forward==four[1].forward && traced[1].backward==four[1].backward,"Diagnostic snapshots changed interpolation")

    print("DENSE FOUR LAYERS: MAE=\(error(four[1].pixels,denseLayerScene(4)))")
    let noContext=try dense.interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: 0.5)
    let fresh=try DenseMotionPrototype(width: w,height: h,variational: variational,finestIterations: finestIterations,inverseSearch: inverseSearch).interpolate(first: data(first),last: data(last),forward: forward,backward: backward,time: 0.5)
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
    precondition(noisyError<5,"Noisy retained neighbors corrupted central-pair motion")
    let odd=try DenseMotionPrototype(width: 65,height: 49,variational: variational,finestIterations: finestIterations)
    let oddPixels: [UInt16]=(0..<65*49).map { UInt16(($0*9)%1000) }
    let oddSeeds=[SIMD2<Int32>](repeating: .zero,count: 9*7)
    let oddResult=try odd.interpolate(first: data(oddPixels),last: data(oddPixels),forward: oddSeeds,backward: oddSeeds,time: 0.5)
    precondition(oddResult.pixels==oddPixels,"Odd geometry lost border pixels")
    print("OK — dense layered sequence, endpoints, static, deterministic output, invalid input and translation checks")
}
