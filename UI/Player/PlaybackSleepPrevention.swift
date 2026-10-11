import Foundation

/// Owns one activity for the entire playback session, including PiP.
/// Call update on the player's main actor; destruction releases the activity.
final class PlaybackSleepPrevention {
    private var activity: NSObjectProtocol?

    func update(hasVideo: Bool, isPlaying: Bool, position: Double, duration: Double) {
        let reachedEnd = duration.isFinite && duration > 0 && position >= duration
        let shouldPreventSleep = hasVideo && isPlaying && !reachedEnd
        if shouldPreventSleep {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "Rift video playback"
            )
        } else if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    deinit {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }
}
