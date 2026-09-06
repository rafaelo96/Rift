import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

// MARK: - FrameScheduler (SDR, sin HDR)

public final class FrameScheduler {
    public private(set) var mode: SchedulerFPSMode
    private let budgetMs: Double
    private let timescale: CMTimeScale
    // sustained fallback detection
    private var consecutiveFallbacks = 0
    private var totalFrames = 0
    private var droppedInterpolated = 0
    private let sync = AVSampleBufferRenderSynchronizer()
    public var synchronizer: AVSampleBufferRenderSynchronizer { sync }

    public init(mode: SchedulerFPSMode, budgetMs: Double = 41.7, timescale: CMTimeScale = schedulerTimescale) {
        self.mode = mode
        self.budgetMs = budgetMs
        self.timescale = timescale
    }

    public func setMode(_ mode: SchedulerFPSMode) {
        self.mode = mode
    }

    // MARK: - Schedule generation (pure, testable)

    public func schedule(frames: [(pts: Double, duration: Double)]) -> [ScheduledFrame] {
        switch mode {
        case .native24, .off:
            return frames.map { ScheduledFrame(pts: cmTime(from: $0.pts), isInterpolated: false, t: nil, pairIndex: -1) }
        case .interpolated60:
            return schedule_24to60(frames: frames)
        case .interpolated48:
            // 24->48 1 interpolado por par t=0.5
            guard frames.count >= 2 else { return frames.map { ScheduledFrame(pts: cmTime(from: $0.pts), isInterpolated: false, t: nil, pairIndex: -1) } }
            var out: [ScheduledFrame] = []
            for i in 0..<(frames.count - 1) {
                let a = frames[i]; let b = frames[i+1]
                if out.isEmpty { out.append(ScheduledFrame(pts: cmTime(from: a.pts), isInterpolated: false, t: nil, pairIndex: i)) }
                out.append(ScheduledFrame(pts: cmTime(from: a.pts + (b.pts - a.pts)*0.5), isInterpolated: true, t: 0.5, pairIndex: i))
                out.append(ScheduledFrame(pts: cmTime(from: b.pts), isInterpolated: false, t: nil, pairIndex: i))
            }
            return out
        }
    }

    // MARK: - CMSampleBuffer wrapping (CVPixelBuffer -> display)

    public func sampleBuffer(from pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime? = nil) -> CMSampleBuffer? {
        // CVPixelBuffer must be IOSurface-backed (VTDecoder already ensures this via kCVPixelBufferIOSurfacePropertiesKey)
        var fmt: CMFormatDescription?
        let s1 = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &fmt)
        guard s1 == noErr, let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: duration ?? CMTime.invalid, presentationTimeStamp: pts, decodeTimeStamp: CMTime.invalid)
        var sbuf: CMSampleBuffer?
        let s2 = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sbuf)
        guard s2 == noErr else { return nil }
        return sbuf
    }

    // MARK: - Enqueue via Apple callback (no polling)

    public func enqueue(scheduled: [ScheduledFrame], pixelFor: @escaping (ScheduledFrame) -> CVPixelBuffer?, to renderer: AVQueuedSampleBufferRendering) {
        // Caller provides pixelFor that returns real or interpolated buffer (or nil if dropped).
        // We use requestMediaDataWhenReady as Apple expects.
        let queue = DispatchQueue(label: "rift.scheduler.enqueue")
        renderer.requestMediaDataWhenReady(on: queue) {
            var idx = 0
            while renderer.isReadyForMoreMediaData && idx < scheduled.count {
                let sf = scheduled[idx]
                guard let pb = pixelFor(sf) else { idx += 1; continue } // dropped
                let dur: CMTime
                if idx + 1 < scheduled.count {
                    dur = CMTimeSubtract(scheduled[idx+1].pts, sf.pts)
                } else {
                    dur = CMTime(value: 1, timescale: 60)
                }
                if let sbuf = self.sampleBuffer(from: pb, pts: sf.pts, duration: dur) {
                    renderer.enqueue(sbuf)
                }
                idx += 1
            }
        }
    }

    // MARK: - Fallback decision (per-frame, not per-mode)

    // Called per pair before warp; returns true if we should attempt interpolation, false = show real only.
    // Sustained fallback detection is separate (see noteFallback).
    public func shouldAttemptInterpolation(pairIndex: Int, estimatedWarpMs: Double) -> Bool {
        if mode == .off || mode == .native24 { return false }
        // single-frame deadline: if warp would exceed budget, drop this one interpolado
        if estimatedWarpMs > budgetMs { return false }
        return true
    }

    public func noteFallback(dropped: Bool) {
        totalFrames += 1
        if dropped { consecutiveFallbacks += 1; droppedInterpolated += 1 } else { consecutiveFallbacks = 0 }
        // Re-evaluate mode only on sustained fallback (~3-5s at 60fps ~180-300 frames, here threshold 30 for prototype)
        if consecutiveFallbacks >= 30 {
            // would trigger re-calibration warm-up; for now just log and downgrade to native
            // In production this would re-run selectFPSMode with fresh pairCostMs
            mode = .off
            consecutiveFallbacks = 0
        }
    }

    public var fallbackRate: Double {
        guard totalFrames > 0 else { return 0 }
        return Double(droppedInterpolated) / Double(totalFrames)
    }
}
