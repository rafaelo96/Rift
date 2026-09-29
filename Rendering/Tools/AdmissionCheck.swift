// Run: swiftc -parse-as-library Rendering/Swift/*.swift Rendering/Tools/AdmissionCheck.swift -o /tmp/rift-admission-check
import AVFoundation
import CoreVideo

private func makeBiPlanar(width: Int, height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attributes: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        kCVPixelBufferMetalCompatibilityKey as String: true
    ]
    precondition(CVPixelBufferCreate(nil, width, height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes as CFDictionary, &buffer) == kCVReturnSuccess)
    let result = buffer!
    CVPixelBufferLockBaseAddress(result, [])
    if let yBase = CVPixelBufferGetBaseAddressOfPlane(result, 0) {
        let stride = CVPixelBufferGetBytesPerRowOfPlane(result, 0)
        for y in 0..<height {
            let row = yBase.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { row[x] = ((x / 8 + y / 8) & 1) == 0 ? 32 : 192 }
        }
    }
    if let cBase = CVPixelBufferGetBaseAddressOfPlane(result, 1) {
        memset(cBase, 128, CVPixelBufferGetBytesPerRowOfPlane(result, 1) * CVPixelBufferGetHeightOfPlane(result, 1))
    }
    CVPixelBufferUnlockBaseAddress(result, [])
    return result
}

private func lumaRange(_ buffer: CVPixelBuffer) -> ClosedRange<UInt8> {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
    var minimum: UInt8 = 255, maximum: UInt8 = 0
    for y in 0..<height {
        let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width { minimum = min(minimum, row[x]); maximum = max(maximum, row[x]) }
    }
    return minimum...maximum
}

private func lumaMeanAbsoluteDifference(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) -> Double {
    precondition(CVPixelBufferGetWidthOfPlane(lhs, 0) == CVPixelBufferGetWidthOfPlane(rhs, 0))
    precondition(CVPixelBufferGetHeightOfPlane(lhs, 0) == CVPixelBufferGetHeightOfPlane(rhs, 0))
    CVPixelBufferLockBaseAddress(lhs, .readOnly)
    CVPixelBufferLockBaseAddress(rhs, .readOnly)
    defer {
        CVPixelBufferUnlockBaseAddress(rhs, .readOnly)
        CVPixelBufferUnlockBaseAddress(lhs, .readOnly)
    }
    let width = CVPixelBufferGetWidthOfPlane(lhs, 0)
    let height = CVPixelBufferGetHeightOfPlane(lhs, 0)
    let lhsStride = CVPixelBufferGetBytesPerRowOfPlane(lhs, 0)
    let rhsStride = CVPixelBufferGetBytesPerRowOfPlane(rhs, 0)
    let lhsBase = CVPixelBufferGetBaseAddressOfPlane(lhs, 0)!
    let rhsBase = CVPixelBufferGetBaseAddressOfPlane(rhs, 0)!
    var total = 0
    for y in 0..<height {
        let lhsRow = lhsBase.advanced(by: y * lhsStride).assumingMemoryBound(to: UInt8.self)
        let rhsRow = rhsBase.advanced(by: y * rhsStride).assumingMemoryBound(to: UInt8.self)
        for x in 0..<width { total += abs(Int(lhsRow[x]) - Int(rhsRow[x])) }
    }
    return Double(total) / Double(width * height)
}

@main
struct AdmissionCheck {
    @MainActor static func main() {
        let renderer = HDRDisplayRenderer()
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess)
        var admitted = 0
        // Clock is paused: enough future samples saturate the layer without
        // requiring a display or changing the user's current playback.
        for index in 0..<1000 {
            let sample = renderer.sampleBuffer(from: buffer!,
                pts: CMTime(value: Int64(index), timescale: 60),
                duration: CMTime(value: 1, timescale: 60))!
            if renderer.enqueue(sample) { admitted += 1 }
        }
        precondition(renderer.enqueueAttempts == 1000)
        precondition(admitted == renderer.enqueuedFrames)
        precondition(renderer.notReadyEnqueues > 0)
        precondition(renderer.enqueuedFrames + renderer.notReadyEnqueues == 1000)
        renderer.flush()
        renderer.resetDiagnostics()
        precondition(renderer.enqueueAttempts == 0 && renderer.enqueuedFrames == 0)

        precondition(SuperResolutionProcessor.outputDimensions(width: 1280, height: 720) == (2560, 1440))
        precondition(SuperResolutionProcessor.outputDimensions(width: 1920, height: 1080) == (3840, 2160))
        precondition(SuperResolutionProcessor.outputDimensions(width: 3840, height: 2160) == (3840, 2160))
        let source = makeBiPlanar(width: 64, height: 36)
        CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        guard let processor = SuperResolutionProcessor(),
              let enhanced = processor.process(source, mode: .balanced) else {
            preconditionFailure("super resolution processor unavailable")
        }
        precondition(CVPixelBufferGetWidth(enhanced) == 128)
        precondition(CVPixelBufferGetHeight(enhanced) == 72)
        let range = lumaRange(enhanced)
        precondition(range.lowerBound >= 32 && range.upperBound <= 192)
        precondition(CVBufferCopyAttachment(enhanced, kCVImageBufferColorPrimariesKey, nil) != nil)
        guard let soft = processor.process(source, mode: .soft),
              let strong = processor.process(source, mode: .strong) else {
            preconditionFailure("super resolution profiles unavailable")
        }
        let profileDifference = lumaMeanAbsoluteDifference(soft, strong)
        print("SR profile difference: \(String(format: "%.2f", profileDifference)) luma levels")
        precondition(profileDifference >= 3.0, "profiles are not visually distinct")
        for size in [(1280, 720), (1920, 1080), (3840, 2160)] {
            let frame = makeBiPlanar(width: size.0, height: size.1)
            precondition(processor.process(frame, mode: .balanced) != nil)
            print("SR \(size.0)x\(size.1): \(String(format: "%.2f", processor.lastProcessingMS)) ms")
        }
        print("PASS: bounded admission, native-range super resolution, attachments, and timing")
    }
}
