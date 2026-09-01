import Foundation

// MARK: - Demuxing
//
// Surface of Core/Demux. Opens a container (MKV), reads compressed packets
// on demand (one at a time), seeks via the container index, and never decodes.

public enum TrackKind: Int, Equatable {
    case video = 0
    case audio = 1
    case other = 2
}

/// Metadata of one container track. Resolution, frame rate and duration are
/// reported when the container exposes them.
public struct TrackInfo: Equatable {
    public let streamIndex: Int
    public let kind: TrackKind
    public let codecName: String
    public let width: Int?
    public let height: Int?
    public let frameRate: Double?
    public let duration: Double

    /// Raw AVColorTransferCharacteristic (e.g. SMPTE2084/PQ for HDR10,
    /// SMPTE2086/HLG for HLG). Demux only reports the primitive — deciding
    /// "what counts as HDR" belongs to the Rendering layer.
    public let colorTransfer: Int?
    /// Raw AVColorPrimaries.
    public let colorPrimaries: Int?

    /// CodecPrivate bytes (VPS/SPS/PPS for HEVC) exposed raw and uninterpreted:
    /// Decode needs them to build a CMFormatDescription; Demux decides nothing
    /// about VideoToolbox. Empty when the container has none.
    public let codecExtradata: [UInt8]

    public init(
        streamIndex: Int,
        kind: TrackKind,
        codecName: String,
        width: Int?,
        height: Int?,
        frameRate: Double?,
        duration: Double,
        colorTransfer: Int?,
        colorPrimaries: Int?,
        codecExtradata: [UInt8]
    ) {
        self.streamIndex = streamIndex
        self.kind = kind
        self.codecName = codecName
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.duration = duration
        self.colorTransfer = colorTransfer
        self.colorPrimaries = colorPrimaries
        self.codecExtradata = codecExtradata
    }
}

/// Container-level summary returned by `open(url:)`.
public struct ContainerInfo: Equatable {
    public let duration: Double
    public let tracks: [TrackInfo]

    public init(duration: Double, tracks: [TrackInfo]) {
        self.duration = duration
        self.tracks = tracks
    }
}

/// One compressed packet: an opaque byte blob plus timing metadata.
/// Data is NOT decoded — decoding belongs to Core/Decode.
public struct CompressedPacket: Equatable {
    public let streamIndex: Int
    /// Presentation timestamp in seconds (stream timebase, 0 if N/A).
    public let pts: Double
    /// Decoding timestamp in seconds (0 if N/A).
    public let dts: Double
    public let duration: Double
    public let isKeyframe: Bool
    /// Raw compressed bytes (HEVC NAL units / AAC frames, etc.).
    public let data: [UInt8]

    public init(
        streamIndex: Int,
        pts: Double,
        dts: Double,
        duration: Double,
        isKeyframe: Bool,
        data: [UInt8]
    ) {
        self.streamIndex = streamIndex
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.isKeyframe = isKeyframe
        self.data = data
    }
}

public enum DemuxError: Error, CustomStringConvertible {
    /// Opening the container failed; the payload is libavformat's message.
    case openFailed(String)
    case readFailed
    case seekFailed
    case notOpen

    public var description: String {
        switch self {
        case .openFailed(let message):
            return "Demux: could not open container — \(message)"
        case .readFailed:
            return "Demux: failed to read the next packet"
        case .seekFailed:
            return "Demux: seek failed"
        case .notOpen:
            return "Demux: no container is open"
        }
    }
}

/// Streaming container reader. Implementations must:
/// - read the source only on demand (never fully into memory, never copied to disk)
/// - never decode packets — Core/Decode does that
/// - keep memory bounded regardless of the source duration
public protocol Demuxing: AnyObject {
    /// Opens `url` and returns container-level info (tracks, duration).
    /// Opening reads only headers/index, so it must stay < ~1s even on very
    /// large files.
    func open(url: URL) throws -> ContainerInfo

    /// Returns the next compressed packet (video or audio) or `nil` at EOF.
    func nextPacket() throws -> CompressedPacket?

    /// Repositions reading to the keyframe closest to `time` (seconds),
    /// without reading any packet before it.
    func seek(to time: Double) throws

    func close()
}