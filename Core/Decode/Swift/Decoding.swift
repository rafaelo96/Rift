import Foundation
import CoreVideo
import Demux

// MARK: - VideoDecoding
//
// Surface of Core/Decode. Consumes Core/Demux output (CompressedPacket +
// TrackInfo with hvcC extradata) and produces one CVPixelBuffer per decoded
// video packet via VTDecompressionSession (hardware). Decoding is streaming:
// one access unit at a time, nothing accumulated on disk or in memory.

public enum DecodeError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case malformedHvcC(String)
    case malformedAvcC(String)
    case missingParameterSets
    case formatDescriptionFailed(OSStatus)
    case sessionFailed(OSStatus)
    case blockBufferFailed(OSStatus)
    case sampleBufferFailed(OSStatus)
    case decodeFailed(OSStatus)
    case notPrepared
    case wrongStream

    public var description: String {
        func hex(_ s: OSStatus) -> String { String(format: "0x%08x", s) }
        switch self {
        case .unsupportedFormat(let detail):
            return "Decode: unsupported format — \(detail)"
        case .malformedHvcC(let detail):
            return "Decode: malformed hvcC extradata — \(detail)"
        case .malformedAvcC(let detail):
            return "Decode: malformed avcC extradata — \(detail)"
        case .missingParameterSets:
            return "Decode: no VPS/SPS/PPS found in hvcC extradata"
        case .formatDescriptionFailed(let s):
            return "Decode: CMFormatDescription creation failed (\(hex(s)))"
        case .sessionFailed(let s):
            return "Decode: VTDecompressionSession creation failed (\(hex(s)))"
        case .blockBufferFailed(let s):
            return "Decode: CMBlockBuffer creation failed (\(hex(s)))"
        case .sampleBufferFailed(let s):
            return "Decode: CMSampleBuffer creation failed (\(hex(s)))"
        case .decodeFailed(let s):
            return "Decode: VTDecompressionSessionDecodeFrame failed (\(hex(s)))"
        case .notPrepared:
            return "Decode: prepare(track:) must be called first"
        case .wrongStream:
            return "Decode: packet streamIndex does not match the prepared track"
        }
    }
}

/// A decoded image and its presentation timestamp as reported by VideoToolbox.
/// The timestamp belongs to the output image, which may differ from the packet
/// currently being fed while codecs reorder B-frames.
public struct DecodedVideoFrame {
    public let pixelBuffer: CVPixelBuffer
    public let pts: Double

    public init(pixelBuffer: CVPixelBuffer, pts: Double) {
        self.pixelBuffer = pixelBuffer
        self.pts = pts
    }
}

/// Decoder for one video track. One packet in → (at most) one decoded frame out.
/// Implementations decode with hardware (VTDecompressionSession) and never
/// transcode nor write anything to disk.
public protocol VideoDecoding: AnyObject {
    /// Parses `track.codecExtradata` (hvcC) and creates the hardware session.
    /// Must be called before decoding; may be called again to switch tracks.
    func prepare(track: TrackInfo) throws

    /// Decodes one compressed packet into a frame with its output PTS.
    /// - Returns: the decoded frame, or `nil` if the packet produced no output
    ///   (e.g. a non-reference NAL). Output buffers carry the HDR color
    ///   CVBufferAttachments (color_trc/color_primaries from Demux).
    func decodeFrame(_ packet: CompressedPacket) throws -> DecodedVideoFrame?

    /// Flushes delayed/in-flight frames of the decoder (call after a seek).
    func flush()

    func close()
}
