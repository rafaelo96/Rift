import Foundation
import Metal
import CoreVideo
import IOSurface

public final class WarpEngine {
    public enum Error: Swift.Error {
        case deviceUnavailable
        case libraryCompile(String)
        case pipeline(String)
    }

    public     let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let upscalePipeline: MTLComputePipelineState
    private let chromaDownPipeline: MTLComputePipelineState
    private let chromaWarpPipeline: MTLComputePipelineState
    private let chromaUpPipeline: MTLComputePipelineState
    private var outTex: MTLTexture?
    private var textureCache: CVMetalTextureCache?

    // Pool de buffers de salida (fast-path 4K/1080p): los CVPixelBuffer de salida
    // se reusan entre frames en vez de crearse desde cero (CVPixelBufferCreate +
    // registro IOSurface por par). El pool es el primitive thread-safe de CoreVideo;
    // el overflow degrada a create aislado si el displayLayer aún retiene todos los
    // buffers del pool. La cache de envoltorios CVMetalTexture por IOSurfaceID evita
    // el CVMetalTextureCacheCreateTextureFromImage por frame (la IOSurface no cambia).
    private var outPool: CVPixelBufferPool?
    private var outPoolSize: (w: Int, h: Int, pixelFormat: OSType)?
    private var pooledTex: [UInt32: (CVPixelBuffer, CVMetalTexture)] = [:]
    private var pooledChromaTex: [UInt32: (CVPixelBuffer, CVMetalTexture)] = [:]
    private var loggedChromaPath = false
    private var loggedChromaStride = false
    private let outPoolCapacity: Int = 8

    public init(msl: String) throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw Error.deviceUnavailable
        }
        self.device = device
        self.queue = queue
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: msl, options: nil)
        } catch {
            throw Error.libraryCompile("\(error)")
        }
        guard let warpFn = library.makeFunction(name: "warpBlend") else {
            throw Error.pipeline("missing warpBlend function")
        }
        guard let upscaleFn = library.makeFunction(name: "upscaleLuma") else {
            throw Error.pipeline("missing upscaleLuma function")
        }
        guard let cDownFn = library.makeFunction(name: "chromaDownscale2"),
              let cWarpFn = library.makeFunction(name: "warpBlendChroma2"),
              let cUpFn = library.makeFunction(name: "upscaleChroma2") else {
            throw Error.pipeline("missing chroma shaders")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: warpFn)
            upscalePipeline = try device.makeComputePipelineState(function: upscaleFn)
            chromaDownPipeline = try device.makeComputePipelineState(function: cDownFn)
            chromaWarpPipeline = try device.makeComputePipelineState(function: cWarpFn)
            chromaUpPipeline = try device.makeComputePipelineState(function: cUpFn)
        } catch {
            throw Error.pipeline("\(error)")
        }
    }

    public func interpolate(I0: [UInt16], I1: [UInt16], mv: [SIMD2<Int32>], width: Int, height: Int, gridW: Int, gridH: Int, blockSize: Int, t: Float, occThresh: Float = 1.0) -> ([UInt16], Double) {
        guard I0.count == width * height, I1.count == width * height else { return ([], 0) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let tex0 = device.makeTexture(descriptor: descriptor),
              let tex1 = device.makeTexture(descriptor: descriptor),
              let texOut = device.makeTexture(descriptor: descriptor),
              let mvBuffer = device.makeBuffer(bytes: mv, length: mv.count * MemoryLayout<SIMD2<Int32>>.stride, options: .storageModeShared) else {
            return ([], 0)
        }
        let region = MTLRegionMake2D(0, 0, width, height)
        I0.withUnsafeBytes { tex0.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * MemoryLayout<UInt16>.stride) }
        I1.withUnsafeBytes { tex1.replace(region: region, mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: width * MemoryLayout<UInt16>.stride) }
        let warpMS = interpolate(tex0: tex0, tex1: tex1, mv: mvBuffer, gridW: UInt32(gridW), gridH: UInt32(gridH), blockSize: UInt32(blockSize), t: t, occThresh: occThresh, outTex: texOut)
        var output = [UInt16](repeating: 0, count: width * height)
        output.withUnsafeMutableBytes { texOut.getBytes($0.baseAddress!, bytesPerRow: width * MemoryLayout<UInt16>.stride, from: region, mipmapLevel: 0) }
        return (output, warpMS)
    }

    func interpolate(tex0: MTLTexture, tex1: MTLTexture, mv: MTLBuffer, gridW: UInt32, gridH: UInt32, blockSize: UInt32, t: Float, occThresh: Float = 1.0, outTex: MTLTexture) -> Double {
        let w = tex0.width
        let h = tex0.height
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return 0 }
        let start = DispatchTime.now().uptimeNanoseconds
        enc.setComputePipelineState(pipeline)
        enc.setTexture(tex0, index: 0)
        enc.setTexture(tex1, index: 1)
        enc.setBuffer(mv, offset: 0, index: 0)
        enc.setTexture(outTex, index: 2)
        var uni = WarpUniforms(width: UInt32(w), height: UInt32(h), gridW: gridW, gridH: gridH, blockSize: blockSize, t: t, occThresh: occThresh)
        enc.setBytes(&uni, length: MemoryLayout<WarpUniforms>.stride, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let n = MTLSize(width: (w + tg.width - 1)/tg.width, height: (h + tg.height - 1)/tg.height, depth: 1)
        enc.dispatchThreadgroups(n, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    /// Interpola un par operando el warp sobre el work-plane y luego haciendo un
    /// upscale bilinear del luma a resolución completa en el CVPixelBuffer de
    /// salida. `I0`/`I1` son los CVPixelBuffer full-res (para CbCr + HDR + dims),
    /// `luma0`/`luma1` son los planos de luma ya escalados a work-plane por
    /// `MotionCompensator.scaledLuma` (el input real del warp). CbCr se copia de
    /// I0→out y los attachments HDR se propagan — sin cambios vs. la versión
    /// anterior. Devuelve el buffer interpolado y el desglose warpMS (warp en
    /// work-plane) / upscaleMS (upscale bilinear a full-res).
    public func interpolatePixelBuffer(
        I0: CVPixelBuffer,
        I1: CVPixelBuffer,
        luma0: Data,
        luma1: Data,
        workWidth: Int,
        workHeight: Int,
        mv: [SIMD2<Int32>],
        gridW: Int,
        gridH: Int,
        blockSize: Int,
        t: Float,
        occThresh: Float = 1.0
    ) -> (interp: CVPixelBuffer?, warpMS: Double, upscaleMS: Double) {
        let w = CVPixelBufferGetWidth(I0), h = CVPixelBufferGetHeight(I0)
        let pixelFormat = CVPixelBufferGetPixelFormatType(I0)
        let metalLumaFormat: MTLPixelFormat
        switch pixelFormat {
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
            metalLumaFormat = .r16Uint
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            metalLumaFormat = .r8Uint
        default:
            return (nil, 0, 0)
        }
        let is10Bit = metalLumaFormat == .r16Uint

        var outPB: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat
        ]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, pixelFormat, attrs as CFDictionary, &outPB)
        guard st == kCVReturnSuccess, let out = outPB, let cache = textureCache else { return (nil, 0, 0) }

        // 1. Texturas de luma work-plane desde los Data ya escalados (inputs del warp).
        // Work-plane SIEMPRE r16Uint, independiente del bit depth de origen:
        // scaledLuma y el ME empaquetan luma como UInt16 (2 bytes/muestra) —
        // en 8-bit el Data trae value<<8 y en 10-bit 0..1023. El layout del
        // Data y su bytesPerRow (width*2) solo es consistente con r16Uint.
        let workLumaFormat = MTLPixelFormat.r16Uint
        guard let tex0w = makeWorkTexture(data: luma0, width: workWidth, height: workHeight, format: workLumaFormat),
              let tex1w = makeWorkTexture(data: luma1, width: workWidth, height: workHeight, format: workLumaFormat),
              let texOutW = device.makeTexture(descriptor: workTextureDescriptor(width: workWidth, height: workHeight, format: workLumaFormat)) else {
            return (nil, 0, 0)
        }

        // 2. Warp en work-plane → texOutW.
        let mvBuf = device.makeBuffer(bytes: mv, length: mv.count * MemoryLayout<SIMD2<Int32>>.stride, options: .storageModeShared)!
        let warpMS = interpolate(tex0: tex0w, tex1: tex1w, mv: mvBuf, gridW: UInt32(gridW), gridH: UInt32(gridH), blockSize: UInt32(blockSize), t: t, occThresh: occThresh, outTex: texOutW)

        // 3. Upscale bilinear work-plane → luma full-res del buffer de salida.
        var cvTexOut: CVMetalTexture?
        let statusOut = CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, out, nil, metalLumaFormat, w, h, 0, &cvTexOut)
        guard statusOut == kCVReturnSuccess,
              let tOut = cvTexOut, let texOut = CVMetalTextureGetTexture(tOut) else { return (nil, warpMS, 0) }
        let upscaleMS = upscale(from: texOutW, to: texOut, srcW: UInt32(workWidth), srcH: UInt32(workHeight), outW: UInt32(w), outH: UInt32(h), fmt10: is10Bit)

        // 4. CbCr warpeado (antes: copia verbatim de I0 → color pegado en t=0).
        let chromaIs10 = isChroma10Bit(I0)
        let cwCh = CVPixelBufferGetWidthOfPlane(I0, 1)
        let chCh = CVPixelBufferGetHeightOfPlane(I0, 1)
        var chromaTotal = 0.0
        if let prepared = prepareChromaWork(I0: I0, I1: I1, workWidth: workWidth, workHeight: workHeight),
           cwCh > 0, chCh > 0,
           let cOutW = device.makeTexture(descriptor: workTextureDescriptor(width: prepared.outW, height: prepared.outH, format: .rg16Uint)),
           let cOutFull = device.makeTexture(descriptor: workTextureDescriptor(width: cwCh, height: chCh, format: .rg16Uint)) {
            chromaTotal += prepared.downMS
            chromaTotal += chromaWarp(c0: prepared.c0, c1: prepared.c1, mv: mvBuf, outW: cOutW,
                                      gridW: gridW, gridH: gridH, blockSize: blockSize, t: t, occThresh: occThresh)
            chromaTotal += chromaUpscale(src: cOutW, outTex: cOutFull,
                                         srcW: prepared.outW, srcH: prepared.outH,
                                         dstW: cwCh, dstH: chCh, fmt10: chromaIs10)
            writeChromaPlane(from: cOutFull, is10Bit: chromaIs10, into: out)
        }

        propagateHDR(from: I0, to: out)
        return (out, warpMS + chromaTotal, upscaleMS)
    }

    /// Variante por-par de `interpolatePixelBuffer`: recibe el par de luma
    /// work-plane ya escalado + el campo de MV (ME/luma corre UNA vez en el
    /// caller) y genera un buffer interpolado por cada `t` en `tValues`.
    /// Los recursos que solo dependen del par — texturas de luma del work-plane,
    /// textura de salida del warp (reusada secuencialmente por t) y el MV buffer —
    /// se crean una vez; por t se repite solo warp + upscale + copy CbCr + HDR.
    ///
    /// Fast-path 4K HDR (pooling): los buffers de salida provienen de un
    /// CVPixelBufferPool reutilizable de 8 slots (en vez de CVPixelBufferCreate
    /// + registro IOSurface por frame), y el envoltorio CVMetalTexture del luma
    /// de salida se cachea por IOSurfaceID (el surface del pool no cambia → no
    /// se re-registra por frame). El pool es el primitive thread-safe de
    /// CoreVideo; overflow → degrada a create aislado si el displayLayer aún
    /// retiene todos los slots.
func interpolatePixelBufferPair(
    I0: CVPixelBuffer,
    I1: CVPixelBuffer,
    luma0: Data,
    luma1: Data,
    workWidth: Int,
    workHeight: Int,
    mv: [SIMD2<Int32>],
    gridW: Int,
    gridH: Int,
    blockSize: Int,
    tValues: [Float],
    occThresh: Float = 1.0
) -> (buffers: [CVPixelBuffer], warpMS: Double, upscaleMS: Double) {
    guard !tValues.isEmpty else { return ([], 0, 0) }
    let w = CVPixelBufferGetWidth(I0), h = CVPixelBufferGetHeight(I0)
    let pixelFormat = CVPixelBufferGetPixelFormatType(I0)
    let metalLumaFormat: MTLPixelFormat
    switch pixelFormat {
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
         kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        metalLumaFormat = .r16Uint
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        metalLumaFormat = .r8Uint
    default:
        return ([], 0, 0)
    }
    let is10Bit = metalLumaFormat == .r16Uint
    guard let cache = textureCache else { return ([], 0, 0) }

    let workLumaFormat = MTLPixelFormat.r16Uint
    guard let tex0w = makeWorkTexture(data: luma0, width: workWidth, height: workHeight, format: workLumaFormat),
          let tex1w = makeWorkTexture(data: luma1, width: workWidth, height: workHeight, format: workLumaFormat),
          let texOutW = device.makeTexture(descriptor: workTextureDescriptor(width: workWidth, height: workHeight, format: workLumaFormat)) else {
        return ([], 0, 0)
    }

    let mvBuf = device.makeBuffer(bytes: mv, length: mv.count * MemoryLayout<SIMD2<Int32>>.stride, options: .storageModeShared)!

    ensureOutputPool(w: w, h: h, pixelFormat: pixelFormat)

    let cwCh = CVPixelBufferGetWidthOfPlane(I0, 1)
    let chCh = CVPixelBufferGetHeightOfPlane(I0, 1)
    let chromaIs10 = isChroma10Bit(I0)
    let prepared = prepareChromaWork(I0: I0, I1: I1, workWidth: workWidth, workHeight: workHeight)
    var cOutFull: MTLTexture?
    var cOutW: MTLTexture?
    if let prepared, cwCh > 0, chCh > 0 {
        cOutFull = device.makeTexture(descriptor: workTextureDescriptor(width: cwCh, height: chCh, format: .rg16Uint))
        cOutW = device.makeTexture(descriptor: workTextureDescriptor(width: prepared.outW, height: prepared.outH, format: .rg16Uint))
    }

    var buffers: [CVPixelBuffer] = []
    var warpTotal = 0.0
    var upscaleTotal = 0.0
    if let prepared { warpTotal += prepared.downMS }
    for t in tValues {
        guard let out = acquireOutputBuffer(w: w, h: h, pixelFormat: pixelFormat) else { continue }

        let wrapped = wrapOutputTexture(out, format: metalLumaFormat, w: w, h: h, cache: cache)
        guard let texOut = wrapped.1 else { continue }
        warpTotal += interpolate(tex0: tex0w, tex1: tex1w, mv: mvBuf,
                                 gridW: UInt32(gridW), gridH: UInt32(gridH),
                                     blockSize: UInt32(blockSize), t: t, occThresh: occThresh, outTex: texOutW)
        upscaleTotal += upscale(from: texOutW, to: texOut,
                                srcW: UInt32(workWidth), srcH: UInt32(workHeight),
                                outW: UInt32(w), outH: UInt32(h), fmt10: is10Bit)

        if let prepared, let cOutW {
            warpTotal += chromaWarp(c0: prepared.c0, c1: prepared.c1, mv: mvBuf, outW: cOutW,
                                    gridW: gridW, gridH: gridH, blockSize: blockSize, t: t, occThresh: occThresh)

            if chromaIs10 {
                let chromaWrapped = wrapOutputChromaTexture(out, w: cwCh, h: chCh, cache: cache)
                if let chromaTexOut = chromaWrapped.1 {
                    logChromaPathOnce(zeroCopy: true)
                    upscaleTotal += chromaUpscale(src: cOutW, outTex: chromaTexOut,
                                                  srcW: prepared.outW, srcH: prepared.outH,
                                                  dstW: cwCh, dstH: chCh, fmt10: true)
                }
            } else if let cOutFull {
                logChromaPathOnce(zeroCopy: false)
                upscaleTotal += chromaUpscale(src: cOutW, outTex: cOutFull,
                                              srcW: prepared.outW, srcH: prepared.outH,
                                              dstW: cwCh, dstH: chCh, fmt10: chromaIs10)
                writeChromaPlane(from: cOutFull, is10Bit: chromaIs10, into: out)
            }
        }

        propagateHDR(from: I0, to: out)

        buffers.append(out)
    }

    return (buffers, warpTotal, upscaleTotal)
}

    /// Crea (si hace falta) el pool de buffers de salida con las dims/formato del
    /// par actual. Si el video cambia de resolución/formato se recrea y se vacía
    /// la cache de envoltorios (los wraps cacheados pinen sus buffers, así que el
    /// pool no reutiliza un surface mientras haya un envoltorio referente a él).
    private func ensureOutputPool(w: Int, h: Int, pixelFormat: OSType) {
        if let cur = outPoolSize, cur.w == w, cur.h == h, cur.pixelFormat == pixelFormat, outPool != nil { return }
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPoolMinimumBufferCountKey as String: outPoolCapacity,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess,
              let p = pool else { return }
        outPool = p
        outPoolSize = (w, h, pixelFormat)
        pooledTex.removeAll()
        // Pre-warm: los 8 buffers se crean y se devuelven al pool.
        for _ in 0..<outPoolCapacity {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, p, &pb)
        }
    }

    /// Adquiere un buffer de salida del pool; si el pool está vacío (todos los
    /// slots aún retenidos por el displayLayer) degrada a create aislado — nunca
    /// bloquea ni devuelve datos de un par anterior.
    private func acquireOutputBuffer(w: Int, h: Int, pixelFormat: OSType) -> CVPixelBuffer? {
        if let pool = outPool {
            var pb: CVPixelBuffer?
            if CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb) == kCVReturnSuccess, let b = pb {
                return b
            }
        }
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, w, h, pixelFormat, attrs as CFDictionary, &pb) == kCVReturnSuccess else { return nil }
        return pb
    }

    /// Devuelve la textura Metal del plano de luma del buffer de salida, cacheada
    /// por IOSurfaceID. El wrap NO retiene el CVPixelBuffer (texture cache), así
    /// que el valor del dict pinea el buffer fuerte para que el pool no pueda
    /// reciclar/destruir la superficie bajo el envoltorio; solo al desalojar el
    /// wrap se libera el buffer y el surface queda a disposición del pool.
    private func wrapOutputTexture(_ pb: CVPixelBuffer, format: MTLPixelFormat, w: Int, h: Int, cache: CVMetalTextureCache) -> (CVMetalTexture?, MTLTexture?) {
        if let surfaceUnmanaged = CVPixelBufferGetIOSurface(pb) {
            let surface = surfaceUnmanaged.takeUnretainedValue()
            let sid = IOSurfaceGetID(surface)
            if let cached = pooledTex[sid], let tex = CVMetalTextureGetTexture(cached.1) {
                return (cached.1, tex)
            }
            var wrapped: CVMetalTexture?
            if CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, 0, &wrapped) == kCVReturnSuccess,
               let w2 = wrapped, let tex = CVMetalTextureGetTexture(w2) {
                if pooledTex.count >= outPoolCapacity * 2 {
                    if let oldest = pooledTex.keys.first {
                        pooledTex.removeValue(forKey: oldest)
                    }
                }
                pooledTex[sid] = (pb, w2)
                return (w2, tex)
            }
        }
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, 0, &wrapped) == kCVReturnSuccess,
              let w2 = wrapped, let tex = CVMetalTextureGetTexture(w2) else { return (nil, nil) }
        return (w2, tex)
    }

    private func wrapOutputChromaTexture(_ pb: CVPixelBuffer, w: Int, h: Int, cache: CVMetalTextureCache) -> (CVMetalTexture?, MTLTexture?) {
        if !loggedChromaStride {
            loggedChromaStride = true
            print("[RIFT-DIAG-CHROMA-STRIDE] bytesPerRow=\(CVPixelBufferGetBytesPerRowOfPlane(pb, 1)) expectedBytesPerRow=\(CVPixelBufferGetWidthOfPlane(pb, 1) * 4) height=\(CVPixelBufferGetHeightOfPlane(pb, 1))")
        }
        let format: MTLPixelFormat = .rg16Uint
        if let surfaceUnmanaged = CVPixelBufferGetIOSurface(pb) {
            let surface = surfaceUnmanaged.takeUnretainedValue()
            let sid = IOSurfaceGetID(surface)
            if let cached = pooledChromaTex[sid], let tex = CVMetalTextureGetTexture(cached.1) {
                return (cached.1, tex)
            }
            var wrappedC: CVMetalTexture?
            if CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, 1, &wrappedC) == kCVReturnSuccess,
               let w2 = wrappedC, let tex = CVMetalTextureGetTexture(w2) {
                if pooledChromaTex.count >= outPoolCapacity * 2 {
                    if let oldest = pooledChromaTex.keys.first {
                        pooledChromaTex.removeValue(forKey: oldest)
                    }
                }
                pooledChromaTex[sid] = (pb, w2)
                return (w2, tex)
            }
        }
        var wrappedC: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, 1, &wrappedC) == kCVReturnSuccess,
              let w2 = wrappedC, let tex = CVMetalTextureGetTexture(w2) else { return (nil, nil) }
        return (w2, tex)
    }

    private func logChromaPathOnce(zeroCopy: Bool) {
        guard !loggedChromaPath else { return }
        loggedChromaPath = true
        let msg = zeroCopy ? "zero-copy 10-bit" : "legacy 8-bit getBytes"
        print("[RIFT-DIAG-CHROMA-PATH] \(msg)")
    }

    // MARK: - Chroma warping
    //
    // La versión anterior copiaba el plano CbCr de I0 verbatim, dejando el color
    // pegado en t=0 mientras el luma se warpeaba. Estas helpers warpean AMBOS
    // planos con el mismo campo MV (resolución de croma = mitad del work-plane
    // de luma), a través de un work-plane de croma (workWidth/2 × workHeight/2)
    // y un upscale bilinear de vuelta a la resolución de cromo completa.

    private func isChroma10Bit(_ pb: CVPixelBuffer) -> Bool {
        let fmt = CVPixelBufferGetPixelFormatType(pb)
        return fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    /// Construye la textura Metal del plano 1 (CbCr) completo de `pb`, desde su
    /// base address (row stride real del plane, copia síncrona con `replace`).
    /// 8-bit → .rg8Uint, 10-bit → .rg16Uint. Nil si no hay plano de croma.
    private func makeFullChromaTexture(_ pb: CVPixelBuffer, is10Bit: Bool) -> MTLTexture? {
        guard CVPixelBufferGetPlaneCount(pb) >= 2 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let sw = CVPixelBufferGetWidthOfPlane(pb, 1)
        let sh = CVPixelBufferGetHeightOfPlane(pb, 1)
        guard sw > 0, sh > 0,
              let base = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return nil }
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        let format: MTLPixelFormat = is10Bit ? .rg16Uint : .rg8Uint
        guard let tex = device.makeTexture(descriptor: workTextureDescriptor(width: sw, height: sh, format: format)) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, sw, sh), mipmapLevel: 0, withBytes: base, bytesPerRow: bpr)
        return tex
    }

    /// Prepara los work-planes de croma del par (downscale full → work 1 vez, se
    /// reusan por t). Devuelve sinonimos, dims del work-plane y el flag 10-bit;
    /// nil si no hay croma.
    private func prepareChromaWork(
        I0: CVPixelBuffer, I1: CVPixelBuffer,
        workWidth: Int, workHeight: Int
    ) -> (c0: MTLTexture, c1: MTLTexture, outW: Int, outH: Int, is10Bit: Bool, downMS: Double)? {
        let is10Bit = isChroma10Bit(I0)
        let cw = CVPixelBufferGetWidthOfPlane(I0, 1)
        let ch = CVPixelBufferGetHeightOfPlane(I0, 1)
        guard cw > 0, ch > 0,
              CVPixelBufferGetPlaneCount(I0) >= 2, CVPixelBufferGetPlaneCount(I1) >= 2,
              CVPixelBufferGetWidthOfPlane(I1, 1) == cw,
              CVPixelBufferGetHeightOfPlane(I1, 1) == ch,
              let t0 = makeFullChromaTexture(I0, is10Bit: is10Bit),
              let t1 = makeFullChromaTexture(I1, is10Bit: is10Bit) else { return nil }
        let ww = max(1, workWidth / 2)
        let wh = max(1, workHeight / 2)
        let wdesc = workTextureDescriptor(width: ww, height: wh, format: .rg16Uint)
        guard let c0w = device.makeTexture(descriptor: wdesc),
              let c1w = device.makeTexture(descriptor: wdesc) else { return nil }
        let down0 = chromaDown(src: t0, outTex: c0w, srcW: cw, srcH: ch, dstW: ww, dstH: wh, fmt10: is10Bit)
        let down1 = chromaDown(src: t1, outTex: c1w, srcW: cw, srcH: ch, dstW: ww, dstH: wh, fmt10: is10Bit)
        return (c0w, c1w, ww, wh, is10Bit, down0 + down1)
    }

    /// Downscale bilinear del croma full-res → work-plane de croma.
    private func chromaDown(src: MTLTexture, outTex: MTLTexture, srcW: Int, srcH: Int, dstW: Int, dstH: Int, fmt10: Bool) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return 0 }
        enc.setComputePipelineState(chromaDownPipeline)
        enc.setTexture(src, index: 0)
        enc.setTexture(outTex, index: 1)
        var uni = UpscaleUniforms(srcW: UInt32(srcW), srcH: UInt32(srcH), outW: UInt32(dstW), outH: UInt32(dstH), fmt10: fmt10 ? 1 : 0)
        enc.setBytes(&uni, length: MemoryLayout<UpscaleUniforms>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let n = MTLSize(width: (dstW + tg.width - 1) / tg.width, height: (dstH + tg.height - 1) / tg.height, depth: 1)
        enc.dispatchThreadgroups(n, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    /// Warp de croma en el work-plane de croma (2 canales), mismos MV que el luma.
    private func chromaWarp(c0: MTLTexture, c1: MTLTexture, mv: MTLBuffer, outW: MTLTexture, gridW: Int, gridH: Int, blockSize: Int, t: Float, occThresh: Float) -> Double {
        let w = outW.width, h = outW.height
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return 0 }
        let start = DispatchTime.now().uptimeNanoseconds
        enc.setComputePipelineState(chromaWarpPipeline)
        enc.setTexture(c0, index: 0)
        enc.setTexture(c1, index: 1)
        enc.setBuffer(mv, offset: 0, index: 0)
        enc.setTexture(outW, index: 2)
        var uni = WarpUniforms(width: UInt32(w), height: UInt32(h), gridW: UInt32(gridW), gridH: UInt32(gridH), blockSize: UInt32(blockSize), t: t, occThresh: occThresh)
        enc.setBytes(&uni, length: MemoryLayout<WarpUniforms>.stride, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let n = MTLSize(width: (w + tg.width - 1) / tg.width, height: (h + tg.height - 1) / tg.height, depth: 1)
        enc.dispatchThreadgroups(n, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    /// Upscale bilinear del work-plane de croma → croma full-res (rg16Uint).
    private func chromaUpscale(src: MTLTexture, outTex: MTLTexture, srcW: Int, srcH: Int, dstW: Int, dstH: Int, fmt10: Bool) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return 0 }
        enc.setComputePipelineState(chromaUpPipeline)
        enc.setTexture(src, index: 0)
        enc.setTexture(outTex, index: 1)
        var uni = UpscaleUniforms(srcW: UInt32(srcW), srcH: UInt32(srcH), outW: UInt32(dstW), outH: UInt32(dstH), fmt10: fmt10 ? 1 : 0)
        enc.setBytes(&uni, length: MemoryLayout<UpscaleUniforms>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let n = MTLSize(width: (dstW + tg.width - 1) / tg.width, height: (dstH + tg.height - 1) / tg.height, depth: 1)
        enc.dispatchThreadgroups(n, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    /// Escribe el resultado del warp de croma (textura rg16Uint full-croma) en el
    /// plano 1 de `out`. 10-bit: los words de 16 bits coinciden con el layout del
    /// plano; 8-bit: los bytes ya viven en el byte bajo (>>8 en el shader) pero el
    /// layout rg16 intercala bytes nulos → compactado fila a fila con el BPR real.
    private func writeChromaPlane(from tex: MTLTexture, is10Bit: Bool, into out: CVPixelBuffer) {
        guard CVPixelBufferGetPlaneCount(out) >= 2 else { return }
        CVPixelBufferLockBaseAddress(out, [])
        defer { CVPixelBufferUnlockBaseAddress(out, []) }
        let cw = tex.width
        let ch = min(tex.height, CVPixelBufferGetHeightOfPlane(out, 1))
        let dstBPR = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
        guard let dst = CVPixelBufferGetBaseAddressOfPlane(out, 1), cw > 0 else { return }

        let rowBytes = cw * 4 // rg16Uint: 2 canales × 2 bytes
        var buf = [UInt8](repeating: 0, count: rowBytes * ch)
        let region = MTLRegionMake2D(0, 0, cw, ch)
        buf.withUnsafeMutableBytes { tex.getBytes($0.baseAddress!, bytesPerRow: rowBytes, from: region, mipmapLevel: 0) }

        buf.withUnsafeBytes { raw in
            if is10Bit {
                for y in 0..<ch {
                    memcpy(dst.advanced(by: y * dstBPR),
                           raw.baseAddress!.advanced(by: y * rowBytes),
                           min(dstBPR, rowBytes))
                }
            } else {
                let words = raw.bindMemory(to: UInt16.self)
                for y in 0..<ch {
                    let dRow = dst.advanced(by: y * dstBPR).assumingMemoryBound(to: UInt8.self)
                    let rowBase = y * cw
                    for x in 0..<cw {
                        dRow[x * 2] = UInt8(truncatingIfNeeded: words[rowBase + x * 2])
                        dRow[x * 2 + 1] = UInt8(truncatingIfNeeded: words[rowBase + x * 2 + 1])
                    }
                }
            }
        }
    }

    private func workTextureDescriptor(width: Int, height: Int, format: MTLPixelFormat) -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        return descriptor
    }

    private func makeWorkTexture(data: Data, width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        guard let tex = device.makeTexture(descriptor: workTextureDescriptor(width: width, height: height, format: format)) else { return nil }
        let bytesPerRow = width * MemoryLayout<UInt16>.stride
        let region = MTLRegionMake2D(0, 0, width, height)
        data.withUnsafeBytes { raw in
            tex.replace(region: region, mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
        }
        return tex
    }

    private func upscale(from srcTex: MTLTexture, to outTex: MTLTexture, srcW: UInt32, srcH: UInt32, outW: UInt32, outH: UInt32, fmt10: Bool) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return 0 }
        enc.setComputePipelineState(upscalePipeline)
        enc.setTexture(srcTex, index: 0)
        enc.setTexture(outTex, index: 1)
        var uni = UpscaleUniforms(srcW: srcW, srcH: srcH, outW: outW, outH: outH, fmt10: fmt10 ? 1 : 0)
        enc.setBytes(&uni, length: MemoryLayout<UpscaleUniforms>.stride, index: 0)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let n = MTLSize(width: (Int(outW) + tg.width - 1) / tg.width, height: (Int(outH) + tg.height - 1) / tg.height, depth: 1)
        enc.dispatchThreadgroups(n, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    private func propagateHDR(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
            if let v = CVBufferCopyAttachment(src, key, nil) {
                CVBufferSetAttachment(dst, key, v, .shouldPropagate)
            }
        }
        if let dict = CVBufferCopyAttachments(src, .shouldPropagate) as? [String: Any] {
            for (k, v) in dict {
                CVBufferSetAttachment(dst, k as CFString, v as CFTypeRef, .shouldPropagate)
            }
        }
    }
}

private struct WarpUniforms {
    var width: UInt32
    var height: UInt32
    var gridW: UInt32
    var gridH: UInt32
    var blockSize: UInt32
    var t: Float
    var occThresh: Float
}

private struct UpscaleUniforms {
    var srcW: UInt32
    var srcH: UInt32
    var outW: UInt32
    var outH: UInt32
    var fmt10: UInt32
}
