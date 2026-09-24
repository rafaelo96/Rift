import CoreGraphics
import CoreImage
import CoreVideo
import Demux
import Foundation

/// A small, display-ready image extracted near a timeline position.
/// The image is downscaled before leaving Core/Decode so the UI cache remains
/// bounded even when the source is 4K HDR.
public struct VideoThumbnail: @unchecked Sendable {
    public let image: CGImage
    public let sourceTime: Double

    public init(image: CGImage, sourceTime: Double) {
        self.image = image
        self.sourceTime = sourceTime
    }
}

/// Serial, bounded thumbnail extraction for timeline previews.
///
/// Each request owns a short-lived demuxer and VTDecompressionSession, so it
/// never seeks, flushes, or competes for mutable state with active playback.
/// It decodes only the packets needed from the preceding keyframe to produce a
/// single 320x180 image; the video source is never copied or transcoded.
public actor VideoThumbnailExtractor {
    private struct CacheKey: Hashable {
        let path: String
        let second: Int
    }

    private let maximumCacheEntries = 18
    private var cache: [CacheKey: VideoThumbnail] = [:]
    private var cacheOrder: [CacheKey] = []

    public init() {}

    public func thumbnail(for sourceURL: URL, at requestedTime: Double) throws -> VideoThumbnail? {
        guard !Task.isCancelled else { return nil }

        let clampedTime = max(requestedTime, 0)
        let key = CacheKey(path: sourceURL.path, second: Int(clampedTime.rounded(.down)))
        if let cached = cache[key] {
            return cached
        }

        let demuxer = FFmpegDemuxer()
        let decoder = VTDecoder()
        defer {
            decoder.close()
            demuxer.close()
        }

        let info = try demuxer.open(url: sourceURL)
        guard let videoTrack = info.tracks.first(where: { $0.kind == .video }) else {
            return nil
        }

        try decoder.prepare(track: videoTrack)
        try demuxer.seek(to: min(clampedTime, max(info.duration, 0)))

        var closestFrame: DecodedVideoFrame?
        var closestDistance = Double.greatestFiniteMagnitude
        var decodedVideoPackets = 0
        let maximumVideoPackets = 180

        while decodedVideoPackets < maximumVideoPackets, let packet = try demuxer.nextPacket() {
            guard !Task.isCancelled else { return nil }
            guard packet.streamIndex == videoTrack.streamIndex else { continue }

            decodedVideoPackets += 1
            guard let frame = try decoder.decodeFrame(packet) else { continue }

            let distance = abs(frame.pts - clampedTime)
            if distance < closestDistance {
                closestFrame = frame
                closestDistance = distance
            }

            // The demuxer seeks backward to a keyframe. Once decode passes the
            // target, the nearest frame is known and further work has no value.
            if frame.pts >= clampedTime, closestFrame != nil {
                break
            }
        }

        guard let frame = closestFrame,
              let image = makeThumbnailImage(from: frame.pixelBuffer) else {
            return nil
        }

        let thumbnail = VideoThumbnail(image: image, sourceTime: frame.pts)
        cacheThumbnail(thumbnail, for: key)
        return thumbnail
    }

    private func cacheThumbnail(_ thumbnail: VideoThumbnail, for key: CacheKey) {
        cache[key] = thumbnail
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)

        while cacheOrder.count > maximumCacheEntries {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private func makeThumbnailImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let maximumSize = CGSize(width: 320, height: 180)
        let scale = min(
            maximumSize.width / max(source.extent.width, 1),
            maximumSize.height / max(source.extent.height, 1),
            1
        )
        let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.linearDisplayP3)!,
            .outputColorSpace: sRGB,
        ])
        return context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB)
    }
}
