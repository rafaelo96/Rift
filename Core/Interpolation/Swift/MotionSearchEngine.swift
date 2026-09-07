import Foundation
import Metal

// MARK: - MotionSearchEngine
//
// Metal wrapper for the hierarchical block-matching measurement prototype.
// Owns the pyramid textures and MV buffers (bounded: one working pair at a
// time — a few MB total), compiles the embedded MSL at init, and runs each
// stage as its own command buffer so per-stage GPU time is measured directly.
//
// Level indexing follows the reference pyramid: index 0 is the finest level
// (L0 = full 480p work size, block 8x8) and index 3 the coarsest (144x60,
// block 16x16). Search runs coarse-to-fine (3 → 0); level i>? seeds its
// search center from the MV buffer of the coarser next level, scaled by the
// geometry (a coarse pixel = 2 fine pixels, so inherited MVs are already in
// half-pel units and stay x2 per level).

/// Pyramid geometry + search config for one level.
public struct LevelSpec: Sendable {
    public let width: Int
    public let height: Int
    public let blockSize: Int
    /// Search radius in half-pel units (even numbers = pixel-aligned candidates).
    public let searchHalfPel: Int32
    public let halfPelRefine: Bool
    /// per-axis grid-inherit factor from the coarser level (blockSizeRatio * 2).
    public let inheritFactor: Int

    public init(width: Int, height: Int, blockSize: Int,
                searchHalfPel: Int32, halfPelRefine: Bool, inheritFactor: Int) {
        self.width = width
        self.height = height
        self.blockSize = blockSize
        self.searchHalfPel = searchHalfPel
        self.halfPelRefine = halfPelRefine
        self.inheritFactor = inheritFactor
    }
}

/// Mirror of the MSL MEUniforms layout (must stay field-for-field identical).
struct MEUniforms {
    var level: UInt32
    var width: UInt32
    var height: UInt32
    var blockSize: UInt32
    var gridW: UInt32
    var gridH: UInt32
    var searchHalfPel: Int32
    var lambdaPx: UInt32
    var halfPelRefine: UInt32
    var clearWinGate: UInt32
    var hasInherited: UInt32
    var inheritedGrid: SIMD2<UInt32>
    var inheritFactor: UInt32
    var temporalGatePx: UInt32
    var hasTemporalPrev: UInt32
}

/// Measurement stages in report order.
public enum SEStage: Int, CaseIterable {
    case downL1, downL2, downL3
    case searchL3, searchL2, searchL1, searchL0

    public var label: String {
        switch self {
        case .downL1: return "pyramid ⟶ L1 (576x240)"
        case .downL2: return "pyramid ⟶ L2 (288x120)"
        case .downL3: return "pyramid ⟶ L3 (144x60)"
        case .searchL3: return "search L3 (blocks 9x4, bs16)"
        case .searchL2: return "search L2 (blocks 18x8, bs16)"
        case .searchL1: return "search L1 (blocks 36x15, bs16)"
        case .searchL0: return "search L0 (blocks 144x60, bs8, halfpel)"
        }
    }
}

/// Per-pair timing breakdown: GPU stage times (SEStage order) + host upload time.
public struct PairTimes {
    public let stages: [Double]
    public let uploadMS: Double

    public init(stages: [Double], uploadMS: Double) {
        self.stages = stages
        self.uploadMS = uploadMS
    }
}

public final class MotionSearchEngine {
    public enum EngineError: Error, CustomStringConvertible {
        case deviceUnavailable
        case libraryCompile(String)
        case pipeline(String)

        public var description: String {
            switch self {
            case .deviceUnavailable: return "MVProbe: no Metal device"
            case .libraryCompile(let m): return "MVProbe: MSL compile failed — \(m)"
            case .pipeline(let m): return "MVProbe: pipeline creation failed — \(m)"
            }
        }
    }

    public let levels: Int
    public let spec: [LevelSpec]
    public let lambdaPx: UInt32

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pyramidPSO: MTLComputePipelineState
    private let searchPSO: MTLComputePipelineState
    private let medianPSO: MTLComputePipelineState?
    private let temporalPSO: MTLComputePipelineState?
    /// Dead-zone snap on the post-median L0 field (|MV| <= 0.5px → 0).
    /// See MSL `mvDeadZone`.
    private let deadZonePSO: MTLComputePipelineState?

    private var curTex: [MTLTexture?] = []
    private var refTex: [MTLTexture?] = []
    private var mvBuffer: [MTLBuffer?] = []
    /// Second L0 buffer: 3x3 vector-median smoothing output (search writes
    /// mvBuffer[0], median writes here). Kept only for level 0.
    private var mvBufferSmoothed: MTLBuffer?
    /// Clear-win gate: L0 keeps an MV only if it beats zero displacement by a
    /// real margin (kills smooth-region noise). Default true.
    private let gateL0: Bool
    /// Temporal EMA gate: max accepted per-block |MV change| in px between
    /// consecutive pairs to blend toward the previous pair's value (0 = off).
    /// See MSL `mvTemporalEMA`. Requires smoothL0 (operates on the median output).
    public let temporalGatePx: UInt32
    /// State for the temporal pass: previous pair's post-EMA field + output buffer.
    private var mvBufferTemporalOut: MTLBuffer?
    private var mvBufferTemporalPrev: MTLBuffer?
    private var hasTemporalPrev = false

    /// Block grid dims per level (flat block count = gridW * gridH).
    public var grids: [(w: Int, h: Int)] { spec.map { (($0.width + $0.blockSize - 1) / $0.blockSize,
                                                  ($0.height + $0.blockSize - 1) / $0.blockSize) } }
    /// Texture pixel dims per level.
    public var texSizes: [(w: Int, h: Int)] { spec.map { ($0.width, $0.height) } }

    public init(msl: String, spec: [LevelSpec], lambdaPx: UInt32, smoothL0: Bool, gateL0: Bool = true, temporalGatePx: UInt32 = 0) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw EngineError.deviceUnavailable
        }
        self.device = device
        self.queue = queue
        self.spec = spec
        self.lambdaPx = lambdaPx
        self.gateL0 = gateL0
        self.temporalGatePx = temporalGatePx
        self.levels = spec.count

        // Guard against a reference window exceeding the dynamic-threadgroup
        // budget (32KB max minus ~2KB static usage): winW^2 * 4 bytes must fit.
        for (i, s) in spec.enumerated() {
            let winW = s.blockSize + 2 * Int(s.searchHalfPel >> 1)
            let bytes = winW * winW * MemoryLayout<UInt32>.stride
            if winW > 78 || bytes > 30_000 {
                throw EngineError.pipeline("level \(i) window \(winW) (win bytes \(bytes)) exceeds threadgroup budget")
            }
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: msl, options: nil)
        } catch {
            throw EngineError.libraryCompile("\(error)")
        }
        guard let pyramidFn = library.makeFunction(name: "pyramidDownsample"),
              let searchFn = library.makeFunction(name: "motionSearch") else {
            throw EngineError.pipeline("missing MSL functions")
        }
        do {
            pyramidPSO = try device.makeComputePipelineState(function: pyramidFn)
            searchPSO = try device.makeComputePipelineState(function: searchFn)
        } catch {
            throw EngineError.pipeline("\(error)")
        }
        if smoothL0, let medianFn = library.makeFunction(name: "mvMedian3") {
            medianPSO = try? device.makeComputePipelineState(function: medianFn)
        } else {
            medianPSO = nil
        }
        // Temporal EMA gating operates on the median-smoothed L0 field, so it
        // only makes sense when the median pass is active.
        if smoothL0 && temporalGatePx > 0, let tFn = library.makeFunction(name: "mvTemporalEMA") {
            temporalPSO = try? device.makeComputePipelineState(function: tFn)
        } else {
            temporalPSO = nil
        }
        // Dead-zone snap runs on the post-median L0 field (or on raw L0 when
        // the median pass is off), always in-place, before the temporal EMA.
        if let dzFn = library.makeFunction(name: "mvDeadZone") {
            deadZonePSO = try? device.makeComputePipelineState(function: dzFn)
        } else {
            deadZonePSO = nil
        }

        for (i, s) in spec.enumerated() {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r16Uint,
                width: s.width,
                height: s.height,
                mipmapped: false
            )
            desc.storageMode = .shared
            desc.usage = [.shaderRead, .shaderWrite]
            curTex.append(device.makeTexture(descriptor: desc))
            refTex.append(device.makeTexture(descriptor: desc))

            let g = grids[i]
            guard let buf = device.makeBuffer(
                length: g.w * g.h * MemoryLayout<SIMD2<Int32>>.stride,
                options: .storageModeShared
            ) else { throw EngineError.pipeline("MV buffer allocation failed (level \(i))") }
            mvBuffer.append(buf)
        }
        if medianPSO != nil {
            let g = grids[0]
            guard let buf = device.makeBuffer(
                length: g.w * g.h * MemoryLayout<SIMD2<Int32>>.stride,
                options: .storageModeShared
            ) else { throw EngineError.pipeline("L0 median buffer allocation failed") }
            mvBufferSmoothed = buf
        }
        if temporalPSO != nil {
            let g = grids[0]
            let len = g.w * g.h * MemoryLayout<SIMD2<Int32>>.stride
            guard let tOut = device.makeBuffer(length: len, options: .storageModeShared),
                  let tPrev = device.makeBuffer(length: len, options: .storageModeShared) else {
                throw EngineError.pipeline("L0 temporal buffer allocation failed")
            }
            mvBufferTemporalOut = tOut
            mvBufferTemporalPrev = tPrev
        }
    }

    /// Uploads the two L0 luma frames and runs pyramid + search for one pair.
    /// Returns per-stage elapsed ms in SEStage order plus host upload time.
    public func runPair(cur: Data, ref: Data) -> PairTimes {
        var times = [Double](repeating: 0, count: SEStage.allCases.count)
        var uploadMS = 0.0

        uploadMS += timeUpload(cur, into: curTex[0]!)
        uploadMS += timeUpload(ref, into: refTex[0]!)

        // Pyramid: L0 → L1 → L2 → L3 for both frames.
        for i in 1..<levels {
            let tCur = runDownsample(from: curTex[i - 1]!, to: curTex[i]!, level: i)
            let tRef = runDownsample(from: refTex[i - 1]!, to: refTex[i]!, level: i)
            times[stageIndex(.downL1, level: i)] = tCur + tRef
        }

        // Search coarse → fine.
        for i in stride(from: levels - 1, through: 0, by: -1) {
            let inherited = i < levels - 1 ? mvBuffer[i + 1] : nil
            let t = runSearch(level: i, inheritedBuffer: inherited)
            times[stageIndex(.searchL3, level: i)] = t
        }

        // L0 3x3 vector-median smoothing (when enabled).
        if let medianPSO = medianPSO, let smooth = mvBufferSmoothed {
            let start = DispatchTime.now().uptimeNanoseconds
            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { return PairTimes(stages: times, uploadMS: uploadMS) }
            enc.setComputePipelineState(medianPSO)
            enc.setBuffer(mvBuffer[0]!, offset: 0, index: 0)
            enc.setBuffer(smooth, offset: 0, index: 1)
            var g0 = grids[0]
            var uni = MEUniforms(
                level: 0, width: 0, height: 0, blockSize: 0,
                gridW: UInt32(g0.w), gridH: UInt32(g0.h),
                searchHalfPel: 0, lambdaPx: 0, halfPelRefine: 0,
                clearWinGate: 0,
                hasInherited: 0, inheritedGrid: SIMD2<UInt32>(0, 0), inheritFactor: 0,
                temporalGatePx: 0, hasTemporalPrev: 0
            )
            enc.setBytes(&uni, length: MemoryLayout<MEUniforms>.stride, index: 2)
            enc.dispatchThreadgroups(
                MTLSize(width: g0.w, height: g0.h, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
            )
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            times[SEStage.searchL0.rawValue] += elapsedMS(from: start)
        }
        // L0 dead-zone snap (when available): |MV| <= 0.5px → 0, in-place on
        // the post-median field (raw L0 when the median pass is off), before
        // the temporal EMA. Kills sub-pel matcher dither on static content so
        // static edges and thin text stop vibrating; EMA state stays at zero.
        if let deadZonePSO = deadZonePSO,
           let target = mvBufferSmoothed ?? mvBuffer[0] {
            let start = DispatchTime.now().uptimeNanoseconds
            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { return PairTimes(stages: times, uploadMS: uploadMS) }
            enc.setComputePipelineState(deadZonePSO)
            enc.setBuffer(target, offset: 0, index: 0)
            var g0 = grids[0]
            var uni = MEUniforms(
                level: 0, width: 0, height: 0, blockSize: 0,
                gridW: UInt32(g0.w), gridH: UInt32(g0.h),
                searchHalfPel: 0, lambdaPx: 0, halfPelRefine: 0,
                clearWinGate: 0,
                hasInherited: 0, inheritedGrid: SIMD2<UInt32>(0, 0), inheritFactor: 0,
                temporalGatePx: 0, hasTemporalPrev: 0
            )
            enc.setBytes(&uni, length: MemoryLayout<MEUniforms>.stride, index: 1)
            enc.dispatchThreadgroups(
                MTLSize(width: g0.w, height: g0.h, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
            )
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            times[SEStage.searchL0.rawValue] += elapsedMS(from: start)
        }
        // L0 temporal EMA gating (when enabled): blends each block toward the
        // previous pair's MV only when the change fits in temporalGatePx. Runs
        // on the median output; the result is what `downloadMV(smoothed:true)`
        // returns (and what the warp consumes in production).
        if let temporalPSO = temporalPSO,
           let tOut = mvBufferTemporalOut, let tPrev = mvBufferTemporalPrev,
           let smoothedBuf = mvBufferSmoothed {
            let start = DispatchTime.now().uptimeNanoseconds
            guard let cmd = queue.makeCommandBuffer(),
                  let enc = cmd.makeComputeCommandEncoder() else { return PairTimes(stages: times, uploadMS: uploadMS) }
            enc.setComputePipelineState(temporalPSO)
            enc.setBuffer(smoothedBuf, offset: 0, index: 0)
            enc.setBuffer(tPrev, offset: 0, index: 1)
            enc.setBuffer(tOut, offset: 0, index: 2)
            var g0 = grids[0]
            var uni = MEUniforms(
                level: 0, width: 0, height: 0, blockSize: 0,
                gridW: UInt32(g0.w), gridH: UInt32(g0.h),
                searchHalfPel: 0, lambdaPx: 0, halfPelRefine: 0,
                clearWinGate: 0,
                hasInherited: 0, inheritedGrid: SIMD2<UInt32>(0, 0), inheritFactor: 0,
                temporalGatePx: temporalGatePx,
                hasTemporalPrev: hasTemporalPrev ? 1 : 0
            )
            enc.setBytes(&uni, length: MemoryLayout<MEUniforms>.stride, index: 3)
            enc.dispatchThreadgroups(
                MTLSize(width: g0.w, height: g0.h, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
            )
            enc.endEncoding()
            cmd.commit()
            cmd.waitUntilCompleted()
            // Host-side state roll: this pair's output becomes next pair's `prev`.
            // 8640 × 8B = ~69KB memcpy (~µs) — kept on host to avoid an extra GPU
            // copy pass and to keep the state buffer layout trivially debuggable.
            memcpy(tPrev.contents(), tOut.contents(),
                   g0.w * g0.h * MemoryLayout<SIMD2<Int32>>.stride)
            hasTemporalPrev = true
            times[SEStage.searchL0.rawValue] += elapsedMS(from: start)
        }
        return PairTimes(stages: times, uploadMS: uploadMS)
    }

    /// Downloads the MV field of a level as (dx, dy) half-pel vectors (level 0
    /// returns the smoothed field when the median pass is active; when temporal
    /// gating is enabled it returns the temporal EMA output, i.e. exactly what
    /// the warp consumes).
    public func downloadMV(level: Int, smoothed: Bool = true) -> [SIMD2<Int32>] {
        let buf: MTLBuffer?
        if level == 0 && smoothed && mvBufferSmoothed != nil {
            buf = (temporalPSO != nil && mvBufferTemporalOut != nil) ? mvBufferTemporalOut : mvBufferSmoothed
        } else {
            buf = mvBuffer[level]
        }
        guard let buf else { return [] }
        let count = grids[level].w * grids[level].h
        let ptr = buf.contents().assumingMemoryBound(to: SIMD2<Int32>.self)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    /// Clears the temporal EMA state so the next pair is emitted without blending
    /// (first-pair copy). Called on seek, pause→resume, flush and loadVideo to
    /// avoid carrying jitter history across a time discontinuity or new content.
    public func resetTemporalState() {
        guard temporalPSO != nil, let tPrev = mvBufferTemporalPrev else { return }
        memset(tPrev.contents(), 0, tPrev.length)
        hasTemporalPrev = false
    }

    /// Reads a pyramid level's pixels back to the host (debug / validation).
    public func readLevel(_ level: Int) -> [UInt16] {
        guard let tex = curTex[level] else { return [] }
        let count = tex.width * tex.height
        var out = [UInt16](repeating: 0, count: count)
        out.withUnsafeMutableBytes { raw in
            tex.getBytes(
                raw.baseAddress!,
                bytesPerRow: tex.width * MemoryLayout<UInt16>.stride,
                bytesPerImage: count * MemoryLayout<UInt16>.stride,
                from: MTLRegionMake2D(0, 0, tex.width, tex.height),
                mipmapLevel: 0,
                slice: 0
            )
        }
        return out
    }

    // MARK: - Stages

    private func stageIndex(_ base: SEStage, level: Int) -> Int {
        // downL1 → levels 1,2,3 ; searchL3 → levels 3,2,1,0
        let idx: Int
        switch base {
        case .downL1: idx = SEStage.downL1.rawValue + (level - 1)
        case .searchL3: idx = SEStage.searchL3.rawValue + (levels - 1 - level)
        default: idx = base.rawValue
        }
        return idx
    }

    @discardableResult
    private func runDownsample(from: MTLTexture, to: MTLTexture, level: Int) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return 0 }
        enc.setComputePipelineState(pyramidPSO)
        enc.setTexture(from, index: 0)
        enc.setTexture(to, index: 1)
        let w = to.width, h = to.height
        enc.dispatchThreadgroups(
            MTLSize(width: (w + 7) / 8, height: (h + 7) / 8, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1)
        )
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return elapsedMS(from: start)
    }

    private func runSearch(level: Int, inheritedBuffer: MTLBuffer?) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return 0 }
        enc.setComputePipelineState(searchPSO)
        enc.setTexture(curTex[level]!, index: 0)
        enc.setTexture(refTex[level]!, index: 1)
        enc.setBuffer(inheritedBuffer, offset: 0, index: 0)
        enc.setBuffer(mvBuffer[level]!, offset: 0, index: 1)

        let s = spec[level]
        let g = grids[level]
        let inherits = level < levels - 1
        var uni = MEUniforms(
            level: UInt32(level),
            width: UInt32(s.width),
            height: UInt32(s.height),
            blockSize: UInt32(s.blockSize),
            gridW: UInt32(g.w),
            gridH: UInt32(g.h),
            searchHalfPel: s.searchHalfPel,
            lambdaPx: lambdaPx,
            halfPelRefine: s.halfPelRefine ? 1 : 0,
            clearWinGate: (level == 0 && gateL0) ? 1 : 0,
            hasInherited: inherits ? 1 : 0,
            inheritedGrid: SIMD2<UInt32>(
                inherits ? UInt32(grids[level + 1].w) : 1,
                inherits ? UInt32(grids[level + 1].h) : 1
            ),
            inheritFactor: UInt32(s.inheritFactor),
            temporalGatePx: 0, hasTemporalPrev: 0
        )
        enc.setBytes(&uni, length: MemoryLayout<MEUniforms>.stride, index: 2)
        let winW = s.blockSize + 2 * Int(s.searchHalfPel >> 1)
        enc.setThreadgroupMemoryLength(winW * winW * MemoryLayout<UInt32>.stride, index: 0)
        enc.dispatchThreadgroups(
            MTLSize(width: g.w, height: g.h, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1)
        )
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return elapsedMS(from: start)
    }

    private func timeUpload(_ data: Data, into tex: MTLTexture) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        data.withUnsafeBytes { raw in
            tex.replace(
                region: MTLRegionMake2D(0, 0, tex.width, tex.height),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: tex.width * MemoryLayout<UInt16>.stride
            )
        }
        return elapsedMS(from: start)
    }

    private func elapsedMS(from start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }
}