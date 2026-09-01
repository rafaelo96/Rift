// ffmpeg_c.c — thin C shim over libavformat for Core/Demux. See ffmpeg_c.h.
//
// Container access ONLY (streaming, one packet at a time). No decoder is ever
// opened or called; the payload bytes are passed through untouched.

#include "ffmpeg_c.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>

struct RiftDemuxCtx {
    AVFormatContext *fmt;
    AVPacket        *pkt;
};

static double ts_to_seconds(int64_t ts, const AVRational tb) {
    if (ts == AV_NOPTS_VALUE || tb.num == 0 || tb.den == 0) {
        return 0.0;
    }
    return (double)ts * av_q2d(tb);
}

RiftDemuxCtx *rift_demux_open(const char *path,
                              char *error_buffer, size_t error_buffer_size) {
    if (error_buffer && error_buffer_size) error_buffer[0] = '\0';

    AVFormatContext *fmt = NULL;
    int err = avformat_open_input(&fmt, path, NULL, NULL);
    if (err < 0) {
        if (error_buffer && error_buffer_size) {
            av_strerror(err, error_buffer, (int)error_buffer_size);
        }
        return NULL;
    }

    /* Reads only enough to discover stream headers — never the whole file. */
    avformat_find_stream_info(fmt, NULL);

    RiftDemuxCtx *ctx = (RiftDemuxCtx *)calloc(1, sizeof(*ctx));
    if (!ctx) {
        avformat_close_input(&fmt);
        if (error_buffer && error_buffer_size) {
            snprintf(error_buffer, error_buffer_size, "out of memory");
        }
        return NULL;
    }
    ctx->fmt = fmt;
    ctx->pkt = av_packet_alloc();
    if (!ctx->pkt) {
        avformat_close_input(&fmt);
        free(ctx);
        return NULL;
    }
    return ctx;
}

double rift_demux_duration_seconds(RiftDemuxCtx *ctx) {
    if (!ctx || !ctx->fmt || ctx->fmt->duration == AV_NOPTS_VALUE) {
        return 0.0;
    }
    return (double)ctx->fmt->duration / (double)AV_TIME_BASE;
}

int rift_demux_track_count(RiftDemuxCtx *ctx) {
    return ctx && ctx->fmt ? (int)ctx->fmt->nb_streams : 0;
}

int rift_demux_track_info(RiftDemuxCtx *ctx, int index, RiftTrackInfoC *out) {
    if (!ctx || !out || !ctx->fmt ||
        index < 0 || index >= (int)ctx->fmt->nb_streams) {
        return -1;
    }

    AVStream *st = ctx->fmt->streams[index];
    const AVCodecParameters *par = st->codecpar;

    memset(out, 0, sizeof(*out));
    out->stream_index = index;

    switch (par->codec_type) {
    case AVMEDIA_TYPE_VIDEO: out->kind = RIFT_TRACK_VIDEO; break;
    case AVMEDIA_TYPE_AUDIO: out->kind = RIFT_TRACK_AUDIO; break;
    default:                 out->kind = RIFT_TRACK_OTHER; break;
    }

    const char *name = avcodec_get_name(par->codec_id);
    out->codec_name = name ? name : "?";

    out->width = par->width;
    out->height = par->height;

    out->frame_rate = 0.0;
    if (st->avg_frame_rate.num > 0 && st->avg_frame_rate.den > 0) {
        out->frame_rate = av_q2d(st->avg_frame_rate);
    } else if (st->r_frame_rate.num > 0 && st->r_frame_rate.den > 0) {
        out->frame_rate = av_q2d(st->r_frame_rate);
    }

    out->duration_seconds = ts_to_seconds(st->duration, st->time_base);

    /* Raw color metadata. Whether this is "HDR" is a decision for the
     * Rendering layer later; Demux only reports the primitives. */
    out->color_trc = par->color_trc;
    out->color_primaries = par->color_primaries;

    return 0;
}

int rift_demux_next_packet(RiftDemuxCtx *ctx, RiftPacketC *out) {
    if (!ctx || !ctx->fmt || !out) {
        return -1;
    }

    int err = av_read_frame(ctx->fmt, ctx->pkt);
    if (err < 0) {
        if (err == AVERROR_EOF) {
            return 0; /* clean end of stream */
        }
        return -1;
    }

    AVStream *st = ctx->fmt->streams[ctx->pkt->stream_index];

    memset(out, 0, sizeof(*out));
    out->stream_index = (int32_t)ctx->pkt->stream_index;
    out->pts_seconds = ts_to_seconds(ctx->pkt->pts, st->time_base);
    out->dts_seconds = ts_to_seconds(ctx->pkt->dts, st->time_base);
    out->duration_seconds =
        ctx->pkt->duration > 0
            ? (double)ctx->pkt->duration * av_q2d(st->time_base)
            : 0.0;
    out->avflags = ctx->pkt->flags;
    out->size = ctx->pkt->size;
    out->data = ctx->pkt->data;
    return 1;
}

int rift_demux_seek(RiftDemuxCtx *ctx, double seconds) {
    if (!ctx || !ctx->fmt) {
        return -1;
    }

    int video = av_find_best_stream(ctx->fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (video < 0) {
        video = 0; /* fallback: seek on the first stream */
    }
    if (video >= (int)ctx->fmt->nb_streams) {
        return -1;
    }

    AVStream *st = ctx->fmt->streams[video];
    int64_t target =
        av_rescale_q((int64_t)(seconds * (double)AV_TIME_BASE),
                     AV_TIME_BASE_Q, st->time_base);

    int err = av_seek_frame(ctx->fmt, video, target, AVSEEK_FLAG_BACKWARD);
    if (err < 0) {
        /* Generic seek across streams as a last resort. */
        err = av_seek_frame(ctx->fmt, -1,
                            (int64_t)(seconds * (double)AV_TIME_BASE),
                            AVSEEK_FLAG_BACKWARD);
    }
    return err < 0 ? -1 : 0;
}

void rift_demux_close(RiftDemuxCtx *ctx) {
    if (!ctx) {
        return;
    }
    if (ctx->pkt) {
        av_packet_free(&ctx->pkt);
    }
    if (ctx->fmt) {
        avformat_close_input(&ctx->fmt);
    }
    free(ctx);
}