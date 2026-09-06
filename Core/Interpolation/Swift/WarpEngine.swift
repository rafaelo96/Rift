import Foundation
import Metal
import CoreVideo

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
