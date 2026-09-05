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
    private var audioTask: Task<Void, Never>?
    private var consumerTimer: Timer?
    private var currentTimeTimer: Timer?
    private var sourceURL: URL?
    private var subtitleTrack: TrackInfo?
    private var subtitleCues: [SubtitleCue] = []
    private var subtitleCueCache: [Int: [SubtitleCue]] = [:]

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
            startAudioLoop(url: url, trackStreamIndex: aTrack.streamIndex, codecName: aTrack.codecName, startTime: time)
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
        audioDecoder = nil; audioRenderer = nil; audioTrack = nil
        sourceURL = nil
        hasVideo = false; isPlaying = false
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
                    // Audio: primera pista de audio (selector queda para fase posterior)
                    if let aTrack = info.tracks.first(where: { $0.kind == .audio }) {
                        self.audioTrack = aTrack
                        let ar = AVSampleBufferAudioRenderer()
                        ar.volume = 1.0
                        ar.isMuted = false
                        self.audioRenderer = ar
                        // Importante: agregar ANTES de que el synchronizer arranque (rate=1.0).
                        self.scheduler?.synchronizer.addRenderer(ar)
                        self.startAudioLoop(url: url, trackStreamIndex: aTrack.streamIndex, codecName: aTrack.codecName, startTime: self.currentTime)
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
                    print("RiftPlayerState: decode loop ended (decoded=\(decoded))")
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

    private func startAudioLoop(url: URL, trackStreamIndex: Int, codecName: String, startTime: Double) {
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
                let decoder = try AudioDecoder(codecName: codecName)
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
                // Pacer contra el reloj del synchronizer (igual que el audio):
                // esperar hasta que el reloj alcance el pts de este frame. Usamos
                // un poll corto en vez de dormir la delta completa, y si el frame
                // está más de 1s en el futuro (tras un seek el reloj puede quedar
                // desalineado del pts del primer frame) lo presentamos de inmediato
                // para no dejar la imagen congelada.
                let target = f.pts
                while true {
                    if Task.isCancelled { break }
                    let clk = sched.synchronizer.currentTime().seconds
                    if clk >= target - 0.001 { break }
                    if target - clk > 1.0 { break }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                if Task.isCancelled { break }
                let pts = CMTime(seconds: f.pts, preferredTimescale: 600)
                let dur = CMTime(seconds: 1.0 / 24.0, preferredTimescale: 600)
                if let sbuf = rend.sampleBuffer(from: f.pixelBuffer, pts: pts, duration: dur) {
                    // DisplayImmediately: ya que pacamos contra el reloj arriba,
                    // presentamos al instante al encolar.
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
                if Task.isCancelled { break }
            }
        }
    }

}
