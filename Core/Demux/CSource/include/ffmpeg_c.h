// ffmpeg_c.h — thin C shim over libavformat for Core/Demux.
//
// This is a PURE C wrapper: it hides the FFmpeg headers (AVFormatContext,
// AVRational, macros) from Swift. It only demuxes — it returns compressed
// packet bytes and container/track metadata. It NEVER decodes.
//
// Memory contract: an opaque RiftDemuxCtx* owns the AVFormatContext. The
// packet `data` pointer returned by rift_demux_next_packet is only valid
// until the next call on the same context; the Swift side copies the bytes.

#ifndef ffmpeg_c_h
#define ffmpeg_c_h

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct RiftDemuxCtx RiftDemuxCtx;

/* One compressed packet, as an opaque byte blob + metadata. */
typedef struct {
    int32_t  stream_index;
    double   pts_seconds;
    double   dts_seconds;
    double   duration_seconds;
    int32_t  avflags;          /* raw AVPacket.flags (AV_PKT_FLAG_KEY = 0x0001) */
    int32_t  size;
    const uint8_t *data;       /* valid until the next call on the same context */
} RiftPacketC;

typedef enum {
    RIFT_TRACK_VIDEO = 0,
    RIFT_TRACK_AUDIO = 1,
    RIFT_TRACK_OTHER = 2
} RiftTrackKindC;

typedef struct {
    int32_t     stream_index;
    int         kind;             /* RiftTrackKindC */
    const char *codec_name;       /* static string from avcodec_get_name */
    int         width;
    int         height;
    double      frame_rate;       /* 0 if unknown */
    double      duration_seconds; /* 0 if unknown */
    int         color_trc;        /* raw AVColorTransferCharacteristic (PQ/HLG/…). NO boolean */
    int         color_primaries;  /* raw AVColorPrimaries */
    int         extradata_size;   /* CodecPrivate / VPS+SPS+PPS for HEVC (0 if none) */
    const uint8_t *extradata;     /* owned by the context; valid while it is open */
} RiftTrackInfoC;

/* Returns NULL on failure; error_buffer receives a human-readable message. */
RiftDemuxCtx *rift_demux_open(const char *path,
                              char *error_buffer, size_t error_buffer_size);

/* Container-level duration in seconds (0 if unknown / no input). */
double rift_demux_duration_seconds(RiftDemuxCtx *ctx);

/* Number of streams (tracks) in the container. */
int rift_demux_track_count(RiftDemuxCtx *ctx);

/* Fills `out` for track `index`. Returns 0 on success, nonzero on error. */
int rift_demux_track_info(RiftDemuxCtx *ctx, int index, RiftTrackInfoC *out);

/* Reads the next compressed packet into `out`.
 * Returns 1 on success, 0 on end-of-stream, negative on error. */
int rift_demux_next_packet(RiftDemuxCtx *ctx, RiftPacketC *out);

/* Repositions to the keyframe closest to `seconds` without reading the
 * packets before it (uses the container index). Returns 0 on success. */
int rift_demux_seek(RiftDemuxCtx *ctx, double seconds);

void rift_demux_close(RiftDemuxCtx *ctx);

#ifdef __cplusplus
}
#endif

#endif /* ffmpeg_c_h */