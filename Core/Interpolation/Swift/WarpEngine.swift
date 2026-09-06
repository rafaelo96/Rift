import Foundation
import Metal
import CoreVideo

public final class WarpEngine {
    public let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var outTex: MTLTexture?
    private var width = 0
    private var height = 0

    public init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw NSError(domain: "WarpEngine", code: 1) }
        self.queue = q
        let lib = try device.makeLibrary(source: warpShadersMSL, options: nil)
        guard let fn = lib.makeFunction(name: "warpBlend") else { throw NSError(domain: "WarpEngine", code: 2) }
        self.pipeline = try device.makeComputePipelineState(function: fn)
    }

    private func ensureTexture(width: Int, height: Int) -> MTLTexture {
        if let t = outTex, t.width == width, t.height == height { return t }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let t = device.makeTexture(descriptor: desc)!
        outTex = t
        self.width = width
        self.height = height
        return t
    }

    private func makeTexture(from plane: [UInt16], width: Int, height: Int) -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Uint, width: width, height: height, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared
        let tex = device.makeTexture(descriptor: desc)!
        plane.withUnsafeBytes { raw in
            tex.replace(region: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: width * MemoryLayout<UInt16>.stride)
        }
        return tex
    }

    // I0,I1 are the same MTLTextures used by MotionSearchEngine (curTex[0]/refTex[0] or luma planes)
    // mv is the L0 field (smoothed) in half-pel units, gridW*gridH
    func interpolate(tex0: MTLTexture, tex1: MTLTexture, mv: MTLBuffer, gridW: UInt32, gridH: UInt32, blockSize: UInt32, t: Float, occThresh: Float = 1.0) -> (MTLTexture, Double) {
        let w = tex0.width
        let h = tex0.height
        let out = ensureTexture(width: w, height: h)
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else { return (out, 0) }
        let start = DispatchTime.now().uptimeNanoseconds
        enc.setComputePipelineState(pipeline)
        enc.setTexture(tex0, index: 0)
        enc.setTexture(tex1, index: 1)
        enc.setBuffer(mv, offset: 0, index: 0)
        enc.setTexture(out, index: 2)
        var uni = WarpUniforms(width: UInt32(w), height: UInt32(h), gridW: gridW, gridH: gridH, blockSize: blockSize, t: t, occThresh: occThresh)
        enc.setBytes(&uni, length: MemoryLayout<WarpUniforms>.stride, index: 1)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let n = MTLSize(width: (w + tg.width - 1)/tg.width, height: (h + tg.height - 1)/tg.height, depth: 1)
        enc.dispatchThreadgroups(n, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
        return (out, ms)
    }

    public func readTexture(_ tex: MTLTexture) -> [UInt16] {
        let w = tex.width, h = tex.height
        var out = [UInt16](repeating: 0, count: w*h)
        out.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w*MemoryLayout<UInt16>.stride, bytesPerImage: w*h*MemoryLayout<UInt16>.stride, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0, slice: 0)
        }
        return out
    }

    // Convenience for prototype: I0/I1 as host planes, mv as [SIMD2<Int32>] half-pel
    public func interpolate(I0: [UInt16], I1: [UInt16], mv: [SIMD2<Int32>], width: Int, height: Int, gridW: Int, gridH: Int, blockSize: Int, t: Float, occThresh: Float = 1.0) -> ([UInt16], Double) {
        let tex0 = makeTexture(from: I0, width: width, height: height)
        let tex1 = makeTexture(from: I1, width: width, height: height)
        let mvBuf = device.makeBuffer(bytes: mv, length: mv.count * MemoryLayout<SIMD2<Int32>>.stride, options: .storageModeShared)!
        let (outTex, ms) = interpolate(tex0: tex0, tex1: tex1, mv: mvBuf, gridW: UInt32(gridW), gridH: UInt32(gridH), blockSize: UInt32(blockSize), t: t, occThresh: occThresh)
        return (readTexture(outTex), ms)
    }

    // HDR: CVPixelBuffer path — propaga attachments BT.2020/PQ del original al interpolado
    // Fix puntual: sin esto el buffer interpolado nacía sin color attachments y se veía SDR aplastado
    public func interpolatePixelBuffer(I0: CVPixelBuffer, I1: CVPixelBuffer, mv: [SIMD2<Int32>], gridW: Int, gridH: Int, blockSize: Int, t: Float, occThresh: Float = 1.0) -> CVPixelBuffer? {
        let w = CVPixelBufferGetWidth(I0), h = CVPixelBufferGetHeight(I0)
        // Luma plane warp reuse existing MTL path (prototype: solo luma, para HDR real se warp-ean ambos planos Y+CbCr)
        // Extrae luma como [UInt16] para reutilizar el kernel actual; luego re-ensambla en CVPixelBuffer
        // Nota: para HDR10 completo habría que warp-ear plano CbCr también; v1 propaga metadata y warp luma.
        guard let luma0 = copyLumaPlane(I0), let luma1 = copyLumaPlane(I1) else { return nil }
        let (outLuma, _) = interpolate(I0: luma0, I1: luma1, mv: mv, width: w, height: h, gridW: gridW, gridH: gridH, blockSize: blockSize, t: t, occThresh: occThresh)
        var outPB: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(I0)
        ]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, CVPixelBufferGetPixelFormatType(I0), attrs as CFDictionary, &outPB)
        guard st == kCVReturnSuccess, let out = outPB else { return nil }
        // Copia luma de vuelta (para 420v solo plano 0 aquí; plano 1 se deja negro en prototype)
        CVPixelBufferLockBaseAddress(out, [])
        CVPixelBufferLockBaseAddress(I0, .readOnly)
        if let dst = CVPixelBufferGetBaseAddressOfPlane(out, 0), let _ = CVPixelBufferGetBaseAddressOfPlane(I0, 0) {
            let bpr = CVPixelBufferGetBytesPerRowOfPlane(out, 0)
            outLuma.withUnsafeBytes { raw in
                let src = raw.baseAddress!
                // out es 10-bit en high bits (como VT): ya viene así desde readTexture
                for y in 0..<h {
                    let dstRow = dst.advanced(by: y * bpr)
                    let srcRow = src.advanced(by: y * w * 2)
                    memcpy(dstRow, srcRow, w * 2)
                }
            }
        }
        // Copia plano CbCr de I0 al buffer interpolado. MVP solo warp-ea luma;
        // el chroma de I0 es una aproximación suficiente para el frame intermedio
        // (la diferencia de chroma entre I0 e I1 es imperceptible a 24→48fps).
        // Sin esto, el plano CbCr queda sin inicializar → frames verdes.
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
        return out
    }

    private func copyLumaPlane(_ pb: CVPixelBuffer) -> [UInt16]? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard CVPixelBufferIsPlanar(pb), CVPixelBufferGetPlaneCount(pb) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0)
        let bpr = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var out = [UInt16](repeating: 0, count: w*h)
        for y in 0..<h {
            let row = base.advanced(by: y * bpr).assumingMemoryBound(to: UInt16.self)
            for x in 0..<w { out[y*w + x] = row[x] }
        }
        return out
    }

    private func propagateHDR(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey] {
            if let v = CVBufferCopyAttachment(src, key, nil) {
                CVBufferSetAttachment(dst, key, v, .shouldPropagate)
            }
        }
        // Propaga todos los attachments restantes por si hay otros (ej. MasteringDisplay)
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
