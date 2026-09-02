import Foundation
import CoreMedia

// MARK: - FPSMode selection (auto-calibration, warm-up only)

public enum SchedulerFPSMode: String, Sendable {
    case native24      // no interpolation
    case interpolated60 // 24->60 3:2
    case interpolated48 // fallback 24->48 2x
    case off           // interpolación desactivada por costo
}

// Decide FPSMode from warm-up pairCostMs (ME+warp) vs budget.
// Solo se llama en warm-up; re-evaluación solo si fallback sostenido (ver FrameScheduler).
public func selectFPSMode(pairCostMs: Double, budgetMs: Double = 41.7) -> SchedulerFPSMode {
    if pairCostMs <= budgetMs * 0.90 { return .interpolated60 }
    if pairCostMs <= budgetMs { return .interpolated48 }
    return .off
}

// MARK: - CMTime helpers — timescale 90_000 keeps 1/24, 1/60 and t=1/2,1/3,2/3 exact
public let schedulerTimescale: CMTimeScale = 90_000

public func cmTime(from seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: schedulerTimescale)
}

// Presentation schedule for 24->60 3:2 (alternating 1 and 2 interpolados por par)
public struct ScheduledFrame: Sendable {
    public let pts: CMTime
    public let isInterpolated: Bool
    public let t: Double?
    public let pairIndex: Int
}

public func schedule_24to60(frames: [(pts: Double, duration: Double)]) -> [ScheduledFrame] {
    guard frames.count >= 2 else {
        return frames.map { ScheduledFrame(pts: cmTime(from: $0.pts), isInterpolated: false, t: nil, pairIndex: -1) }
    }
    var out: [ScheduledFrame] = []
    // Emit real 0, then for each interval [i,i+1): interpolados + real i+1
    for i in 0..<(frames.count - 1) {
        let a = frames[i]
        let b = frames[i + 1]
        let delta = b.pts - a.pts
        guard delta > 0 else { continue }
        if out.isEmpty {
            out.append(ScheduledFrame(pts: cmTime(from: a.pts), isInterpolated: false, t: nil, pairIndex: i))
        }
        let tValues: [Double] = (i % 2 == 0) ? [0.5] : [1.0/3.0, 2.0/3.0]
        for t in tValues {
            out.append(ScheduledFrame(pts: cmTime(from: a.pts + delta * t), isInterpolated: true, t: t, pairIndex: i))
        }
        out.append(ScheduledFrame(pts: cmTime(from: b.pts), isInterpolated: false, t: nil, pairIndex: i))
    }
    return out
}
