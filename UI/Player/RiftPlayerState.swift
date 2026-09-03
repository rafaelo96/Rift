import Foundation
import AVFoundation
import Combine
import Contracts
import Demux
import Decode
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
        // Vaciar también la cola del displayLayer (frames encolados del
        // segmento anterior) para que no se "pegue" contenido viejo.
        if let rend = renderer { rend.displayLayer.flush() }
        if let sched = scheduler {
            sched.synchronizer.setRate(isPlaying ? 1.0 : 0, time: CMTime(seconds: time, preferredTimescale: 600), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
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
        decodeTask?.cancel()
        decodeTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            var decoded = 0
            while true {
                await MainActor.run {
                    print("RiftPlayerState: decode loop ABOUT TO WAIT (totalDecoded=\(self.totalDecoded))")
                }
                let before = Date()
                await self.coordinator.wait()
                let after = Date()
                await MainActor.run {
                    print("RiftPlayerState: decode loop PASSED WAIT in \(after.timeIntervalSince(before))s (totalDecoded=\(self.totalDecoded))")
                }
                if Task.isCancelled { await self.coordinator.signal(); break }
                guard let pkt = try? d.nextPacket() else {
                    await self.coordinator.signal()
                    print("RiftPlayerState: decode loop ended")
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
                await MainActor.run { self.totalDecoded = decoded }
                if decoded <= 5 || decoded % 24 == 0 {
                    print("RiftPlayerState: decoded frame \(decoded) pts \(pkt.pts)")
                }
                await MainActor.run {
                    pool.add(buffer: pb, pts: pkt.pts)
                    if decoded == 1 {
                        self.startDisplayLoop()
                    }
                }
                if decoded == 1 {
                    for sec in 1...10 {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: UInt64(sec) * 1_000_000_000)
                            guard let self else { return }
                            print("RiftPlayerState: wall-clock \(sec)s after first decode, total decoded=\(self.totalDecoded) pool.count=\(self.framePool?.count ?? -1)")
                        }
                    }
                }
                if Task.isCancelled { break }
            }
        }
    }

    private func startDisplayLoop() {
        print("RiftPlayerState: startDisplayLoop called hasVideo \(hasVideo) isPlaying \(isPlaying)")
        if !isPlaying { isPlaying = true }
        updateTimePolling()
        if let sched = scheduler, sched.synchronizer.rate == 0 {
            sched.synchronizer.setRate(1.0, time: CMTime(seconds: currentTime, preferredTimescale: 600), atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        }
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            guard let self else {
                print("RiftPlayerState: startDisplayLoop task self nil")
                return
            }
            print("RiftPlayerState: startDisplayLoop task started pool=\(self.framePool != nil) renderer=\(self.renderer != nil)")
            while true {
                if Task.isCancelled {
                    print("RiftPlayerState: startDisplayLoop cancelled")
                    break
                }
                guard let pool = self.framePool, let rend = self.renderer, let sched = self.scheduler else {
                    print("RiftPlayerState: startDisplayLoop missing pool/rend/sched")
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
                    rend.displayLayer.enqueue(sbuf)
                    pool.removeFirst()
                }
                await self.coordinator.signal()
                try? await Task.sleep(nanoseconds: 1_000_000_000 / 24)
                if Task.isCancelled { print("RiftPlayerState: startDisplayLoop cancelled loop"); break }
            }
            print("RiftPlayerState: startDisplayLoop task ended")
        }
        print("RiftPlayerState: startDisplayLoop scheduled, task \(String(describing: displayTask))")
    }

    private func startSimulatedConsumer() {
        // Deprecated en 3c: ahora el display loop real consume y señaliza
        consumerTimer?.invalidate()
    }
}
