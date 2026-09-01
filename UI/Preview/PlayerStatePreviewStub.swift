import SwiftUI
import Contracts

// MARK: - PlayerStatePreviewStub
//
// ⚠️ SOLO PARA PREVIEW / DESARROLLO AISLADO DE UI.
//
// Implementación de muestra de `PlayerStateProviding` con valores estáticos y
// animaciones de juguete, para poder previsualizar la capa UI sin Core/.
// NO USAR como base de la implementación real: cuando Core/ exista, la
// implementación real conformará `PlayerStateProviding` y reemplazará a este
// stub desde `RiftApp` (ver TODO(Core) en RiftApp.swift).

@MainActor
final class PlayerStatePreviewStub: PlayerStateProviding, ObservableObject {

    // MARK: PlaybackControlling

    var isPlaying: Bool { false }
    var currentTime: Double = 0
    var duration: Double = 118.5
    var volume: Double = 0.68
    var playbackRate: Float = 1.0
    var hasVideo: Bool = false
    var areControlsVisible: Bool = true

    // MARK: InterpolationStateProviding

    var fpsMode: FPSMode = .native
    var interpolationMode: InterpolationMode = .disabled
    var isFramePlusPreparing: Bool = false
    var isFramePlusPreRendered: Bool = false
    var isArtificialInterpolationActive: Bool = false
    var displayRenderingFPS: Double = 24

    // MARK: TrackSelectionProviding

    var audioTracks: [AudioTrack] = []
    var selectedAudioTrackIndex: Int = 0
    var availableTracks: [MediaTrack] = []
    var selectedSubtitleTrack: MediaTrack?
    var visualEnhancementsEnabled: Bool = false
    var currentSubtitleText: String? = nil

    // MARK: PlaybackControlling methods

    func togglePlay() {}
    func seek(to time: Double) { currentTime = time }
    func seek(by delta: Double) { currentTime = max(0, min(duration, currentTime + delta)) }
    func setVolume(_ volume: Double) { self.volume = volume }
    func cyclePlaybackRate() {}
    func closeVideo() {}

    func startHideTimer() {}
    func stopHideTimer() {}
    func resetHideTimer() {}

    func formattedTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    // MARK: InterpolationStateProviding methods

    func setInterpolationMode(_ mode: InterpolationMode) { interpolationMode = mode }

    // MARK: TrackSelectionProviding methods

    func selectAudioTrack(_ index: Int) { selectedAudioTrackIndex = index }
    func selectPipelineTrack(_ track: MediaTrack?) { selectedSubtitleTrack = track }
    func toggleVisualEnhancements() { visualEnhancementsEnabled.toggle() }
}