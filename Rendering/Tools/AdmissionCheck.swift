// Run: swiftc -parse-as-library Rendering/Swift/*.swift Rendering/Tools/AdmissionCheck.swift -o /tmp/rift-admission-check
import AVFoundation
import CoreVideo

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
        print("PASS: bounded admission and exact accepted/rejected accounting")
    }
}
