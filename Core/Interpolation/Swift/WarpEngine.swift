import Foundation
import Metal
import CoreVideo

public final class WarpEngine {
    public enum Error: Swift.Error {
        case deviceUnavailable
        case libraryCompile(String)
        case pipeline(String)
    }

    public let device: MTLDevice
    let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
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
        guard let warpFn = library.makeFunction(name: "warpLuma") else {
            throw Error.pipeline("missing warpLuma function")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: warpFn)
        } catch {
            throw Error.pipeline("\(error)")
        }
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

    public func interpolatePixelBuffer(I0: CVPixelBuffer, I1: CVPixelBuffer, mv: [SIMD2<Int32>], gridW: Int, gridH: Int, blockSize: Int, t: Float, occThresh: Float = 1.0) -> (CVPixelBuffer?, Double) {
        let w = CVPixelBufferGetWidth(I0), h = CVPixelBufferGetHeight(I0)
        
        var outPB: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(I0)
        ]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, w, h, CVPixelBufferGetPixelFormatType(I0), attrs as CFDictionary, &outPB)
        guard st == kCVReturnSuccess, let out = outPB, let cache = textureCache else { return (nil, 0) }

        var cvTex0: CVMetalTexture?, cvTex1: CVMetalTexture?, cvTexOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, I0, nil, .r16Uint, w, h, 0, &cvTex0)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, I1, nil, .r16Uint, w, h, 0, &cvTex1)
        CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, out, nil, .r16Uint, w, h, 0, &cvTexOut)
        
        guard let t0 = cvTex0, let tex0 = CVMetalTextureGetTexture(t0),
              let t1 = cvTex1, let tex1 = CVMetalTextureGetTexture(t1),
              let tOut = cvTexOut, let texOut = CVMetalTextureGetTexture(tOut) else { return (nil, 0) }

        let mvBuf = device.makeBuffer(bytes: mv, length: mv.count * MemoryLayout<SIMD2<Int32>>.stride, options: .storageModeShared)!
        
        let warpMS = interpolate(tex0: tex0, tex1: tex1, mv: mvBuf, gridW: UInt32(gridW), gridH: UInt32(gridH), blockSize: UInt32(blockSize), t: t, occThresh: occThresh, outTex: texOut)

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
        return (out, warpMS)
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
