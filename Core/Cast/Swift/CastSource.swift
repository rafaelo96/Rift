import Foundation
import CCastShim

/// Un archivo de video preparado para enviarse por AirPlay como HLS (fMP4).
/// Los paquetes comprimidos se reempaquetan en memoria, segmento a segmento y
/// bajo demanda: no se decodifica, no se recodifica y no se escribe en disco.
/// No es seguro entre hilos; `CastServer` lo usa desde una sola cola.
public final class CastSource {
    public enum VideoRange: Int { case sdr = 0, pq = 1, hlg = 2 }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    private let handle: OpaquePointer

    public let segmentCount: Int
    public let duration: Double
    public let width: Int
    public let height: Int
    public let frameRate: Double
    public let videoRange: VideoRange
    public let codecs: String
    /// Pista de audio que se envía (índice del contenedor), o `nil` sin audio.
    public let audioStreamIndex: Int?

    /// - Parameter audioStreamIndex: pista preferida; si HLS no admite su códec
    ///   se usa la primera que sí (AAC, AC-3 o E-AC-3).
    public init(url: URL, audioStreamIndex: Int? = nil) throws {
        var message = [CChar](repeating: 0, count: 256)
        guard let handle = rift_cast_open(url.path, Int32(audioStreamIndex ?? -1), &message, Int32(message.count)) else {
            throw Failure(description: String(cString: message))
        }
        self.handle = handle
        segmentCount = Int(rift_cast_segment_count(handle))
        duration = rift_cast_segment_start(handle, Int32(segmentCount))
        width = Int(rift_cast_width(handle))
        height = Int(rift_cast_height(handle))
        frameRate = rift_cast_frame_rate(handle)
        videoRange = VideoRange(rawValue: Int(rift_cast_video_range(handle))) ?? .sdr
        codecs = String(cString: rift_cast_codecs(handle))
        let audio = Int(rift_cast_audio_stream(handle))
        self.audioStreamIndex = audio >= 0 ? audio : nil
        bitRate = Int(rift_cast_bit_rate(handle))
    }

    deinit { rift_cast_close(handle) }

    private let bitRate: Int

    public func segmentStart(_ index: Int) -> Double {
        rift_cast_segment_start(handle, Int32(index))
    }

    public func initSegment() -> Data? {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard rift_cast_init_segment(handle, &pointer, &length) == 0, let pointer else { return nil }
        defer { rift_cast_free(pointer) }
        return Data(bytes: pointer, count: length)
    }

    public func mediaSegment(_ index: Int) -> Data? {
        var pointer: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard rift_cast_media_segment(handle, Int32(index), &pointer, &length) == 0, let pointer else { return nil }
        defer { rift_cast_free(pointer) }
        return Data(bytes: pointer, count: length)
    }

    // MARK: - Listas HLS

    public var masterPlaylist: String {
        var attributes = ["BANDWIDTH=\(max(bitRate, 1_000_000))", "CODECS=\"\(codecs)\""]
        if width > 0, height > 0 { attributes.append("RESOLUTION=\(width)x\(height)") }
        attributes.append(String(format: "FRAME-RATE=%.3f", frameRate))
        switch videoRange {
        case .sdr: attributes.append("VIDEO-RANGE=SDR")
        case .pq: attributes.append("VIDEO-RANGE=PQ")
        case .hlg: attributes.append("VIDEO-RANGE=HLG")
        }
        return """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-STREAM-INF:\(attributes.joined(separator: ","))
        media.m3u8

        """
    }

    public var mediaPlaylist: String {
        var durations: [Double] = []
        for index in 0..<segmentCount {
            durations.append(segmentStart(index + 1) - segmentStart(index))
        }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int((durations.max() ?? 6).rounded(.up)))",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for (index, duration) in durations.enumerated() {
            lines.append(String(format: "#EXTINF:%.5f,", duration))
            lines.append("segment-\(index).m4s")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
