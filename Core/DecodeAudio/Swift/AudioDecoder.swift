import Foundation
import Demux
import CDecodeAudioShim

/// Decodifica paquetes EAC3 a PCM float32 interleavado usando libavcodec.
/// Interfaz isolada: recibe CompressedPacket (de Core/Demux) y entrega
/// (pcmBytes, ptsSeconds, channels) por frame. Sin CoreMedia, sin UI.
public final class AudioDecoder {
    /// (pcmData, ptsSeconds, nbSamples, sampleRate, channels)
    public typealias DecodedAudioFrame = (data: Data, pts: Double, sampleCount: Int, sampleRate: Int, channels: Int)

    private var ctx: OpaquePointer?
    private var capacity: Int

    /// Nombre del sample_fmt crudo del último frame decodificado (diagnóstico).
    public var lastSampleFmtName: String {
        guard let ctx else { return "nil" }
        return String(cString: rift_audio_decode_last_sample_fmt(ctx))
    }

    /// `capacity` es el número máximo de frames por decodificación (EAC3 genera 1 frame por packet).
    public init(codecName: String = "eac3", capacity: Int = 4) throws {
        var err = [CChar](repeating: 0, count: 256)
        ctx = rift_audio_decode_open(codecName, &err, 256)
        guard ctx != nil else {
            let msg = String(cString: err)
            throw NSError(domain: "AudioDecoder", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed: \(msg)"])
        }
        self.capacity = capacity
    }

    deinit { if let c = ctx { rift_audio_decode_close(c) } }

    private func drain(withFrames body: (UnsafeMutablePointer<RiftAudioFrameC>, Int32) -> Int32) -> [DecodedAudioFrame] {
        guard let ctx else { return [] }
        var result: [DecodedAudioFrame] = []
        var buffer = [RiftAudioFrameC](repeating: RiftAudioFrameC(), count: capacity)
        let count = buffer.withUnsafeMutableBufferPointer { bufPtr -> Int32 in
            body(bufPtr.baseAddress!, Int32(capacity))
        }
        guard count > 0 else { return result }
        for i in 0..<Int(count) {
            let f = buffer[i]
            guard let pcm = f.pcm, f.pcm_bytes > 0 else { continue }
            let data = Data(bytes: pcm, count: Int(f.pcm_bytes))
            result.append((data: data, pts: f.pts_seconds, sampleCount: Int(f.nb_samples), sampleRate: Int(f.sample_rate), channels: Int(f.channels)))
        }
        return result
    }

    /// Decodifica 1 packet; devuelve hasta `capacity` frames de audio.
    public func decode(packet: CompressedPacket) -> [DecodedAudioFrame] {
        guard let ctx else { return [] }
        return packet.data.withUnsafeBufferPointer { bytes in
            drain(withFrames: { bufPtr, maxFrames in
                rift_audio_decode_packet(
                    ctx,
                    bytes.baseAddress,
                    Int32(packet.data.count),
                    packet.pts,
                    bufPtr,
                    maxFrames
                )
            })
        }
    }

    /// Flush final: devuelve frames pendientes (si alguno).
    public func flush() -> [DecodedAudioFrame] {
        guard let ctx else { return [] }
        return drain(withFrames: { bufPtr, maxFrames in
            rift_audio_decode_flush(ctx, bufPtr, maxFrames)
        })
    }
}
