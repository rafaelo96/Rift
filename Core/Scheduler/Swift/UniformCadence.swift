import CoreMedia
import Foundation

/// A bounded, half-open [start,end) slice of a persistent presentation grid.
/// Recomputes positions from the epoch instead of accumulating rounded deltas.
public struct UniformCadence {
    public struct Sample {
        public let pts: CMTime
        public let t: Float
    }

    public let step: CMTime
    private var epoch: CMTime?
    private var nextIndex: Int64 = 0
    private var lastEnd: Double?

    public init(framesPerSecond: Double) {
        let fps = framesPerSecond.isFinite && framesPerSecond > 0 ? framesPerSecond : 60
        step = CMTime(seconds: 1 / min(fps, 120), preferredTimescale: 60_000_000)
    }

    public mutating func reset() {
        epoch = nil
        nextIndex = 0
        lastEnd = nil
    }

    public mutating func samples(from start: Double, to end: Double) -> [Sample] {
        guard start.isFinite, end.isFinite, end > start else { return [] }
        // Discontinuities require a fresh epoch; never synthesize across seeks.
        if let previous = lastEnd, abs(start - previous) > 0.002 { reset() }
        if epoch == nil { epoch = CMTime(seconds: start, preferredTimescale: 60_000_000) }
        guard let epoch else { return [] }
        lastEnd = end
        let firstIndex = max(0, ceil((start - epoch.seconds) / step.seconds - 0.000_01))
        guard firstIndex < Double(Int32.max) else { reset(); return [] }
        nextIndex = max(nextIndex, Int64(firstIndex))
        var output: [Sample] = []
        // Corrupt timestamps cannot allocate an unbounded output window.
        while output.count < 8, nextIndex < Int64(Int32.max) {
            let pts = CMTimeAdd(epoch, CMTimeMultiply(step, multiplier: Int32(nextIndex)))
            if pts.seconds >= end - 0.000_000_1 { break }
            let fraction = (pts.seconds - start) / (end - start)
            output.append(Sample(pts: pts, t: Float(min(max(fraction, 0), 1))))
            nextIndex += 1
        }
        return output
    }
}

/// Measures whole-pair costs relative to the real playback budget.
/// Warmup/pause/seek/starvation must be excluded by the caller.
public struct AdaptiveLoadMonitor {
    public enum Action { case reduce, recover }
    private var start: Double?
    private var last: Double?
    private var ratios: [Double] = []
    private var weakWindows = 0
    private var healthyWindows = 0

    public init() {}
    public mutating func reset() { self = Self() }

    public mutating func record(costMS: Double, pairBudgetMS: Double, now: Double) -> Action? {
        guard costMS.isFinite, costMS >= 0, pairBudgetMS.isFinite,
              pairBudgetMS > 0, now.isFinite else { return nil }
        if let last, now < last || now - last > 0.5 { reset() }
        last = now
        if start == nil { start = now }
        ratios.append(costMS / pairBudgetMS)
        if ratios.count > 360 { ratios.removeFirst() }
        guard let start, now - start >= 3 else { return nil }
        let sorted = ratios.sorted()
        let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
        weakWindows = p95 > 0.80 ? weakWindows + 1 : 0
        // Recovery needs substantially more headroom and 30 healthy seconds.
        healthyWindows = p95 < 0.45 ? healthyWindows + 1 : 0
        self.start = now
        ratios.removeAll(keepingCapacity: true)
        if weakWindows >= 2 { reset(); return .reduce }
        if healthyWindows >= 10 { reset(); return .recover }
        return nil
    }
}
