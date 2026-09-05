// ffmpeg_audio.h — thin C shim over libavcodec for Core/DecodeAudio.
//
// This is a PURE C wrapper: it hides the FFmpeg headers (AVCodecContext,
// AVFrame, AVPacket, macros) from Swift. It decodes EAC3 (and theoretically
// other codecs by name) into interleaved PCM float32 frames.
//
// Memory contract: an opaque RiftAudioDecCtx* owns the AVCodecContext and
// AVFrame. The PCM data pointer returned by rift_audio_decode_frame is only
// valid until the next decode call on the same context; the Swift side
// copies the bytes out.

#ifndef ffmpeg_audio_h
#define ffmpeg_audio_h

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RiftAudioDecCtx RiftAudioDecCtx;

/* One decoded audio frame: interleaved PCM float32, sample_rate × channels. */
typedef struct {
    int64_t pts_90khz;        /* raw AVFrame pts in 90kHz ticks (container base) */
    double  pts_seconds;      /* pts converted to seconds (stream timebase) */
    int     nb_samples;       /* number of samples per channel in this frame */
    int     sample_rate;      /* e.g. 48000 */
    int     channels;         /* e.g. 2 */
    const float *pcm;         /* interleaved float32, nb_samples * channels floats */
    size_t  pcm_bytes;        /* size in bytes of the pcm buffer */
} RiftAudioFrameC;

/* Returns NULL on failure; error_buffer receives a human-readable message.
 * `extradata`/`extradata_size` is the codec-private data (e.g. AAC
 * AudioSpecificConfig) and `sample_rate`/`channels` the stream audio params,
 * all of which MUST be set on the codec context before it is opened. They may
 * be NULL/0 for codecs that are self-contained per-packet (EAC3). */
RiftAudioDecCtx *rift_audio_decode_open(const char *codec_name,
                                        const uint8_t *extradata, int extradata_size,
                                        int sample_rate, int channels,
                                        char *error_buffer, size_t error_buffer_size);

/* Decodes one compressed packet. Returns:
 *   >0 number of frames written to `out_frames` (up to max_frames)
 *    0 if more input is needed (buffered)
 *   <0 on error
 *
 * `out_frames` must point to an array of at least max_frames RiftAudioFrameC.
 * The .pcm pointers in the output are only valid until the next call on
 * the same context; the caller must copy the PCM data out if retaining.
 */
int rift_audio_decode_packet(RiftAudioDecCtx *ctx,
                             const uint8_t *packet_data, int packet_size,
                             double packet_pts_seconds,
                             RiftAudioFrameC *out_frames, int max_frames);

/* Flushes the decoder (EOF on input). Same return semantics as decode. */
int rift_audio_decode_flush(RiftAudioDecCtx *ctx,
                            RiftAudioFrameC *out_frames, int max_frames);

/* Last error string on this context (empty if none). */
const char *rift_audio_decode_last_error(RiftAudioDecCtx *ctx);

/* Sample format name ("fltp", "flt", "s16", ...) of the most recently
 * decoded frame on this context, or NULL if none yet. For diagnostics. */
const char *rift_audio_decode_last_sample_fmt(RiftAudioDecCtx *ctx);

void rift_audio_decode_close(RiftAudioDecCtx *ctx);

#ifdef __cplusplus
}
#endif

#endif /* ffmpeg_audio_h */
