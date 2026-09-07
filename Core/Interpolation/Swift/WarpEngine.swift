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
        do {
            pipeline = try device.makeComputePipelineState(function: warpFn)
            upscalePipeline = try device.makeComputePipelineState(function: upscaleFn)
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

        // 4. CbCr copiado de I0 → out (sin cambios).
        CVPixelBufferLockBaseAddress(out, [])
        CVPixelBufferLockBaseAddress(I0, .readOnly)
        if CVPixelBufferGetPlaneCount(out) >= 2,
           let dstCbCr = CVPixelBufferGetBaseAddressOfPlane(out, 1),
           let srcCbCr = CVPixelBufferGetBaseAddressOfPlane(I0, 1) {
            let cbcrH = CVPixelBufferGetHeightOfPlane(out, 1)
            let dstBPR = CVPixelBufferGetBytesPerRowOfPlane(out, 1)
            let srcBPR = CVPixelBufferGetBytesPerRowOfPlane(I0, 1)
            let copyW = min(dstBPR, srcBPR)
            for y in 0..<cbcrH {
                memcpy(dstCbCr.advanced(by: y * dstBPR),
                       srcCbCr.advanced(by: y * srcBPR),
                       copyW)
            }
        }
        CVPixelBufferUnlockBaseAddress(I0, .readOnly)
        CVPixelBufferUnlockBaseAddress(out, [])

        propagateHDR(from: I0, to: out)
        return (out, warpMS, upscaleMS)
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

        // Recursos por-par: texturas de luma del work-plane + textura de salida
        // del warp (el warp escribe/lee secuencialmente por t).
        let workLumaFormat = MTLPixelFormat.r16Uint
        guard let tex0w = makeWorkTexture(data: luma0, width: workWidth, height: workHeight, format: workLumaFormat),
              let tex1w = makeWorkTexture(data: luma1, width: workWidth, height: workHeight, format: workLumaFormat),
              let texOutW = device.makeTexture(descriptor: workTextureDescriptor(width: workWidth, height: workHeight, format: workLumaFormat)) else {
            return ([], 0, 0)
        }

        let mvBuf = device.makeBuffer(bytes: mv, length: mv.count * MemoryLayout<SIMD2<Int32>>.stride, options: .storageModeShared)!

        ensureOutputPool(w: w, h: h, pixelFormat: pixelFormat)

        var buffers: [CVPixelBuffer] = []
        var warpTotal = 0.0
        var upscaleTotal = 0.0
        for t in tValues {
            guard let out = acquireOutputBuffer(w: w, h: h, pixelFormat: pixelFormat) else { continue }

            // Warp t → texOutW, luego upscale texOutW → luma full-res del out.
            let wrapped = wrapOutputTexture(out, format: metalLumaFormat, w: w, h: h, cache: cache)
            guard let texOut = wrapped.1 else { continue }
            warpTotal += interpolate(tex0: tex0w, tex1: tex1w, mv: mvBuf,
                                     gridW: UInt32(gridW), gridH: UInt32(gridH),
                                     blockSize: UInt32(blockSize), t: t, occThresh: occThresh, outTex: texOutW)
            upscaleTotal += upscale(from: texOutW, to: texOut,
                                    srcW: UInt32(workWidth), srcH: UInt32(workHeight),
                                    outW: UInt32(w), outH: UInt32(h), fmt10: is10Bit)

            copyCbCr(from: I0, to: out)
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
                    // Desaloja el envoltorio más antiguo (libera su buffer → el pool
                    // vuelve a recuperar esa superficie, ya sin wraps pendientes).
                    if let oldest = pooledTex.keys.first {
                        pooledTex.removeValue(forKey: oldest)
                    }
                }
                pooledTex[sid] = (pb, w2)
                return (w2, tex)
            }
        }
        // Sin IOSurface (overflow sin surface) → registrar el envoltorio sin cachear.
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pb, nil, format, w, h, 0, &wrapped) == kCVReturnSuccess,
              let w2 = wrapped, let tex = CVMetalTextureGetTexture(w2) else { return (nil, nil) }
        return (w2, tex)
    }

    /// Copia el plano CbCr de I0 → out (puede ser un buffer del pool con datos de
    /// un frame anterior; se sobreescribe COMPLETO, no hay residuo posible).
    private func copyCbCr(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(dst, [])
        CVPixelBufferLockBaseAddress(src, .readOnly)
        if CVPixelBufferGetPlaneCount(dst) >= 2,
           let dstCbCr = CVPixelBufferGetBaseAddressOfPlane(dst, 1),
           let srcCbCr = CVPixelBufferGetBaseAddressOfPlane(src, 1) {
            let cbcrH = CVPixelBufferGetHeightOfPlane(dst, 1)
            let dstBPR = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
            let srcBPR = CVPixelBufferGetBytesPerRowOfPlane(src, 1)
            let copyW = min(dstBPR, srcBPR)
            for y in 0..<cbcrH {
                memcpy(dstCbCr.advanced(by: y * dstBPR),
                       srcCbCr.advanced(by: y * srcBPR),
                       copyW)
            }
        }
        CVPixelBufferUnlockBaseAddress(src, .readOnly)
        CVPixelBufferUnlockBaseAddress(dst, [])
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
