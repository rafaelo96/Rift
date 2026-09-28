// swiftc -O -parse-as-library Core/Interpolation/Swift/*.swift Core/Interpolation/Checks/PoolCheck.swift -o /tmp/rift-pool-check
import CoreVideo
import Foundation

@main
struct PoolCheck {
    static func main() throws {
        let engine = try WarpEngine(msl: warpShadersMSL)
        var source: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 64, 64,
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source) == kCVReturnSuccess)
        let input = source!
        CVPixelBufferLockBaseAddress(input, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(input) {
            memset(CVPixelBufferGetBaseAddressOfPlane(input, plane), 0,
                CVPixelBufferGetBytesPerRowOfPlane(input, plane) * CVPixelBufferGetHeightOfPlane(input, plane))
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        CVBufferSetAttachment(input, kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        let luma = [UInt16](repeating: 256, count: 64 * 64).withUnsafeBytes { Data($0) }
        func generate() -> [CVPixelBuffer] {
            engine.interpolatePixelBufferPair(I0: input, I1: input,
                luma0: luma, luma1: luma, workWidth: 64, workHeight: 64,
                mv: [SIMD2<Int32>](repeating: .zero, count: 64),
                gridW: 8, gridH: 8, blockSize: 8, tValues: [0.4, 0.8]).buffers
        }
        var held: [CVPixelBuffer] = []
        for _ in 0..<16 {
            let pair = generate()
            precondition(pair.count == 2)
            held += pair
        }
        precondition(generate().isEmpty, "Allocation must stop at 32 outstanding buffers")
        held.removeAll()
        for _ in 0..<100 {
            let pair = generate()
            precondition(pair.count == 2, "Buffers must recycle after references are released")
            precondition(CVPixelBufferGetWidth(pair[0]) == 64)
            precondition(CVBufferCopyAttachment(pair[0], kCVImageBufferColorPrimariesKey, nil) != nil)
        }
        print("PASS: 32-buffer hard limit, exhaustion recovery, 100 reused pairs and HDR metadata")
    }
}
