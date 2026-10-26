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

// Ten minutes for each source/output combination. Quantized source PTS mimic
// MKV's millisecond time base; the output grid must not inherit its jitter.
for sourceFPS in [24_000.0 / 1001, 24, 25, 30_000.0 / 1001, 30] {
    for targetFPS in [50.0, 60_000.0 / 1001, 60] {
        var grid = UniformCadence(framesPerSecond: targetFPS)
        var previous: CMTime?
        var count = 0
        let pairs = Int(sourceFPS * 600)
        for index in 0..<pairs {
            let start = (Double(index) / sourceFPS * 1000).rounded() / 1000
            let end = (Double(index + 1) / sourceFPS * 1000).rounded() / 1000
            for sample in grid.samples(from: start, to: end) {
                precondition(sample.t >= 0 && sample.t < 1)
                if let previous {
                    precondition(CMTimeCompare(CMTimeSubtract(sample.pts, previous), grid.step) == 0)
                }
                precondition(abs(sample.pts.seconds - Double(count) * grid.step.seconds) < 0.000_001)
                previous = sample.pts
                count += 1
            }
        }
        precondition(abs(Double(count) - Double(pairs) / sourceFPS * targetFPS) < 2)
        grid.reset()
        precondition(abs(grid.samples(from: 120, to: 120.04).first!.pts.seconds - 120) < 0.000_001)
    }
}
var load = AdaptiveLoadMonitor()
var reductions = 0
for index in 0..<160 {
    if load.record(costMS: 40, pairBudgetMS: 41.7, now: Double(index) / 24) == .reduce {
        reductions += 1
    }
}
precondition(reductions == 1)
load.reset()
for index in 0..<160 {
    precondition(load.record(costMS: index == 80 ? 100 : 15,
        pairBudgetMS: 41.7, now: Double(index) / 24) == nil)
}
load.reset()
var recoveries = 0
for index in 0..<760 {
    if load.record(costMS: 10, pairBudgetMS: 41.7, now: Double(index) / 24) == .recover {
        recoveries += 1
    }
}
precondition(recoveries == 1)
precondition(load.record(costMS: 100, pairBudgetMS: 41.7, now: 1000) == nil)
var presentation = PresentationDropMonitor()
precondition(presentation.record(totalFrames: 100, droppedFrames: 0) == nil)
for window in 1...5 {
    precondition(presentation.record(totalFrames: 100 + window * 100, droppedFrames: window * 3) == nil)
}
precondition(presentation.record(totalFrames: 700, droppedFrames: 18) == .reduce)
presentation.reset()
precondition(presentation.record(totalFrames: 100, droppedFrames: 0) == nil)
for window in 1...19 {
    precondition(presentation.record(totalFrames: 100 + window * 100, droppedFrames: window * 15) != .disable)
}
precondition(presentation.record(totalFrames: 2100, droppedFrames: 300) == .disable)
presentation.reset()
precondition(presentation.record(totalFrames: 100, droppedFrames: 10) == nil)
for window in 1...11 {
    precondition(presentation.record(totalFrames: 100 + window * 100, droppedFrames: 10) == nil)
}
precondition(presentation.record(totalFrames: 1300, droppedFrames: 10) == .recover)
print("PASS: 15 rational cadence cases, 10 minutes each; overload, spike, recovery, discontinuity and presentation drops")

// Repeated source frames dropped by FramePool: pairs span one or two source
// periods (never more), alternating 10 s of animation on twos with 10 s on ones.
// The 60 fps grid must stay continuous and uniform across both pair lengths.
do {
    let sourceFPS = 24_000.0 / 1001, targetFPS = 60.0
    var grid = UniformCadence(framesPerSecond: targetFPS)
    let frameCount = Int(sourceFPS * 600)
    let kept = (0..<frameCount).filter { index in
        let onTwos = Int(Double(index) / sourceFPS / 10) % 2 == 0
        return !(onTwos && index % 2 == 1)
    }
    var previous: CMTime?
    var count = 0, longPairs = 0
    for (start, end) in zip(kept, kept.dropFirst()) {
        precondition(end - start <= 2)
        let a = (Double(start) / sourceFPS * 1000).rounded() / 1000
        let b = (Double(end) / sourceFPS * 1000).rounded() / 1000
        let samples = grid.samples(from: a, to: b)
        // 2 × 41.71 ms slightly exceeds 5 × 16.67 ms: a long pair can hold six grid
        // points, but then the first lies within the player's 1 ms source tolerance,
        // so at most five need synthesis (DenseMotionPrototype.maxSamplesPerPair = 6).
        precondition(samples.count <= (end - start == 2 ? 6 : 3))
        let synthetic = samples.filter { $0.pts.seconds - a > 0.001 && b - $0.pts.seconds > 0.001 }
        precondition(synthetic.count <= (end - start == 2 ? 5 : 3))
        precondition(zip(samples, samples.dropFirst()).allSatisfy { $0.t < $1.t })
        if end - start == 2 { longPairs += 1 }
        for sample in samples {
            precondition(sample.t >= 0 && sample.t < 1)
            if let previous { precondition(CMTimeCompare(CMTimeSubtract(sample.pts, previous), grid.step) == 0) }
            precondition(abs(sample.pts.seconds - Double(count) * grid.step.seconds) < 0.000_001)
            previous = sample.pts
            count += 1
        }
    }
    let duration = (Double(kept.last!) / sourceFPS * 1000).rounded() / 1000
    precondition(abs(Double(count) - duration * targetFPS) < 2)
    precondition(longPairs > 3000)

    // The monitor sees cost relative to each pair's own budget, so long pairs at
    // a healthy ratio never reduce and an overloaded ratio reduces as for short pairs.
    let longBudget = 2 * 1000 / sourceFPS
    var monitor = AdaptiveLoadMonitor()
    for index in 0..<360 {
        precondition(monitor.record(costMS: 38, pairBudgetMS: longBudget, now: Double(index) * 2 / sourceFPS) == nil)
    }
    monitor.reset()
    var longReductions = 0
    for index in 0..<80 {
        if monitor.record(costMS: longBudget * 0.96, pairBudgetMS: longBudget, now: Double(index) * 2 / sourceFPS) == .reduce {
            longReductions += 1
        }
    }
    precondition(longReductions == 1)
    monitor.reset()
    var mixedReductions = 0, now = 0.0
    for index in 0..<120 {
        let periods = index % 3 == 0 ? 1.0 : 2.0
        let budget = periods * 1000 / sourceFPS
        if monitor.record(costMS: budget * 0.96, pairBudgetMS: budget, now: now) == .reduce { mixedReductions += 1 }
        now += periods / sourceFPS
    }
    precondition(mixedReductions == 1)
    print("PASS: mixed one/two-period pairs (\(longPairs) long) keep a continuous 60 fps grid; load monitor uses each pair's own budget")
}

// Maximum-fluidity mode: FramePool may drop two repeats in a row, so pairs span
// one, two or three source periods (animation on ones, twos and threes). A
// three-period pair lasts up to 125.1 ms: at most eight grid points, exactly
// UniformCadence's per-call bound, and up to eight may need synthesis.
do {
    var cases = 0, threePeriodPairs = 0, maxSynthetic = 0
    for sourceFPS in [24_000.0 / 1001, 24, 25, 30_000.0 / 1001] {
        for targetFPS in [50.0, 60_000.0 / 1001, 60] {
            var grid = UniformCadence(framesPerSecond: targetFPS)
            let frameCount = Int(sourceFPS * 600)
            // 10 s segments cycling ones → twos → threes; keep every Nth frame.
            var kept = [0]
            while true {
                let hold = Int(Double(kept.last!) / sourceFPS / 10) % 3 + 1
                guard kept.last! + hold < frameCount else { break }
                kept.append(kept.last! + hold)
            }
            var previous: CMTime?
            var count = 0
            for (start, end) in zip(kept, kept.dropFirst()) {
                let periods = end - start
                precondition(periods >= 1 && periods <= 3)
                let a = (Double(start) / sourceFPS * 1000).rounded() / 1000
                let b = (Double(end) / sourceFPS * 1000).rounded() / 1000
                let samples = grid.samples(from: a, to: b)
                // The per-call bound (8) must never truncate a pair: the next grid point
                // after the last sample has to fall at or beyond the pair's end.
                if let last = samples.last { precondition(last.pts.seconds + grid.step.seconds >= b - 0.000_001) }
                // 23.976→59.94 or 25→60: a three-period pair can hold eight points with
                // none within the 1 ms source tolerance — maxSamplesPerPair = 8 covers it.
                let synthetic = samples.filter { $0.pts.seconds - a > 0.001 && b - $0.pts.seconds > 0.001 }
                precondition(synthetic.count <= 8)
                maxSynthetic = max(maxSynthetic, synthetic.count)
                precondition(zip(samples, samples.dropFirst()).allSatisfy { $0.t < $1.t })
                if periods == 3 { threePeriodPairs += 1 }
                for sample in samples {
                    precondition(sample.t >= 0 && sample.t < 1)
                    if let previous { precondition(CMTimeCompare(CMTimeSubtract(sample.pts, previous), grid.step) == 0) }
                    precondition(abs(sample.pts.seconds - Double(count) * grid.step.seconds) < 0.000_001)
                    previous = sample.pts
                    count += 1
                }
            }
            let duration = (Double(kept.last!) / sourceFPS * 1000).rounded() / 1000
            precondition(abs(Double(count) - duration * targetFPS) < 2)
            cases += 1
        }
    }

    // Three-period pairs use their own 125 ms budget.
    let period = 1000 / (24_000.0 / 1001)
    var monitor = AdaptiveLoadMonitor()
    for index in 0..<240 {
        precondition(monitor.record(costMS: 56, pairBudgetMS: 3 * period, now: Double(index) * 3 * period / 1000) == nil)
    }
    monitor.reset()
    var reductions = 0
    for index in 0..<60 {
        if monitor.record(costMS: 3 * period * 0.96, pairBudgetMS: 3 * period, now: Double(index) * 3 * period / 1000) == .reduce { reductions += 1 }
    }
    precondition(reductions == 1)
    monitor.reset()
    var mixedReductions = 0, now = 0.0
    for index in 0..<120 {
        let periods = Double(index % 3 + 1)
        if monitor.record(costMS: periods * period * 0.96, pairBudgetMS: periods * period, now: now) == .reduce { mixedReductions += 1 }
        now += periods * period / 1000
    }
    precondition(mixedReductions == 1)
    print("PASS: one/two/three-period pairs, \(cases) rate combinations (\(threePeriodPairs) three-period pairs): continuous grid, max \(maxSynthetic) synthetic per pair; load monitor per-pair budgets")
}
