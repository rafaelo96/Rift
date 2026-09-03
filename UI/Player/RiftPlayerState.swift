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

actor DecodeCoordinator {
    private let sema: DispatchSemaphore
    init(capacity: Int) { sema = DispatchSemaphore(value: capacity) }
    func wait() { sema.wait() }
    func signal() { sema.signal() }
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
    var displayLayer: AVSampleBufferDisplayLayer? { renderer?.displayLayer }
    var player: AVPlayer? { nil }
    private var videoTrack: TrackInfo?
    private var sourceFrameRate: Double?
    private let coordinator = DecodeCoordinator(capacity: 4)
    private var totalDecoded = 0
    private var decodeTask: Task<Void, Never>?
    private var consumerTimer: Timer?

    func togglePlay() {
        isPlaying.toggle()
        if let sched = scheduler {
            let t = CMTime(seconds: currentTime, preferredTimescale: 600)
            sched.synchronizer.setRate(isPlaying ? 1.0 : 0, time: t)
        }
        // Start display loop on first play
        if isPlaying { startDisplayLoop() }
    }
    func seek(to time: Double) {
        currentTime = time
        try? demuxer?.seek(to: time); decoder?.flush(); framePool?.flush()
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
                if Task.isCancelled { break }
                await self.coordinator.wait()
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
        displayTask?.cancel()
        displayTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var nextIndex = 0
            while true {
                if Task.isCancelled { break }
                guard let pool = self.framePool, let rend = self.renderer else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                let frames = pool.frames
                guard nextIndex < frames.count else {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }
                let f = frames[nextIndex]
                let pts = CMTime(seconds: f.pts, preferredTimescale: 600)
                let dur = CMTime(seconds: 1.0/24.0, preferredTimescale: 600)
                if let sbuf = rend.sampleBuffer(from: f.pixelBuffer, pts: pts, duration: dur) {
                    rend.displayLayer.enqueue(sbuf)
                }
                nextIndex += 1
                Task { await self.coordinator.signal() }
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
