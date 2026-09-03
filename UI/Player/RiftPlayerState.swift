import Foundation
import AVFoundation
import Combine
import Contracts
import Demux
import Decode
import UniformTypeIdentifiers
import AppKit

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
    var displayLayer: AVSampleBufferDisplayLayer? { nil } // paso 3

    func togglePlay() { isPlaying.toggle() }
    func seek(to time: Double) { currentTime = time }
    func seek(by delta: Double) { seek(to: currentTime + delta) }
    func setVolume(_ v: Double) { volume = v }
    func cyclePlaybackRate() {}
    func closeVideo() {
        demuxer?.close(); decoder?.close()
        demuxer = nil; decoder = nil
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
        // UI inmediata, trabajo pesado a background, demuxer vivo
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
                // Mantener demuxer vivo (NO d.close() tras metadata)
                await MainActor.run {
                    guard let self else { return }
                    self.demuxer = d
                    self.decoder = dec
                    self.duration = info.duration
                    self.sourceFrameRate = v.frameRate
                    self.availableTracks = info.tracks.map { t in
                        let kind: MediaTrack.Kind
                        switch t.kind { case .video: kind = .video; case .audio: kind = .audio; default: kind = .subtitle }
                        return MediaTrack(id: "\(t.streamIndex)", kind: kind, index: t.streamIndex, label: t.codecName, languageCode: nil)
                    }
                    self.audioTracks = info.tracks.filter { $0.kind == .audio }.enumerated().map { idx, t in AudioTrack(id: idx, label: t.codecName, language: nil) }
                    self.hasVideo = true
                    self.statusMessage = "Ready"
                    self.conversionProgress = 1.0
                }
            } catch {
                await MainActor.run {
                    self?.statusMessage = "Open failed: \(error)"
                    self?.conversionProgress = 0
                }
            }
        }
    }

    private var sourceFrameRate: Double?

    func openVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.movie, UTType.video, UTType(filenameExtension: "mkv") ?? .data, UTType(filenameExtension: "mka") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadVideo(url) }
    }
    func cleanup() { closeVideo() }
}
