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
    int              packet_pending; /* pkt already filled by seek preroll */

    /* Legacy containers (AVI with B-frame codecs) carry no video PTS at all,
     * only decode-order DTS. libavformat refuses to derive PTS for H.264
     * ("We skip H264 currently", demux.c) and FFmpeg 8 keeps AVStream parsing
     * private, so this shim runs its own AVCodecParser — a metadata-only
     * parse of slice headers, no pixel decoding — to recover each picture's
     * display rank from its POC (output_picture_number). AVI chunks already
     * delimit complete access units, so the parser is configured to report
     * the rank for the current packet without buffering another packet. */
    AVCodecParserContext *parser;
    AVCodecContext       *parser_ctx;
    int                   parser_stream;    /* stream index using the parser, -1 = none */
    double                frame_interval;   /* seconds per displayed frame */
    int64_t               poc_base;         /* rank offset carried across IDR POC resets */
    int64_t               poc_max_rank;     /* highest absolute display rank assigned, -1 = none */
    double                first_video_seconds; /* dts of first video pkt after open/seek */
    int                   have_first_video;
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

    AVFormatContext *fmt = avformat_alloc_context();
    if (!fmt) {
        if (error_buffer && error_buffer_size) {
            snprintf(error_buffer, error_buffer_size, "out of memory");
        }
        return NULL;
    }

    /* Ask libavformat to derive missing presentation timestamps before
     * packets leave Demux. NOTE: for legacy AVI/H.264 this can only fall
     * back to pts=dts (decode order), which is NOT the presentation order
     * when the stream has B-frames — libavformat's compute_pkt_fields
     * explicitly skips H.264 ("We skip H264 currently", demux.c). For those
     * containers this shim recovers presentation order itself from the
     * bitstream POC via an AVCodecParser (see RiftDemuxCtx). */
    fmt->flags |= AVFMT_FLAG_GENPTS;
    int err = avformat_open_input(&fmt, path, NULL, NULL);
    if (err < 0) {
        if (error_buffer && error_buffer_size) {
            av_strerror(err, error_buffer, (int)error_buffer_size);
        }
        if (fmt) {
            avformat_close_input(&fmt);
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
    ctx->parser_stream = -1;
    ctx->poc_max_rank = -1;
    if (!ctx->pkt) {
        avformat_close_input(&fmt);
        free(ctx);
        return NULL;
    }

    /* Enable the POC-rank parser only for the validated case: AVI/H.264. */
    if (fmt->iformat && fmt->iformat->name &&
        strcmp(fmt->iformat->name, "avi") == 0) {
        for (unsigned i = 0; i < fmt->nb_streams; i++) {
            AVStream *st = fmt->streams[i];
            AVCodecParameters *par = st->codecpar;
            if (par->codec_type != AVMEDIA_TYPE_VIDEO) continue;
            if (par->codec_id != AV_CODEC_ID_H264) continue;
            AVCodecParserContext *parser = av_parser_init(par->codec_id);
            if (!parser) continue;
            /* AVI chunks already delimit complete H.264 access units. Without
             * this flag the parser may buffer multiple chunks and cannot map
             * one presentation rank to each packet deterministically. */
            parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
            AVCodecContext *pctx = avcodec_alloc_context3(NULL);
            if (!pctx || avcodec_parameters_to_context(pctx, par) < 0) {
                av_parser_close(parser);
                if (pctx) avcodec_free_context(&pctx);
                continue;
            }
            ctx->parser = parser;
            ctx->parser_ctx = pctx;
            ctx->parser_stream = (int)i;
            double fps = st->avg_frame_rate.num > 0 && st->avg_frame_rate.den > 0
                ? av_q2d(st->avg_frame_rate)
                : (st->r_frame_rate.num > 0 && st->r_frame_rate.den > 0
                    ? av_q2d(st->r_frame_rate) : 24.0);
            if (fps <= 0) fps = 24.0;
            ctx->frame_interval = 1.0 / fps;
            break;
        }
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

    /* Stream title (raw "title" metadata, e.g. the language label of a
     * subtitle track). NULL if the stream has no such tag. */
    {
        AVDictionaryEntry *tag = av_dict_get(st->metadata, "title", NULL, 0);
        out->stream_title = tag ? tag->value : NULL;
    }
    /* Stream language code (raw "language" metadata, e.g. "spa"/"eng").
     * NULL if the stream has no such tag. Exposed raw, not interpreted. */
    {
        AVDictionaryEntry *tag = av_dict_get(st->metadata, "language", NULL, 0);
        out->stream_language = tag ? tag->value : NULL;
    }

    out->width = par->width;
    out->height = par->height;

    out->frame_rate = 0.0;
    if (st->avg_frame_rate.num > 0 && st->avg_frame_rate.den > 0) {
        out->frame_rate = av_q2d(st->avg_frame_rate);
    } else if (st->r_frame_rate.num > 0 && st->r_frame_rate.den > 0) {
        out->frame_rate = av_q2d(st->r_frame_rate);
    }

    out->duration_seconds = ts_to_seconds(st->duration, st->time_base);

    /* Audio params (raw; 0 for video/other tracks). Demux only reports the
     * primitives — deciding anything about them belongs to DecodeAudio. */
    out->sample_rate = par->sample_rate > 0 ? par->sample_rate : 0;
#if LIBAVCODEC_VERSION_INT >= AV_VERSION_INT(59, 0, 0)
    out->channels = par->ch_layout.nb_channels > 0 ? par->ch_layout.nb_channels : 0;
#else
    out->channels = par->channels > 0 ? par->channels : 0;
#endif

    /* Raw color metadata. Whether this is "HDR" is a decision for the
     * Rendering layer later; Demux only reports the primitives. */
    out->color_trc = par->color_trc;
    out->color_primaries = par->color_primaries;

    /* CodecPrivate (VPS/SPS/PPS for HEVC). Pointer owned by the
     * AVFormatContext; the caller must copy it before using the ctx. */
    out->extradata_size = par->extradata_size;
    out->extradata = par->extradata;

    return 0;
}

int rift_demux_chapter_count(RiftDemuxCtx *ctx) {
    return ctx && ctx->fmt ? (int)ctx->fmt->nb_chapters : 0;
}

int rift_demux_chapter_info(RiftDemuxCtx *ctx, int index, RiftChapterInfoC *out) {
    if (!ctx || !ctx->fmt || !out || index < 0 || index >= (int)ctx->fmt->nb_chapters) {
        return -1;
    }

    AVChapter *chapter = ctx->fmt->chapters[index];
    memset(out, 0, sizeof(*out));
    out->start_seconds = ts_to_seconds(chapter->start, chapter->time_base);
    out->end_seconds = ts_to_seconds(chapter->end, chapter->time_base);
    {
        AVDictionaryEntry *tag = av_dict_get(chapter->metadata, "title", NULL, 0);
        out->title = tag ? tag->value : NULL;
    }
    return 0;
}

/* Convert an owned AVPacket into the public RiftPacketC view. For a parsed
 * video packet with display rank >= 0 the presentation timestamp is
 * synthesized from the POC rank (true display order); everything else keeps
 * the container/native timestamps. */
static void fill_packet_out(RiftDemuxCtx *ctx, AVPacket *pkt, int64_t rank,
                            RiftPacketC *out) {
    AVStream *st = ctx->fmt->streams[pkt->stream_index];

    memset(out, 0, sizeof(*out));
    out->stream_index = (int32_t)pkt->stream_index;
    const int64_t presentation_ts =
        pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
    const int64_t decoding_ts =
        pkt->dts != AV_NOPTS_VALUE ? pkt->dts : pkt->pts;
    out->dts_seconds = ts_to_seconds(decoding_ts, st->time_base);
    out->pts_seconds = ts_to_seconds(presentation_ts, st->time_base);
    if (rank >= 0) {
        out->pts_seconds = ctx->first_video_seconds
            + (double)rank * ctx->frame_interval;
    }
    out->duration_seconds =
        pkt->duration > 0
            ? (double)pkt->duration * av_q2d(st->time_base)
            : 0.0;
    out->avflags = pkt->flags;
    out->size = pkt->size;
    out->data = pkt->data;
}

/* Feed one complete AVI/H.264 access unit to the parser and return its
 * absolute presentation rank. */
static int64_t parser_rank(RiftDemuxCtx *ctx, const uint8_t *data, int size,
                           int64_t dts, int64_t pos) {
    while (size > 0) {
        uint8_t *ob = NULL;
        int ol = 0;
        int used = av_parser_parse2(ctx->parser, ctx->parser_ctx, &ob, &ol,
                                    data, size, AV_NOPTS_VALUE, dts, pos);
        if (used < 0) break;
        if (ol > 0) {
            /* output_picture_number is the picture order count (field units,
             * i.e. 2 per frame in frame-coded content). Translate to an
             * absolute display rank, healing POC resets at IDR boundaries by
             * continuing right after the highest rank assigned so far. */
            int64_t half_poc = ctx->parser->output_picture_number / 2;
            int64_t rank = half_poc + ctx->poc_base;
            /* Normal POC regression within a GOP (B-frames reference lower
             * POCs) is expected and is NOT a reset: only re-base when the
             * completed picture is an IDR-ish keyframe restarting numbering. */
            if (ctx->parser->key_frame && ctx->poc_max_rank >= 0 &&
                rank <= ctx->poc_max_rank) {
                ctx->poc_base += ctx->poc_max_rank + 1 - rank;
                rank = half_poc + ctx->poc_base;
            }
            if (rank > ctx->poc_max_rank) ctx->poc_max_rank = rank;
            if (getenv("RIFT_DEMUX_DEBUG")) {
                fprintf(stderr, "[poc] picture poc=%lld -> rank=%lld\n",
                        (long long)ctx->parser->output_picture_number,
                        (long long)rank);
            }
            return rank;
        }
        if (used == 0) break;
        data += used;
        size -= used;
    }
    return -1;
}

int rift_demux_next_packet(RiftDemuxCtx *ctx, RiftPacketC *out) {
    if (!ctx || !ctx->fmt || !out) {
        return -1;
    }

    int err = 0;
    if (ctx->packet_pending) {
        ctx->packet_pending = 0;
    } else {
        av_packet_unref(ctx->pkt);
        err = av_read_frame(ctx->fmt, ctx->pkt);
        if (err < 0) return err == AVERROR_EOF ? 0 : -1;
    }

    int64_t rank = -1;
    if (ctx->pkt->stream_index == ctx->parser_stream) {
        AVStream *st = ctx->fmt->streams[ctx->pkt->stream_index];
        if (!ctx->have_first_video) {
            ctx->have_first_video = 1;
            const int64_t d = ctx->pkt->dts != AV_NOPTS_VALUE
                ? ctx->pkt->dts : ctx->pkt->pts;
            ctx->first_video_seconds = ts_to_seconds(d, st->time_base);
        }
        rank = parser_rank(ctx, ctx->pkt->data, ctx->pkt->size,
                           ctx->pkt->dts != AV_NOPTS_VALUE ? ctx->pkt->dts : 0,
                           ctx->pkt->pos);
        if (rank < 0) return -1;
    }
    fill_packet_out(ctx, ctx->pkt, rank, out);
    return 1;
}

static int seek_stream_backward(RiftDemuxCtx *ctx, int video, int64_t target) {
    int err = av_seek_frame(ctx->fmt, video, target, AVSEEK_FLAG_BACKWARD);
    if (err < 0) {
        AVStream *st = ctx->fmt->streams[video];
        int64_t global_target = av_rescale_q(target, st->time_base, AV_TIME_BASE_Q);
        err = av_seek_frame(ctx->fmt, -1, global_target, AVSEEK_FLAG_BACKWARD);
    }
    return err;
}

/* MPEG-TS usually has no seek index. Its demuxer estimates a byte position,
 * which can land in the middle of an H.264 GOP even with AVSEEK_FLAG_BACKWARD.
 * VideoToolbox cannot start from such a packet because the reference frames
 * are absent. Search progressively earlier (bounded to 32 seconds), retaining
 * the first keyframe found as the next public packet. No payload is decoded,
 * copied to disk, or accumulated in memory. */
static int seek_mpegts_to_keyframe(RiftDemuxCtx *ctx, int video,
                                   int64_t target) {
    AVStream *st = ctx->fmt->streams[video];
    const int64_t one_second = av_rescale_q(AV_TIME_BASE, AV_TIME_BASE_Q,
                                            st->time_base);
    int64_t lookback = one_second;

    for (;;) {
        int64_t candidate = target > lookback ? target - lookback : 0;
        av_packet_unref(ctx->pkt);
        if (seek_stream_backward(ctx, video, candidate) < 0) return -1;

        int video_packets = 0;
        while (video_packets < 100000) {
            av_packet_unref(ctx->pkt);
            int err = av_read_frame(ctx->fmt, ctx->pkt);
            if (err < 0) break;
            if (ctx->pkt->stream_index != video) continue;
            video_packets++;

            int64_t packet_ts = ctx->pkt->dts != AV_NOPTS_VALUE
                ? ctx->pkt->dts : ctx->pkt->pts;
            if ((ctx->pkt->flags & AV_PKT_FLAG_KEY) &&
                (packet_ts == AV_NOPTS_VALUE || packet_ts <= target || candidate == 0)) {
                ctx->packet_pending = 1;
                return 0;
            }
            if (packet_ts != AV_NOPTS_VALUE && packet_ts > target) break;
        }

        if (candidate == 0 || lookback >= 32 * one_second) break;
        lookback *= 2;
        if (lookback > 32 * one_second) lookback = 32 * one_second;
    }
    av_packet_unref(ctx->pkt);
    return -1;
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

    ctx->packet_pending = 0;
    av_packet_unref(ctx->pkt);
    const int is_mpegts = ctx->fmt->iformat && ctx->fmt->iformat->name &&
        strcmp(ctx->fmt->iformat->name, "mpegts") == 0;
    int err = is_mpegts
        ? seek_mpegts_to_keyframe(ctx, video, target)
        : seek_stream_backward(ctx, video, target);
    if (err >= 0) {
        /* Stale parser/POC state must not cross the seek boundary. */
        if (ctx->parser) {
            enum AVCodecID id =
                ctx->fmt->streams[ctx->parser_stream]->codecpar->codec_id;
            AVCodecParserContext *fresh_parser = av_parser_init(id);
            if (!fresh_parser) return -1;
            fresh_parser->flags |= PARSER_FLAG_COMPLETE_FRAMES;
            av_parser_close(ctx->parser);
            ctx->parser = fresh_parser;
        }
        ctx->poc_base = 0;
        ctx->poc_max_rank = -1;
        ctx->have_first_video = 0;
    }
    return err < 0 ? -1 : 0;
}

void rift_demux_close(RiftDemuxCtx *ctx) {
    if (!ctx) {
        return;
    }
    if (ctx->parser) {
        av_parser_close(ctx->parser);
    }
    if (ctx->parser_ctx) {
        avcodec_free_context(&ctx->parser_ctx);
    }
    if (ctx->pkt) {
        av_packet_free(&ctx->pkt);
    }
    if (ctx->fmt) {
        avformat_close_input(&ctx->fmt);
    }
    free(ctx);
}
