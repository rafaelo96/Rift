import Foundation
import Metal

final class WarpEngine {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var outTex: MTLTexture?
    private var width = 0
    private var height = 0

    init(device: MTLDevice) throws {
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

    func readTexture(_ tex: MTLTexture) -> [UInt16] {
        let w = tex.width, h = tex.height
        var out = [UInt16](repeating: 0, count: w*h)
        out.withUnsafeMutableBytes { raw in
            tex.getBytes(raw.baseAddress!, bytesPerRow: w*MemoryLayout<UInt16>.stride, bytesPerImage: w*h*MemoryLayout<UInt16>.stride, from: MTLRegionMake2D(0,0,w,h), mipmapLevel: 0, slice: 0)
        }
        return out
    }

    // Convenience for prototype: I0/I1 as host planes, mv as [SIMD2<Int32>] half-pel
    func interpolate(I0: [UInt16], I1: [UInt16], mv: [SIMD2<Int32>], width: Int, height: Int, gridW: Int, gridH: Int, blockSize: Int, t: Float, occThresh: Float = 1.0) -> ([UInt16], Double) {
        let tex0 = makeTexture(from: I0, width: width, height: height)
        let tex1 = makeTexture(from: I1, width: width, height: height)
        let mvBuf = device.makeBuffer(bytes: mv, length: mv.count * MemoryLayout<SIMD2<Int32>>.stride, options: .storageModeShared)!
        let (outTex, ms) = interpolate(tex0: tex0, tex1: tex1, mv: mvBuf, gridW: UInt32(gridW), gridH: UInt32(gridH), blockSize: UInt32(blockSize), t: t, occThresh: occThresh)
        return (readTexture(outTex), ms)
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
