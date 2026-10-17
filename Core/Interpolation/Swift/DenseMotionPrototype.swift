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
    private let nativeCoordinates: MTLTexture
    private let nativeBlend: MTLTexture
    private let variational: Bool
    private let finestIterations: Int
    private let projectedOwnership: Bool
    private let ownership: [MTLBuffer]
    /// Intrusive diagnostic snapshots; callers must serialize access and exclude timings from benchmarks.
    public var diagnosticObserver: ((String,Int,Int,[SIMD4<Float>])->Void)?
    /// Requires RIFT_DENSE_CANDIDATES=1 at construction. 16 slots/patch; w=0 unused,
    /// w=1 evaluated/admitted, w=-1 rejected by temporal central-cost gate. Intrusive, offline only.
    public var candidateObserver: ((String,Int,Int,[SIMD4<Float>])->Void)?
    /// Offline-only, opt-in final-field replacement. Never connected by the player.
    /// Requires RIFT_DENSE_ORACLE=1; callers serialize access and exclude diagnostic timings.
    public var diagnosticFlowOverride: (([SIMD4<Float>],[SIMD4<Float>])->([SIMD4<Float>],[SIMD4<Float>]))?
    private let oracleEnabled=ProcessInfo.processInfo.environment["RIFT_DENSE_ORACLE"] == "1"
    /// Read-only, once per pair. Requires RIFT_PAIR_CONFIDENCE=1; no disk I/O in this module.
    public var pairConfidenceObserver: ((Int,Int,[SIMD4<Float>])->Void)?
    /// Offline temporal velocity evidence, normalized to this pair's interval; never used by synthesis.
    public var diagnosticTemporalVectors: [SIMD4<Float>]?
    private let pairConfidence: PairConfidenceDiagnostics?
    private let candidateTrace: MTLBuffer?
    private let inverseSearch: Bool
    private let profileStages=ProcessInfo.processInfo.environment["RIFT_DENSE_PROFILE"] == "1"
    private let temporalPatchSearch=ProcessInfo.processInfo.environment["RIFT_PATCH_TEMPORAL"] != "0"
    private let patches: [MTLTexture]
    private let patchScratch: [MTLTexture]
    private let patchJacobians: [MTLTexture]
    private let dual: [[MTLTexture]]
    private let linear: [MTLTexture]

    public init(width: Int,height: Int,blockSize: Int=8,variational: Bool=false,finestIterations: Int=8,projectedOwnership: Bool=true,inverseSearch: Bool=false) throws {
        guard width>=8,height>=8,width<=8192,height<=8192,blockSize>0,blockSize<=64 else { throw MotionSearchEngine.EngineError.pipeline("Invalid dense geometry") }
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw MotionSearchEngine.EngineError.deviceUnavailable }
        self.device=device; self.queue=queue
        self.width=width; self.height=height; self.blockSize=blockSize
        self.variational=variational
        guard finestIterations>=1,finestIterations<=8 else { throw MotionSearchEngine.EngineError.pipeline("Invalid finest-level iteration count") }
        self.finestIterations=finestIterations
        self.projectedOwnership=projectedOwnership
        self.inverseSearch=inverseSearch
        ownership=try (0..<2).map { _ in
            guard let buffer=device.makeBuffer(length: width*height*4,options: .storageModeShared) else { throw MotionSearchEngine.EngineError.pipeline("Ownership allocation failed") }
            return buffer
        }
        pairConfidence=ProcessInfo.processInfo.environment["RIFT_PAIR_CONFIDENCE"] == "1" ? try PairConfidenceDiagnostics(device: device,width: width,height: height) : nil
        let candidateMode=ProcessInfo.processInfo.environment["RIFT_DENSE_CANDIDATES"] == "1"
        if candidateMode {
            guard let trace=device.makeBuffer(length: max(((width+3)/4+1)*((height+3)/4+1)*16*16,width*height*32),options: .storageModeShared) else { throw MotionSearchEngine.EngineError.pipeline("Candidate trace allocation failed") }
            candidateTrace=trace
        } else { candidateTrace=nil }
        let staticMotion=ProcessInfo.processInfo.environment["RIFT_STATIC_MOTION_GUARD"] == "1"
        let library=try device.makeLibrary(source: (candidateMode ? "#define DENSE_CANDIDATES 1\n" : "")+(staticMotion ? "#define DENSE_STATIC_MOTION 1\n" : "")+denseMotionMSL,options: nil)
        var compiled: [String:MTLComputePipelineState]=[:]
        for name in ["denseUpload","denseAnalysisBlur","denseDown","denseSeed","denseExpand","densePatchSearch","densePatchAffine","densePatchAggregateAffine","densePatchPropagate","densePatchTemporalSelect","densePatchAggregate","denseLK","denseRegularize","denseTVReset","denseTVLinearize","denseTVPrimal","denseTVDual","denseTVAssess","denseTemporalAssess","denseProject","denseSynthesize"] {
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
        nativeCoordinates=try texture(.rgba32Float,width,height)
        nativeBlend=try texture(.r32Float,width,height)
        var sizes=[(width,height)]
        while sizes.count<4,let last=sizes.last,last.0>=16,last.1>=16 { sizes.append(((last.0+1)/2,(last.1+1)/2)) }
        images=try (0..<4).map { _ in try sizes.map { try texture(.r32Float,$0.0,$0.1) } }
        patches=inverseSearch ? try sizes.map { try texture(.rgba32Float,($0.0+3)/4+1,($0.1+3)/4+1) } : []
        patchScratch=inverseSearch ? try sizes.map { try texture(.rgba32Float,($0.0+3)/4+1,($0.1+3)/4+1) } : []
        patchJacobians=inverseSearch && ProcessInfo.processInfo.environment["RIFT_PATCH_AFFINE"] == "1" ? try sizes.map { try texture(.rgba32Float,($0.0+3)/4+1,($0.1+3)/4+1) } : []
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
    /// Milliseconds are incremental elapsed costs; their sum covers analysis and all syntheses.
    /// With batched native output, only the final increment waits for GPU completion.
    /// nativeRenderer may encode into the supplied command, but must not submit it.
    public func interpolate(first: Data,last: Data,forward: [SIMD2<Int32>],backward: [SIMD2<Int32>],times: [Float],context: TemporalContext?=nil,nativeRenderer: ((Float,MTLTexture,MTLTexture,MTLCommandBuffer)->Void)?=nil,downloadResults: Bool=true) throws -> [Result] {
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
        // Identical held neighbors contain no evidence for extrapolating the central motion.
        let context=context.flatMap { $0.before==first && $0.after==last ? nil : $0 }
        let start=DispatchTime.now().uptimeNanoseconds
        var gpuStages: [String:Double]=[:]
        func illuminationOffset(_ target: Data) -> Float {
            guard inverseSearch else { return 0 }
            return first.withUnsafeBytes { a in target.withUnsafeBytes { b in
                var sum=0.0,squares=0.0,count=0
                for y in stride(from: 0,to: height,by: 8) { for x in stride(from: 0,to: width,by: 8) {
                    var delta=0.0,n=0
                    for yy in y..<min(y+8,height) { for xx in x..<min(x+8,width) {
                        let k=(yy*width+xx)*2
                        delta+=Double(b.loadUnaligned(fromByteOffset: k,as: UInt16.self))-Double(a.loadUnaligned(fromByteOffset: k,as: UInt16.self)); n+=1
                    } }
                    delta/=Double(n); sum+=delta; squares+=delta*delta; count+=1
                } }
                let mean=sum/Double(count),variance=max(0,squares/Double(count)-mean*mean)
                // Compensate a coherent exposure change, not movement-induced local brightness changes.
                return mean*mean>variance ? Float(mean/1023) : 0
            } }
        }
        let offsets: [Float]=[0]+inputs.dropFirst().map(illuminationOffset)
        func sampledDifference(_ i: Int,_ j: Int) -> Float {
            inputs[i].withUnsafeBytes { a in inputs[j].withUnsafeBytes { b in
                var sum: Float=0,count: Float=0
                for y in stride(from: 0,to: height,by: 8) { for x in stride(from: 0,to: width,by: 8) {
                    let k=(y*width+x)*2
                    let delta=Float(a.loadUnaligned(fromByteOffset: k,as: UInt16.self))-Float(b.loadUnaligned(fromByteOffset: k,as: UInt16.self))
                    sum+=abs(delta/1023-(offsets[i]-offsets[j])); count+=1
                } }
                return sum/max(1,count)
            } }
        }
        var temporalNeighbors=SIMD2<UInt32>.zero
        if temporalPatchSearch,context != nil {
            let heldLimit=max(2.0/1023,sampledDifference(0,1)*0.25)
            temporalNeighbors=SIMD2(min(sampledDifference(2,0),sampledDifference(2,1))>heldLimit ? 1 : 0,
                                   min(sampledDifference(3,0),sampledDifference(3,1))>heldLimit ? 1 : 0)
        }
        let region=MTLRegionMake2D(0,0,width,height)
        for (i,data) in inputs.enumerated() { data.withUnsafeBytes { raw[i].replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: width*2) } }
        for (i,field) in [forward,backward].enumerated() { field.withUnsafeBytes { bytes in _=memcpy(seeds[i].contents(),bytes.baseAddress!,bytes.count) } }
        guard var command=queue.makeCommandBuffer() else { throw MotionSearchEngine.EngineError.pipeline("Dense command allocation failed") }
        var traceLabel=""
        func encode(_ name: String,_ textures: [MTLTexture],_ target: MTLTexture,_ setup: (MTLComputeCommandEncoder)->Void = { _ in }) throws {
            let captureCandidates=candidateTrace != nil && ["densePatchSearch","densePatchPropagate","densePatchTemporalSelect"].contains(name)
            if captureCandidates { memset(candidateTrace!.contents(),0,candidateTrace!.length) }
            guard let encoder=command.makeComputeCommandEncoder(),let pipeline=pipelines[name] else { throw MotionSearchEngine.EngineError.pipeline("Dense encoder allocation failed") }
            encoder.setComputePipelineState(pipeline)
            for (i,texture) in textures.enumerated() { encoder.setTexture(texture,index: i) }
            setup(encoder)
            if captureCandidates || (candidateTrace != nil && name=="denseSynthesize") { encoder.setBuffer(candidateTrace,offset: 0,index: 10) }
            encoder.dispatchThreads(MTLSize(width: target.width,height: target.height,depth: 1),threadsPerThreadgroup: MTLSize(width: 8,height: 8,depth: 1))
            encoder.endEncoding()
            let trace=diagnosticObserver != nil && target.pixelFormat == .rgba32Float
            if profileStages || trace || captureCandidates {
                command.commit(); command.waitUntilCompleted()
                guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Dense profiling GPU failure") }
                gpuStages[name,default: 0]+=(command.gpuEndTime-command.gpuStartTime)*1000
                if captureCandidates,let observer=candidateObserver {
                    let count=target.width*target.height*16
                    let records=Array(UnsafeBufferPointer(start: candidateTrace!.contents().assumingMemoryBound(to: SIMD4<Float>.self),count: count))
                    observer("\(traceLabel)/\(name)",target.width,target.height,records)
                }
                if trace {
                    var field=[SIMD4<Float>](repeating: .zero,count: target.width*target.height)
                    field.withUnsafeMutableBytes { target.getBytes($0.baseAddress!,bytesPerRow: target.width*16,from: MTLRegionMake2D(0,0,target.width,target.height),mipmapLevel: 0) }
                    if name=="densePatchAggregate" || name=="densePatchAggregateAffine" {
                        let input=textures[2]
                        var proposals=[SIMD4<Float>](repeating: .zero,count: input.width*input.height)
                        proposals.withUnsafeMutableBytes { input.getBytes($0.baseAddress!,bytesPerRow: input.width*16,from: MTLRegionMake2D(0,0,input.width,input.height),mipmapLevel: 0) }
                        diagnosticObserver?("\(traceLabel)/aggregateCandidates",input.width,input.height,proposals)
                    }
                    diagnosticObserver?("\(traceLabel)/\(name)",target.width,target.height,field)
                }
                guard let next=queue.makeCommandBuffer() else { throw MotionSearchEngine.EngineError.pipeline("Dense profiling command allocation failed") }
                command=next
            }
        }
        for direction in inputs.indices {
            try encode("denseUpload",[raw[direction],original[direction]],original[direction])
            var offset=offsets[direction]
            try encode("denseAnalysisBlur",[original[direction],images[direction][0]],images[direction][0]) { $0.setBytes(&offset,length: 4,index: 0) }
            for level in 1..<images[direction].count { try encode("denseDown",[images[direction][level-1],images[direction][level]],images[direction][level]) }
        }
        var finalFlows: [MTLTexture]=[]
        for direction in 0..<2 {
            var previous: MTLTexture?
            for level in stride(from: images[direction].count-1,through: 0,by: -1) {
                traceLabel="d\(direction)/l\(level)"
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
                if inverseSearch {
                    try encode("densePatchSearch",[images[direction][level],images[1-direction][level],buffers[0],patches[level]],patches[level])
                    try encode("densePatchPropagate",[images[direction][level],images[1-direction][level],patches[level],patchScratch[level]],patchScratch[level])
                    try encode("densePatchPropagate",[images[direction][level],images[1-direction][level],patchScratch[level],patches[level]],patches[level])
                    var selected=patches[level]
                    if level>=2,temporalNeighbors.x != 0 || temporalNeighbors.y != 0 {
                        var evidence=SIMD2(temporalNeighbors.x==0 ? 0 : intervals.x,temporalNeighbors.y==0 ? 0 : intervals.y)
                        try encode("densePatchTemporalSelect",[images[direction][level],images[1-direction][level],patches[level],patchScratch[level],images[2][level],images[3][level]],patchScratch[level]) {
                            $0.setBytes(&evidence,length: MemoryLayout<SIMD2<Float>>.stride,index: 0)
                        }
                        selected=patchScratch[level]
                    }
                    if !patchJacobians.isEmpty {
                        let affineOutput=selected === patches[level] ? patchScratch[level] : patches[level]
                        var geometry=SIMD4<UInt32>(UInt32(gw),UInt32(gh),UInt32(blockSize),UInt32(1<<level))
                        var exposure=offsets[1-direction]-offsets[direction]
                        try encode("densePatchAffine",[images[direction][level],images[1-direction][level],selected,affineOutput,patchJacobians[level],original[direction],original[1-direction]],affineOutput) {
                            $0.setBuffer(seeds[direction],offset: 0,index: 0)
                            $0.setBytes(&geometry,length: MemoryLayout<SIMD4<UInt32>>.stride,index: 1)
                            $0.setBytes(&exposure,length: MemoryLayout<Float>.stride,index: 2)
                        }
                        try encode("densePatchAggregateAffine",[images[direction][level],images[1-direction][level],affineOutput,buffers[0],patchJacobians[level]],buffers[0])
                    } else {
                        try encode("densePatchAggregate",[images[direction][level],images[1-direction][level],selected,buffers[0]],buffers[0])
                    }
                } else { for _ in 0..<(level==0 ? finestIterations : 8) {
                    try encode("denseLK",[images[direction][level],images[1-direction][level],buffers[0],buffers[1],images[2][level],images[3][level]],buffers[1]) {
                        $0.setBytes(&intervals,length: MemoryLayout<SIMD2<Float>>.stride,index: 0)
                    }
                    try encode("denseRegularize",[images[direction][level],buffers[1],buffers[0]],buffers[0])
                } }
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
            traceLabel="d\(direction)/assessment"
            let current=finalFlows[direction]
            let next=current === flows[direction][0][0] ? flows[direction][0][1] : flows[direction][0][0]
            try encode("denseTVAssess",[images[direction][0],images[1-direction][0],current,next,finalFlows[1-direction]],next)
            assessed.append(next)
        }
        finalFlows=assessed
        // Patch search uses temporal evidence for selection, retaining central closure for synthesis.
        if let context,!inverseSearch {
            var temporal: [MTLTexture]=[]
            for direction in 0..<2 {
                let current=finalFlows[direction]
                let next=current === flows[direction][0][0] ? flows[direction][0][1] : flows[direction][0][0]
                var intervals=direction==0 ? SIMD2<Float>(-context.beforeInterval,1+context.afterInterval) : SIMD2<Float>(1+context.beforeInterval,-context.afterInterval)
                var exposure=SIMD2(offsets[2]-offsets[direction],offsets[3]-offsets[direction])
                try encode("denseTemporalAssess",[original[direction],original[2],original[3],current,next],next) {
                    $0.setBytes(&intervals,length: MemoryLayout<SIMD2<Float>>.stride,index: 0)
                    $0.setBytes(&exposure,length: MemoryLayout<SIMD2<Float>>.stride,index: 1)
                }
                temporal.append(next)
            }
            finalFlows=temporal
        }
        if oracleEnabled,let override=diagnosticFlowOverride {
            command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline("Oracle readback failed") }
            let fields=finalFlows.map { texture -> [SIMD4<Float>] in
                var values=[SIMD4<Float>](repeating: .zero,count: width*height)
                values.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!,bytesPerRow: width*16,from: region,mipmapLevel: 0) }
                return values
            }
            let replacement=override(fields[0],fields[1])
            for (texture,values) in zip(finalFlows,[replacement.0,replacement.1]) {
                guard values.count==width*height,values.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite && abs($0.x)<=Float(width)*2 && abs($0.y)<=Float(height)*2 && $0.z>=0 && $0.z<=1 }) else { throw MotionSearchEngine.EngineError.pipeline("Invalid oracle field") }
                values.withUnsafeBytes { texture.replace(region: region,mipmapLevel: 0,withBytes: $0.baseAddress!,bytesPerRow: width*16) }
            }
            guard let next=queue.makeCommandBuffer() else { throw MotionSearchEngine.EngineError.pipeline("Oracle synthesis allocation failed") }
            command=next
        }
        try pairConfidence?.encode(command: command,images: original,fields: finalFlows,vectors: diagnosticTemporalVectors,offset: offsets[1])
        var results: [Result]=[]
        var fields: [[SIMD4<Float>]]=[]
        let batchNative = !downloadResults && !profileStages && diagnosticObserver == nil && candidateTrace == nil
        var accountedMS=0.0
        for (sample,time) in times.enumerated() {
            let sampleStart=sample==0 ? start : DispatchTime.now().uptimeNanoseconds
            if sample>0 && !batchNative {
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
                    var offset=direction==0 ? offsets[1] : -offsets[1]
                    try encode("denseProject",[original[direction],original[1-direction],finalFlows[direction],finalFlows[1-direction]],output) {
                        $0.setBuffer(ownership[direction],offset: 0,index: 0)
                        $0.setBytes(&indexBits,length: 4,index: 1)
                        $0.setBytes(&amount,length: 4,index: 2)
                        $0.setBytes(&offset,length: 4,index: 3)
                    }
                }
            }
            var offset=offsets[1]
            try encode("denseSynthesize",[original[0],original[1],finalFlows[0],finalFlows[1],output,reliability,mappingResidual,nativeCoordinates,nativeBlend],output) {
                $0.setBytes(&t,length: MemoryLayout<Float>.stride,index: 0)
                $0.setBytes(&projection,length: 8,index: 1)
                $0.setBuffer(ownership[0],offset: 0,index: 2)
                $0.setBuffer(ownership[1],offset: 0,index: 3)
                $0.setBytes(&offset,length: 4,index: 4)
            }
            nativeRenderer?(time,nativeCoordinates,nativeBlend,command)
            // The native consumer encodes before shared maps are reused by the next sample.
            if !batchNative || sample==times.count-1 {
                command.commit(); command.waitUntilCompleted()
                guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline(command.error?.localizedDescription ?? "Dense GPU failure") }
            }
            if let observer=diagnosticObserver {
                var coordinates=[SIMD4<Float>](repeating: .zero,count: width*height)
                coordinates.withUnsafeMutableBytes { nativeCoordinates.getBytes($0.baseAddress!,bytesPerRow: width*16,from: region,mipmapLevel: 0) }
                if let candidateTrace {
                    let records=candidateTrace.contents().assumingMemoryBound(to: SIMD4<Float>.self)
                    let initial=(0..<width*height).map { records[2*$0] }
                    let flags=(0..<width*height).map { records[2*$0+1] }
                    observer("synthesis/t\(time)/inverseCoordinates",width,height,initial)
                    observer("synthesis/t\(time)/decisions",width,height,flags)
                }
                observer("synthesis/t\(time)/coordinates",width,height,coordinates)
                var weights=[Float](repeating: 0,count: width*height)
                weights.withUnsafeMutableBytes { nativeBlend.getBytes($0.baseAddress!,bytesPerRow: width*4,from: region,mipmapLevel: 0) }
                observer("synthesis/t\(time)/blend",width,height,weights.map { SIMD4($0,0,0,0) })
            }
            if profileStages { gpuStages["nativeColor",default: 0]+=(command.gpuEndTime-command.gpuStartTime)*1000 }
            let cumulativeMS=Double(DispatchTime.now().uptimeNanoseconds-start)/1e6
            let elapsed=batchNative ? max(0,cumulativeMS-accountedMS) : Double(DispatchTime.now().uptimeNanoseconds-sampleStart)/1e6
            accountedMS=cumulativeMS
            if !downloadResults {
                results.append(Result(pixels: [],reliability: [],forward: [],backward: [],mappingResidual: [],milliseconds: elapsed))
                continue
            }
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
        if profileStages {
            let stages=gpuStages.keys.sorted().map { "\($0)=\(String(format: "%.3f",gpuStages[$0]!))ms" }.joined(separator: " ")
            print("DENSE GPU PROFILE \(width)x\(height) outputs=\(times.count) \(stages)")
        }
        if let pairConfidence,let observer=pairConfidenceObserver {observer(pairConfidence.width,pairConfidence.height,pairConfidence.read())}
        return results
    }
}
