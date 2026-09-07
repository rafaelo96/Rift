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
    /// If Frame+ was disabled by sustained fallback, allow re-attempt
    /// after a user-initiated seek or mode change.
    private var fallbackDisabled = false
    /// Number of interpolated pairs to skip before the budget gate activates.
    private let interpolationWarmupPairs = 5
    /// Moving-average window for the budget gate (post-warmup).
    private let interpolationTimingWindow = 10

    // MARK: - Throughput deficit gate (pairs/s measurement)
    /// Seconds of pair-completion timestamps kept for the sliding window.
    private let throughputWindowSeconds = 3.0
    /// Minimum pairs/s to consider the pipeline keeping up with realtime.
    /// Expressed as fraction of source framerate: 0.95× ≈ 22.8 pairs/s for 24fps.
    /// Triggers only after `throughputRequiredWeakWindows` consecutive evaluations.
    private let throughputMinRatio = 0.95
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
    /// Wall-clock timestamps of recently completed pair iterations.
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
    var displayLayer: AVSampleBufferDisplayLayer? { renderer?.displayLayer }
    var player: AVPlayer? { nil }
    private var videoTrack: TrackInfo?
    private var audioTrack: TrackInfo?
    private var audioTrackInfos: [Int: TrackInfo] = [:]
    private var audioDecoder: AudioDecoder?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var sourceFrameRate: Double?
    private let coordinator = DecodeCoordinator(value: 4)
    /// Fijación B: presupuesto de decode por delante del reloj de presentación
    /// (segundos). El decode no produce frames cuyo pts supere `reloj + budget`;
    /// sin esto el pool (ventana de 4 frames con eviction) corre por delante de la
    /// presentación sin límite y los toggles de modo provocan ráfagas/saltos.
    /// Tunable vía RIFT_DECODE_AHEAD_BUDGET para validación en distintos chips.
    private let decodeAheadBudget: Double
    private var totalDecoded = 0
    private var decodeTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var consumerTimer: Timer?
    private var currentTimeTimer: Timer?
    private var fpsTimer: Timer?
    private var enqueuedFramesInWindow: Int = 0
    private var fpsWindowStart: DispatchTime = .now()
    private var sourceURL: URL?
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
        fallbackDisabled = false
        interpPairIndex = 0
        interpSinglePairCount = 0
        interpDoublePairCount = 0
        // Throughput gate: clean slate for the new evaluation window.
        pairCompletionTimes = []
        weakThroughputWindows = 0
        lastThroughputEval = 0
        firstPairCompletedAt = 0
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
    /// Mide pares/s sostenidos; si cae por debajo del umbral durante
    /// `throughputRequiredWeakWindows` evaluaciones consecutivas, desactiva
    /// la interpolación para evitar drift A/V acumulativo.
    private func notePairCompleted() {
        let now = DispatchTime.now().uptimeNanoseconds
        if firstPairCompletedAt == 0 { firstPairCompletedAt = now }
        pairCompletionTimes.append(now)
        let cutoff = now - UInt64(throughputWindowSeconds * 1e9)
        pairCompletionTimes.removeAll { $0 < cutoff }

        // Evaluar solo después del warm-up, de los pares de arranque y de que la
        // ventana tenga datos.
        guard interpolationPairCount > interpolationWarmupPairs,
              now - lastThroughputEval >= UInt64(throughputWindowSeconds * 1e9) else { return }
        lastThroughputEval = now

        let windowStart = pairCompletionTimes.first ?? now
        let span = Double(now - windowStart) / 1e9
        guard span >= 1.0 else { return }
        let pps = Double(pairCompletionTimes.count) / span
        let realtimeRate = sourceFrameRate ?? 24.0
        let minPPS = realtimeRate * throughputMinRatio

        // No armar el gate durante la rampa de arranque del pipeline (decoder/
        // shaders/fill): medir ahí pares/s bajos es ruido, no un déficit real.
        let elapsedSinceFirst = Double(now - firstPairCompletedAt) / 1e9
        guard elapsedSinceFirst >= throughputSkipStartupSeconds else { return }

        os_log("Throughput: %.1f pares/s (mín %.1f, ventana %.1fs, weak %d/%d)",
               log: benchLog, type: .info, pps, minPPS, span,
               weakThroughputWindows, throughputRequiredWeakWindows)

        if pps < minPPS {
            weakThroughputWindows += 1
        } else {
            weakThroughputWindows = 0
        }
        if weakThroughputWindows >= throughputRequiredWeakWindows {
            weakThroughputWindows = 0
            disableInterpolation(reason: String(format: "throughput sostenido %.1f pares/s < %.1f (realtime)",
                                               pps, minPPS))
        }
    }

    // MARK: - Test harness (headless GUI-channel validation)
    // RIFT_AUTO_OPEN=<file> opens a video at launch; RIFT_AUTO_MODE=<mode>
    // force-activates an interpolation mode. Inert without the env vars.
    // RIFT_AUTO_SEEK_AT=<secs> + RIFT_AUTO_SEEK_TO=<secs> schedule a seek()
    // that many seconds after launch (used to validate rearmFallbackInterpolation
    // after a fallback). RIFT_AUTO_REOPEN=<file> + RIFT_AUTO_REOPEN_AT=<secs>
    // schedule a loadVideo() to validate the same rearm on file change.
    // Permite verificar el pipeline de reproducción/interpolación sin interacción
    // GUI (NSOpenPanel no funciona en corridas headless — ver AGENTS.md).
    init() {
        decodeAheadBudget = ProcessInfo.processInfo.environment["RIFT_DECODE_AHEAD_BUDGET"].flatMap(Double.init) ?? 1.0
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RIFT_AUTO_OPEN"], !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        let seekAt = env["RIFT_AUTO_SEEK_AT"].flatMap(Double.init)
        let seekTo = env["RIFT_AUTO_SEEK_TO"].flatMap(Double.init)
        let reopenAt = env["RIFT_AUTO_REOPEN_AT"].flatMap(Double.init)
        let reopenURL = env["RIFT_AUTO_REOPEN"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            print("RIFT_AUTO_OPEN → loadVideo \(url.lastPathComponent)")
            self.loadVideo(url)
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
        audioTask?.cancel()
        currentTime = time
        // Actualizar el subtítulo de inmediato (los cues ya están todos en
        // memoria desde el inicio, no hace falta releer ni reiniciar ningún loop).
        updateActiveSubtitle(at: time)
        try? demuxer?.seek(to: time); decoder?.flush(); framePool?.flush()
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
        // Reintento: si Frame+ había caído por fallback y el usuario hace seek,
        // volver a armarlo (el seek libera el pipeline; si sigue lento, caerá de nuevo).
        rearmFallbackInterpolation()
        resetInterpolationCounters()
        if let url = sourceURL, let aTrack = audioTrack {
            startAudioLoop(url: url, trackStreamIndex: aTrack.streamIndex, codecName: aTrack.codecName, startTime: time, extradata: aTrack.codecExtradata, sampleRate: aTrack.sampleRate ?? 0, channels: aTrack.channelCount ?? 0)
        }
        // Tras el flush, el pool vacío puede dejar al decodeLoop bloqueado en
        // wait() sin nadie que lo despierte (displayLoop no señaliza sin
        // frames). Restaurar el cupo del semáforo señalando explícitamente.
        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<4 { await self.coordinator.signal() }
        }
    }
    func seek(by delta: Double) { seek(to: currentTime + delta) }
    func setVolume(_ v: Double) { volume = v }
    func cyclePlaybackRate() {}
    func closeVideo() {
        decodeTask?.cancel(); decodeTask = nil
        audioTask?.cancel(); audioTask = nil
        displayTask?.cancel(); displayTask = nil
        consumerTimer?.invalidate(); consumerTimer = nil
        currentTimeTimer?.invalidate(); currentTimeTimer = nil
        fpsTimer?.invalidate(); fpsTimer = nil
        if let sched = scheduler {
            sched.synchronizer.setRate(0, time: .zero)
        }
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
        hasVideo = false; isPlaying = false
    }
    func startHideTimer() {}
    func stopHideTimer() {}
    func resetHideTimer() {}
    func formattedTime(_ s: Double) -> String { let i = Int(s); return String(format: "%d:%02d", i/60, i%60) }
    func setInterpolationMode(_ m: InterpolationMode) {
        interpolationMode = m
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
    func toggleVisualEnhancements() { visualEnhancementsEnabled.toggle() }

    func loadVideo(_ url: URL) {
        audioTask?.cancel()
        sourceURL = url
        statusMessage = "Opening \(url.lastPathComponent)..."
        conversionProgress = 0.1
        hasVideo = false
        rearmFallbackInterpolation()
        resetInterpolationCounters()
        // Limpiar log de diagnóstico audio por corrida (no append).
        try? FileManager.default.removeItem(atPath: "/tmp/rift_audio.log")
        Task.detached(priority: .userInitiated) { [weak self] in
            let d = FFmpegDemuxer()
            do {
                let info = try d.open(url: url)
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
                    await self.installNewPipeline(demuxer: d, decoder: dec, videoTrack: v, info: info, subTrack: subTrack, url: url)
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
    private func installNewPipeline(demuxer d: FFmpegDemuxer, decoder dec: VTDecoder, videoTrack v: TrackInfo, info: ContainerInfo, subTrack: TrackInfo?, url: URL) async {
        self.decodeTask?.cancel()
        await self.coordinator.reset()
        self.framePool?.flush()
        self.decodeTask = nil
        self.demuxer = d
        self.decoder = dec
        self.videoTrack = v
        self.duration = info.duration
        self.sourceFrameRate = v.frameRate
        self.framePool = SlidingFramePool(capacity: 4)
        self.scheduler = FrameScheduler(mode: .native24)
        self.syncSchedulerMode()
        self.timingLogStart = DispatchTime.now().uptimeNanoseconds
        self.subtitleTrack = subTrack
        self.subtitleCues = []
        // CLAVE: sin esto el synchronizer retrasa el arranque del
        // reloj hasta tener preroll suficiente en TODOS los renderers,
        // y con buffers de 32ms el audio se atasca (isReady=false
        // perpetuo) sin llegar nunca a reproducir.
        self.scheduler?.synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        // Video y audio comparten el MISMO synchronizer para
        // reproducirse en sync (el displayLayer y el audioRenderer
        // viven en el reloj del scheduler).
        self.renderer = HDRDisplayRenderer(synchronizer: self.scheduler?.synchronizer)
        // Audio: guardar todas las pistas reales y arrancar la primera.
        let audioTracksAll = info.tracks.filter { $0.kind == .audio }
        self.audioTrackInfos = Dictionary(uniqueKeysWithValues: audioTracksAll.map { ($0.streamIndex, $0) })
        if let aTrack = audioTracksAll.first {
            self.audioTrack = aTrack
            self.selectedAudioTrackIndex = aTrack.streamIndex
            let ar = AVSampleBufferAudioRenderer()
            ar.volume = 1.0
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
        self.startDecodeLoop()
        // Subtítulos: cargar la primera pista en background (paralelo
        // al video) vía cache, sin bloquear el primer frame.
        if let subTrack {
            self.ensureSubtitleCues(url: url, streamIndex: subTrack.streamIndex) {
                self.subtitleCues = self.subtitleCueCache[subTrack.streamIndex] ?? []
                self.updateActiveSubtitle(at: self.currentTime)
            }
        }
    }

    func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.movie, UTType.video, UTType(filenameExtension: "mkv") ?? .data, UTType(filenameExtension: "mka") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadVideo(url) }
    }
    func cleanup() { closeVideo() }

    // MARK: - 3a: Decode + FramePool con backpressure real + consumidor simulado
    private var displayTask: Task<Void, Never>?
    private var firstPts: Double?

    // MARK: - 3a/3b: Decode + FramePool con backpressure real
    private func startDecodeLoop() {
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
                guard let pkt = try? d.nextPacket() else {
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
                guard let pb = try? dec.decodeFrame(pkt) else {
                    await self.coordinator.signal()
                    continue
                }
                decoded += 1
                await MainActor.run {
                    self.totalDecoded = decoded
                    pool.add(buffer: pb, pts: pkt.pts)
                    if decoded == 1 {
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
        let maxAheadSeconds = 0.25
        audioTask = Task.detached(priority: .userInitiated) {
            let audioDemuxer = FFmpegDemuxer()
            defer { audioDemuxer.close() }

            do {
                _ = try audioDemuxer.open(url: url)
                if startPTS > 0 {
                    try? audioDemuxer.seek(to: startPTS)
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
                        let presentationPTS = packet.pts + accumulatedSeconds
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
                compensator = try await Task.detached(priority: .userInitiated) {
                    try MotionCompensator(config: .default)
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

        // Presupuesto por-frame interpolado, independiente del tipo de par.
        // Un par "doble" (2 interp) hace ~2× el trabajo de un par simple, así
        // que normalizamos la muestra por nº de frames interpolados: esto le da
        // a los pares dobles un presupuesto efectivo ~2× sin contaminar la media
        // móvil (si mezcláramos costes totales de pares simples y dobles en la
        // misma serie, la media falsearía el gate).
        let frameBudgetMS = 1_000.0 / max(sourceFrameRate ?? 24.0, 24.0)
        let budgetThreshold = frameBudgetMS * 0.90
        let perFrameCost = measured.totalMS / Double(max(tValues.count, 1))

        if interpolationPairCount <= interpolationWarmupPairs {
            os_log("interpolatePair [warm-up %d/%d, %d interp]: %.1fms pair / %.1fms per-frame (ME: %.1f Warp: %.1f)",
                   log: benchLog, type: .info,
                   interpolationPairCount, interpolationWarmupPairs, tValues.count,
                   measured.totalMS, perFrameCost, measured.meMS, measured.warpMS)
        } else {
            recentPairTimings.append(perFrameCost)
            if recentPairTimings.count > interpolationTimingWindow {
                recentPairTimings.removeFirst()
            }
            let avg = recentPairTimings.reduce(0, +) / Double(recentPairTimings.count)
            os_log("interpolatePair [%d/%d avg %.1fms/frame, %d interp]: %.1fms pair / %.1fms per-frame (ME: %.1f Warp: %.1f)",
                   log: benchLog, type: .info,
                   recentPairTimings.count, interpolationTimingWindow, avg, tValues.count,
                   measured.totalMS, perFrameCost, measured.meMS, measured.warpMS)
            if avg > budgetThreshold {
                disableInterpolation(reason: String(format: "coste medio %.1fms/frame > presupuesto %.1fms", avg, budgetThreshold))
                return (buffers: InterpolatedBuffersBox(buffers: []), totalMS: 0, meMS: 0, warpMS: 0)
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
        if let raw = ProcessInfo.processInfo.environment["RIFT_AUTO_MODE"],
           let m = InterpolationMode(rawValue: raw), m != .disabled, interpolationMode == .disabled {
            os_log("RIFT_AUTO_MODE=%{public}@ → activando interpolación", log: benchLog, type: .info, raw)
            self.setInterpolationMode(m)
        }
        if let sched = scheduler, sched.synchronizer.rate == 0 {
            sched.synchronizer.setRate(1.0, time: CMTime(seconds: currentTime, preferredTimescale: 600), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var hasPresentedInterpolatedStart = false
            while true {
                if Task.isCancelled { break }
                guard let pool = self.framePool, let rend = self.renderer, let sched = self.scheduler else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
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
                        let pts = CMTime(seconds: f.pts, preferredTimescale: 600)
                        let dur = CMTime(seconds: 1.0 / 24.0, preferredTimescale: 600)
                        if let sbuf = rend.sampleBuffer(from: f.pixelBuffer, pts: pts, duration: dur) {
                            if f.pts - clkN <= aheadMargin {
                                self.markDisplayImmediately(sbuf)
                            }
                            rend.displayLayer.enqueue(sbuf)
                            self.enqueuedFramesInWindow += 1
                        }
                    }
                } else {
                    guard let pair = pool.reservePair() else {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        continue
                    }
                    let first = pair.0
                    let second = pair.1
                    let delta = max(second.pts - first.pts, 1.0 / 24.0)

                    // Patrón de salida según el modo del scheduler:
                    //   .interpolated48 → 1 interp/par (t=0.5)           → 24→48
                    //   .interpolated60 → 3:2: [0.5] en pares pares,      → 24→60
                    //                    [1/3,2/3] en pares impares
                    let tValues: [Float]
                    switch sched.mode {
                    case .interpolated60:
                        tValues = (interpPairIndex % 2 == 0) ? [0.5] : [1.0/3.0, 2.0/3.0]
                    default: // .interpolated48
                        tValues = [0.5]
                    }
                    interpPairIndex += 1

                    let result = await self.interpolatePair(i0: first, i1: second, tValues: tValues)
                    let interpBuffers = result.buffers.buffers

                    // Construir la secuencia ordenada de salida del par.
                    var outputs: [(pts: Double, isInterp: Bool, pb: CVPixelBuffer)] = []
                    if result.totalMS > 0 || !interpBuffers.isEmpty || hasPresentedInterpolatedStart {
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

                    // Encolar con duración = intervalo hasta el siguiente pts.
                    for i in 0..<outputs.count {
                        let o = outputs[i]
                        let pts = CMTime(seconds: o.pts, preferredTimescale: 600)
                        let endPTS = (i + 1 < outputs.count)
                            ? outputs[i + 1].pts
                            : o.pts + delta / Double(max(tValues.count + 1, 2))
                        let dur = CMTime(seconds: endPTS - o.pts, preferredTimescale: 600)
                        if let sbuf = rend.sampleBuffer(from: o.pb, pts: pts, duration: dur) {
                            rend.displayLayer.enqueue(sbuf)
                            self.enqueuedFramesInWindow += 1
                        }
                    }
                    if hasPresentedInterpolatedStart == false, !outputs.isEmpty {
                        hasPresentedInterpolatedStart = true
                    }
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
                }
                if Task.isCancelled { break }

            }
        }
    }

}
