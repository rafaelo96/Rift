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
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(value: Int) { count = value }
    func wait() async {
        if count > 0 { count -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if waiters.isEmpty { count += 1 }
        else { waiters.removeFirst().resume() }
    }
}

typealias DecodeCoordinator = AsyncSemaphore

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
    var displayLayer: AVSampleBufferDisplayLayer? { renderer?.displayLayer }
    var player: AVPlayer? { nil }
    private var videoTrack: TrackInfo?
    private var audioTrack: TrackInfo?
    private var audioTrackInfos: [Int: TrackInfo] = [:]
    private var audioDecoder: AudioDecoder?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var sourceFrameRate: Double?
    private let coordinator = DecodeCoordinator(value: 4)
    private var totalDecoded = 0
    private var decodeTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var consumerTimer: Timer?
    private var currentTimeTimer: Timer?
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
        } else {
            currentTimeTimer?.invalidate()
            currentTimeTimer = nil
        }
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
        if let sched = scheduler {
            sched.synchronizer.setRate(0, time: .zero)
        }
        renderer?.flush()
        audioRenderer?.flush()
        demuxer?.close(); decoder?.close()
        demuxer = nil; decoder = nil; framePool = nil; scheduler = nil; renderer = nil
        compensator = nil
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
        // Forzar re-inicialización lazy del motor en el próximo par — evita que
        // un cambio de modo en vivo use un compensator con configuración vieja.
        compensator = nil
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
                await MainActor.run {
                    guard let self else { return }
                    self.demuxer = d
                    self.decoder = dec
                    self.videoTrack = v
                    self.duration = info.duration
                    self.sourceFrameRate = v.frameRate
                    self.framePool = SlidingFramePool(capacity: 4)
                    self.scheduler = FrameScheduler(mode: .native24)
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
            } catch {
                await MainActor.run {
                    self?.statusMessage = "Open failed: \(error)"
                    self?.conversionProgress = 0
                }
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
                await self.coordinator.wait()
                if Task.isCancelled { await self.coordinator.signal(); break }
                guard let pkt = try? d.nextPacket() else {
                    await self.coordinator.signal()
                    break
                }
                if pkt.streamIndex != targetIndex {
                    await self.coordinator.signal()
                    continue
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
                if Task.isCancelled { break }
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

    /// Spawn de un interpolador en background para el par (I0, I1). El resultado se encola
    /// solo si sigue siendo válido (pts aún no pasado por el synchronizer).
    /// Sin tocar el display loop ni el pool — el loop nativo mantiene su ciclo.
    private func spawnInterpolatedPair(i0: Frame, i1: Frame) {
        guard interpolationMode != .disabled else { return }
        if compensator == nil {
            do {
                let created = try MotionCompensator(config: .default)
                compensator = created
            } catch {
                return
            }
        }
        guard let comp = compensator else { return }

        Task.detached { @Sendable [benchLog] in
            let t0 = DispatchTime.now().uptimeNanoseconds
            let interp = comp.interpolate(I0: i0.pixelBuffer, I1: i1.pixelBuffer, t: 0.5)
            let interpMs = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000.0

            // Calcula el pts del frame interpolado (entre I0 e I1)
            let midPTS = i0.pts + (i1.pts - i0.pts) * 0.5
            let dur = (i1.pts - i0.pts) * 0.5

            guard let pb = interp else {
                os_log("spawnInterp: interpolate returned nil after %.1fms (i0=%.3f i1=%.3f)",
                       log: benchLog, type: .error, interpMs, i0.pts, i1.pts)
                return
            }

            await MainActor.run { [weak self] in
                guard let self, let sbuf = self.renderer?.sampleBuffer(from: pb, pts: CMTime(seconds: midPTS, preferredTimescale: 600), duration: CMTime(seconds: dur, preferredTimescale: 600)) else { return }

                let clockNow = self.scheduler?.synchronizer.currentTime().seconds ?? midPTS
                let late = midPTS < clockNow
                os_log("spawnInterp: %.1fms  midPTS=%.3f  clock=%.3f  %{public}@",
                       log: benchLog, type: .info, interpMs, midPTS, clockNow,
                       late ? "LATE→discard" : "OK→enqueue")

                guard !late else { return }

                self.markDisplayImmediately(sbuf)
                self.renderer?.displayLayer.enqueue(sbuf)
                if !self.isArtificialInterpolationActive {
                    self.isArtificialInterpolationActive = true
                }
            }
        }
    }

    private func startDisplayLoop() {
        if !isPlaying { isPlaying = true }
        updateTimePolling()
        if let sched = scheduler, sched.synchronizer.rate == 0 {
            sched.synchronizer.setRate(1.0, time: CMTime(seconds: currentTime, preferredTimescale: 600), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                if Task.isCancelled { break }
                guard let pool = self.framePool, let rend = self.renderer, let sched = self.scheduler else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                // Si está pausado, no consumir el pool ni encolar nada —
                // el synchronizer detiene la presentación con rate=0.
                if sched.synchronizer.rate == 0 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                // Consumir el frame más viejo de la ventana deslizante.
                let f = pool.oldest() ?? {
                    return Optional<Frame>.none
                }()
                guard let f else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                await self.waitUntilDisplayClock(atLeast: f.pts)
                if Task.isCancelled { break }
                let workStart = DispatchTime.now().uptimeNanoseconds
                let pts = CMTime(seconds: f.pts, preferredTimescale: 600)
                let dur = CMTime(seconds: 1.0 / 24.0, preferredTimescale: 600)
                if let sbuf = rend.sampleBuffer(from: f.pixelBuffer, pts: pts, duration: dur) {
                    self.markDisplayImmediately(sbuf)
                    rend.displayLayer.enqueue(sbuf)
                    pool.removeFirst()
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
                }
                await self.coordinator.signal()
                if Task.isCancelled { break }

                // --- Interpolation helper (background, non-blocking) ---
                // Sólo si la interpolación está activada y la lógica está legal.
                // No remueves del pool — el pool sigue fluyendo a su ritmo nativo.
                if self.interpolationMode != .disabled {
                    // Mantén los últimos 2 frames mostrados (sin tocar el pool).
                    var frames = self.lastShownFrames
                    frames.append(f)  // f es no-optional, siempre existe aquí
                    if frames.count > 2 { frames.removeFirst() }
                    self.lastShownFrames = frames

                    // Si tenemos al menos 2 pares, compute el frame interpolado.
                    if frames.count == 2, let i0 = frames.first, let i1 = frames.last {
                        await self.spawnInterpolatedPair(i0: i0, i1: i1)
                    }
                }

            }
        }
    }

}
