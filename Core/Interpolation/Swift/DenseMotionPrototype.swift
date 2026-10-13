import Foundation
import Metal

/// Isolated luma prototype; no decoder, disk, UI, or production state.
public final class DenseMotionPrototype {
    public struct TemporalContext {
        public let before: Data, after: Data
        public let beforeInterval: Float, afterInterval: Float
        /// Neighbor intervals relative to the central pair's duration.
        /// shortcut: constant velocity across this window; acceleration and cuts need a different temporal model.
        public init(before: Data,after: Data,beforeInterval: Float,afterInterval: Float) {
            self.before=before; self.after=after
            self.beforeInterval=beforeInterval; self.afterInterval=afterInterval
        }
    }
    public struct Result {
        public let pixels: [UInt16]
        public let reliability: [Float]
        public let forward: [SIMD4<Float>]
        public let backward: [SIMD4<Float>]
        public let mappingResidual: [SIMD2<Float>]
        public let milliseconds: Double
    }
    private let width: Int, height: Int, blockSize: Int
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String:MTLComputePipelineState]
    private let raw: [MTLTexture]
    private let original: [MTLTexture]
    private let images: [[MTLTexture]]
    private let flows: [[[MTLTexture]]]
    private let seeds: [MTLBuffer]
    private let output: MTLTexture
    private let reliability: MTLTexture
    private let mappingResidual: MTLTexture
    private let variational: Bool
    private let finestIterations: Int
    private let projectedOwnership: Bool
    private let ownership: [MTLBuffer]
    private let dual: [[MTLTexture]]
    private let linear: [MTLTexture]

    public init(width: Int,height: Int,blockSize: Int=8,variational: Bool=false,finestIterations: Int=8,projectedOwnership: Bool=true) throws {
        guard width>=8,height>=8,width<=8192,height<=8192,blockSize>0,blockSize<=64 else { throw MotionSearchEngine.EngineError.pipeline("Invalid dense geometry") }
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw MotionSearchEngine.EngineError.deviceUnavailable }
        self.device=device; self.queue=queue
        self.width=width; self.height=height; self.blockSize=blockSize
        self.variational=variational
        guard finestIterations>=1,finestIterations<=8 else { throw MotionSearchEngine.EngineError.pipeline("Invalid finest-level iteration count") }
        self.finestIterations=finestIterations
        self.projectedOwnership=projectedOwnership
        ownership=try (0..<2).map { _ in
            guard let buffer=device.makeBuffer(length: width*height*4,options: .storageModeShared) else { throw MotionSearchEngine.EngineError.pipeline("Ownership allocation failed") }
            return buffer
        }
        let library=try device.makeLibrary(source: denseMotionMSL,options: nil)
        var compiled: [String:MTLComputePipelineState]=[:]
        for name in ["denseUpload","denseAnalysisBlur","denseDown","denseSeed","denseExpand","denseLK","denseRegularize","denseTVReset","denseTVLinearize","denseTVPrimal","denseTVDual","denseTVAssess","denseTemporalAssess","denseProject","denseSynthesize"] {
            guard let function=library.makeFunction(name: name) else { throw MotionSearchEngine.EngineError.pipeline("Missing \(name)") }
            compiled[name]=try device.makeComputePipelineState(function: function)
        }
        pipelines=compiled
        func texture(_ format: MTLPixelFormat,_ w: Int,_ h: Int) throws -> MTLTexture {
            let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,width: w,height: h,mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead,.shaderWrite]
            guard let result=device.makeTexture(descriptor: descriptor) else { throw MotionSearchEngine.EngineError.pipeline("Dense texture allocation failed") }
            return result
        }
        raw=try (0..<4).map { _ in try texture(.r16Uint,width,height) }
        original=try (0..<4).map { _ in try texture(.r32Float,width,height) }
        output=try texture(.r16Uint,width,height)
        reliability=try texture(.r32Float,width,height)
        mappingResidual=try texture(.rg32Float,width,height)
        var sizes=[(width,height)]
        while sizes.count<4,let last=sizes.last,last.0>=16,last.1>=16 { sizes.append(((last.0+1)/2,(last.1+1)/2)) }
        images=try (0..<4).map { _ in try sizes.map { try texture(.r32Float,$0.0,$0.1) } }
        flows=try (0..<2).map { _ in try sizes.map { size in try [texture(.rgba32Float,size.0,size.1),texture(.rgba32Float,size.0,size.1)] } }
        dual=variational ? try (0..<2).map { _ in try [texture(.rgba32Float,width,height),texture(.rgba32Float,width,height)] } : []
        linear=variational ? try (0..<2).map { _ in try texture(.rgba32Float,width,height) } : []
        let count=((width+blockSize-1)/blockSize)*((height+blockSize-1)/blockSize)
        seeds=try (0..<2).map { _ in
            guard let buffer=device.makeBuffer(length: count*MemoryLayout<SIMD2<Int32>>.stride,options: .storageModeShared) else { throw MotionSearchEngine.EngineError.pipeline("Dense seed allocation failed") }
            return buffer
        }
    }

    /// UInt16 work-plane luma in 0...1023; vectors in half-pixel units.
    /// Resources are reused; callers must serialize access to this instance.
    public func interpolate(first: Data,last: Data,forward: [SIMD2<Int32>],backward: [SIMD2<Int32>],time: Float,context: TemporalContext?=nil) throws -> Result {
        try interpolate(first: first,last: last,forward: forward,backward: backward,times: [time],context: context)[0]
    }

    /// One bounded pair analysis shared by up to four temporal samples.
    /// The first result's milliseconds includes analysis; subsequent results measure synthesis.
    public func interpolate(first: Data,last: Data,forward: [SIMD2<Int32>],backward: [SIMD2<Int32>],times: [Float],context: TemporalContext?=nil) throws -> [Result] {
        let gw=(width+blockSize-1)/blockSize,gh=(height+blockSize-1)/blockSize
        guard first.count==width*height*2,last.count==first.count,forward.count==gw*gh,backward.count==forward.count,!times.isEmpty,times.count<=4,times.allSatisfy({ $0.isFinite && $0>=0 && $0<=1 }),
              forward.allSatisfy({ abs(Int($0.x))<=width*2 && abs(Int($0.y))<=height*2 }),backward.allSatisfy({ abs(Int($0.x))<=width*2 && abs(Int($0.y))<=height*2 }) else {
            throw MotionSearchEngine.EngineError.pipeline("Invalid dense input")
        }
        var inputs=[first,last]
        if let context {
            guard context.before.count==first.count,context.after.count==first.count,
                  context.beforeInterval.isFinite,context.afterInterval.isFinite,
                  context.beforeInterval>=0.25,context.beforeInterval<=4,
                  context.afterInterval>=0.25,context.afterInterval<=4 else {
                throw MotionSearchEngine.EngineError.pipeline("Invalid dense temporal context")
            }
            inputs += [context.before,context.after]
        }
        for data in inputs {
            let normalized=data.withUnsafeBytes { bytes in stride(from: 0,to: bytes.count,by: 2).allSatisfy { bytes.loadUnaligned(fromByteOffset: $0,as: UInt16.self)<=1023 } }
            guard normalized else { throw MotionSearchEngine.EngineError.pipeline("Dense luma must be normalized to 10-bit") }
        }
        let start=DispatchTime.now().uptimeNanoseconds
        let region=MTLRegionMake2D(0,0,width,height)
        for (i,data) in inputs.enumerated() { data.withUnsafeBytes { raw[i].replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: width*2) } }
        for (i,field) in [forward,backward].enumerated() { field.withUnsafeBytes { bytes in _=memcpy(seeds[i].contents(),bytes.baseAddress!,bytes.count) } }
        guard var command=queue.makeCommandBuffer() else { throw MotionSearchEngine.EngineError.pipeline("Dense command allocation failed") }
        func encode(_ name: String,_ textures: [MTLTexture],_ target: MTLTexture,_ setup: (MTLComputeCommandEncoder)->Void = { _ in }) throws {
            guard let encoder=command.makeComputeCommandEncoder(),let pipeline=pipelines[name] else { throw MotionSearchEngine.EngineError.pipeline("Dense encoder allocation failed") }
            encoder.setComputePipelineState(pipeline)
            for (i,texture) in textures.enumerated() { encoder.setTexture(texture,index: i) }
            setup(encoder)
            encoder.dispatchThreads(MTLSize(width: target.width,height: target.height,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
            encoder.endEncoding()
        }
        for direction in inputs.indices {
            try encode("denseUpload",[raw[direction],original[direction]],original[direction])
            try encode("denseAnalysisBlur",[original[direction],images[direction][0]],images[direction][0])
            for level in 1..<images[direction].count { try encode("denseDown",[images[direction][level-1],images[direction][level]],images[direction][level]) }
        }
        var finalFlows: [MTLTexture]=[]
        for direction in 0..<2 {
            var previous: MTLTexture?
            for level in stride(from: images[direction].count-1,through: 0,by: -1) {
                let buffers=flows[direction][level]
                if let previous=previous { try encode("denseExpand",[previous,buffers[0]],buffers[0]) }
                else {
                    var geometry=SIMD4<UInt32>(UInt32(gw),UInt32(gh),UInt32(blockSize),UInt32(1<<level))
                    try encode("denseSeed",[buffers[0]],buffers[0]) { encoder in
                        encoder.setBuffer(seeds[direction],offset: 0,index: 0)
                        encoder.setBytes(&geometry,length: MemoryLayout<SIMD4<UInt32>>.stride,index: 1)
                    }
                }
                var intervals=SIMD2<Float>.zero
                if let context {
                    intervals=direction==0 ? SIMD2(-context.beforeInterval,1+context.afterInterval) : SIMD2(1+context.beforeInterval,-context.afterInterval)
                }
                for _ in 0..<(level==0 ? finestIterations : 8) {
                    try encode("denseLK",[images[direction][level],images[1-direction][level],buffers[0],buffers[1],images[2][level],images[3][level]],buffers[1]) {
                        $0.setBytes(&intervals,length: MemoryLayout<SIMD2<Float>>.stride,index: 0)
                    }
                    try encode("denseRegularize",[images[direction][level],buffers[1],buffers[0]],buffers[0])
                }
                previous=buffers[0]
            }
            finalFlows.append(previous!)
        }
        if variational {
            for direction in 0..<2 { try encode("denseTVReset",[dual[direction][0]],dual[direction][0]) }
            for _ in 0..<4 {
                for direction in 0..<2 {
                    var current=finalFlows[direction]
                    var next=current === flows[direction][0][0] ? flows[direction][0][1] : flows[direction][0][0]
                    var dualInput=dual[direction][0],dualOutput=dual[direction][1]
                    try encode("denseTVLinearize",[images[direction][0],images[1-direction][0],current,linear[direction],finalFlows[1-direction]],linear[direction])
                    for _ in 0..<24 {
                        try encode("denseTVPrimal",[current,dualInput,linear[direction],next],next)
                        try encode("denseTVDual",[next,dualInput,images[direction][0],dualOutput,current],dualOutput)
                        swap(&current,&next); swap(&dualInput,&dualOutput)
                    }
                    finalFlows[direction]=current
                }
            }
        }
        var assessed: [MTLTexture]=[]
        for direction in 0..<2 {
            let current=finalFlows[direction]
            let next=current === flows[direction][0][0] ? flows[direction][0][1] : flows[direction][0][0]
            try encode("denseTVAssess",[images[direction][0],images[1-direction][0],current,next,finalFlows[1-direction]],next)
            assessed.append(next)
        }
        finalFlows=assessed
        if let context {
            var temporal: [MTLTexture]=[]
            for direction in 0..<2 {
                let current=finalFlows[direction]
                let next=current === flows[direction][0][0] ? flows[direction][0][1] : flows[direction][0][0]
                var intervals=direction==0 ? SIMD2<Float>(-context.beforeInterval,1+context.afterInterval) : SIMD2<Float>(1+context.beforeInterval,-context.afterInterval)
                try encode("denseTemporalAssess",[original[direction],original[2],original[3],current,next],next) {
                    $0.setBytes(&intervals,length: MemoryLayout<SIMD2<Float>>.stride,index: 0)
                }
                temporal.append(next)
            }
            finalFlows=temporal
        }
        var results: [Result]=[]
        var fields: [[SIMD4<Float>]]=[]
        for (sample,time) in times.enumerated() {
            let sampleStart=sample==0 ? start : DispatchTime.now().uptimeNanoseconds
            if sample>0 {
                guard let nextCommand=queue.makeCommandBuffer() else { throw MotionSearchEngine.EngineError.pipeline("Dense synthesis command allocation failed") }
                command=nextCommand
            }
            var t=time
            var indexBits=UInt32(UInt32.bitWidth-UInt32(width*height).leadingZeroBitCount)
            var projection=SIMD2<UInt32>(indexBits,projectedOwnership && first != last && time>0 && time<1 ? 1 : 0)
            if projection.y != 0 {
                guard let clear=command.makeBlitCommandEncoder() else { throw MotionSearchEngine.EngineError.pipeline("Ownership reset failed") }
                for buffer in ownership { clear.fill(buffer: buffer,range: 0..<width*height*4,value: 0) }
                clear.endEncoding()
                for direction in 0..<2 {
                    var amount=direction==0 ? time : 1-time
                    try encode("denseProject",[original[direction],original[1-direction],finalFlows[direction],finalFlows[1-direction]],output) {
                        $0.setBuffer(ownership[direction],offset: 0,index: 0)
                        $0.setBytes(&indexBits,length: 4,index: 1)
                        $0.setBytes(&amount,length: 4,index: 2)
                    }
                }
            }
            try encode("denseSynthesize",[original[0],original[1],finalFlows[0],finalFlows[1],output,reliability,mappingResidual],output) {
                $0.setBytes(&t,length: MemoryLayout<Float>.stride,index: 0)
                $0.setBytes(&projection,length: 8,index: 1)
                $0.setBuffer(ownership[0],offset: 0,index: 2)
                $0.setBuffer(ownership[1],offset: 0,index: 3)
            }
            command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline(command.error?.localizedDescription ?? "Dense GPU failure") }
            let elapsed=Double(DispatchTime.now().uptimeNanoseconds-sampleStart)/1e6
            var pixels=[UInt16](repeating: 0,count: width*height),confidence=[Float](repeating: 0,count: width*height)
            pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: width*2,from: region,mipmapLevel: 0) }
            confidence.withUnsafeMutableBytes { reliability.getBytes($0.baseAddress!,bytesPerRow: width*4,from: region,mipmapLevel: 0) }
            var errors=[SIMD2<Float>](repeating: .zero,count: width*height)
            errors.withUnsafeMutableBytes { mappingResidual.getBytes($0.baseAddress!,bytesPerRow: width*8,from: region,mipmapLevel: 0) }
            if sample==0 {
                fields=finalFlows.map { texture -> [SIMD4<Float>] in
                    var array=[SIMD4<Float>](repeating: .zero,count: width*height)
                    array.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow: width*16,from: region,mipmapLevel: 0) }
                    return array
                }
                guard fields.joined().allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite }) else { throw MotionSearchEngine.EngineError.pipeline("Nonfinite dense field") }
            }
            guard confidence.allSatisfy({ $0.isFinite }) else { throw MotionSearchEngine.EngineError.pipeline("Nonfinite dense output") }
            guard errors.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw MotionSearchEngine.EngineError.pipeline("Nonfinite dense transport") }
            results.append(Result(pixels: pixels,reliability: confidence,forward: fields[0],backward: fields[1],mappingResidual: errors,milliseconds: elapsed))
        }
        return results
    }
}
