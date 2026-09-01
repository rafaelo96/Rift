import Combine
import Foundation

// MARK: - Playback Controlling
//
// Control básico de reproducción y visibilidad de la barra de controles.

/// Control básico de reproducción y visibilidad de la barra de controles.
@MainActor
public protocol PlaybackControlling: ObservableObject {
    var isPlaying: Bool { get }
    var currentTime: Double { get }
    var duration: Double { get }
    var volume: Double { get }
    var playbackRate: Float { get set }
    var hasVideo: Bool { get }
    var areControlsVisible: Bool { get set }

    func togglePlay()
    func seek(to time: Double)
    func seek(by delta: Double)
    func setVolume(_ volume: Double)
    func cyclePlaybackRate()
    func closeVideo()

    func startHideTimer()
    func stopHideTimer()
    func resetHideTimer()

    func formattedTime(_ seconds: Double) -> String
}

/// Estado relacionado con interpolación de frames (Frame⁺).
@MainActor
public protocol InterpolationStateProviding: ObservableObject {
    var fpsMode: FPSMode { get }
    var interpolationMode: InterpolationMode { get }
    var isFramePlusPreparing: Bool { get }
    var isFramePlusPreRendered: Bool { get }
    var isArtificialInterpolationActive: Bool { get }
    var displayRenderingFPS: Double { get }

    func setInterpolationMode(_ mode: InterpolationMode)
}

/// Selección de pistas (audio / subtítulos) y realces visuales.
@MainActor
public protocol TrackSelectionProviding: ObservableObject {
    var audioTracks: [AudioTrack] { get }
    var selectedAudioTrackIndex: Int { get }
    var availableTracks: [MediaTrack] { get }
    var selectedSubtitleTrack: MediaTrack? { get }
    var visualEnhancementsEnabled: Bool { get }
    var currentSubtitleText: String? { get }

    func selectAudioTrack(_ index: Int)
    func selectPipelineTrack(_ track: MediaTrack?)
    func toggleVisualEnhancements()
}

/// Estado completo que la capa UI necesita. Core/ implementará esta combinación
/// cuando exista; mientras tanto `UI/Preview/PlayerStatePreviewStub` provee una
/// implementación de muestra solo para previsualización.
public typealias PlayerStateProviding =
    PlaybackControlling &
    InterpolationStateProviding &
    TrackSelectionProviding