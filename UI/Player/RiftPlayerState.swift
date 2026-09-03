import Foundation
import Combine
import Contracts

@MainActor
final class RiftPlayerState: PlayerStateProviding, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.68
    @Published var playbackRate: Float = 1.0
    @Published var hasVideo = false
    @Published var areControlsVisible = true
    @Published var fpsMode: FPSMode = .native
    @Published var interpolationMode: InterpolationMode = .disabled
    @Published var isFramePlusPreparing = false
    @Published var isFramePlusPreRendered = false
    @Published var isArtificialInterpolationActive = false
    @Published var displayRenderingFPS: Double = 24
    @Published var audioTracks: [AudioTrack] = []
    @Published var selectedAudioTrackIndex = 0
    @Published var availableTracks: [MediaTrack] = []
    @Published var selectedSubtitleTrack: MediaTrack?
    @Published var visualEnhancementsEnabled = false
    @Published var currentSubtitleText: String?
    @Published var conversionProgress: Double = 0
    @Published var statusMessage: String?

    func togglePlay() { isPlaying.toggle() }
    func seek(to time: Double) { currentTime = time }
    func seek(by delta: Double) { seek(to: currentTime + delta) }
    func setVolume(_ v: Double) { volume = v }
    func cyclePlaybackRate() {}
    func closeVideo() { hasVideo = false }
    func startHideTimer() {}
    func stopHideTimer() {}
    func resetHideTimer() {}
    func formattedTime(_ s: Double) -> String { let i = Int(s); return String(format: "%d:%02d", i/60, i%60) }
    func setInterpolationMode(_ m: InterpolationMode) { interpolationMode = m }
    func selectAudioTrack(_ i: Int) { selectedAudioTrackIndex = i }
    func selectPipelineTrack(_ t: MediaTrack?) { selectedSubtitleTrack = t }
    func toggleVisualEnhancements() { visualEnhancementsEnabled.toggle() }
    func loadVideo(_ url: URL) { statusMessage = "Stub loadVideo \(url.lastPathComponent) — paso 1 sin pipeline" }
    func openVideo() {}
    func cleanup() {}
}
