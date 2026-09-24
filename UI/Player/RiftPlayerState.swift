import Foundation
import AVFoundation
import Combine
import os
import Contracts
import Demux
import Decode
import DecodeAudio
import FramePool
import Scheduler
import Rendering
import Interpolation
import UniformTypeIdentifiers
import AppKit
import CoreMedia
import CoreVideo
@preconcurrency import AVKit

actor AsyncSemaphore {
    private let capacity: Int
    private var count: Int
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    init(value: Int) { capacity = value; count = value }
    /// true si el permiso fue concedido; false si `reset()` anuló la espera
    /// (pipeline descartado). Permite al decay loop distinguir "no hay cupo
    /// ahora" de "mi trabajo fue invalidado" y terminar sin robar permisos.
    func wait() async -> Bool {
        if count > 0 { count -= 1; return true }
        return await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if waiters.isEmpty { count += 1 }
        else { waiters.removeFirst().resume(returning: true) }
    }
    /// Restaura el cupo a su capacidad inicial y despierta los waiters colgados
    /// con `false` (permiso anulado). Se usa al descartar un pipeline viejo en
    /// loadVideo: un decodeTask aparcado en wait() sin manejo de cancelación
    /// jamás se reanudaba por Task.cancel, secuestrando un permit para siempre.
    func reset() {
        count = capacity
        let parked = waiters
        waiters = []
        for w in parked { w.resume(returning: false) }
    }
    /// Ejecuta `body` con acceso exclusivo al demuxer. El executor serial del
    /// actor garantiza que dos llamadas (nextPacket del decode loop y seek
    /// desde UI) jamás se solapan: av_seek_frame concurrente con av_read_frame
    /// sobre el mismo contexto FFmpeg es UB y era la causa del video congelado
    /// post-seek (decode muerto en silencio + audio ok). El body es síncrono:
    /// no debe hacer await ni tocar el MainActor (bloquearía al resto).
    func withDemuxAccess<T>(_ body: () throws -> T) rethrows -> T {
        try body()
    }
}

typealias DecodeCoordinator = AsyncSemaphore

/// Wrapper Sendable-safe para los `CVPixelBuffer` generados por interpolación.
/// CVPixelBuffer (Core Foundation, IOSurface-backed) es seguro de pasar entre
/// hilos por diseño de VideoToolbox/CoreVideo, pero Swift no puede verificarlo
/// estáticamente; `@unchecked Sendable` declara explícitamente esa seguridad
/// cuando los buffers cruzan el límite del detatched task → MainActor.
private struct InterpolatedBuffersBox: @unchecked Sendable {
    let buffers: [CVPixelBuffer]
}

struct RecentVideo: Codable, Identifiable {
    let path: String
    let lastOpened: Date
    let playbackPosition: Double
    let duration: Double

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var title: String { url.lastPathComponent }

    var resumePosition: Double {
        guard duration > 0, playbackPosition < max(duration - 15, 0) else { return 0 }
        return max(playbackPosition, 0)
    }
}

struct PlaylistItem: Codable, Identifiable, Equatable {
    let path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

struct PlaybackMarker: Codable, Identifiable, Equatable {
    let id: UUID
    let time: Double
    let title: String
}

struct PlaybackTechnicalInfo: Equatable {
    let title: String
    let resolution: String
    let videoCodec: String
    let frameRate: String
    let colorSpace: String
    let audio: String
    let duration: String
}

private struct PlaybackPreferences: Codable {
    let volume: Double
    let interpolationMode: String
    let audioSyncOffset: Double?
}

@MainActor
private final class PictureInPictureCoordinator: NSObject, @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate, @preconcurrency AVPictureInPictureControllerDelegate {
    weak var state: RiftPlayerState?

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard let state, state.isPlaying != playing else { return }
        state.togglePlay()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        guard let state, state.duration > 0 else { return .invalid }
        return CMTimeRange(start: .zero, duration: CMTime(seconds: state.duration, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        !(state?.isPlaying ?? false)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        state?.resizePictureInPictureSourceLayer()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
        state?.seek(by: skipInterval.seconds)
        completion()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        state?.isPictureInPictureActive = true
        state?.resizePictureInPictureSourceLayer()
        state?.suppressBrokenPictureInPictureHostOverlay()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        state?.restorePictureInPictureSourceLayer()
        state?.isPictureInPictureActive = false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        state?.statusMessage = "Picture in Picture unavailable: \(error.localizedDescription)"
    }
}

@MainActor
final class RiftPlayerState: PlayerStateProviding, ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var volume: Double = 0.68
    @Published private(set) var audioSyncOffset: Double = 0
    @Published var playbackRate: Float = 1.0
    @Published var hasVideo = false
    @Published var areControlsVisible = true
    private var controlsHideTimer: Timer?
    private var isPointerOverControls = false
    private let controlsHideDelay: TimeInterval = 2.0
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
    @Published private(set) var recentVideos: [RecentVideo] = []
    @Published private(set) var playlist: [PlaylistItem] = []
    @Published private(set) var activePlaylistItemID: String?
    @Published private(set) var markers: [PlaybackMarker] = []
    @Published private(set) var chapters: [ChapterInfo] = []
    @Published private(set) var technicalInfo: PlaybackTechnicalInfo?
    @Published private(set) var externalSubtitleName: String?
    @Published private(set) var timelineThumbnail: VideoThumbnail?
    @Published private(set) var isTimelineThumbnailLoading = false
    @Published fileprivate(set) var isPictureInPictureAvailable = false
    @Published fileprivate(set) var isPictureInPictureActive = false

    private static let preferencesKey = "rift.playback.preferences.v1"
    private static let recentVideosKey = "rift.playback.recents.v1"
    private static let resumeSessionKey = "rift.playback.resume.v1"
    private static let playlistKey = "rift.playback.playlist.v1"
    private static let markersKey = "rift.playback.markers.v1"
    private static let externalSubtitlesKey = "rift.playback.external-subtitles.v1"
    private static let recentVideoLimit = 10
    private var lastPersistedPlaybackPosition: Double = -1
    private var markersByPath: [String: [PlaybackMarker]] = [:]
    private var externalSubtitlePathByVideoPath: [String: String] = [:]
    private var externalSubtitleURL: URL?
    private var pictureInPictureController: AVPictureInPictureController?
    private var pictureInPictureCoordinator: PictureInPictureCoordinator?
    private var pictureInPictureSourceFrame: CGRect?
    private var pictureInPictureResizeObserver: NSObjectProtocol?

    private var demuxer: FFmpegDemuxer?
    private var decoder: VTDecoder?
    private var framePool: SlidingFramePool?
    private var scheduler: FrameScheduler?
    private var renderer: HDRDisplayRenderer?
    /// Motor MCFI. Se inicializa lazy la primera vez que se necesita (cuando
    /// `interpolationMode != .disabled`) y se libera en closeVideo(). Es stateful
    /// solo en buffers Metal internos; cada `interpolate()` es autocontenida.
    private var compensator: MotionCompensator?
    /// Almacena los últimos 2 frames mostrados (SIN remover del pool).
    /// Usado por el interpolador en background para evitar dependencia
    /// directa con reservePair/consumePair.
    private var lastShownFrames: [Frame] = []
    /// Bloqueo para asegurar que solo haya 1 frame interpolándose a la vez.
    /// Evita saturar la GPU y sobreescribir los recursos Metal del compensator.
    private var isInterpolating = false
    /// Pairs interpolated since the last mode change / seek. Budget check is
    /// skipped during the first `interpolationWarmupPairs` to let Metal JIT
    /// and first-time buffer allocations settle.
    private var interpolationPairCount = 0
    /// Wall-clock ms of each post-warmup pair (capped window of last 10).
    /// Fallback triggers only when the *moving average* exceeds budget,
    /// preventing a single outlier (GC, thermal blip) from killing Frame+.
    private var recentPairTimings: [Double] = []
    /// El perfil HQ se prueba en vivo; si sus pares completos no caben en el
    /// periodo fuente, se degrada a `.fluid` sin apagar la interpolación.
    private var recentHighQualityPairTimings: [Double] = []
    private var usesHighQualityFluidProfile = true
    /// If Frame+ was disabled by sustained fallback, allow re-attempt
    /// after a user-initiated seek or mode change.
    private var fallbackDisabled = false
    /// Number of interpolated pairs to skip before the budget gate activates.
    private let interpolationWarmupPairs = 5
    /// Moving-average window for the budget gate (post-warmup).
    private let interpolationTimingWindow = 10

    // MARK: - Throughput deficit gate (latencia bajo pacing)
    /// Seconds between consecutive gate evaluations.
    private let throughputWindowSeconds = 3.0
    /// Number of consecutive weak evaluations (each spanning `throughputWindowSeconds`)
    /// before the gate fires (avoids reacting to a single isolated burst).
    private let throughputRequiredWeakWindows = 2
    /// Seconds after the first completed pair before any evaluation runs.
    /// The interp pipeline is slow to reach steady state (decoder cold start,
    /// Metal shader JIT, initial pool fill), so early windows read artificially
    /// low and must not trip the gate (measured: false-positive at ~6s on 1080p).
    private let throughputSkipStartupSeconds = 8.0
    /// Wall-clock of the first completed pair (arms the startup skip).
    private var firstPairCompletedAt: UInt64 = 0
    // ── Timeline instrumentation (diagnostic only, no behavior change) ──────
    struct FrameTimeline {
        let pts: Double
        var decodeStartNS: UInt64 = 0
        var decodeEndNS: UInt64 = 0
        var poolAddNS: UInt64 = 0
    }
    private var frameTimelines: [Int64: FrameTimeline] = [:]
    private static func timelineKey(_ pts: Double) -> Int64 { Int64(pts * 1_000) }
    private static let timelineLogPath = "/tmp/rift_timeline.log"
    private static func writeTimelineLog(_ s: String) {
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: timelineLogPath) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            FileManager.default.createFile(atPath: timelineLogPath, contents: line.data(using: .utf8))
        }
    }
    /// Wall-clock timestamps of recently completed pair iterations (legacy
    /// bookkeeping; el gate actual usa latencia, no pares/s).
    private var pairCompletionTimes: [UInt64] = []
    /// Consecutive weak windows observed (reset when a good window is seen).
    private var weakThroughputWindows = 0
    /// Last evaluation wall-clock (uptimeNanoseconds).
    private var lastThroughputEval: UInt64 = 0
    /// Mode the user requested before a fallback disabled interpolation;
    /// non-nil only while fallbackDisabled is true. Used for re-attempt
    /// after seek/load (reintento automático).
    private var fallbackFailedMode: InterpolationMode?

    /// Paridad del par actual para el patrón 3:2 de 60fps (pares → 1 interp,
    /// impares → 2 interps). Se resetea en seek/load para empezar el patrón limpio.
    private var interpPairIndex = 0
    /// Conteo diagnóstico: pares con 1 frame interpolado (patrón 3:2/48fps).
    private var interpSinglePairCount = 0
    /// Conteo diagnóstico: pares con 2 frames interpolados (patrón 3:2, 60fps).
    private var interpDoublePairCount = 0
    /// Conteo acumulado de pares descartados como stale en la rama interpolada
    /// (equivalente de Fijación C). Alimenta el gate de latencia de
    /// `notePairCompleted` (bajo pacing, es el canario de que el pipeline no
    /// mantiene tiempo real).
    private var interpolationStaleDrops = 0
    private var lastStaleDropSnapshot = 0
    var displayLayer: AVSampleBufferDisplayLayer? { renderer?.displayLayer }
    var player: AVPlayer? { nil }
    private var videoTrack: TrackInfo?
    private var audioTrack: TrackInfo?
    private var audioTrackInfos: [Int: TrackInfo] = [:]
    private var audioDecoder: AudioDecoder?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var sourceFrameRate: Double?
    /// Periodo del vídeo fuente en segundos (1/fps), usado para detectar pares
    /// con hueco (decode rezagado ≥2 frames) en la rama interpolada.
    private var sourcePeriod: Double { 1.0 / max(sourceFrameRate ?? 24.0, 24.0) }
    /// Margen acotado para reordenar B-frames antes de entregar pares al MCFI.
    /// Ocho imágenes cubren GOPs con B-frames profundos sin convertir el pool
    /// en una cola de reproducción sin límite.
    private static let framePoolCapacity = 8
    private let coordinator = DecodeCoordinator(value: RiftPlayerState.framePoolCapacity)
    /// Fijación B: presupuesto de decode por delante del reloj de presentación
    /// (segundos). El decode no produce frames cuyo pts supere `reloj + budget`;
    /// sin esto el pool (ventana acotada con eviction) corre por delante de la
    /// presentación sin límite y los toggles de modo provocan ráfagas/saltos.
    /// El default es ~0.25s (unos pocos frames): lead suficiente para no
    /// starvation del pool pero sin saturar la cola del AVSampleBufferDisplayLayer
    /// (un lead de 1s acumulaba ~50 frames futuros → la capa descartaba frames
    /// interpolados en silencio → tirones). Tunable vía RIFT_DECODE_AHEAD_BUDGET.
    private let decodeAheadBudget: Double
    /// Pacing de la rama interpolada: no interpolar/encolar un par cuyo
    /// `first.pts` esté a más de `interpLeadMargin` (pocos frames) del reloj de
    /// presentación. Equivale al waitUntilDisplayClock de la rama nativa.
    /// Tunable vía RIFT_INTERP_LEAD.
    private let interpLeadMargin: Double
    /// Margen "stale" de la rama interpolada (equivalente de Fijación C): un par
    /// cuyo primer sample visible queda detrás del reloj se descarta en vez de
    /// interpolarlo tarde.
    /// Tolerancia para picos aislados de GPU/Metal. Un sample con unos pocos
    /// milisegundos de retraso se presenta de inmediato; descartarlo abriría un
    /// hueco perceptible de 58ms en la cadencia de 60 Hz.
    private let interpBehindMargin = 0.050
    /// EXPERIMENTO de cadencia 60fps: la 3:2 clásica usa duraciones desiguales
    /// (20.8ms/13.9ms → judder de telecine). La cadencia uniforme (default)
    /// saca cada frame a 16.67ms exactos con t=0.4/0.8 y 0.2/0.6 (fase que
    /// deriv hacia el par siguiente, como un FRC real). Revertir a 3:2 para
    /// A/B visual: RIFT_CADENCE=telecine.
    private let uniformCadence: Bool
    private var interpBurstDropped = 0
    // MARK: - Delivery diagnostics (soap-opera root-cause investigation)
    /// Frames enqueued when isReadyForMoreMediaData was true.
    private var framesEnqueuedReady: Int = 0
    /// Frames enqueued when isReadyForMoreMediaData was false (silently discarded by layer).
    private var framesEnqueuedNotReady: Int = 0
    /// Frames dropped because enqueuePaced timed out (>50ms waiting for ready).
    private var framesDroppedTimeout: Int = 0
    /// Wall-clock of last diagnostic log emission.
    private var lastDiagLogTime: CFAbsoluteTime = 0
    /// Sampling counters for isReady state.
    private var readyStateSamples: Int = 0
    private var notReadySamples: Int = 0
    /// Count of enqueuePaced invocations requested this window (before success/drop).
    private var framesRequestedForEnqueue: Int = 0
    // MARK: - Stage timing diagnostics (reserve/pace/interp/enqueueLoop breakdown)
    private var stagePairs: Int = 0
    private var stageReserveMS: Double = 0
    private var stagePaceMS: Double = 0
    private var stageInterpMS: Double = 0
    private var stageEnqueueLoopMS: Double = 0
    private var lastStageLogTime: CFAbsoluteTime = 0
    /// Feature flag: force DisplayImmediately on interpolated frames (A/B test).
    /// Activate with RIFT_FORCE_DISPLAY_IMMEDIATE=1 env var.
    private static let forceDisplayImmediateOnInterpolated =
        ProcessInfo.processInfo.environment["RIFT_FORCE_DISPLAY_IMMEDIATE"] == "1"
    private var totalDecoded = 0
    private var decodeTask: Task<Void, Never>?
    /// Seek coalescente: los drags del timeline disparan decenas de seeks por
    /// segundo; solo importa el último. `seek(to:)` (sync, UI-friendly) anota
    /// el target y una única tarea drenadora los ejecuta en orden.
    private var pendingSeekTarget: Double?
    private var seekTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var consumerTimer: Timer?
    private var currentTimeTimer: Timer?
    private var fpsTimer: Timer?
    private var enqueuedFramesInWindow: Int = 0
    private var fpsWindowStart: DispatchTime = .now()
    private var sourceURL: URL?
    private let timelineThumbnailExtractor = VideoThumbnailExtractor()
    private var timelineThumbnailTask: Task<Void, Never>?
    private var timelineThumbnailRequestID = 0
    private var timelineThumbnailSecond: Int?
    private var subtitleTrack: TrackInfo?
    private var subtitleCues: [SubtitleCue] = []
    private var subtitleCueCache: [Int: [SubtitleCue]] = [:]

    // MARK: - Interpolation benchmark (baseline del display loop)
    private var benchSamples: [Double] = []
    private var meSamples: [Double] = []
    private var warpSamples: [Double] = []
    private let benchLog = OSLog(subsystem: "com.rift.player", category: "InterpolationBench")

    /// Avg/p99 de una ventana de muestras. Helper compartido entre los dos modos.
    private nonisolated static func summary(samples: [Double]) -> (avg: Double, p99: Double) {
        guard !samples.isEmpty else { return (0, 0) }
        let avg = samples.reduce(0, +) / Double(samples.count)
        let sorted = samples.sorted()
        let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
        return (avg, p99)
    }

    /// Reset warm-up counter + timing window. Called on mode change, seek, or
    /// file open — gives Frame+ a fresh chance to measure sustained cost.
    private func resetInterpolationCounters() {
        interpolationPairCount = 0
        recentPairTimings = []
        recentHighQualityPairTimings = []
        fallbackDisabled = false
        interpPairIndex = 0
        interpSinglePairCount = 0
        interpDoublePairCount = 0
        interpBurstDropped = 0
        // Throughput gate: clean slate for the new evaluation window.
        pairCompletionTimes = []
        weakThroughputWindows = 0
        lastThroughputEval = 0
        firstPairCompletedAt = 0
        interpolationStaleDrops = 0
        lastStaleDropSnapshot = 0
        // Estados de UI: transición real (seek/load/modo) → fuera de "60fps ready"
        // y de artificial activo; volvemos a "Preparing HQ" si hay modo activo, y
        // el warm-up pasará a "60fps ready" al completarse el 6º par.
        isFramePlusPreRendered = false
        isArtificialInterpolationActive = false
        isFramePlusPreparing = interpolationMode != .disabled

    }

    // MARK: - Fallback shared helpers

    /// Desactiva la interpolación por una razón dada (coste o throughput),
    /// guardando el modo solicitado para reintento tras seek/load.
    private func disableInterpolation(reason: String) {
        let was = interpolationMode
        interpolationMode = .disabled
        scheduler?.setMode(.native24)
        // Al degradar a nativo hay que salir de "60fps ready": framePlusStateTitle
        // evalúa isFramePlusPreRendered ANTES que interpolationMode == .disabled,
        // así que sin esta limpieza el texto quedaría pegado pese a estar desactivado.
        isArtificialInterpolationActive = false
        isFramePlusPreRendered = false
        isFramePlusPreparing = false
        fallbackDisabled = true
        if was != .disabled {
            fallbackFailedMode = was
            os_log("Interpolation fallback: %{public}@ (modo %{public}@ guardado para reintento tras seek/load)",
                   log: benchLog, type: .default, reason, was.rawValue)
        } else {
            os_log("Interpolation fallback: %{public}@", log: benchLog, type: .default, reason)
        }
    }

    /// Frame+ siempre intenta primero la cadencia uniforme de 60 fps. Si el
    /// coste o la latencia sostenida no la sostienen, conservar la interpolación
    /// a 48 fps es preferible a volver de golpe al vídeo nativo.
    private func downgradeTo48OrDisable(reason: String) {
        guard interpolationMode == .motion4x else {
            disableInterpolation(reason: reason)
            return
        }
        os_log("Frame+ baja de 60 a 48 fps: %{public}@", log: benchLog, type: .info, reason)
        setInterpolationMode(.motion2x)
    }

    /// Tras un fallback, si el usuario vuelve a dar seek o cambia de archivo
    /// se reintenta automáticamente el modo que estaba activo antes del fallback.
    private func rearmFallbackInterpolation() {
        guard fallbackDisabled, let m = fallbackFailedMode, m != .disabled else { return }
        os_log("Reintento Frame+ tras degradación: modo %{public}@", log: benchLog, type: .default, m.rawValue)
        setInterpolationMode(m)
    }

    // MARK: - Throughput measurement (pairs/s)

    private func resetThroughputWindow() {
        pairCompletionTimes = []
        weakThroughputWindows = 0
        lastThroughputEval = 0
        firstPairCompletedAt = 0
    }

    /// Llamar tras consumir (interpolar+encolar) un par con éxito.
    /// Gate de latencia bajo pacing de reloj: si la rama interpolada NO puede
    /// mantener tiempo real (decode o ME no siguen la cadencia fuente), el pool
    /// queda por detrás del reloj y se manifiesta en dos señales sostenidas —
    /// pares descartados como stale (equivalente de Fijación C) y lead del pool
    /// negativo. Antes medíamos pares/s por wall-clock; bajo pacing eso ya no
    /// discrimina (la producción queda literalmente anclada a la cadencia
    /// fuente ≈ 24/s, con cero holgura: cualquier bache de decode hunde la
    /// ventana y el gate disparaba fallbacks espurios).
    private func notePairCompleted() {
        let now = DispatchTime.now().uptimeNanoseconds
        if firstPairCompletedAt == 0 { firstPairCompletedAt = now }

        // Evaluar solo después del warm-up, con cadencia de ventana.
        guard interpolationPairCount > interpolationWarmupPairs,
              now - lastThroughputEval >= UInt64(throughputWindowSeconds * 1e9) else { return }
        lastThroughputEval = now

        // No armar el gate durante la rampa de arranque del pipeline (decoder/
        // shaders/fill): ahí la latencia inicial es ruido, no un déficit real.
        let elapsedSinceFirst = Double(now - firstPairCompletedAt) / 1e9
        guard elapsedSinceFirst >= throughputSkipStartupSeconds else { return }

        let clk = scheduler?.synchronizer.currentTime().seconds ?? 0
        let lead = (framePool?.oldest().map { $0.pts - clk }) ?? 0
        let staleDelta = interpolationStaleDrops - lastStaleDropSnapshot
        lastStaleDropSnapshot = interpolationStaleDrops
        let minLead = -1.5 * sourcePeriod
        let weak = (staleDelta >= 6) || (lead < minLead)

        os_log("Throughput(latencia): staleΔ=%d lead=%.3fs (mín %.3f) → %@",
               log: benchLog, type: .info, staleDelta, lead, minLead, weak ? "weak" : "ok")

        if weak {
            weakThroughputWindows += 1
        } else {
            weakThroughputWindows = 0
        }
        if weakThroughputWindows >= throughputRequiredWeakWindows {
            weakThroughputWindows = 0
            downgradeTo48OrDisable(reason: String(format: "bajo pacing: %d pares stale / lead %.3fs (estancado)",
                                                   staleDelta, lead))
        }
    }

    // MARK: - Test harness (headless GUI-channel validation)
    // RIFT_AUTO_OPEN=<file> opens a video at launch; RIFT_AUTO_MODE=<mode>
    // force-activates an interpolation mode. Inert without the env vars.
    // RIFT_AUTO_SEEK_AT=<secs> + RIFT_AUTO_SEEK_TO=<secs> schedule a seek()
    // that many seconds after launch (used to validate rearmFallbackInterpolation
    // after a fallback). RIFT_AUTO_REOPEN=<file> + RIFT_AUTO_REOPEN_AT=<secs>
    // schedule a loadVideo() to validate the same rearm on file change.
    // RIFT_AUTO_MODE_AT=<secs> activates an interpolation mode mid-playback
    // (same path as the menu toggle: setInterpolationMode) to reproduce the
    // "toggle mode then seek" flow without GUI interaction. RIFT_AUTO_MODE still
    // applies at display-loop start; use MODE_AT to delay it.
    // Permite verificar el pipeline de reproducción/interpolación sin interacción
    // GUI (NSOpenPanel no funciona en corridas headless — ver AGENTS.md).
    init() {
        decodeAheadBudget = ProcessInfo.processInfo.environment["RIFT_DECODE_AHEAD_BUDGET"].flatMap(Double.init) ?? 0.25
        interpLeadMargin = ProcessInfo.processInfo.environment["RIFT_INTERP_LEAD"].flatMap(Double.init) ?? 0.12
        uniformCadence = ProcessInfo.processInfo.environment["RIFT_CADENCE"] != "telecine"
        restorePlaybackPreferences()
        restoreRecentVideos()
        restorePlaylist()
        restoreMarkers()
        restoreExternalSubtitleAssociations()

        let env = ProcessInfo.processInfo.environment
        guard let path = env["RIFT_AUTO_OPEN"], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        let seekAt = env["RIFT_AUTO_SEEK_AT"].flatMap(Double.init)
        let seekTo = env["RIFT_AUTO_SEEK_TO"].flatMap(Double.init)
        let reopenAt = env["RIFT_AUTO_REOPEN_AT"].flatMap(Double.init)
        let reopenURL = env["RIFT_AUTO_REOPEN"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let modeAt = env["RIFT_AUTO_MODE_AT"].flatMap(Double.init)
        let delayedMode = env["RIFT_AUTO_MODE"].flatMap(InterpolationMode.init(rawValue:))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            print("RIFT_AUTO_OPEN → loadVideo \(url.lastPathComponent)")
            self.loadVideo(url)
            if let modeAt, let delayedMode {
                try? await Task.sleep(nanoseconds: UInt64(modeAt * 1e9))
                guard !Task.isCancelled else { return }
                os_log("RIFT_AUTO_MODE_AT=%.0f → setInterpolationMode(%{public}@)",
                       log: benchLog, type: .info, modeAt, delayedMode.rawValue)
                self.setInterpolationMode(delayedMode)
            }
            if let seekAt, let seekTo {
                try? await Task.sleep(nanoseconds: UInt64(seekAt * 1e9))
                guard !Task.isCancelled else { return }
                os_log("RIFT_AUTO_SEEK_AT → seek(to: %.0f)", log: benchLog, type: .info, seekTo)
                self.seek(to: seekTo)
            }
            if let reopenAt, let reopenURL {
                try? await Task.sleep(nanoseconds: UInt64(reopenAt * 1e9))
                guard !Task.isCancelled else { return }
                os_log("RIFT_AUTO_REOPEN_AT → loadVideo %{public}@", log: benchLog, type: .info, reopenURL.lastPathComponent)
                self.loadVideo(reopenURL)
            }
        }
    }

    func restoreLastSessionIfAvailable() {
        guard !hasVideo,
              ProcessInfo.processInfo.environment["RIFT_AUTO_OPEN"]?.isEmpty != false,
              let record = decode(RecentVideo.self, forKey: Self.resumeSessionKey),
              FileManager.default.fileExists(atPath: record.path) else {
            return
        }

        loadVideo(record.url, restoringAt: record.resumePosition)
    }

    private func restorePlaybackPreferences() {
        guard let preferences = decode(PlaybackPreferences.self, forKey: Self.preferencesKey) else { return }
        volume = min(max(preferences.volume, 0), 1)
        interpolationMode = InterpolationMode(rawValue: preferences.interpolationMode) ?? .disabled
        audioSyncOffset = min(max(preferences.audioSyncOffset ?? 0, -2), 2)
    }

    private func restoreRecentVideos() {
        recentVideos = decode([RecentVideo].self, forKey: Self.recentVideosKey) ?? []
    }

    private func restorePlaylist() {
        playlist = decode([PlaylistItem].self, forKey: Self.playlistKey) ?? []
    }

    private func restoreMarkers() {
        markersByPath = decode([String: [PlaybackMarker]].self, forKey: Self.markersKey) ?? [:]
    }

    private func restoreExternalSubtitleAssociations() {
        externalSubtitlePathByVideoPath = decode([String: String].self, forKey: Self.externalSubtitlesKey) ?? [:]
    }

    private func persistPlaybackPreferences() {
        encode(
            PlaybackPreferences(
                volume: volume,
                interpolationMode: interpolationMode.rawValue,
                audioSyncOffset: audioSyncOffset
            ),
            forKey: Self.preferencesKey
        )
    }

    private func persistCurrentSession(force: Bool = false) {
        guard let sourceURL, duration > 0, currentTime.isFinite else { return }
        guard force || abs(currentTime - lastPersistedPlaybackPosition) >= 5 else { return }

        let record = RecentVideo(
            path: sourceURL.path,
            lastOpened: Date(),
            playbackPosition: min(max(currentTime, 0), duration),
            duration: duration
        )
        lastPersistedPlaybackPosition = record.playbackPosition
        updateRecentVideos(with: record)
        encode(record, forKey: Self.resumeSessionKey)
    }

    private func updateRecentVideos(with record: RecentVideo) {
        recentVideos.removeAll { $0.path == record.path }
        recentVideos.insert(record, at: 0)
        recentVideos = Array(recentVideos.prefix(Self.recentVideoLimit))
        encode(recentVideos, forKey: Self.recentVideosKey)
    }

    func clearRecentVideos() {
        recentVideos = []
        UserDefaults.standard.removeObject(forKey: Self.recentVideosKey)
    }

    func replacePlaylist(with urls: [URL]) {
        let items = deduplicatedPlaylistItems(from: urls)
        playlist = items
        activePlaylistItemID = items.first?.id
        encode(items, forKey: Self.playlistKey)
        if let first = items.first {
            loadVideo(first.url)
        }
    }

    func appendToPlaylist(_ urls: [URL]) {
        let additions = deduplicatedPlaylistItems(from: urls)
        guard !additions.isEmpty else { return }
        var paths = Set(playlist.map(\.path))
        playlist.append(contentsOf: additions.filter { paths.insert($0.path).inserted })
        encode(playlist, forKey: Self.playlistKey)
        if !hasVideo, let first = playlist.first {
            activePlaylistItemID = first.id
            loadVideo(first.url)
        }
    }

    func removeFromPlaylist(_ item: PlaylistItem) {
        guard let index = playlist.firstIndex(of: item) else { return }
        playlist.remove(at: index)
        encode(playlist, forKey: Self.playlistKey)
        if activePlaylistItemID == item.id {
            activePlaylistItemID = playlist.indices.contains(index) ? playlist[index].id : playlist.last?.id
        }
    }

    func playPlaylistItem(_ item: PlaylistItem) {
        guard playlist.contains(item) else { return }
        activePlaylistItemID = item.id
        loadVideo(item.url)
    }

    func playNextPlaylistItem() {
        guard let activePlaylistItemID,
              let index = playlist.firstIndex(where: { $0.id == activePlaylistItemID }),
              playlist.indices.contains(index + 1) else { return }
        playPlaylistItem(playlist[index + 1])
    }

    func playPreviousPlaylistItem() {
        guard let activePlaylistItemID,
              let index = playlist.firstIndex(where: { $0.id == activePlaylistItemID }),
              playlist.indices.contains(index - 1) else { return }
        playPlaylistItem(playlist[index - 1])
    }

    func addMarker() {
        guard let sourceURL, duration > 0 else { return }
        let marker = PlaybackMarker(
            id: UUID(),
            time: min(max(currentTime, 0), duration),
            title: String(format: NSLocalizedString("Marker %@", comment: ""), formattedTime(currentTime))
        )
        markers.append(marker)
        markers.sort { $0.time < $1.time }
        markersByPath[sourceURL.path] = markers
        encode(markersByPath, forKey: Self.markersKey)
    }

    func removeMarker(_ marker: PlaybackMarker) {
        guard let sourceURL else { return }
        markers.removeAll { $0.id == marker.id }
        markersByPath[sourceURL.path] = markers
        encode(markersByPath, forKey: Self.markersKey)
    }

    private func deduplicatedPlaylistItems(from urls: [URL]) -> [PlaylistItem] {
        var paths = Set<String>()
        return urls.compactMap { url in
            guard url.isFileURL, FileManager.default.fileExists(atPath: url.path), paths.insert(url.path).inserted else {
                return nil
            }
            return PlaylistItem(path: url.path)
        }
    }

    private func clearResumeSession() {
        UserDefaults.standard.removeObject(forKey: Self.resumeSessionKey)
    }

    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func colorDescription(for transfer: Int?) -> String {
        switch transfer {
        case 16: "HDR10 (PQ)"
        case 18: "HDR (HLG)"
        case .some: "SDR / tagged"
        case nil: "SDR"
        }
    }

    private static func audioDescription(for track: TrackInfo?) -> String {
        guard let track else { return "No audio track" }
        let channels = track.channelCount.map { "\($0) ch" } ?? "unknown channels"
        let sampleRate = track.sampleRate.map { "\($0 / 1_000) kHz" } ?? nil
        return [track.codecName.uppercased(), channels, sampleRate].compactMap { $0 }.joined(separator: " · ")
    }

    // Mapa de códigos de idioma comunes → nombre legible. Cubre los más
    // frecuentes; si no está, se usa streamTitle o índice como fallback.
    private static let languageNames: [String: String] = [
        "spa": "Español", "eng": "Inglés", "fre": "Francés", "fra": "Francés",
        "deu": "Alemán", "ger": "Alemán", "ita": "Italiano", "por": "Portugués",
        "jpn": "Japonés", "kor": "Coreano", "chi": "Chino", "zho": "Chino",
        "rus": "Ruso", "ara": "Árabe", "hin": "Hindi",
    ]

    /// Nombre legible de un código de idioma (compartido entre audio y subtítulos).
    private static nonisolated func languageName(for code: String?) -> String? {
        guard let code = code?.lowercased() else { return nil }
        return languageNames[code]
    }

    /// Etiqueta legible para una pista de subtítulos (se compone en UI, no en Demux).
    private static nonisolated func subtitleLabel(for track: TrackInfo, index: Int) -> String {
        if let name = languageName(for: track.streamLanguage) {
            return name
        }
        if let title = track.streamTitle, !title.isEmpty {
            return title
        }
        return "Subtítulo \(index + 1)"
    }

    /// Etiqueta legible para una pista de audio (comparte languageName con subtítulos).
    private static nonisolated func audioLabel(for track: TrackInfo) -> String {
        if let name = languageName(for: track.streamLanguage) {
            return name
        }
        if let title = track.streamTitle, !title.isEmpty {
            return title
        }
        return track.codecName
    }

    func togglePlay() {
        isPlaying.toggle()
        let wasPaused = !isPlaying
        if wasPaused {
            // Pausa: la próxima reanudación parte de un estado limpio — sin
            // historia temporal de MVs del segmento anterior.
            compensator?.resetTemporalState()
        }
        if let sched = scheduler {
            let t = CMTime(seconds: currentTime, preferredTimescale: 600)
            sched.synchronizer.setRate(isPlaying ? 1.0 : 0, time: t)
        }
        // Start display loop on first play
        if isPlaying { startDisplayLoop() }
        updateTimePolling()
    }
    private func updateTimePolling() {
        if isPlaying {
            currentTimeTimer?.invalidate()
            currentTimeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, let sched = self.scheduler else { return }
                    self.currentTime = sched.synchronizer.currentTime().seconds
                    self.updateActiveSubtitle(at: self.currentTime)
                    self.persistCurrentSession()
                }
            }
            fpsTimer?.invalidate()
            fpsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    self?.updateRenderingFPS()
                }
            }
        } else {
            currentTimeTimer?.invalidate(); currentTimeTimer = nil
            fpsTimer?.invalidate(); fpsTimer = nil
            enqueuedFramesInWindow = 0
            fpsWindowStart = .now()
            persistCurrentSession(force: true)
        }
    }

    /// Contador de FPS de presentación (readout estable).
    /// Antes displayRenderingFPS era una constante fija en 24 que jamás reflejaba
    /// el modo real. Ahora el valor nominal depende del modo del scheduler
    /// (24 nativo / 48 / 60 interpolado) y solo se reemplaza por el throughput
    /// medido si la ventana de 1s no sostiene al menos la mitad del nominal
    /// (pipeline trabado/degradado): así el readout es estable mientras reproduce
    /// normal y revela el fallo si ya no alcanza. Con rate==0 (pausa) no se
    /// computa ni se pisa el valor mostrado.
    private func updateRenderingFPS() {
        guard scheduler?.synchronizer.rate != 0 else { return }
        let nominal: Double
        switch scheduler?.mode {
        case .interpolated48: nominal = 48.0
        case .interpolated60: nominal = 60.0
        default: nominal = sourceFrameRate ?? 24.0
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - fpsWindowStart.uptimeNanoseconds
        guard elapsed >= UInt64(1.0 * 1e9) else { return }
        let measured = Double(enqueuedFramesInWindow) / 1.0
        let shown = measured >= nominal * 0.5 ? nominal : measured
        if abs(shown - displayRenderingFPS) >= 0.5 || shown == 0 {
            displayRenderingFPS = shown
        }
        enqueuedFramesInWindow = 0
        fpsWindowStart = .now()
    }
    private func updateActiveSubtitle(at time: Double) {
        let active = subtitleCues.first { cue in
            cue.start <= time && time < cue.end
        }
        let newText = active?.text
        if newText != currentSubtitleText {
            currentSubtitleText = newText
        }
    }
    func seek(to time: Double) {
        pendingSeekTarget = time
        pumpSeekQueue()
    }
    /// Drena seeks pendientes en orden; si llega otro seek mientras el actual
    /// corre, el drainer lo retoma al terminar (sin llamadas superpuestas y
    /// sin perder el último). Todo corre en MainActor: serial por construcción.
    private func pumpSeekQueue() {
        guard seekTask == nil, pendingSeekTarget != nil else { return }
        seekTask = Task { @MainActor [weak self] in
            while let target = self?.takePendingSeek() {
                await self?.performSeek(to: target)
            }
            self?.seekTask = nil
            // Re-chequeo: un seek que llegó en la ventana de teardown del
            // drainer no debe perderse (seekTask ya es nil → re-bombea).
            self?.pumpSeekQueue()
        }
    }
    private func takePendingSeek() -> Double? {
        let t = pendingSeekTarget
        pendingSeekTarget = nil
        return t
    }
    private func performSeek(to time: Double) async {
        audioTask?.cancel()
        currentTime = min(max(time, 0), duration)
        persistCurrentSession(force: true)
        // Actualizar el subtítulo de inmediato (los cues ya están todos en
        // memoria desde el inicio, no hace falta releer ni reiniciar ningún loop).
        updateActiveSubtitle(at: time)
        // Single-flight con el decode loop: cancelar + despertar parked +
        // ESPERAR el teardown antes de tocar el demuxer. Sin esto,
        // av_seek_frame corría concurrente con av_read_frame (UB en FFmpeg)
        // y mataba el decode en silencio → video congelado + audio ok.
        // El await es seguro: performSeek es async (MainActor queda libre) y
        // el loop viejo solo necesita MainActor para un add residual.
        decodeTask?.cancel()
        await coordinator.reset()
        await decodeTask?.value
        decodeTask = nil
        // Seek serializado vía actor (cinturón + tirantes tras el teardown).
        if demuxer != nil {
            do {
                try await coordinator.withDemuxAccess { try demuxer?.seek(to: time) }
            } catch {
                os_log("seek: demuxer.seek falló: %{public}@", log: benchLog, type: .error, String(describing: error))
            }
        }
        decoder?.flush(); framePool?.flush()
        // Vaciar también las colas de video y audio (frames/buffers encolados
        // del segmento anterior) para que no se "pegue" contenido viejo.
        if let rend = renderer { rend.displayLayer.flush() }
        audioRenderer?.flush()
        if let sched = scheduler {
            sched.synchronizer.setRate(isPlaying ? 1.0 : 0, time: CMTime(seconds: time, preferredTimescale: 600), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        lastShownFrames.removeAll()
        isArtificialInterpolationActive = false
        isFramePlusPreparing = false
        // EMA temporal: el seek crea una discontinuidad; el primer par tras el
        // reset se emite sin blending (ver MotionCompensator.resetTemporalState).
        compensator?.resetTemporalState()
        // Reintento: si Frame+ había caído por fallback y el usuario hace seek,
        // volver a armarlo (el seek libera el pipeline; si sigue lento, caerá de nuevo).
        rearmFallbackInterpolation()
        resetInterpolationCounters()
        if let url = sourceURL, let aTrack = audioTrack {
            startAudioLoop(url: url, trackStreamIndex: aTrack.streamIndex, codecName: aTrack.codecName, startTime: time, extradata: aTrack.codecExtradata, sampleRate: aTrack.sampleRate ?? 0, channels: aTrack.channelCount ?? 0)
        }
        // Reiniciar el decode loop (nuevo task; el viejo terminó arriba).
        // reset() ya restauró el cupo a capacidad — el +4 manual anterior
        // inflaba el conteo sin cota con seeks repetidos y se elimina.
        // Sin poke al display loop: ya corre (solo se re-pokea en loadVideo).
        startDecodeLoop(callDisplayLoopOnFirstFrame: false)
    }
    func seek(by delta: Double) { seek(to: currentTime + delta) }
    func setVolume(_ v: Double) {
        volume = min(max(v, 0), 1)
        audioRenderer?.volume = Float(volume)
        persistPlaybackPreferences()
    }

    func setAudioSyncOffset(_ offset: Double) {
        audioSyncOffset = min(max(offset, -2), 2)
        persistPlaybackPreferences()
        guard let url = sourceURL, let track = audioTrack else { return }
        audioRenderer?.flush()
        startAudioLoop(
            url: url,
            trackStreamIndex: track.streamIndex,
            codecName: track.codecName,
            startTime: currentTime,
            extradata: track.codecExtradata,
            sampleRate: track.sampleRate ?? 0,
            channels: track.channelCount ?? 0
        )
    }
    func cyclePlaybackRate() {}
    func closeVideo() {
        persistCurrentSession(force: true)
        clearResumeSession()
        clearTimelineThumbnail()
        decodeTask?.cancel(); decodeTask = nil
        audioTask?.cancel(); audioTask = nil
        displayTask?.cancel(); displayTask = nil
        seekTask?.cancel(); seekTask = nil; pendingSeekTarget = nil
        consumerTimer?.invalidate(); consumerTimer = nil
        currentTimeTimer?.invalidate(); currentTimeTimer = nil
        fpsTimer?.invalidate(); fpsTimer = nil
        if let sched = scheduler {
            sched.synchronizer.setRate(0, time: .zero)
        }
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        }
        restorePictureInPictureSourceLayer()
        renderer?.flush()
        audioRenderer?.flush()
        demuxer?.close(); decoder?.close()
        demuxer = nil; decoder = nil; framePool = nil; scheduler = nil; renderer = nil
        compensator = nil
        lastShownFrames.removeAll()
        isInterpolating = false
        isFramePlusPreparing = false
        isArtificialInterpolationActive = false
        audioDecoder = nil; audioRenderer = nil; audioTrack = nil
        audioTrackInfos = [:]
        sourceURL = nil
        currentTime = 0; duration = 0
        markers = []
        chapters = []
        technicalInfo = nil
        externalSubtitleURL = nil
        externalSubtitleName = nil
        pictureInPictureController = nil
        pictureInPictureCoordinator = nil
        isPictureInPictureAvailable = false
        isPictureInPictureActive = false
        hasVideo = false; isPlaying = false
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
    }
    func startHideTimer() {
        isPointerOverControls = false
        scheduleControlsHide()
    }
    func stopHideTimer() {
        isPointerOverControls = true
        controlsHideTimer?.invalidate()
        controlsHideTimer = nil
    }
    func resetHideTimer() {
        areControlsVisible = true
        guard !isPointerOverControls else { return }
        scheduleControlsHide()
    }

    private func scheduleControlsHide() {
        controlsHideTimer?.invalidate()
        guard hasVideo else { return }
        controlsHideTimer = Timer.scheduledTimer(withTimeInterval: controlsHideDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPointerOverControls else { return }
                self.areControlsVisible = false
            }
        }
    }
    func formattedTime(_ s: Double) -> String { let i = Int(s); return String(format: "%d:%02d", i/60, i%60) }
    func setInterpolationMode(_ m: InterpolationMode) {
        interpolationMode = m
        persistPlaybackPreferences()
        usesHighQualityFluidProfile = true
        compensator = nil
        lastShownFrames.removeAll()
        // Estados de UI por transiciones reales (no por-par): al activar un modo
        // entramos en la fase de warm-up ("Preparing HQ"); al completarse el 6º
        // par, interpolatePair pasa a isFramePlusPreRendered ("60fps ready").
        isArtificialInterpolationActive = false
        isFramePlusPreRendered = false
        isFramePlusPreparing = m != .disabled
        fallbackFailedMode = nil          // fresh user choice clears any pending re-arm
        resetInterpolationCounters()
        syncSchedulerMode()
    }

    /// Aplica el modo del scheduler según el `interpolationMode` actual. Se llama
    /// desde `setInterpolationMode` y también cuando el scheduler se (re)crea en
    /// `loadVideo`, para no perder el modo si se activa antes de que exista.
    private func syncSchedulerMode() {
        switch interpolationMode {
        case .disabled:
            scheduler?.setMode(.native24)
        case .motion2x:
            scheduler?.setMode(.interpolated48)
        case .motion4x, .motionAdaptive, .motion2Intense:
            scheduler?.setMode(.interpolated60)
        }
    }

    /// El interruptor Frame+ usa estos dos niveles internamente: 60 fps primero
    /// y 48 fps cuando la máquina no puede sostener 60. Ambos conservan la
    /// máxima calidad disponible antes de reducir el plano de trabajo.
    private var interpolationConfig: InterpolationConfig {
        switch interpolationMode {
        case .motion2x, .motion4x, .motion2Intense:
            return usesHighQualityFluidProfile ? .fluidHighQuality : .fluid
        case .disabled, .motionAdaptive:
            return .default
        }
    }
    func selectAudioTrack(_ streamIndex: Int) {
        guard streamIndex != selectedAudioTrackIndex else { return }
        selectedAudioTrackIndex = streamIndex
        guard let url = sourceURL, let track = audioTrackInfos[streamIndex] else { return }
        audioTrack = track
        // Reiniciar el audio con la pista elegida (mismo patrón que seek): el
        // audioRenderer ya está en el synchronizer, solo se relanza el loop.
        startAudioLoop(url: url, trackStreamIndex: track.streamIndex, codecName: track.codecName, startTime: currentTime, extradata: track.codecExtradata, sampleRate: track.sampleRate ?? 0, channels: track.channelCount ?? 0)
    }
    func selectPipelineTrack(_ t: MediaTrack?) {
        selectedSubtitleTrack = t
        externalSubtitleURL = nil
        externalSubtitleName = nil
        if let sourceURL {
            externalSubtitlePathByVideoPath.removeValue(forKey: sourceURL.path)
            encode(externalSubtitlePathByVideoPath, forKey: Self.externalSubtitlesKey)
        }
        guard let t, let url = sourceURL else {
            // "None": desactivar subtítulos.
            subtitleCues = []
            currentSubtitleText = nil
            return
        }
        let streamIndex = t.index
        // Reflejar el cambio de inmediato con lo ya cacheado (o vacío mientras
        // se lee en background), y recargar si aún no está en cache.
        subtitleCues = subtitleCueCache[streamIndex] ?? []
        updateActiveSubtitle(at: currentTime)
        ensureSubtitleCues(url: url, streamIndex: streamIndex) {
            self.subtitleCues = self.subtitleCueCache[streamIndex] ?? []
            self.updateActiveSubtitle(at: self.currentTime)
        }
    }

    func openExternalSubtitles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt") ?? .plainText,
            UTType(filenameExtension: "vtt") ?? .plainText
        ]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadExternalSubtitles(from: url, persistAssociation: true)
    }

    func removeExternalSubtitles() {
        externalSubtitleURL = nil
        externalSubtitleName = nil
        if let sourceURL {
            externalSubtitlePathByVideoPath.removeValue(forKey: sourceURL.path)
            encode(externalSubtitlePathByVideoPath, forKey: Self.externalSubtitlesKey)
        }
        if let selectedSubtitleTrack {
            selectPipelineTrack(selectedSubtitleTrack)
        } else if let fallbackTrack = availableTracks.first(where: { $0.kind == .subtitle }) {
            selectPipelineTrack(fallbackTrack)
        } else {
            subtitleCues = []
            currentSubtitleText = nil
        }
    }

    private func restoreExternalSubtitles(for videoURL: URL) {
        guard let path = externalSubtitlePathByVideoPath[videoURL.path] else { return }
        let subtitleURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: subtitleURL.path) else {
            externalSubtitlePathByVideoPath.removeValue(forKey: videoURL.path)
            encode(externalSubtitlePathByVideoPath, forKey: Self.externalSubtitlesKey)
            return
        }
        loadExternalSubtitles(from: subtitleURL, persistAssociation: false)
    }

    private func loadExternalSubtitles(from url: URL, persistAssociation: Bool) {
        let cues = Self.readExternalSubtitleCues(url: url)
        guard !cues.isEmpty else {
            statusMessage = "No readable subtitles in \(url.lastPathComponent)"
            return
        }
        subtitleCues = cues
        externalSubtitleURL = url
        externalSubtitleName = url.lastPathComponent
        selectedSubtitleTrack = nil
        updateActiveSubtitle(at: currentTime)
        if persistAssociation, let sourceURL {
            externalSubtitlePathByVideoPath[sourceURL.path] = url.path
            encode(externalSubtitlePathByVideoPath, forKey: Self.externalSubtitlesKey)
        }
    }

    func togglePictureInPicture() {
        guard let controller = pictureInPictureController, controller.isPictureInPicturePossible else {
            statusMessage = "Picture in Picture is not available for this video"
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    private func configurePictureInPicture() {
        guard #available(macOS 12.0, *),
              AVPictureInPictureController.isPictureInPictureSupported(),
              let displayLayer = renderer?.displayLayer else {
            isPictureInPictureAvailable = false
            return
        }
        let coordinator = PictureInPictureCoordinator()
        coordinator.state = self
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: coordinator
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = coordinator
        pictureInPictureCoordinator = coordinator
        pictureInPictureController = controller
        isPictureInPictureAvailable = controller.isPictureInPicturePossible
    }

    /// macOS Tahoe añade un host CALayer vacío encima del renderer de muestras
    /// de PiP. Ese host negro tapa el contenido correcto que AVKit ya compuso.
    /// No enlazamos símbolos privados: solo ocultamos la vista vacía si el
    /// sistema la crea para este flujo concreto.
    fileprivate func suppressBrokenPictureInPictureHostOverlay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            let pipWindows = NSApplication.shared.windows.filter {
                String(describing: type(of: $0)).contains("PIPPanel")
            }
            for window in pipWindows {
                guard let rootView = window.contentView else { continue }
                Self.hideBrokenPictureInPictureHost(in: rootView)
            }
        }
    }

    /// AVKit Tahoe refleja la capa de muestras a escala 1:1. Mantener la capa
    /// fuente sincronizada con el panel PiP hace que esa copia coincida con el
    /// destino también después de que el usuario lo redimensione.
    fileprivate func resizePictureInPictureSourceLayer() {
        DispatchQueue.main.async { [weak self] in
            self?.synchronizePictureInPictureSourceLayer()
        }
    }

    fileprivate func restorePictureInPictureSourceLayer() {
        if let observer = pictureInPictureResizeObserver {
            NotificationCenter.default.removeObserver(observer)
            pictureInPictureResizeObserver = nil
        }
        if let frame = pictureInPictureSourceFrame {
            renderer?.displayLayer.frame = frame
        }
        pictureInPictureSourceFrame = nil
    }

    private func synchronizePictureInPictureSourceLayer() {
        guard let layer = renderer?.displayLayer,
              let panel = pictureInPicturePanel(),
              let contentView = panel.contentView else {
            return
        }
        observePictureInPicturePanelResize(panel)
        let targetSize = contentView.bounds.size
        guard targetSize.width > 0, targetSize.height > 0 else { return }
        if pictureInPictureSourceFrame == nil {
            pictureInPictureSourceFrame = layer.frame
        }
        layer.frame = CGRect(origin: .zero, size: targetSize)
        suppressBrokenPictureInPictureHostOverlay()
    }

    private func pictureInPicturePanel() -> NSWindow? {
        NSApplication.shared.windows.first {
            String(describing: type(of: $0)).contains("PIPPanel")
        }
    }

    private func observePictureInPicturePanelResize(_ panel: NSWindow) {
        guard pictureInPictureResizeObserver == nil else { return }
        pictureInPictureResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.synchronizePictureInPictureSourceLayer()
            }
        }
    }

    private static func hideBrokenPictureInPictureHost(in view: NSView) {
        let className = String(describing: type(of: view))
        if className == "AVPictureInPictureCALayerHostView" {
            view.isHidden = true
        }
        for subview in view.subviews {
            hideBrokenPictureInPictureHost(in: subview)
        }
    }
    func toggleVisualEnhancements() { visualEnhancementsEnabled.toggle() }

    func requestTimelineThumbnail(at time: Double) {
        guard let sourceURL, duration > 0 else { return }

        let targetTime = min(max(time, 0), duration)
        let targetSecond = Int(targetTime.rounded(.down))
        guard timelineThumbnailSecond != targetSecond else { return }

        timelineThumbnailSecond = targetSecond
        timelineThumbnailRequestID &+= 1
        let requestID = timelineThumbnailRequestID
        isTimelineThumbnailLoading = true
        timelineThumbnailTask?.cancel()

        timelineThumbnailTask = Task { [weak self, timelineThumbnailExtractor] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }

            let thumbnail = try? await timelineThumbnailExtractor.thumbnail(
                for: sourceURL,
                at: targetTime
            )
            guard !Task.isCancelled,
                  let self,
                  self.timelineThumbnailRequestID == requestID else {
                return
            }
            self.timelineThumbnail = thumbnail
            self.isTimelineThumbnailLoading = false
        }
    }

    /// Stops work when the pointer leaves the timeline but preserves the last
    /// decoded image. Re-entering the track can therefore show feedback
    /// immediately instead of flashing a loading indicator on every hover.
    func hideTimelineThumbnailPreview() {
        timelineThumbnailTask?.cancel()
        timelineThumbnailTask = nil
        timelineThumbnailRequestID &+= 1
        timelineThumbnailSecond = nil
        isTimelineThumbnailLoading = false
    }

    func clearTimelineThumbnail() {
        hideTimelineThumbnailPreview()
        timelineThumbnail = nil
    }

    func loadVideo(_ url: URL) {
        let rememberedPosition = recentVideos.first(where: { $0.path == url.path })?.resumePosition ?? 0
        loadVideo(url, restoringAt: rememberedPosition)
    }

    private func loadVideo(_ url: URL, restoringAt rememberedPosition: Double) {
        persistCurrentSession(force: true)
        clearTimelineThumbnail()
        audioTask?.cancel()
        // Un seek en vuelo del video anterior no debe ejecutarse sobre el nuevo
        // demuxer (seek a timestamp viejo en archivo nuevo).
        seekTask?.cancel(); seekTask = nil; pendingSeekTarget = nil
        sourceURL = url
        currentTime = max(rememberedPosition, 0)
        duration = 0
        lastPersistedPlaybackPosition = -1
        statusMessage = "Opening \(url.lastPathComponent)..."
        conversionProgress = 0.1
        hasVideo = false
        rearmFallbackInterpolation()
        resetInterpolationCounters()
        // EMA temporal: nuevo contenido → descartar la historia de vectores de
        // la sesión anterior (el compensator sobrevive entre videos).
        compensator?.resetTemporalState()
        // Limpiar log de diagnóstico audio por corrida (no append).
        try? FileManager.default.removeItem(atPath: "/tmp/rift_audio.log")
        Task.detached(priority: .userInitiated) { [weak self] in
            let d = FFmpegDemuxer()
            do {
                let info = try d.open(url: url)
                let startTime = min(max(rememberedPosition, 0), info.duration)
                if startTime > 0 {
                    try d.seek(to: startTime)
                }
                guard let v = info.tracks.first(where: { $0.kind == .video }) else {
                    await MainActor.run { self?.statusMessage = "No video track" }
                    return
                }
                let dec = VTDecoder()
                try dec.prepare(track: v)
                // Subtítulos: detectar la primera pista subrip (la lectura de cues
                // se hace en un Task en background, no aquí, para no bloquear el
                // primer frame de video — recorrer 17GB tarda ~8s).
                let subTrack: TrackInfo? = {
                    var found: TrackInfo? = nil
                    for track in info.tracks {
                        if track.kind == .other && track.codecName == "subrip" {
                            found = track
                            break
                        }
                    }
                    return found
                }()
                if let self {
                    await self.installNewPipeline(
                        demuxer: d,
                        decoder: dec,
                        videoTrack: v,
                        info: info,
                        subTrack: subTrack,
                        url: url,
                        startTime: startTime
                    )
                }
            } catch {
                await MainActor.run {
                    self?.statusMessage = "Open failed: \(error)"
                    self?.conversionProgress = 0
                }
            }
        }
    }

    /// Instala el pipeline recién abierto (demuxer/decoder/pool/scheduler/
    /// renderer/audio). Antes descarta el pipeline anterior de forma segura:
    /// root cause del loadVideo-while-playing (display loop en silencio tras
    /// reopen) — el decodeTask viejo podía quedar aparcado en coordinator.wait()
    /// (wait no maneja cancelación) y los frames del pool viejo jamás devolvían
    /// su permit, dejando al decode nuevo sin cupo y al pool sin llenarse.
    @MainActor
    private func installNewPipeline(demuxer d: FFmpegDemuxer, decoder dec: VTDecoder, videoTrack v: TrackInfo, info: ContainerInfo, subTrack: TrackInfo?, url: URL, startTime: Double) async {
        self.decodeTask?.cancel()
        await self.coordinator.reset()
        self.framePool?.flush()
        self.decodeTask = nil
        self.demuxer = d
        self.decoder = dec
        self.videoTrack = v
        self.duration = info.duration
        self.currentTime = min(max(startTime, 0), info.duration)
        self.sourceFrameRate = v.frameRate
        self.activePlaylistItemID = self.playlist.first(where: { $0.path == url.path })?.id
        self.markers = self.markersByPath[url.path] ?? []
        self.chapters = info.chapters
        self.technicalInfo = PlaybackTechnicalInfo(
            title: url.lastPathComponent,
            resolution: [v.width, v.height].compactMap { $0 }.map(String.init).joined(separator: " x "),
            videoCodec: v.codecName.uppercased(),
            frameRate: v.frameRate.map { String(format: "%.3g fps", $0) } ?? "Unknown",
            colorSpace: Self.colorDescription(for: v.colorTransfer),
            audio: Self.audioDescription(for: info.tracks.first(where: { $0.kind == .audio })),
            duration: formattedTime(info.duration)
        )
        self.framePool = SlidingFramePool(capacity: Self.framePoolCapacity)
        self.scheduler = FrameScheduler(mode: .native24)
        self.syncSchedulerMode()
        self.timingLogStart = DispatchTime.now().uptimeNanoseconds
        self.subtitleTrack = subTrack
        self.subtitleCues = []
        self.externalSubtitleURL = nil
        self.externalSubtitleName = nil
        // CLAVE: sin esto el synchronizer retrasa el arranque del
        // reloj hasta tener preroll suficiente en TODOS los renderers,
        // y con buffers de 32ms el audio se atasca (isReady=false
        // perpetuo) sin llegar nunca a reproducir.
        self.scheduler?.synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        // Video y audio comparten el MISMO synchronizer para
        // reproducirse en sync (el displayLayer y el audioRenderer
        // viven en el reloj del scheduler).
        self.renderer = HDRDisplayRenderer(synchronizer: self.scheduler?.synchronizer)
        self.configurePictureInPicture()
        // Audio: guardar todas las pistas reales y arrancar la primera.
        let audioTracksAll = info.tracks.filter { $0.kind == .audio }
        self.audioTrackInfos = Dictionary(uniqueKeysWithValues: audioTracksAll.map { ($0.streamIndex, $0) })
        if let aTrack = audioTracksAll.first {
            self.audioTrack = aTrack
            self.selectedAudioTrackIndex = aTrack.streamIndex
            let ar = AVSampleBufferAudioRenderer()
            ar.volume = Float(volume)
            ar.isMuted = false
            self.audioRenderer = ar
            // Importante: agregar ANTES de que el synchronizer arranque (rate=1.0).
            self.scheduler?.synchronizer.addRenderer(ar)
            self.startAudioLoop(url: url, trackStreamIndex: aTrack.streamIndex, codecName: aTrack.codecName, startTime: self.currentTime, extradata: aTrack.codecExtradata, sampleRate: aTrack.sampleRate ?? 0, channels: aTrack.channelCount ?? 0)
        }
        self.availableTracks = {
            var subtitleOrdinal = 0
            return info.tracks.map { t in
                let kind: MediaTrack.Kind
                switch t.kind { case .video: kind = .video; case .audio: kind = .audio; default: kind = .subtitle }
                let label: String
                if kind == .subtitle {
                    label = Self.subtitleLabel(for: t, index: subtitleOrdinal)
                    subtitleOrdinal += 1
                } else {
                    label = t.codecName
                }
                return MediaTrack(id: "\(t.streamIndex)", kind: kind, index: t.streamIndex, label: label, languageCode: t.streamLanguage)
            }
        }()
        // Al cargar, la primera pista de subtítulos queda seleccionada
        // (se muestran por defecto), reflejando el estado en el popover.
        if let subTrack {
            self.selectedSubtitleTrack = self.availableTracks.first { $0.kind == .subtitle && $0.index == subTrack.streamIndex }
        }
        self.audioTracks = audioTracksAll.map { t in AudioTrack(id: t.streamIndex, label: Self.audioLabel(for: t), language: t.streamLanguage) }
        self.hasVideo = true
        self.statusMessage = "Ready"
        self.conversionProgress = 1.0
        self.persistCurrentSession(force: true)
        self.restoreExternalSubtitles(for: url)
        self.startDecodeLoop()
        // Subtítulos: cargar la primera pista en background (paralelo
        // al video) vía cache, sin bloquear el primer frame.
        if let subTrack {
            self.ensureSubtitleCues(url: url, streamIndex: subTrack.streamIndex) {
                guard self.externalSubtitleURL == nil else { return }
                self.subtitleCues = self.subtitleCueCache[subTrack.streamIndex] ?? []
                self.updateActiveSubtitle(at: self.currentTime)
            }
        }
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.movie, UTType.video, UTType(filenameExtension: "mkv") ?? .data, UTType(filenameExtension: "mka") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { replacePlaylist(with: [url]) }
    }

    func addVideosToPlaylist() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.movie, UTType.video, UTType(filenameExtension: "mkv") ?? .data, UTType(filenameExtension: "mka") ?? .data]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            appendToPlaylist(panel.urls)
        }
    }
    func cleanup() { closeVideo() }

    // MARK: - 3a: Decode + FramePool con backpressure real + consumidor simulado
    private var displayTask: Task<Void, Never>?
    private var firstPts: Double?

    // MARK: - 3a/3b: Decode + FramePool con backpressure real
    // `callDisplayLoopOnFirstFrame` = false en reinicios por seek (el display
    // loop ya corre; re-pokearlo cancelaría y recrearía su Task a mitad de
    // reproducción). loadVideo lo deja en true (arranque inicial).
    private func startDecodeLoop(callDisplayLoopOnFirstFrame: Bool = true) {
        guard let d = demuxer, let dec = decoder, let pool = framePool else { return }
        let targetIndex = videoTrack?.streamIndex ?? -1
        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var decoded = 0
            while true {
                let granted = await self.coordinator.wait()
                if Task.isCancelled || !granted {
                    // Cancelado con permiso concedido → devolverlo; anulado por
                    // reset() → el permit ya no es nuestro (nunca se otorgó).
                    if granted { await self.coordinator.signal() }
                    break
                }
                // Lectura serializada con seek (withDemuxAccess) + reintentos con
                // log: antes un solo fallo mataba el decode en silencio para toda
                // la sesión (video congelado + audio ok). nil = EOF limpio (fin
                // del archivo, salida normal); throw = error real (reintentar
                // acotado y luego morir CON log + mensaje visible, no en silencio).
                var pkt: CompressedPacket?
                var readError: Error?
                for _ in 0..<3 {
                    do {
                        pkt = try await self.coordinator.withDemuxAccess { try d.nextPacket() }
                        readError = nil
                        break
                    } catch {
                        readError = error
                    }
                }
                if let readError {
                    os_log("decode: read error %{public}@ tras reintentos — loop terminado",
                           log: benchLog, type: .error, String(describing: readError))
                    await MainActor.run { self.statusMessage = "Decode error: \(readError)" }
                    await self.coordinator.signal()
                    break
                }
                guard let pkt else {
                    // EOF limpio: fin del archivo, salida normal del loop.
                    await self.coordinator.signal()
                    break
                }
                if pkt.streamIndex != targetIndex {
                    await self.coordinator.signal()
                    continue
                }
                // Fijación B: gate de decode por presupuesto TEMPORAL (no por
                // conteo de frames). No decodificar paquetes cuyo pts supere el
                // reloj de presentación en más de `decodeAheadBudget` segundos —
                // así el pool nunca corre por delante del clock sin límite. Solo
                // se aplica cuando el reloj ya avanza (rate>0) y el pool tiene
                // insumos (pool.count >= 2): evita deadlock en pre-roll (primeros
                // frames) y nunca bloquea al pipeline que va al límite (si el
                // decode es lento, pts < clk+budget y no hay espera → sin
                // starvation nueva para ME/interpolación).
                if decodeAheadBudget > 0 {
                    let sched = await self.scheduler
                    let rate = sched?.synchronizer.rate ?? 0
                    if rate > 0 && pool.count >= 2 {
                        while !Task.isCancelled {
                            let clk = sched?.synchronizer.currentTime().seconds ?? 0
                            if pkt.pts - clk <= decodeAheadBudget { break }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        if Task.isCancelled {
                            await self.coordinator.signal()
                            break
                        }
                    }
                }
                let tDecodeStartNS = DispatchTime.now().uptimeNanoseconds
                guard let decodedFrame = try? dec.decodeFrame(pkt) else {
                    await self.coordinator.signal()
                    continue
                }
                let tDecodeEndNS = DispatchTime.now().uptimeNanoseconds
                decoded += 1
                await MainActor.run {
                    self.totalDecoded = decoded
                    pool.add(buffer: decodedFrame.pixelBuffer, pts: decodedFrame.pts)
                    let tPoolAddNS = DispatchTime.now().uptimeNanoseconds
                    let key = RiftPlayerState.timelineKey(decodedFrame.pts)
                    self.frameTimelines[key] = FrameTimeline(
                        pts: decodedFrame.pts,
                        decodeStartNS: tDecodeStartNS,
                        decodeEndNS: tDecodeEndNS,
                        poolAddNS: tPoolAddNS
                    )
                    if decoded == 1 && callDisplayLoopOnFirstFrame {
                        self.startDisplayLoop()
                    }
                }
                if Task.isCancelled {
                    // Devolver el permit del frame ya añadido (su pool será
                    // descartado/flusheado por el teardown de loadVideo).
                    await self.coordinator.signal()
                    break
                }
            }
        }
    }

    // MARK: - Audio

    private nonisolated static func audioLog(_ s: String) {
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/rift_audio.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            FileManager.default.createFile(atPath: "/tmp/rift_audio.log", contents: line.data(using: .utf8))
        }
    }

    private struct PreparedAudioBuffer {
        let sampleBuffer: CMSampleBuffer
        let outputChannels: Int
        let dataSize: Int
        let rms: Float
        let peak: Float
    }

    private struct SubtitleCue {
        let start: Double
        let end: Double
        let text: String
    }

    private static nonisolated func readExternalSubtitleCues(url: URL) -> [SubtitleCue] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")

        return blocks.compactMap { block in
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard !lines.isEmpty else { return nil }
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
            let timing = lines[timingIndex]
                .components(separatedBy: "-->")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard timing.count == 2,
                  let start = subtitleTimestamp(timing[0]),
                  let end = subtitleTimestamp(timing[1].components(separatedBy: " ").first ?? "") else {
                return nil
            }
            let subtitleText = lines.dropFirst(timingIndex + 1)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !subtitleText.isEmpty else { return nil }
            return SubtitleCue(start: start, end: max(end, start + 0.1), text: subtitleText)
        }
    }

    private static nonisolated func subtitleTimestamp(_ value: String) -> Double? {
        let normalized = value.replacingOccurrences(of: ",", with: ".")
        let components = normalized.split(separator: ":").map(String.init)
        guard components.count == 2 || components.count == 3 else { return nil }
        let seconds = Double(components.last ?? "") ?? -1
        guard seconds >= 0 else { return nil }
        let minutes = Double(components[components.count - 2]) ?? -1
        guard minutes >= 0 else { return nil }
        let hours = components.count == 3 ? (Double(components[0]) ?? -1) : 0
        guard hours >= 0 else { return nil }
        return hours * 3_600 + minutes * 60 + seconds
    }

    private static nonisolated func readSubtitleCues(url: URL, trackStreamIndex: Int) -> [SubtitleCue] {
        let demuxer = FFmpegDemuxer()
        defer { demuxer.close() }
        guard (try? demuxer.open(url: url)) != nil else { return [] }
        var cues: [SubtitleCue] = []
        while let packet = try? demuxer.nextPacket() {
            guard packet.streamIndex == trackStreamIndex else { continue }
            guard let text = String(bytes: packet.data, encoding: .utf8) else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let end = packet.duration > 0 ? packet.pts + packet.duration : packet.pts + 3.0
            cues.append(SubtitleCue(start: packet.pts, end: end, text: trimmed))
        }
        return cues
    }

    private func ensureSubtitleCues(url: URL, streamIndex: Int, done: @escaping () -> Void) {
        let cached = subtitleCueCache[streamIndex]
        if cached != nil {
            done()
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let cues = Self.readSubtitleCues(url: url, trackStreamIndex: streamIndex)
            await MainActor.run {
                self?.subtitleCueCache[streamIndex] = cues
                done()
            }
        }
    }

    private func startAudioLoop(url: URL, trackStreamIndex: Int, codecName: String, startTime: Double, extradata: [UInt8] = [], sampleRate: Int = 0, channels: Int = 0) {
        audioTask?.cancel()
        guard let renderer = audioRenderer, let sync = scheduler?.synchronizer else {
            Self.audioLog("audioLoop SKIP: renderer/synchronizer missing")
            return
        }

        let startPTS = max(0, startTime)
        let offset = audioSyncOffset
        let sourceStartPTS = max(0, startPTS - offset)
        let maxAheadSeconds = 0.25
        audioTask = Task.detached(priority: .userInitiated) {
            let audioDemuxer = FFmpegDemuxer()
            defer { audioDemuxer.close() }

            do {
                _ = try audioDemuxer.open(url: url)
                if sourceStartPTS > 0 {
                    try? audioDemuxer.seek(to: sourceStartPTS)
                }
                let decoder = try AudioDecoder(codecName: codecName, extradata: extradata, sampleRate: sampleRate, channels: channels)
                var framesEnqueued = 0
                var framesSkippedBeforeStart = 0
                var failures = 0

                while !Task.isCancelled {
                    guard let packet = try? audioDemuxer.nextPacket() else { break }
                    guard packet.streamIndex == trackStreamIndex else { continue }

                    let frames = decoder.decode(packet: packet)
                    var accumulatedSeconds = 0.0

                    for frame in frames {
                        if Task.isCancelled { break }
                        guard frame.sampleCount > 0, frame.sampleRate > 0, frame.channels > 0 else {
                            failures += 1
                            continue
                        }

                        let frameDuration = Double(frame.sampleCount) / Double(frame.sampleRate)
                        let presentationPTS = packet.pts + accumulatedSeconds + offset
                        accumulatedSeconds += frameDuration

                        if presentationPTS + frameDuration < startPTS - 0.02 {
                            framesSkippedBeforeStart += 1
                            continue
                        }

                        while !Task.isCancelled {
                            let rawClock = sync.currentTime().seconds
                            let clock = rawClock.isFinite ? rawClock : startPTS
                            if presentationPTS <= clock + maxAheadSeconds { break }
                            try? await Task.sleep(nanoseconds: 10_000_000)
                        }
                        if Task.isCancelled { break }

                        guard let prepared = Self.makeAudioSampleBuffer(from: frame, presentationPts: presentationPTS) else {
                            failures += 1
                            continue
                        }

                        renderer.enqueue(prepared.sampleBuffer)
                        framesEnqueued += 1
                    }
                }
            } catch {
                Self.audioLog("audioLoop FAILED: \(error)")
            }
        }
    }

    private nonisolated static func makeAudioSampleBuffer(from frame: AudioDecoder.DecodedAudioFrame, presentationPts: Double) -> PreparedAudioBuffer? {
        guard frame.sampleCount > 0, frame.sampleRate > 0, frame.channels > 0 else { return nil }
        let bytesPerFloat = MemoryLayout<Float>.stride
        guard frame.data.count >= frame.sampleCount * frame.channels * bytesPerFloat else { return nil }

        var audioData = frame.data
        var outChannels = frame.channels
        if frame.channels > 2 {
            let totalFrames = frame.sampleCount
            var stereo = [Float](repeating: 0, count: totalFrames * 2)
            let centerGain: Float = 0.70710678
            frame.data.withUnsafeBytes { ptr in
                guard let samples = ptr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                for sampleIndex in 0..<totalFrames {
                    let srcIdx = sampleIndex * frame.channels
                    let dstIdx = sampleIndex * 2
                    let fl = samples[srcIdx]
                    let fr = samples[srcIdx + 1]
                    let fc = frame.channels >= 3 ? samples[srcIdx + 2] : 0
                    stereo[dstIdx] = min(1.0, max(-1.0, fl + centerGain * fc))
                    stereo[dstIdx + 1] = min(1.0, max(-1.0, fr + centerGain * fc))
                }
            }
            audioData = stereo.withUnsafeBufferPointer { Data(buffer: $0) }
            outChannels = 2
        }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(frame.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(outChannels * bytesPerFloat),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(outChannels * bytesPerFloat),
            mChannelsPerFrame: UInt32(outChannels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var channelLayout = AudioChannelLayout()
        channelLayout.mChannelLayoutTag = (outChannels > 2) ? kAudioChannelLayoutTag_MPEG_5_1_D : kAudioChannelLayoutTag_Stereo
        var format: CMAudioFormatDescription?
        let fmtStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &channelLayout, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard fmtStatus == noErr, let format else { return nil }

        let dataSize = audioData.count
        var blockBuffer: CMBlockBuffer?
        let statusBB = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                          memoryBlock: nil,
                                                          blockLength: dataSize,
                                                          blockAllocator: kCFAllocatorDefault,
                                                          customBlockSource: nil,
                                                          offsetToData: 0,
                                                          dataLength: dataSize,
                                                          flags: 0,
                                                          blockBufferOut: &blockBuffer)
        guard statusBB == noErr, let blockBuffer else { return nil }

        let copyOK = audioData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataSize)
        }
        guard copyOK == noErr else { return nil }

        let ptsTime = CMTime(seconds: presentationPts, preferredTimescale: 90000)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(frame.sampleCount), timescale: CMTimeScale(frame.sampleRate)),
            presentationTimeStamp: ptsTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let statusSB = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: CMItemCount(frame.sampleCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard statusSB == noErr, let sampleBuffer else { return nil }

        var rms: Float = 0
        var peak: Float = 0
        let nFloats = audioData.count / bytesPerFloat
        audioData.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            var sum: Double = 0
            for i in 0..<nFloats {
                let value = base[i]
                sum += Double(value) * Double(value)
                peak = max(peak, abs(value))
            }
            rms = nFloats > 0 ? Float(sqrt(sum / Double(nFloats))) : 0
        }

        return PreparedAudioBuffer(sampleBuffer: sampleBuffer, outputChannels: outChannels, dataSize: dataSize, rms: rms, peak: peak)
    }

    // MARK: - Debug timing log to file

    /// Timestamp de inicio del logging. Se reinicia cada vez que se carga un video.
    private var timingLogStart: UInt64 = 0

    /// Debug: log de timing por par — escrito a /tmp/rift_timing.csv para diagnóstico rápido de overhead.
    private func logTiming(pairIndex: Int, pairMS: Double, meMS: Double, warpMS: Double) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - timingLogStart) / 1_000_000.0
        let line = "\(Int(elapsed)),\(pairIndex),\(String(format: "%.2f", pairMS)),\(String(format: "%.2f", meMS)),\(String(format: "%.2f", warpMS))\n"
        FileManager.default.createFile(atPath: "/tmp/rift_timing.csv", contents: line.data(using: .utf8))
    }

    // MARK: - Negative-PTS diagnostic (B-frame investigation)

    /// Writes a single line to /tmp/rift_negpts.log. Creates the file if needed.
    private static func writeNegPTSLog(_ s: String) {
        let line = s + "\n"
        let path = "/tmp/rift_negpts.log"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    // MARK: - Delivery diagnostics (soap-opera investigation)

    /// Emit a [RIFT-DIAG] log once per second with ready/notReady/dropped counters.
    /// Resets counters after each emission so each line represents a 1s window.
    private func logDiagIfDue() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastDiagLogTime >= 1.0 else { return }
        lastDiagLogTime = now
        let total = framesEnqueuedReady + framesEnqueuedNotReady + framesDroppedTimeout
        let line = "[RIFT-DIAG] requested=\(framesRequestedForEnqueue) enqueued=\(total) ready=\(framesEnqueuedReady) notReady=\(framesEnqueuedNotReady) dropped=\(framesDroppedTimeout)\n"
        RiftPlayerState.writeDiagLog(line)
        framesRequestedForEnqueue = 0
        framesEnqueuedReady = 0
        framesEnqueuedNotReady = 0
        framesDroppedTimeout = 0
    }

    /// Sample isReadyForMoreMediaData state; log percentage of not-ready samples
    /// every 60 samples (~1 second at display-loop rate).
    private func sampleReadyState(_ rend: HDRDisplayRenderer) {
        readyStateSamples += 1
        if !rend.displayLayer.isReadyForMoreMediaData {
            notReadySamples += 1
        }
        if readyStateSamples >= 60 {
            let pct = Double(notReadySamples) / Double(readyStateSamples) * 100
            let line = String(format: "[RIFT-DIAG] isReady=false en %.1f%% de las muestras (notReady=%d/%d)\n", pct, notReadySamples, readyStateSamples)
            RiftPlayerState.writeDiagLog(line)
            readyStateSamples = 0
            notReadySamples = 0
        }
    }

    /// Accumulates the four per-pair stage timings (reserve/pace/interp/enqueueLoop)
    /// measured around the interpolated-branch display loop, and emits a throttled
    /// [RIFT-DIAG-STAGE] average once per second via logStageIfDue().
    private func accumulateStageTimes(reserveMS: Double, paceMS: Double, interpMS: Double, enqueueLoopMS: Double) {
        stagePairs += 1
        stageReserveMS += reserveMS
        stagePaceMS += paceMS
        stageInterpMS += interpMS
        stageEnqueueLoopMS += enqueueLoopMS
        logStageIfDue()
    }

    private func logStageIfDue() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastStageLogTime >= 1.0, stagePairs > 0 else { return }
        lastStageLogTime = now
        let n = Double(stagePairs)
        let line = String(format: "[RIFT-DIAG-STAGE] pairs=%d reserve=%.2fms pace=%.2fms interp=%.2fms enqueueLoop=%.2fms total=%.2fms\n",
            stagePairs, stageReserveMS/n, stagePaceMS/n, stageInterpMS/n, stageEnqueueLoopMS/n,
            (stageReserveMS+stagePaceMS+stageInterpMS+stageEnqueueLoopMS)/n)
        RiftPlayerState.writeDiagLog(line)
        stagePairs = 0
        stageReserveMS = 0
        stagePaceMS = 0
        stageInterpMS = 0
        stageEnqueueLoopMS = 0
    }

    /// Write a diagnostic line to /tmp/rift_diag.log for headless capture.
    private static func writeDiagLog(_ line: String) {
        if let h = FileHandle(forWritingAtPath: "/tmp/rift_diag.log") {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            h.closeFile()
        } else {
            FileManager.default.createFile(atPath: "/tmp/rift_diag.log", contents: line.data(using: .utf8))
        }
    }

    /// Espera hasta que el reloj del synchronizer alcance el pts objetivo. Si el
    /// frame está más de 1s en el futuro (p.ej. tras un seek con el reloj
    /// desalineado), lo presenta de inmediato para no dejar la imagen congelada.
    private func waitUntilDisplayClock(atLeast pts: Double) async {
        guard let sched = self.scheduler else { return }
        while !Task.isCancelled {
            let clk = sched.synchronizer.currentTime().seconds
            if clk >= pts - 0.001 { return }
            if pts - clk > 1.0 { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Pacing de la rama interpolada (equivalente al waitUntilDisplayClock de la
    /// nativa): no interpolar/encolar un par cuyo `first.pts` esté a más de `lead`
    /// segundos del reloj de presentación. Solo se invoca con rate>0 (el loop ya
    /// hace `continue` si el reloj está en pausa), así que el reloj siempre avanza
    /// y no hay deadlock. Sin esto la rama interp consumía pares tan rápido como
    /// podía, acumulaba ~1s de frames futuros en la cola del AVSampleBufferDisplayLayer
    /// (descartaba interpolados en silencio: isReady==false, tirones) y generaba
    /// huecos en el pool (PTS no-monótono hacia atrás → brincos).
    private func paceInterpPair(firstPTS: Double, lead: Double) async {
        guard let sched = self.scheduler else { return }
        while !Task.isCancelled {
            let clk = sched.synchronizer.currentTime().seconds
            if clk >= firstPTS - lead { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// Encola un frame del par interpolado respetando la capacidad de la capa.
    /// La ráfaga de 3 frames/par de la cadencia uniforme satura la cola del
    /// AVSampleBufferDisplayLayer (isReadyForMoreMediaData=false en ~55-75% de
    /// los enqueues medidos): los frames encolados en esa condición se descartan
    /// en silencio, y con displayLayer.flush() tras un seek pueden dejar el video
    /// congelado mientras el audio (loop separado) sigue. Este helper espera a
    /// que la capa readmita (con tope de espera) antes de encolar.
    private func enqueuePaced(_ rend: HDRDisplayRenderer, _ sbuf: CMSampleBuffer) async {
        let maxWaitNS = UInt64(3 * 16_666_667)
        var waited = UInt64(0)
        while !Task.isCancelled {
            if rend.displayLayer.isReadyForMoreMediaData {
                rend.enqueue(sbuf)
                self.enqueuedFramesInWindow += 1
                self.framesEnqueuedReady += 1
                self.logDiagIfDue()
                return
            }
            if waited >= maxWaitNS {
                self.interpBurstDropped += 1
                self.framesDroppedTimeout += 1
                self.logDiagIfDue()
                return
            }
            try? await Task.sleep(nanoseconds: 4_000_000)
            waited += 4_000_000
        }
    }

    /// Encola un frame en el displayLayer con DisplayImmediately=true (pacer
    /// contra el reloj ya se hizo antes). Helper compartido entre el modo nativo
    /// y el modo interpolado para evitar duplicar el patrón.
    private func enqueueForDisplay(rend: HDRDisplayRenderer, pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        guard let sbuf = rend.sampleBuffer(from: pixelBuffer, pts: pts, duration: duration) else { return }
        self.markDisplayImmediately(sbuf)
        rend.displayLayer.enqueue(sbuf)
    }

    /// Marca el CMSampleBuffer para presentación inmediata (sin esperar más).
    /// Replica el patrón inline que ya usaba el modo nativo.
    private func markDisplayImmediately(_ sbuf: CMSampleBuffer) {
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
    }

    /// Genera los frames interpolados del par (I0, I1) según los `tValues`
    /// pedidos (1 para 48fps, [1/3,2/3] o [0.5] para el patrón 3:2 de 60fps).
    /// Devuelve los buffers generados + el coste total del par (ME+warp+upscale
    /// de todas las interpolaciones) para el gate de fallback por par.
    private func interpolatePair(i0: Frame, i1: Frame, tValues: [Float])
        async -> (buffers: InterpolatedBuffersBox, totalMS: Double, meMS: Double, warpMS: Double) {
        guard interpolationMode != .disabled, !isInterpolating else { return (buffers: InterpolatedBuffersBox(buffers: []), totalMS: 0, meMS: 0, warpMS: 0) }
        if compensator == nil {
            // Bonus: construir los pipelines Metal en background. El init de
            // MotionCompensator compila el shader fuente / crea PSOs (cientos de
            // ms); hacerlo aquí (MainActor) congelaba la UI y alimentaba la brecha
            // decode↔clock en los toggles de modo. al await, el MainActor queda
            // libre durante la construcción.
            do {
                let config = interpolationConfig
                compensator = try await Task.detached(priority: .userInitiated) {
                    try MotionCompensator(config: config)
                }.value
            } catch {
                os_log("interpolatePair: failed to init MotionCompensator: %{public}@",
                       log: benchLog, type: .error, String(describing: error))
                return (buffers: InterpolatedBuffersBox(buffers: []), totalMS: 0, meMS: 0, warpMS: 0)
            }
        }
        guard let comp = compensator else { return (buffers: InterpolatedBuffersBox(buffers: []), totalMS: 0, meMS: 0, warpMS: 0) }

        isInterpolating = true
        let measured = await Task.detached { @Sendable in
            let started = DispatchTime.now().uptimeNanoseconds
            // Fase B fast-path: luma + ME se calculan UNA vez por par; el warp/
            // upscale/cbcr/hdr se repite por cada t pedido (1 para 48fps, 2 para
            // el patrón 3:2 de 60fps). Antes llamábamos interpolateWithTimings por
            // cada t — re-ejecutando scaledLuma+ME en pares dobles (~52ms/pair 4K).
            let r = comp.interpolatePair(I0: i0.pixelBuffer, I1: i1.pixelBuffer, tValues: tValues)
            // El tiempo del par = coste real transcurrido de todas las interps del par.
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0
            return (buffers: InterpolatedBuffersBox(buffers: r.pixelBuffers), totalMS: elapsed, meMS: r.meMS, warpMS: r.warpMS + r.upscaleMS)
        }.value
        isInterpolating = false
        interpolationPairCount += 1

        if comp.config.workWidth > InterpolationConfig.default.workWidth {
            recentHighQualityPairTimings.append(measured.totalMS)
            if recentHighQualityPairTimings.count > 6 {
                recentHighQualityPairTimings.removeFirst()
            }
            // El MCFI se procesa por cada intervalo de la fuente: el par entero
            // debe caber holgadamente en ese periodo, no solo cada frame de salida.
            if interpolationPairCount > interpolationWarmupPairs,
               recentHighQualityPairTimings.count == 6 {
                let average = recentHighQualityPairTimings.reduce(0, +)
                    / Double(recentHighQualityPairTimings.count)
                let pairBudgetMS = sourcePeriod * 1_000.0 * 0.90
                if average > pairBudgetMS {
                    usesHighQualityFluidProfile = false
                    compensator = nil
                    recentHighQualityPairTimings.removeAll()
                    recentPairTimings.removeAll()
                    os_log("Frame+ HQ degradado: %.1fms/par > presupuesto %.1fms; se mantiene perfil fluido",
                           log: benchLog, type: .info, average, pairBudgetMS)
                }
            }
        }

        // A 60 fps se sintetizan dos imágenes por intervalo fuente, así que la
        // medida debe ser el coste del PAR completo. A 48 sólo hay una síntesis
        // por par y el coste por imagen coincide con ese mismo presupuesto.
        let frameBudgetMS = 1_000.0 / max(sourceFrameRate ?? 24.0, 24.0)
        let budgetThreshold = frameBudgetMS * 0.90
        let perFrameCost = measured.totalMS / Double(max(tValues.count, 1))
        let is60FPS = scheduler?.mode == .interpolated60
        let budgetCost = is60FPS ? measured.totalMS : perFrameCost
        let budgetUnit = is60FPS ? "par" : "frame"

        if interpolationPairCount <= interpolationWarmupPairs {
            os_log("interpolatePair [warm-up %d/%d, %d interp]: %.1fms pair / %.1fms per-frame (ME: %.1f Warp: %.1f)",
                   log: benchLog, type: .info,
                   interpolationPairCount, interpolationWarmupPairs, tValues.count,
                   measured.totalMS, perFrameCost, measured.meMS, measured.warpMS)
        } else {
            recentPairTimings.append(budgetCost)
            if recentPairTimings.count > interpolationTimingWindow {
                recentPairTimings.removeFirst()
            }
            let avg = recentPairTimings.reduce(0, +) / Double(recentPairTimings.count)
            os_log("interpolatePair [%d/%d avg %.1fms/%{public}@, %d interp]: %.1fms pair / %.1fms per-frame (ME: %.1f Warp: %.1f)",
                   log: benchLog, type: .info,
                   recentPairTimings.count, interpolationTimingWindow, avg, budgetUnit, tValues.count,
                   measured.totalMS, perFrameCost, measured.meMS, measured.warpMS)
            // Falso positivo de arranque (medido en BLEACH 1080p y Avatar 4K):
            // el decoder/GPU en frío + warm-up dejan muestras de 45-100ms en los
            // primeros pares, y una media de 1-2 muestras dispara el gate antes
            // de que el pipeline alcance régimen. Dos condiciones extra:
            //  1) promedio estable: exigir la ventana llena (10 pares), no 1;
            //  2) skip de arranque: no evaluar durante la misma rampa que el gate
            //     de latencia (throughputSkipStartupSeconds). El déficit real
            //     sostenido lo sigue capturando ese gate, ya calibrado.
            if avg > budgetThreshold,
               recentPairTimings.count >= interpolationTimingWindow {
                let startupElapsed = firstPairCompletedAt == 0
                    ? 0
                    : Double(DispatchTime.now().uptimeNanoseconds - firstPairCompletedAt) / 1e9
                if startupElapsed >= throughputSkipStartupSeconds {
                    downgradeTo48OrDisable(reason: String(format: "coste medio %.1fms/%@ > presupuesto %.1fms", avg, budgetUnit, budgetThreshold))
                    return (buffers: InterpolatedBuffersBox(buffers: []), totalMS: 0, meMS: 0, warpMS: 0)
                }
            }
        }

        // Estados de UI por transiciones reales (no por-par): al completar el
        // warm-up (6º par, tras pasar el gate de presupuesto) pasamos de
        // "Preparing HQ" a "60fps ready" una sola vez, y se mantiene hasta una
        // transición real (seek/load/fallback lo limpian en
        // resetInterpolationCounters/disableInterpolation). Sin writes por-par →
        // sin @Published redundante (~24-60 invalidaciones/seg antes).
        if interpolationPairCount == interpolationWarmupPairs + 1 {
            isFramePlusPreparing = false
            isFramePlusPreRendered = true
        }

        if !measured.buffers.buffers.isEmpty {
            if !isArtificialInterpolationActive { isArtificialInterpolationActive = true }
        } else {
            os_log("interpolatePair: no output buffer; Frame+ remains waiting",
                   log: benchLog, type: .error)
        }
        return measured
    }

    private func startDisplayLoop() {
        if !isPlaying { isPlaying = true }
        updateTimePolling()
        // Test harness: arrancar con un modo de interpolación forzado (inert sin env var).
        // Si se usa RIFT_AUTO_MODE_AT, el arranque comienza nativo y el modo se aplica
        // en vivo más tarde (mismo camino que el toggle del menú) — no aplicar dos veces.
        let autoMode = ProcessInfo.processInfo.environment["RIFT_AUTO_MODE"]
        let autoModeAt = ProcessInfo.processInfo.environment["RIFT_AUTO_MODE_AT"]
        if let autoMode, autoModeAt == nil,
           let m = InterpolationMode(rawValue: autoMode), m != .disabled, interpolationMode == .disabled {
            os_log("RIFT_AUTO_MODE=%{public}@ → activando interpolación", log: benchLog, type: .info, autoMode)
            self.setInterpolationMode(m)
        }
        if let sched = scheduler, sched.synchronizer.rate == 0 {
            sched.synchronizer.setRate(1.0, time: CMTime(seconds: currentTime, preferredTimescale: 600), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var hasPresentedInterpolatedStart = false
            // Fix gap-duplicate: when interpOutputs emits `second` as SOURCE,
            // the next iteration's `first` (== prev `second`) would be emitted
            // again by gapFallback. Track whether previous pair emitted `second`
            // so gapFallback can skip the redundant emission.
            var prevPairEmittedSecondSource = false
            var previousEnqueuedPTS: Double = -1
            var lastEnqueuedInvocationID: UInt64 = 0
            var interpInvocationID: UInt64 = 0
            var interpEntryTime: UInt64 = 0
            var poolFlushCount: UInt64 = 0
            var prevPoolFrameCount: Int = 0
            // --- GAP CORRELATION STATE ---
            var lastEmittedPTS: Double = -1
            var lastEmittedID: UInt64 = 0
            var invEnqueueWaitNS: UInt64 = 0
            var invEnqueueCalls: Int = 0
            var invEnqueueNotReady: Int = 0
            while true {
                if Task.isCancelled { break }
                guard let pool = self.framePool, let rend = self.renderer, let sched = self.scheduler else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                // Diagnostic tag: scheduler mode (set once per iteration).
                rend.pendingSchedulerMode = sched.mode == .interpolated60 ? "interpolated60"
                    : sched.mode == .interpolated48 ? "interpolated48"
                    : sched.mode == .native24 ? "native24" : "other"
                // --- INVOCATION TRACKING ---
                interpInvocationID += 1
                interpEntryTime = DispatchTime.now().uptimeNanoseconds
                let currentPoolCount = pool.count
                if prevPoolFrameCount > 0 && currentPoolCount == 0 {
                    poolFlushCount += 1
                    RiftPlayerState.writeNegPTSLog(String(format: "[RIFT-POOL-FLUSH] id=%d flushN=%d prevCount=%d pts=???", interpInvocationID, poolFlushCount, prevPoolFrameCount))
                }
                prevPoolFrameCount = currentPoolCount
                // Si está pausado, no consumir el pool ni encolar nada —
                // el synchronizer detiene la presentación con rate=0.
                if sched.synchronizer.rate == 0 {
                    self.resetThroughputWindow()
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                let workStart = DispatchTime.now().uptimeNanoseconds
                if self.interpolationMode == .disabled {
                    guard let f = pool.oldest() else {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    }
                    await self.waitUntilDisplayClock(atLeast: f.pts)
                    if Task.isCancelled { break }
                    let clkN = sched.synchronizer.currentTime().seconds
                    // Consumir el frame del pool y devolver el permit pase lo que
                    // pase (presentado o descartado) para no frenar la cadena.
                    pool.removeFirst()
                    await self.coordinator.signal()
                    // Fijación C — red de seguridad en la rama nativa:
                    //   • Frame atrasado (pts + margen < reloj): DESCARTAR en vez
                    //     de presentarlo en ráfaga con DisplayImmediately (causaba
                    //     el fast-forward tras un toggle).
                    //   • Frames con pts por delante del reloj: NO marcar
                    //     DisplayImmediately (el layer los retiene hasta que el
                    //     synchronizer alcance su pts → pacing correcto, sin salto).
                    //   • Solo los frames genuinamente a tiempo se presentan ya.
                    let behindMargin = 0.020
                    let aheadMargin = 0.050
                    if f.pts + behindMargin >= clkN {
                        let pts = CMTime(seconds: f.pts, preferredTimescale: 1200)
                        let dur = CMTime(seconds: 1.0 / 24.0, preferredTimescale: 1200)
                        rend.pendingOrigin = "native"; rend.pendingType = "SOURCE"
                        if let sbuf = rend.sampleBuffer(from: f.pixelBuffer, pts: pts, duration: dur) {
                            if f.pts - clkN <= aheadMargin {
                                self.markDisplayImmediately(sbuf)
                            }
                            rend.enqueue(sbuf)
                            self.enqueuedFramesInWindow += 1
                        }
                    }
                } else {
                    let tStageStart = DispatchTime.now().uptimeNanoseconds
                    guard let pair = pool.reservePair() else {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    }
                    let tAfterReserve = DispatchTime.now().uptimeNanoseconds
                    let stageReserveMS = Double(tAfterReserve - tStageStart) / 1_000_000.0
                    let first = pair.0
                    let second = pair.1
                    let delta = max(second.pts - first.pts, 1.0 / 24.0)
                    let pairIsEven = interpPairIndex % 2 == 0
                    let uniform60 = uniformCadence && sched.mode == .interpolated60
                    // The first source image of a uniform-60 pair is often not
                    // emitted at all: the earliest visible sample is t=0.4 or
                    // t=0.2. Staleness must therefore use that sample's PTS,
                    // not I0's PTS, otherwise a still-viable pair is discarded
                    // and creates a 58ms presentation hole.
                    let firstOutputT: Double
                    if uniform60 {
                        firstOutputT = pairIsEven ? 0.4 : 0.2
                    } else if !hasPresentedInterpolatedStart {
                        firstOutputT = 0
                    } else if sched.mode == .interpolated60 {
                        firstOutputT = pairIsEven ? 0.5 : (1.0 / 3.0)
                    } else {
                        firstOutputT = 0.5
                    }
                    let firstOutputPTS = first.pts + delta * firstOutputT
                    // ── Timeline log: display reserve ──────────────────────────────
                    do {
                        let isConsecutive = abs(delta - sourcePeriod) < 1e-4
                        let isDoubleGap = abs(delta - 2 * sourcePeriod) < 1e-3
                        let nPlusOnePTS = first.pts + sourcePeriod
                        let hasNPlusOne = pool.frames.contains { abs($0.pts - nPlusOnePTS) < 1e-3 }
                        // Tolerance-based lookup: find timeline entry closest to nPlusOnePTS within 2ms
                        var nPlusOneTL: FrameTimeline?
                        for (_, entry) in frameTimelines where abs(entry.pts - nPlusOnePTS) < 0.002 {
                            if nPlusOneTL == nil || abs(entry.pts - nPlusOnePTS) < abs(nPlusOneTL!.pts - nPlusOnePTS) {
                                nPlusOneTL = entry
                            }
                        }
                        let nPlusOnePoolAddMS = nPlusOneTL.map { Double($0.poolAddNS) / 1_000_000.0 } ?? -1
                        let nPlusOneDecodeEndMS = nPlusOneTL.map { Double($0.decodeEndNS) / 1_000_000.0 } ?? -1
                        let firstKey = RiftPlayerState.timelineKey(first.pts)
                        let firstTL = frameTimelines[firstKey]
                        let firstDecodeMS = firstTL.map { Double($0.decodeEndNS) / 1_000_000.0 } ?? -1
                        let firstPoolAddMS = firstTL.map { Double($0.poolAddNS) / 1_000_000.0 } ?? -1
                        let secondKey = RiftPlayerState.timelineKey(second.pts)
                        let secondTL = frameTimelines[secondKey]
                        let secondDecodeMS = secondTL.map { Double($0.decodeEndNS) / 1_000_000.0 } ?? -1
                        let secondPoolAddMS = secondTL.map { Double($0.poolAddNS) / 1_000_000.0 } ?? -1
                        let reserveMS = Double(tAfterReserve) / 1_000_000.0
                        let poolN = pool.count
                        let gapType = isDoubleGap ? "2x" : (isConsecutive ? "1x" : "other")
                        let n1FoundPTS = nPlusOneTL.map { String(format: "%.3f", $0.pts) } ?? "n/a"
                        RiftPlayerState.writeTimelineLog(String(format:
                            "[RIFT-TL-RESERVE] id=%d reserveMS=%.1f first=%.3f sec=%.3f delta=%.4f gap=%@ poolN=%d firstDec=%.1f firstPool=%.1f secDec=%.1f secPool=%.1f n1Has=%d n1FoundPTS=%@ n1PoolAdd=%.1f n1DecEnd=%.1f",
                            interpInvocationID, reserveMS, first.pts, second.pts, delta, gapType, poolN,
                            firstDecodeMS, firstPoolAddMS, secondDecodeMS, secondPoolAddMS,
                            hasNPlusOne ? 1 : 0, n1FoundPTS, nPlusOnePoolAddMS, nPlusOneDecodeEndMS))
                    }

                    await self.paceInterpPair(firstPTS: first.pts, lead: self.interpLeadMargin)
                    let tAfterPace = DispatchTime.now().uptimeNanoseconds
                    let stagePaceMS = Double(tAfterPace - tAfterReserve) / 1_000_000.0
                    if Task.isCancelled { break }
                    // Equivalente de Fijación C en la rama interpolada: si el
                    // primer sample visible del par quedó obsoleto, descartarlo en
                    // vez de interpolar y presentarlo tarde.
                    let clkPace = sched.synchronizer.currentTime().seconds
                    if firstOutputPTS + self.interpBehindMargin < clkPace {
                        self.interpolationStaleDrops += 1
                        let staleDeltaMS = (clkPace - (firstOutputPTS + self.interpBehindMargin)) * 1000.0
                        RiftPlayerState.writeNegPTSLog(String(format: "[RIFT-STALE] id=%d pair=(%.3f,%.3f) firstOut=%.3f clock=%.3f behindMargin=%.3f staleDelta=%.1fms poolN=%d prevPTS=%.3f",
                            interpInvocationID, first.pts, second.pts,
                            firstOutputPTS, clkPace, self.interpBehindMargin, staleDeltaMS,
                            pool.count, lastEmittedPTS))
                        pool.consumePair()
                        await self.coordinator.signal()
                        // Stale pair consumed without emitting anything:
                        // reset flag so gapFallback doesn't incorrectly skip.
                        prevPairEmittedSecondSource = false
                        continue
                    }

                    // Par con hueco (decode rezagado ≥2 frames de origen): NO
                    // interpolar a través del hueco. El mid fabricado a mitad del
                    // gap no corresponde a ningún instante real, y si el frame
                    // perdido llega después se interpola TAMBIÉN el par contiguo
                    // (duplica el mismo pts real y encola un mid en PTS menor que
                    // el second anterior → grilla no-monótona, brincos). En su
                    // lugar se presenta `first` nativo y se avanza; el siguiente
                    // par contiguo retoma la interpolación sin duplicar contenido.
                    if second.pts - first.pts > 1.5 * sourcePeriod {
                        // HEVC puede entregar primero los frames de referencia
                        // futuros y después sus B-frames. Mientras el pool tenga
                        // cupo, esperar su pequeña ventana de reordenamiento evita
                        // publicar ese futuro y volver obsoletos los frames que
                        // llegan a continuación. Un hueco que persiste con el pool
                        // lleno sí usa el fallback de abajo.
                        if pool.count < pool.capacity {
                            try? await Task.sleep(nanoseconds: 1_000_000)
                            continue
                        }
                        // If previous iteration already emitted `second` as
                        // SOURCE (via interpOutputs), then `first` here is
                        // the same frame — skip to avoid duplicate PTS.
                        if prevPairEmittedSecondSource {
                        pool.consumePair()
                        // --- GAP-POOL: snapshot del pool DESPUÉS del consumePair ---
                        let poolPtsAfter = pool.frames.map { String(format: "%.3f", $0.pts) }.joined(separator: ",")
                        let nPlusOnePTS2 = first.pts + sourcePeriod
                        let hasNPlusOneAfter = pool.frames.contains { abs($0.pts - nPlusOnePTS2) < 1e-4 }
                        RiftPlayerState.writeNegPTSLog(String(format: "[RIFT-GAP-AFTER] id=%d poolAfter=[%@] hasN1After=%d(%.3f) poolNAfter=%d",
                            interpInvocationID, poolPtsAfter,
                            hasNPlusOneAfter ? 1 : 0, nPlusOnePTS2, pool.count))
                        await self.coordinator.signal()
                            prevPairEmittedSecondSource = false
                            continue
                        }
                        // --- GAP-POOL: snapshot del pool ANTES del fallback ---
                        let poolPtsStr = pool.frames.map { String(format: "%.3f", $0.pts) }.joined(separator: ",")
                        let poolDelta = second.pts - first.pts
                        let nPlusOnePTS = first.pts + sourcePeriod
                        let hasNPlusOne = pool.frames.contains { abs($0.pts - nPlusOnePTS) < 1e-3 }
                        let nPlusTwoPTS = first.pts + 2 * sourcePeriod
                        let hasNPlusTwo = pool.frames.contains { abs($0.pts - nPlusTwoPTS) < 1e-4 }
                        RiftPlayerState.writeNegPTSLog(String(format: "[RIFT-GAP-POOL] id=%d first=%.3f second=%.3f delta=%.3fs pool=[%@] hasN1=%d(%.3f) hasN2=%d(%.3f) prevPTS=%.3f gapFallbackPTS=%.3f poolN=%d",
                            interpInvocationID, first.pts, second.pts, poolDelta,
                            poolPtsStr,
                            hasNPlusOne ? 1 : 0, nPlusOnePTS,
                            hasNPlusTwo ? 1 : 0, nPlusTwoPTS,
                            previousEnqueuedPTS, first.pts, pool.count))
                        if first.pts <= previousEnqueuedPTS + 0.000_001 {
                            RiftPlayerState.writeNegPTSLog(String(format:
                                "[RIFT-STALE-GAP] id=%d first=%.3f prevPTS=%.3f",
                                interpInvocationID, first.pts, previousEnqueuedPTS))
                            pool.consumePair()
                            await self.coordinator.signal()
                            prevPairEmittedSecondSource = false
                            continue
                        }
                        let pts = CMTime(seconds: first.pts, preferredTimescale: 1200)
                        let gridStep = uniformCadence ? (sourcePeriod * 0.4) : (second.pts - first.pts)
                        let dur = CMTime(seconds: gridStep, preferredTimescale: 1200)
                        rend.pendingOrigin = "gapFallback"; rend.pendingType = "SOURCE"
                        if let sbuf = rend.sampleBuffer(from: first.pixelBuffer, pts: pts, duration: dur) {
                            rend.enqueue(sbuf)
                            self.enqueuedFramesInWindow += 1
                            // --- DIAGNOSTIC: gapFallback enqueue ---
                            let diagLine = String(format: "[RIFT-GAP] id=%d pair=(%.3f,%.3f) enqueued=%.3f poolN=%d prev=%.3f",
                                interpInvocationID, first.pts, second.pts, first.pts, pool.count, previousEnqueuedPTS)
                            RiftPlayerState.writeNegPTSLog(diagLine)
                            if first.pts < previousEnqueuedPTS && previousEnqueuedPTS >= 0 {
                                let delta = first.pts - previousEnqueuedPTS
                                let marker = String(format: "[RIFT-NEGATIVE-PTS] id=%d prevId=%d prev=%.3f curr=%.3f delta=%.6f src=gapFallback first=%.3f second=%.3f poolN=%d",
                                    interpInvocationID, lastEnqueuedInvocationID,
                                    previousEnqueuedPTS, first.pts, delta, first.pts, second.pts,
                                    pool.count)
                                RiftPlayerState.writeNegPTSLog(marker)
                                os_log("RIFT-NEGATIVE-PTS via gapFallback: id=%d prevId=%d prev=%.3f curr=%.3f delta=%.6f", interpInvocationID, lastEnqueuedInvocationID, previousEnqueuedPTS, first.pts, delta)
                            }
                            previousEnqueuedPTS = first.pts
                            lastEnqueuedInvocationID = interpInvocationID
                        }
                        pool.consumePair()
                        await self.coordinator.signal()
                        prevPairEmittedSecondSource = false
                        continue
                    }

                    // Patrón de salida según el modo del scheduler:
                    //   .interpolated48 → 1 interp/par (t=0.5)           → 24→48
                    //   .interpolated60 → 3:2: [0.5] en pares pares,      → 24→60
                    //                    [1/3,2/3] en pares impares
                    // Cadencia uniforme (default en .interpolated60, soap-opera):
                    // 60fps sale cada 16.67ms con t transversal — 0.4/0.8 en el
                    // par par, 0.2/0.6 en el impar — en vez de las duraciones
                    // 20.8/13.9 alternantes de la 3:2 (judder de telecine).
                    // Revertir a 3:2 para A/B: RIFT_CADENCE=telecine.
                    interpPairIndex += 1
                    let tValues: [Float]
                    switch sched.mode {
                    case .interpolated60 where uniformCadence:
                        // Grid 60Hz uniforme (16.67ms = delta/2.5): par par [A,
                        // 0.4, 0.8] a A+{0, .4*, .8*delta}; par impar [0.2, 0.6]
                        // + B a A+{0.2, .6, 1.0}*delta del par (50/66.67/83.33).
                        // La fase transversal evita las duraciones 20.8/13.9
                        // alternantes de la 3:2 (judder).
                        tValues = pairIsEven ? [0.4, 0.8] : [0.2, 0.6]
                    case .interpolated60:
                        tValues = pairIsEven ? [0.5] : [1.0/3.0, 2.0/3.0]
                    default: // .interpolated48
                        tValues = [0.5]
                    }

                    let result = await self.interpolatePair(i0: first, i1: second, tValues: tValues)
                    let tAfterInterp = DispatchTime.now().uptimeNanoseconds
                    let stageInterpMS = Double(tAfterInterp - tAfterPace) / 1_000_000.0
                    let interpBuffers = result.buffers.buffers

                    // Construir la secuencia ordenada de salida del par.
                    var outputs: [(pts: Double, isInterp: Bool, pb: CVPixelBuffer)] = []
                    if uniform60 {
                        // Cadencia uniforme 60Hz: cada salida cae en el grid de
                        // 16.67ms. El frame real central (B) de cada par par NO
                        // cae sobre el grid (41.67 vs 0/16.67/33.33/50...) y se
                        // sustituye por las interpolaciones que lo flanquean:
                        //   par par   (A,B): [A?, M0.4@16.67, M0.8@33.33]   (sin B)
                        //   par impar (B,C): [M0.2@50, M0.6@66.67, C@83.33] (sin I0)
                        // Deltas consecutivos = 16.67 uniforme (sin judder).
                        if result.totalMS > 0 || !interpBuffers.isEmpty || hasPresentedInterpolatedStart {
                            if pairIsEven {
                                if !hasPresentedInterpolatedStart {
                                    outputs.append((first.pts, false, first.pixelBuffer))
                                }
                                for (idx, interpBuf) in interpBuffers.enumerated() where idx < tValues.count {
                                    outputs.append((first.pts + delta * Double(tValues[idx]), true, interpBuf))
                                }
                            } else {
                                for (idx, interpBuf) in interpBuffers.enumerated() where idx < tValues.count {
                                    outputs.append((first.pts + delta * Double(tValues[idx]), true, interpBuf))
                                }
                                outputs.append((second.pts, false, second.pixelBuffer))
                            }
                        }
                        // Fallback: interpolación devolvió nada (fallback interno)
                        // → presentar I0 nativo en vez de quedarse sin frame.
                        if outputs.isEmpty {
                            outputs.append((first.pts, false, first.pixelBuffer))
                        }
                    } else if result.totalMS > 0 || !interpBuffers.isEmpty || hasPresentedInterpolatedStart {
                        // Real I0 (solo si aún no se presentó el arranque interpolado)
                        if !hasPresentedInterpolatedStart {
                            outputs.append((first.pts, false, first.pixelBuffer))
                        }
                        // Interpolados en sus t correspondientes
                        for (idx, interpBuf) in interpBuffers.enumerated() where idx < tValues.count {
                            outputs.append((first.pts + delta * Double(tValues[idx]), true, interpBuf))
                        }
                        // Real I1
                        outputs.append((second.pts, false, second.pixelBuffer))
                    }

                    // --- INVOCATION ENTRY LOG ---
                    let tEnqueueStart = DispatchTime.now().uptimeNanoseconds
                    RiftPlayerState.writeNegPTSLog(String(format: "[RIFT-ENQ-START] id=%d pair=(%.3f,%.3f) even=%d outN=%d poolN=%d entryMsAgo=%.1f",
                        interpInvocationID, first.pts, second.pts, pairIsEven ? 1 : 0,
                        outputs.count, pool.count,
                        Double(tEnqueueStart - interpEntryTime) / 1_000_000.0))
                    // --- GAP CORRELATION: reset per-invocation enqueue counters ---
                    invEnqueueWaitNS = 0
                    invEnqueueCalls = 0
                    invEnqueueNotReady = 0

                    // AVSampleBufferDisplayLayer cannot repair samples that
                    // arrive behind its active timeline. A repeated/gapped pair
                    // can otherwise make an old synthetic buffer visible after
                    // a newer source frame. Keep the presentation queue strictly
                    // monotonic; the next valid pair fills the cadence.
                    if previousEnqueuedPTS >= 0 {
                        let beforeCount = outputs.count
                        outputs.removeAll { $0.pts <= previousEnqueuedPTS + 0.000_001 }
                        if outputs.count != beforeCount {
                            RiftPlayerState.writeNegPTSLog(String(format:
                                "[RIFT-STALE-OUTPUT] id=%d removed=%d prevPTS=%.3f",
                                interpInvocationID, beforeCount - outputs.count, previousEnqueuedPTS))
                        }
                    }

                    // Encolar con duración = intervalo hasta el siguiente pts.
                    for i in 0..<outputs.count {
                        let o = outputs[i]
                        let pts = CMTime(seconds: o.pts, preferredTimescale: 1200)
                        let endPTS: Double
                        if i + 1 < outputs.count {
                            endPTS = outputs[i + 1].pts
                        } else if uniform60 {
                            // El siguiente frame del grid está a 0.4*delta
                            // (16.67ms), no a delta/3 como en la 3:2.
                            endPTS = o.pts + delta * 0.4
                        } else {
                            endPTS = o.pts + delta / Double(max(tValues.count + 1, 2))
                        }
                        let dur = CMTime(seconds: endPTS - o.pts, preferredTimescale: 1200)
                        rend.pendingOrigin = "interpOutputs"; rend.pendingType = o.isInterp ? "INTERP" : "SOURCE"
                        if let sbuf = rend.sampleBuffer(from: o.pb, pts: pts, duration: dur) {
                            let clockAtEnqueue = sched.synchronizer.currentTime().seconds
                            if Self.forceDisplayImmediateOnInterpolated || o.pts <= clockAtEnqueue {
                                self.markDisplayImmediately(sbuf)
                            }
                            self.framesRequestedForEnqueue += 1
                            let wasReadyBefore = rend.displayLayer.isReadyForMoreMediaData
                            let tBeforeEnq = DispatchTime.now().uptimeNanoseconds
                            await self.enqueuePaced(rend, sbuf)
                            let tAfterEnq = DispatchTime.now().uptimeNanoseconds
                            invEnqueueWaitNS += (tAfterEnq - tBeforeEnq)
                            invEnqueueCalls += 1
                            if !wasReadyBefore { invEnqueueNotReady += 1 }
                            // --- DIAGNOSTIC: interpOutputs enqueue ---
                            let diagLine = String(format: "[RIFT-INTERP] id=%d out[%d/%d] pts=%.3f type=%@ pair=(%.3f,%.3f) t=%.2f poolN=%d prev=%.3f",
                                interpInvocationID, i, outputs.count, o.pts, o.isInterp ? "INTERP" : "SOURCE",
                                first.pts, second.pts, tValues.count > i ? Double(tValues[i]) : 0,
                                pool.count, previousEnqueuedPTS)
                            RiftPlayerState.writeNegPTSLog(diagLine)
                            if o.pts < previousEnqueuedPTS && previousEnqueuedPTS >= 0 {
                                let delta = o.pts - previousEnqueuedPTS
                                let marker = String(format: "[RIFT-NEGATIVE-PTS] id=%d prevId=%d prev=%.3f curr=%.3f delta=%.6f src=interpOutputs outIdx=%d/%d type=%@ first=%.3f second=%.3f t=%.2f poolN=%d",
                                    interpInvocationID, lastEnqueuedInvocationID,
                                    previousEnqueuedPTS, o.pts, delta, i, outputs.count,
                                    o.isInterp ? "INTERP" : "SOURCE", first.pts, second.pts,
                                    tValues.count > i ? Double(tValues[i]) : 0,
                                    pool.count)
                                RiftPlayerState.writeNegPTSLog(marker)
                                os_log("RIFT-NEGATIVE-PTS via interpOutputs: id=%d prevId=%d prev=%.3f curr=%.3f delta=%.6f out[%d/%d]", interpInvocationID, lastEnqueuedInvocationID, previousEnqueuedPTS, o.pts, delta, i, outputs.count)
                            }
                            previousEnqueuedPTS = o.pts
                            lastEnqueuedInvocationID = interpInvocationID
                        }
                    }
                    // --- GAP CORRELATION: detect gaps >50ms ---
                    if !outputs.isEmpty {
                        let firstOutPTS = outputs[0].pts
                        if lastEmittedPTS >= 0 {
                            let gapMS = (firstOutPTS - lastEmittedPTS) * 1000.0
                            if gapMS > 50.0 {
                                let enqWaitMS = Double(invEnqueueWaitNS) / 1_000_000.0
                                let skipCount = interpInvocationID > lastEmittedID ? interpInvocationID - lastEmittedID : 0
                                RiftPlayerState.writeNegPTSLog(String(format: "[RIFT-GAP-EVENT] id=%d prevId=%d pair=(%.3f,%.3f) prevPTS=%.3f nextPTS=%.3f gap=%.1fms paceMS=%.1f interpMS=%.1f enqLoopMS=%.1f enqWaitMS=%.1f enqCalls=%d enqNotReady=%d clock=%.3f margin=%.3f poolN=%d skip=%d",
                                    interpInvocationID, lastEmittedID,
                                    first.pts, second.pts,
                                    lastEmittedPTS, firstOutPTS, gapMS,
                                    stagePaceMS, stageInterpMS, stageEnqueueLoopMS,
                                    enqWaitMS, invEnqueueCalls, invEnqueueNotReady,
                                    clkPace, self.interpBehindMargin,
                                    pool.count, skipCount))
                            }
                        }
                        lastEmittedPTS = outputs[outputs.count - 1].pts
                        lastEmittedID = interpInvocationID
                    }
                    let tAfterEnqueueLoop = DispatchTime.now().uptimeNanoseconds
                    let stageEnqueueLoopMS = Double(tAfterEnqueueLoop - tAfterInterp) / 1_000_000.0
                    self.accumulateStageTimes(reserveMS: stageReserveMS, paceMS: stagePaceMS, interpMS: stageInterpMS, enqueueLoopMS: stageEnqueueLoopMS)
                    // Diagnostic: sample isReady state every iteration.
                    self.sampleReadyState(rend)
                    if hasPresentedInterpolatedStart == false, !outputs.isEmpty {
                        hasPresentedInterpolatedStart = true
                    }
                    // Track whether `second` was emitted as SOURCE so the
                    // next iteration's gapFallback knows to skip it.
                    prevPairEmittedSecondSource = outputs.contains { !$0.isInterp && abs($0.pts - second.pts) < 1e-6 }
                    // Conteo diagnóstico 1-vs-2 interps por par.
                    if tValues.count == 1 {
                        interpSinglePairCount += 1
                    } else {
                        interpDoublePairCount += 1
                    }
                    pool.consumePair()
                    // Déficit de throughput sostenido (pares/s < realtime) → fallback.
                    self.notePairCompleted()
                    await self.coordinator.signal()
                }
                let workEnd = DispatchTime.now().uptimeNanoseconds
                let frameTimeMs = Double(workEnd - workStart) / 1_000_000
                benchSamples.append(frameTimeMs)
                if benchSamples.count >= 60 {
                    let avg = benchSamples.reduce(0, +) / Double(benchSamples.count)
                    let sorted = benchSamples.sorted()
                    let p99 = sorted[Int(Double(sorted.count - 1) * 0.99)]
                    os_log("DisplayLoop baseline: avg=%.2fms p99=%.2fms samples=%d", log: benchLog, type: .info, avg, p99, benchSamples.count)
                    benchSamples.removeAll()
                    os_log("Interp3to2: pairsSingle=%d pairsDouble=%d (esperado ~1:1 en .interpolated60)", log: benchLog, type: .info, self.interpSinglePairCount, self.interpDoublePairCount)
                    let diag = rend.enqueueDiagnostics()
                    os_log("Render diag: %{public}@ burstDropped=%d", log: benchLog, type: .info, diag, self.interpBurstDropped)
                    rend.resetDiagnostics()
                }
                if Task.isCancelled { break }

            }
        }
    }

}
