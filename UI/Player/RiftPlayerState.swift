import Foundation
import AVFoundation
import Combine
import Contracts
import Demux
import Decode
import DecodeAudio
import FramePool
import Scheduler
import Rendering
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
    var displayLayer: AVSampleBufferDisplayLayer? { renderer?.displayLayer }
    var player: AVPlayer? { nil }
    private var videoTrack: TrackInfo?
    private var audioTrack: TrackInfo?
    private var audioDecoder: AudioDecoder?
    private var audioRenderer: AVSampleBufferAudioRenderer?
    private var sourceFrameRate: Double?
    private let coordinator = DecodeCoordinator(value: 4)
    private var totalDecoded = 0
    private var decodeTask: Task<Void, Never>?
    private var consumerTimer: Timer?
    private var currentTimeTimer: Timer?

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
                }
            }
        } else {
            currentTimeTimer?.invalidate()
            currentTimeTimer = nil
        }
    }
    func seek(to time: Double) {
        currentTime = time
        try? demuxer?.seek(to: time); decoder?.flush(); framePool?.flush()
        // Vaciar también las colas de video y audio (frames/buffers encolados
        // del segmento anterior) para que no se "pegue" contenido viejo.
        if let rend = renderer { rend.displayLayer.flush() }
        audioRenderer?.flush()
        if let aTrack = audioTrack {
            audioDecoder = try? AudioDecoder(codecName: aTrack.codecName) // reset del decoder para el nuevo segmento
        }
        if let sched = scheduler {
            sched.synchronizer.setRate(isPlaying ? 1.0 : 0, time: CMTime(seconds: time, preferredTimescale: 600), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
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
        consumerTimer?.invalidate(); consumerTimer = nil
        demuxer?.close(); decoder?.close()
        demuxer = nil; decoder = nil; framePool = nil; scheduler = nil; renderer = nil
        audioDecoder = nil; audioRenderer = nil; audioTrack = nil
        hasVideo = false; isPlaying = false
        if let sched = scheduler {
            sched.synchronizer.setRate(0, time: .zero)
        }
    }
    func startHideTimer() {}
    func stopHideTimer() {}
    func resetHideTimer() {}
    func formattedTime(_ s: Double) -> String { let i = Int(s); return String(format: "%d:%02d", i/60, i%60) }
    func setInterpolationMode(_ m: InterpolationMode) { interpolationMode = m }
    func selectAudioTrack(_ i: Int) { selectedAudioTrackIndex = i }
    func selectPipelineTrack(_ t: MediaTrack?) { selectedSubtitleTrack = t }
    func toggleVisualEnhancements() { visualEnhancementsEnabled.toggle() }

    func loadVideo(_ url: URL) {
        statusMessage = "Opening \(url.lastPathComponent)..."
        conversionProgress = 0.1
        hasVideo = false
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
                await MainActor.run {
                    guard let self else { return }
                    self.demuxer = d
                    self.decoder = dec
                    self.videoTrack = v
                    self.duration = info.duration
                    self.sourceFrameRate = v.frameRate
                    self.framePool = SlidingFramePool(capacity: 4)
                    self.scheduler = FrameScheduler(mode: .native24)
                    self.renderer = HDRDisplayRenderer()
                    // Audio: primera pista de audio (selector queda para fase posterior)
                    if let aTrack = info.tracks.first(where: { $0.kind == .audio }) {
                        self.audioTrack = aTrack
                        do {
                            self.audioDecoder = try AudioDecoder(codecName: aTrack.codecName)
                        } catch {
                            Self.audioLog("audioDecoder init FAILED: \(error)")
                        }
                        let ar = AVSampleBufferAudioRenderer()
                        self.audioRenderer = ar
                        // Importante: agregar ANTES de que el synchronizer arranque (rate=1.0).
                        self.scheduler?.synchronizer.addRenderer(ar)
                        Self.audioLog("audioRenderer added to synchronizer rate=\(self.scheduler?.synchronizer.rate ?? -999)")
                    }
                    self.availableTracks = info.tracks.map { t in
                        let kind: MediaTrack.Kind
                        switch t.kind { case .video: kind = .video; case .audio: kind = .audio; default: kind = .subtitle }
                        return MediaTrack(id: "\(t.streamIndex)", kind: kind, index: t.streamIndex, label: t.codecName, languageCode: nil)
                    }
                    self.audioTracks = info.tracks.filter { $0.kind == .audio }.enumerated().map { idx, t in AudioTrack(id: idx, label: t.codecName, language: nil) }
                    self.hasVideo = true
                    self.statusMessage = "Ready"
                    self.conversionProgress = 1.0
                    self.startDecodeLoop()
                    self.startSimulatedConsumer() // TODO(3c): reemplazar por Scheduler.synchronizer real
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
        // Extraer refs de audio en el MainActor antes de entrar al Task.detached
        let aTrack = audioTrack
        let aDec = audioDecoder
        let aRend = audioRenderer
        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var decoded = 0
            while true {
                await self.coordinator.wait()
                if Task.isCancelled { await self.coordinator.signal(); break }
                guard let pkt = try? d.nextPacket() else {
                    await self.coordinator.signal()
                    print("RiftPlayerState: decode loop ended (decoded=\(decoded))")
                    break
                }
                // Audio: se decodifica y encola al audioRenderer de inmediato,
                // sin consumir un cupo del pool de video (el backpressure de
                // video no debe gobernar el audio).
                if let aIndex = aTrack?.streamIndex, pkt.streamIndex == aIndex,
                   let aDec, let aRend {
                    Self.decodeAndEnqueueAudio(packet: pkt, decoder: aDec, renderer: aRend)
                    await self.coordinator.signal()
                    continue
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

    // MARK: - Audio fase 1
    // Contadores no hay problema de concurrencia: solo se escriben desde el
    // decode loop (Task.detached) — sin aislamiento, no owned por el actor.
    private nonisolated(unsafe) static var audioPacketsSeen = 0
    private nonisolated(unsafe) static var audioFramesEnqueued = 0
    private nonisolated(unsafe) static var audioFailures = 0
    private nonisolated(unsafe) static var audioDroppedNotReady = 0

    private nonisolated static func audioLog(_ s: String) {
        let line = s + "\n"
        if let h = FileHandle(forWritingAtPath: "/tmp/rift_audio.log") {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
        } else {
            FileManager.default.createFile(atPath: "/tmp/rift_audio.log", contents: line.data(using: .utf8))
        }
    }

    private nonisolated static func decodeAndEnqueueAudio(packet: CompressedPacket, decoder: AudioDecoder, renderer: AVSampleBufferAudioRenderer) {
        audioPacketsSeen += 1
        let frames = decoder.decode(packet: packet)
        if audioPacketsSeen == 1 || audioPacketsSeen % 100 == 0 {
            audioLog("audio pkt #\(audioPacketsSeen) pts=\(packet.pts) frames=\(frames.count) rendererStatus=\(renderer.status.rawValue) err=\(renderer.error?.localizedDescription ?? "nil") isReady=\(renderer.isReadyForMoreMediaData)")
        }
        for frame in frames {
            guard frame.sampleCount > 0, frame.sampleRate > 0, frame.channels > 0 else {
                audioFailures += 1
                continue
            }
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(frame.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(frame.channels * 4),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(frame.channels * 4),
                mChannelsPerFrame: UInt32(frame.channels),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            var format: CMAudioFormatDescription?
            let fmtStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            guard fmtStatus == noErr, let format else {
                if audioFailures < 5 { audioLog("audio format create FAIL status=\(fmtStatus) sr=\(frame.sampleRate) ch=\(frame.channels)") }
                audioFailures += 1
                continue
            }

            // Copiar PCM a un block buffer propio (Data se dealloca al salir;
            // el block buffer debe ser dueño de los bytes).
            var blockBuffer: CMBlockBuffer?
            let dataSize = frame.data.count
            let statusBB = CMBlockBufferCreateEmpty(allocator: kCFAllocatorDefault, capacity: UInt32(dataSize), flags: 0, blockBufferOut: &blockBuffer)
            guard statusBB == noErr, let blockBuffer else { continue }
            let copyOK = frame.data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
                guard let base = ptr.baseAddress else { return -1 }
                return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataSize)
            }
            guard copyOK == noErr else { continue }

            let ptsTime = CMTime(seconds: frame.pts, preferredTimescale: 90000)
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: Int64(frame.sampleCount), timescale: CMTimeScale(frame.sampleRate)),
                presentationTimeStamp: ptsTime,
                decodeTimeStamp: ptsTime
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
            guard statusSB == noErr, let sampleBuffer else { continue }
            if !renderer.isReadyForMoreMediaData {
                audioDroppedNotReady += 1
                if audioDroppedNotReady == 1 || audioDroppedNotReady % 100 == 0 {
                    audioLog("audio SKIP (not ready) #\(audioDroppedNotReady) pts=\(frame.pts)")
                }
                continue
            }
            renderer.enqueue(sampleBuffer)
            audioFramesEnqueued += 1
            if audioFramesEnqueued <= 3 || audioFramesEnqueued % 50 == 0 {
                audioLog("audio enqueue #\(audioFramesEnqueued) pts=\(frame.pts) sr=\(frame.sampleRate) ch=\(frame.channels) samples=\(frame.sampleCount)")
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
                    // No hay frames disponibles todavía; esperar y reintentar.
                    return Optional<Frame>.none
                }()
                guard let f else {
                    try? await Task.sleep(nanoseconds: 33_000_000) // ~30fps poll
                    continue
                }
                let pts = CMTime(seconds: f.pts, preferredTimescale: 600)
                let dur = CMTime(seconds: 1.0 / 24.0, preferredTimescale: 600)
                if let sbuf = rend.sampleBuffer(from: f.pixelBuffer, pts: pts, duration: dur) {
                    // Presentar inmediatamente: el pacing lo gobierna el flujo
                    // decode↔display (pool+semaphore), y la pausa se garantiza
                    // porque en rate==0 este loop no encola ningún frame.
                    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: true) {
                        let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                        CFDictionarySetValue(dict,
                            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
                    }
                    rend.displayLayer.enqueue(sbuf)
                    pool.removeFirst()
                }
                await self.coordinator.signal()
                try? await Task.sleep(nanoseconds: 1_000_000_000 / 24)
                if Task.isCancelled { break }
            }
        }
    }

    private func startSimulatedConsumer() {
        // Deprecated en 3c: ahora el display loop real consume y señaliza
        consumerTimer?.invalidate()
    }
}
