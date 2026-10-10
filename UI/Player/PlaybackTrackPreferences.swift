import Foundation

/// A missing selection preserves the player's defaults for older sessions.
struct PlaybackTrackPreferences: Codable, Equatable {
    enum SubtitleSelection: Codable, Equatable {
        case off
        case embedded(Int)
        case external
    }

    var audioStreamIndex: Int?
    var subtitles: SubtitleSelection?

    func audioIndex(available: [Int]) -> Int? {
        if let audioStreamIndex, available.contains(audioStreamIndex) {
            return audioStreamIndex
        }
        return available.first
    }

    func subtitleIndex(available: [Int], defaultIndex: Int?) -> Int? {
        switch subtitles {
        case .off:
            return nil
        case .embedded(let index):
            return available.contains(index) ? index : defaultIndex
        case .external, nil:
            return defaultIndex
        }
    }

    var shouldRestoreExternalSubtitles: Bool {
        switch subtitles {
        case .off, .embedded: return false
        case .external, nil: return true
        }
    }
}
