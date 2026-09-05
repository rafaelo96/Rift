import Foundation
import CDemuxShim

// The C shim symbols (rift_demux_*, RiftDemuxCtx, RiftPacketC…) come from the
// CDemuxShim target.

/// FFmpeg/libavformat implementation of `Demuxing`.
///
/// Container access only — never decodes. `av_read_frame` pulls one packet at
/// a time from the demuxer's internal IO buffer (bounded, streaming); seeking
/// uses the container index/cues so nothing before the target is read.
public final class FFmpegDemuxer: Demuxing {
    private var ctx: OpaquePointer?

    public init() {}

    public func open(url: URL) throws -> ContainerInfo {
        close()

        var errorBuffer = Array(repeating: CChar(0), count: 256)
        guard let handle = rift_demux_open(url.path, &errorBuffer, errorBuffer.count) else {
            let message = String(cString: errorBuffer).isEmpty
                ? "unknown error"
                : String(cString: errorBuffer)
            throw DemuxError.openFailed(message)
        }
        ctx = handle

        let count = Int(rift_demux_track_count(handle))
        var tracks: [TrackInfo] = []
        tracks.reserveCapacity(count)
        for index in 0..<count {
            var raw = RiftTrackInfoC()
            guard rift_demux_track_info(handle, Int32(index), &raw) == 0 else { continue }
            tracks.append(TrackInfo(
                streamIndex: Int(raw.stream_index),
                kind: TrackKind(rawValue: Int(raw.kind)) ?? .other,
                codecName: raw.codec_name.map { String(cString: $0) } ?? "?",
                streamTitle: raw.stream_title.map { String(cString: $0) },
                streamLanguage: raw.stream_language.map { String(cString: $0) },
                width: raw.width > 0 ? Int(raw.width) : nil,
                height: raw.height > 0 ? Int(raw.height) : nil,
                frameRate: raw.frame_rate > 0 ? raw.frame_rate : nil,
                duration: raw.duration_seconds,
                sampleRate: raw.sample_rate > 0 ? Int(raw.sample_rate) : nil,
                channelCount: raw.channels > 0 ? Int(raw.channels) : nil,
                colorTransfer: raw.color_trc >= 0 ? Int(raw.color_trc) : nil,
                colorPrimaries: raw.color_primaries >= 0 ? Int(raw.color_primaries) : nil,
                codecExtradata: Array(UnsafeBufferPointer(start: raw.extradata, count: Int(raw.extradata_size)))
            ))
        }

        return ContainerInfo(
            duration: rift_demux_duration_seconds(handle),
            tracks: tracks
        )
    }

    public func nextPacket() throws -> CompressedPacket? {
        guard let ctx else { throw DemuxError.notOpen }

        var raw = RiftPacketC()
        let result = rift_demux_next_packet(ctx, &raw)
        if result == 0 { return nil } // end of stream
        if result < 0 { throw DemuxError.readFailed }

        // AV_PKT_FLAG_KEY == 0x0001 (macro unavailable to Swift)
        let isKeyframe = (raw.avflags & 0x0001) != 0

        let bytes = raw.size > 0
            ? Array(UnsafeBufferPointer(start: raw.data, count: Int(raw.size)))
            : []

        return CompressedPacket(
            streamIndex: Int(raw.stream_index),
            pts: raw.pts_seconds,
            dts: raw.dts_seconds,
            duration: raw.duration_seconds,
            isKeyframe: isKeyframe,
            data: bytes
        )
    }

    public func seek(to time: Double) throws {
        guard let ctx else { throw DemuxError.notOpen }
        guard rift_demux_seek(ctx, time) == 0 else {
            throw DemuxError.seekFailed
        }
    }

    public func close() {
        guard let ctx else { return }
        rift_demux_close(ctx)
        self.ctx = nil
    }

    deinit {
        if let ctx {
            rift_demux_close(ctx)
        }
    }
}