import Foundation
import CoreMedia
import CoreVideo
import Scheduler
import AVFoundation

func checkMonotonic(_ scheduled: [ScheduledFrame]) -> Bool {
    for i in 1..<scheduled.count {
        if scheduled[i].pts <= scheduled[i-1].pts { return false }
    }
    return true
}

func ptsSeconds(_ t: CMTime) -> Double { t.seconds }

print("=== SchedulerProbe (SDR, 24->60 3:2) ===")
let fps: Double = 24
let nReal = 6
let frames: [(pts: Double, duration: Double)] = (0..<nReal).map { i in (pts: Double(i)/fps, duration: 1.0/fps) }
print("Real frames: \(frames.map { String(format: "%.3f", $0.pts) }.joined(separator: ", "))")

let sched60 = schedule_24to60(frames: frames)
print("\n-- schedule_24to60 (\(sched60.count) display frames, expected 6 real + 1+2+1+2+1=13) --")
for (idx, f) in sched60.enumerated() {
    let sec = ptsSeconds(f.pts)
    let kind = f.isInterpolated ? String(format: "interp t=%.2f pair%d", f.t ?? 0, f.pairIndex) : "real"
    print(String(format: "%2d: %.6f s (%@) pts=%.6f", idx, sec, kind, sec))
}
let mono = checkMonotonic(sched60)
print("\nMonotonic: \(mono ? "OK" : "FAIL")")
if !mono { print("FAIL: timestamps not monotonic"); exit(1) }

// 3:2 pattern alternates 1 and 2 interpolados per pair -> intervals 0.020833 (2 splits) and 0.013889 (3 splits), avg 0.0166
print("\nIntervals (3:2 -> 0.020833 and 0.013889 alternating, avg 0.0166):")
for i in 1..<min(sched60.count, 6) {
    let d = sched60[i].pts.seconds - sched60[i-1].pts.seconds
    print(String(format: " %d->%d: %.6f", i-1, i, d))
}
let avgInterval = (sched60.last!.pts.seconds - sched60.first!.pts.seconds) / Double(sched60.count - 1)
print(String(format: " avg interval: %.6f (expected ~0.0166)", avgInterval))

// Test FPSMode selection (auto-calibration)
print("\n-- FPSMode selection (pairCostMs vs 41.7ms) --")
for cost in [20.0, 35.0, 40.0, 50.0] {
    print(String(format: " cost %.1f ms -> %@", cost, selectFPSMode(pairCostMs: cost).rawValue))
}

// Test fallback: simulate warp too slow for pair 1
print("\n-- Fallback simulation (warp budget 41.7ms) --")
let scheduler = FrameScheduler(mode: .interpolated60)
for i in 0..<5 {
    let est: Double = (i == 2) ? 50.0 : 20.0 // pair 2 slow
    let attempt = scheduler.shouldAttemptInterpolation(pairIndex: i, estimatedWarpMs: est)
    let dropped = !attempt
    scheduler.noteFallback(dropped: dropped)
    print(String(format: " pair %d est %.1f ms -> %@ (consecutiveFallbacks, mode=%@)", i, est, attempt ? "attempt" : "DROP", scheduler.mode.rawValue))
}
print(String(format: "Fallback rate: %.1f%%", scheduler.fallbackRate*100))
if scheduler.mode == .interpolated60 {
    print("OK: single drop did NOT downgrade mode (needs sustained)")
} else {
    print("FAIL: single drop incorrectly changed mode"); exit(1)
}
// Sustained fallback (30 consecutive)
let sched2 = FrameScheduler(mode: .interpolated60)
for i in 0..<35 { sched2.noteFallback(dropped: true) }
print("After 35 consecutive drops, mode=\(sched2.mode.rawValue) (expected off after 30)")
if sched2.mode != .off { print("FAIL: sustained fallback should downgrade"); exit(1) }

// Test CMSampleBuffer wrapping (need IOSurface-backed pixel buffer)
print("\n-- CMSampleBuffer wrapping (CVPixelBuffer -> display) --")
var pb: CVPixelBuffer?
let attrs: [String: Any] = [
    kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    kCVPixelBufferWidthKey as String: 64,
    kCVPixelBufferHeightKey as String: 64,
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
]
let st = CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
if st == kCVReturnSuccess, let pb {
    let sched = FrameScheduler(mode: .interpolated60)
    let pts = cmTime(from: 1.0)
    if let sbuf = sched.sampleBuffer(from: pb, pts: pts, duration: CMTime(value: 1, timescale: 60)) {
        let p = CMSampleBufferGetPresentationTimeStamp(sbuf)
        print("CMSampleBuffer pts: \(p.seconds) (expected 1.0) -> \(abs(p.seconds - 1.0) < 0.001 ? "OK" : "FAIL")")
        // Test enqueue via requestMediaDataWhenReady (mock renderer)
        let layer = AVSampleBufferDisplayLayer()
        let sync = sched.synchronizer
        sync.addRenderer(layer)
        print("AVSampleBufferRenderSynchronizer + requestMediaDataWhenReady: wired (renderers \(sync.renderers.count))")
        sync.removeRenderer(layer, at: .zero, completionHandler: nil)
    } else {
        print("FAIL: sampleBuffer creation failed"); exit(1)
    }
} else {
    print("FAIL: CVPixelBufferCreate failed \(st)"); exit(1)
}

print("\nOK — SchedulerProbe finished")
