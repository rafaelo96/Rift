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
            var tick = 0
            currentTimeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    guard let self, let sched = self.scheduler else { return }
                    self.currentTime = sched.synchronizer.currentTime().seconds
                    tick += 1
                    if tick % 10 == 0 {
                        Self.audioLog("CLOCK sync.rate=\(sched.synchronizer.rate) currentTime=\(self.currentTime) hasVideo=\(self.hasVideo)")
                    }
                }
            }
        } else {
            currentTimeTimer?.invalidate()
            currentTimeTimer = nil
        }
    }
    func seek(to time: Double) {
        audioTask?.cancel()
        currentTime = time
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
        Self.audioLog("=== loadVideo CALLED === \(url.lastPathComponent) isPlaying=\(isPlaying)")
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
                        if let sync = self.scheduler?.synchronizer {
                            let syncId = ObjectIdentifier(sync)
                            Self.audioLog("audioRenderer added to synchronizer rate=\(sync.rate) vol=\(ar.volume) muted=\(ar.isMuted) synchronizerId=\(syncId)")
                        } else {
                            Self.audioLog("audioRenderer added to synchronizer rate=nil vol=\(ar.volume) muted=\(ar.isMuted)")
                        }
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

    private struct PreparedAudioBuffer {
        let sampleBuffer: CMSampleBuffer
        let outputChannels: Int
        let dataSize: Int
        let rms: Float
        let peak: Float
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
                var packetsSeen = 0
                var framesEnqueued = 0
                var framesSkippedBeforeStart = 0
                var failures = 0

                Self.audioLog("audioLoop START track=\(trackStreamIndex) codec=\(codecName) start=\(startPTS) ahead=\(maxAheadSeconds)")

                while !Task.isCancelled {
                    guard let packet = try? audioDemuxer.nextPacket() else { break }
                    guard packet.streamIndex == trackStreamIndex else { continue }

                    packetsSeen += 1
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

                        if framesEnqueued <= 3 || framesEnqueued % 100 == 0 {
                            let rawClock = sync.currentTime().seconds
                            let clock = rawClock.isFinite ? rawClock : startPTS
                            let ahead = presentationPTS - clock
                            Self.audioLog("audioLoop enqueue #\(framesEnqueued) pts=\(presentationPTS) clock=\(clock) ahead=\(ahead) ch=\(prepared.outputChannels) size=\(prepared.dataSize) rms=\(prepared.rms) peak=\(prepared.peak) status=\(renderer.status.rawValue) ready=\(renderer.isReadyForMoreMediaData) err=\(renderer.error?.localizedDescription ?? "nil")")
                        }
                    }
                }

                Self.audioLog("audioLoop END packets=\(packetsSeen) enqueued=\(framesEnqueued) skippedBeforeStart=\(framesSkippedBeforeStart) failures=\(failures) cancelled=\(Task.isCancelled)")
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

    private nonisolated static func decodeAndEnqueueAudio(packet: CompressedPacket, decoder: AudioDecoder, renderer: AVSampleBufferAudioRenderer) {
        audioPacketsSeen += 1
        let frames = decoder.decode(packet: packet)
        // Usar el pts del paquete del demux como base y acumular duración por
        // frame: el pts que el decoder C escupe tras leave callback puede estar
        // basado en una timebase distinta de la stream timebase (EAC3) y marcar
        // un "futuro" relativo al reloj del synchronizer, produciendo silencio
        // por timing.
        var accumulatedSeconds: Double = 0
        if audioPacketsSeen == 1 || audioPacketsSeen % 100 == 0 {
            audioLog("audio pkt #\(audioPacketsSeen) pts=\(packet.pts) frames=\(frames.count) rendererStatus=\(renderer.status.rawValue) err=\(renderer.error?.localizedDescription ?? "nil") isReady=\(renderer.isReadyForMoreMediaData)")
        }
        for frame in frames {
            guard frame.sampleCount > 0, frame.sampleRate > 0, frame.channels > 0 else {
                audioFailures += 1
                if audioFailures <= 5 {
                    audioLog("audio SKIP guard sc=\(frame.sampleCount) sr=\(frame.sampleRate) ch=\(frame.channels)")
                }
                continue
            }
            // Si el PCM es 5.1+ (channels>2), downmix L/R → estéreo aquí: el
            // renderer nativo NO consume 6ch interleaved en salida estéreo
            // (cola silenciosa infinita), así que lo aplanamos en origen.
            var audioData = frame.data
            var outChannels = frame.channels
            if frame.channels > 2 {
                let totalFrames = frame.sampleCount
                var stereo = [Float](repeating: 0, count: totalFrames * 2)
                var srcIdx = 0
                var dstIdx = 0
                // Downmix 5.1→stereo: FL/FR + canal central (voces/diálogo) a 0.707.
                // El diálogo vive en el centro (FC); sin él solo suena música/efectos.
                for _ in 0..<totalFrames {
                    let FL = audioData.withUnsafeBytes { $0.load(fromByteOffset: srcIdx * 4, as: Float.self) }
                    let FR = audioData.withUnsafeBytes { $0.load(fromByteOffset: (srcIdx + 1) * 4, as: Float.self) }
                    let FC = frame.channels >= 3
                        ? audioData.withUnsafeBytes { $0.load(fromByteOffset: (srcIdx + 2) * 4, as: Float.self) }
                        : 0
                    let L = min(1.0, max(-1.0, FL + 0.707 * FC))
                    let R = min(1.0, max(-1.0, FR + 0.707 * FC))
                    stereo[dstIdx]     = L
                    stereo[dstIdx + 1] = R
                    srcIdx += frame.channels
                    dstIdx += 2
                }
                audioData = Data(bytes: &stereo, count: stereo.count * 4)
                outChannels = 2
            }
            // DEBUG: log channels/sizes post-downmix
            if audioPacketsSeen == 1 {
                audioLog("DEBUG audio pkt #1 post-downmix: frame.channels=\(frame.channels) outChannels=\(outChannels) audioData.count=\(audioData.count) frame.data.count=\(frame.data.count) ASBD_channels=2 ASBD_bytesPerFrame=\(UInt32(outChannels * 4)) ASBD_bytesPerPacket=\(UInt32(outChannels * 4))")
            }
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(frame.sampleRate),
                mFormatID: kAudioFormatLinearPCM,
                // Little-endian nativo (Arm/Intel): sin este flag el sistema
                // asume big-endian y produce silencio/garbage.
                mFormatFlags: kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: UInt32(outChannels * 4),
                mFramesPerPacket: 1,
                mBytesPerFrame: UInt32(outChannels * 4),
                mChannelsPerFrame: UInt32(outChannels),
                mBitsPerChannel: 32,
                mReserved: 0
            )
            // Channel layout explícito para 5.1: sin layout tag el sistema
            // no puede rutar los 6 canales a la salida física → silencio.
            var channelLayout = AudioChannelLayout()
            channelLayout.mChannelLayoutTag = (outChannels > 2) ? kAudioChannelLayoutTag_MPEG_5_1_D : kAudioChannelLayoutTag_Stereo
            var format: CMAudioFormatDescription?
            let fmtStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &channelLayout, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            guard fmtStatus == noErr, let format else {
                if audioFailures < 5 { audioLog("audio format create FAIL status=\(fmtStatus) sr=\(frame.sampleRate) ch=\(frame.channels)") }
                audioFailures += 1
                continue
            }

            // Copiar PCM a un block buffer propio (Data se dealloca al salir;
            // el block buffer debe ser dueño de los bytes).
            var blockBuffer: CMBlockBuffer?
            let dataSize = audioData.count
            // CMBlockBufferCreateWithMemoryBlock con memoryBlock=nil y
            // blockAllocator=default: CM aloca y posee la memoria; luego
            // ReplaceDataBytes funciona (CreateEmpty no tiene backing store).
            let statusBB = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                              memoryBlock: nil,
                                                              blockLength: dataSize,
                                                              blockAllocator: kCFAllocatorDefault,
                                                              customBlockSource: nil,
                                                              offsetToData: 0,
                                                              dataLength: dataSize,
                                                              flags: 0,
                                                              blockBufferOut: &blockBuffer)
            guard statusBB == noErr, let blockBuffer else {
                if audioFailures < 5 { audioLog("audio blockBuffer FAIL status=\(statusBB) size=\(dataSize)") }
                audioFailures += 1
                continue
            }
            let copyOK = audioData.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
                guard let base = ptr.baseAddress else { return -1 }
                return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataSize)
            }
            guard copyOK == noErr else {
                if audioFailures < 5 { audioLog("audio replaceBytes FAIL status=\(copyOK)") }
                audioFailures += 1
                continue
            }
            // LOG: RMS/min/max de audioData post-downmix (primeros 10 packets)
            if audioPacketsSeen <= 10 {
                audioData.withUnsafeBytes { ptr in
                    guard let base = ptr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                    let n = ptr.count / MemoryLayout<Float>.stride
                    if n > 0 {
                        var minSample = Float.greatestFiniteMagnitude
                        var maxSample = -Float.greatestFiniteMagnitude
                        var sumSquares: Double = 0
                        for i in 0..<n {
                            let v = base[i]
                            if v < minSample { minSample = v }
                            if v > maxSample { maxSample = v }
                            sumSquares += Double(v) * Double(v)
                        }
                        let rms = sqrt(sumSquares / Double(max(n, 1)))
                        audioLog("DEBUG audio pkt #\(audioPacketsSeen) post-downmix: min=\(minSample) max=\(maxSample) rms=\(rms) samples=\(n)")
                    }
                }
            }

            let presentationPts = packet.pts + accumulatedSeconds
            accumulatedSeconds += Double(frame.sampleCount) / Double(frame.sampleRate)
            let ptsTime = CMTime(seconds: presentationPts, preferredTimescale: 90000)
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
            guard statusSB == noErr, let sampleBuffer else {
                if audioFailures < 5 { audioLog("audio sampleBuffer FAIL status=\(statusSB)") }
                audioFailures += 1
                continue
            }
            // No descartar por isReadyForMoreMediaData: el renderer acepta
            // buffers aunque reporte isReady=false (eso solo indica que tiene
            // suficiente en cola). El pacing real lo gobierna el synchronizer.
            renderer.enqueue(sampleBuffer)
            audioFramesEnqueued += 1
            if audioFramesEnqueued <= 3 || audioFramesEnqueued % 50 == 0 {
                // Medir RMS del PCM justo antes del enqueue para descartar
                // que el buffer tenga silencio digital.
                // USAMOS audioData (post-downmix) EN VEZ DE frame.data para
                // ser coherente con el buffer real que se envía al renderer.
                var rms: Float = 0
                var peak: Float = 0
                let nFloats = audioData.count / MemoryLayout<Float>.size
                audioData.withUnsafeBytes { ptr in
                    guard let base = ptr.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                    var sum: Double = 0
                    for i in 0..<nFloats {
                        let v = base[i]
                        sum += Double(v) * Double(v)
                        peak = max(peak, abs(v))
                    }
                    rms = nFloats > 0 ? Float(sqrt(sum / Double(nFloats))) : 0
                }
                audioLog("audio enqueue #\(audioFramesEnqueued) pts=\(presentationPts) (frame.pts=\(frame.pts)) sr=\(frame.sampleRate) ch=\(outChannels) samples=\(frame.sampleCount) dataSize=\(dataSize) rms=\(rms) peak=\(peak) rendererStatus=\(renderer.status.rawValue) err=\(renderer.error?.localizedDescription ?? "nil") vol=\(renderer.volume) muted=\(renderer.isMuted) dev=\(renderer.audioOutputDeviceUniqueID ?? "nil")")
            }
        }
    }

    private func startDisplayLoop() {
        if !isPlaying { isPlaying = true }
        updateTimePolling()
        if let sched = scheduler, sched.synchronizer.rate == 0 {
            let syncId = ObjectIdentifier(sched.synchronizer)
            sched.synchronizer.setRate(1.0, time: CMTime(seconds: currentTime, preferredTimescale: 600), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
            Self.audioLog("synchronizer.setRate(1.0) synchronizerId=\(syncId) rate=\(sched.synchronizer.rate)")
        }
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var videoFrameCount = 0
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
                // esperar hasta que el reloj alcance el pts de este frame, en
                // lugar de un sleep fijo (que deriva y desincroniza A/V).
                let target = f.pts
                while true {
                    if Task.isCancelled { break }
                    let clk = sched.synchronizer.currentTime().seconds
                    if clk >= target - 0.001 { break }
                    let delta = target - clk
                    try? await Task.sleep(nanoseconds: UInt64(max(0, delta) * 1_000_000_000))
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
                    videoFrameCount += 1
                    if videoFrameCount == 1 || videoFrameCount % 24 == 0 {
                        let clk = sched.synchronizer.currentTime().seconds
                        Self.audioLog("VIDEO frame #\(videoFrameCount) pts=\(f.pts) clock=\(clk) videoAhead=\(f.pts - clk)")
                    }
                    pool.removeFirst()
                }
                await self.coordinator.signal()
                if Task.isCancelled { break }
            }
        }
    }

}
