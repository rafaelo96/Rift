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

typedef struct RiftQNode {
    struct RiftQNode *next;
    AVPacket *pkt;      /* owned reference; freed on dequeue */
    int64_t   rank;     /* display rank for video packets, -1 = pending */
    int       is_video;
} RiftQNode;

struct RiftDemuxCtx {
    AVFormatContext *fmt;
    AVPacket        *pkt;

    /* Legacy containers (AVI with B-frame codecs) carry no video PTS at all,
     * only decode-order DTS. libavformat refuses to derive PTS for H.264
     * ("We skip H264 currently", demux.c) and FFmpeg 8 keeps AVStream parsing
     * private, so this shim runs its own AVCodecParser — a metadata-only
     * parse of slice headers, no pixel decoding — to recover each picture's
     * display rank from its POC (output_picture_number). A picture's rank is
     * only known once the NEXT picture's start has been seen, so video
     * packets are delayed by one packet in a small in-order FIFO (audio
     * packets interleaved in between queue behind them). */
    AVCodecParserContext *parser;
    AVCodecContext       *parser_ctx;
    int                   parser_stream;    /* stream index using the parser, -1 = none */
    double                frame_interval;   /* seconds per displayed frame */
    int64_t               poc_base;         /* rank offset carried across IDR POC resets */
    int64_t               poc_max_rank;     /* highest absolute display rank assigned, -1 = none */
    double                first_video_seconds; /* dts of first video pkt after open/seek */
    int                   have_first_video;
    RiftQNode            *queue_head, *queue_tail;
    RiftQNode            *queue_last_video; /* newest queued video awaiting rank */
    int                   eof;
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

/* Feed a video packet's bytes to the POC parser. A picture is only complete
 * once the next one starts, so the rank returned here belongs to the PREVIOUS
 * video packet — the caller stores it in the queued node. */
static void parser_feed(RiftDemuxCtx *ctx, const uint8_t *data, int size,
                        int64_t dts, int64_t pos, RiftQNode *pending_video) {
    while (size > 0) {
        uint8_t *ob = NULL;
        int ol = 0;
        int used = av_parser_parse2(ctx->parser, ctx->parser_ctx, &ob, &ol,
                                    data, size, AV_NOPTS_VALUE, dts, pos);
        if (used < 0) break;
        if (ol > 0 && pending_video && pending_video->rank < 0) {
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
            pending_video->rank = rank;
            if (rank > ctx->poc_max_rank) ctx->poc_max_rank = rank;
            if (getenv("RIFT_DEMUX_DEBUG")) {
                fprintf(stderr, "[poc] picture poc=%lld -> rank=%lld (prev rank fed packet)\n",
                        (long long)ctx->parser->output_picture_number,
                        (long long)rank);
            }
        }
        if (used == 0) break;
        data += used;
        size -= used;
    }
}

static int queue_push(RiftDemuxCtx *ctx, AVPacket *pkt, int is_video,
                      RiftQNode **out_node) {
    RiftQNode *node = (RiftQNode *)calloc(1, sizeof(*node));
    if (!node) return -1;
    node->pkt = av_packet_alloc();
    if (!node->pkt || av_packet_ref(node->pkt, pkt) < 0) {
        if (node->pkt) av_packet_free(&node->pkt);
        free(node);
        return -1;
    }
    node->rank = is_video ? -1 : 0;
    node->is_video = is_video;
    if (ctx->queue_tail) {
        ctx->queue_tail->next = node;
    } else {
        ctx->queue_head = node;
    }
    ctx->queue_tail = node;
    if (out_node) *out_node = node;
    return 0;
}

static void queue_flush(RiftDemuxCtx *ctx) {
    RiftQNode *n = ctx->queue_head;
    while (n) {
        RiftQNode *next = n->next;
        if (n->pkt) av_packet_free(&n->pkt);
        free(n);
        n = next;
    }
    ctx->queue_head = ctx->queue_tail = NULL;
    ctx->queue_last_video = NULL;
}

int rift_demux_next_packet(RiftDemuxCtx *ctx, RiftPacketC *out) {
    if (!ctx || !ctx->fmt || !out) {
        return -1;
    }

    /* Fast path: containers with native PTS are untouched (zero queueing). */
    if (ctx->parser_stream < 0) {
        av_packet_unref(ctx->pkt);
        int err = av_read_frame(ctx->fmt, ctx->pkt);
        if (err < 0) {
            return err == AVERROR_EOF ? 0 : -1;
        }
        fill_packet_out(ctx, ctx->pkt, -1, out);
        return 1;
    }

    /* Legacy path: feed the POC parser to recover true display order. Video
     * packets wait one packet in the queue until their rank is known. */
    for (;;) {
        if (ctx->queue_head &&
            (!ctx->queue_head->is_video || ctx->queue_head->rank >= 0)) {
            RiftQNode *node = ctx->queue_head;
            ctx->queue_head = node->next;
            if (!ctx->queue_head) ctx->queue_tail = NULL;
            if (ctx->queue_last_video == node) ctx->queue_last_video = NULL;
            /* Copy into ctx->pkt so `out->data` obeys the existing contract
             * (valid until the next call on this context). */
            av_packet_unref(ctx->pkt);
            if (av_packet_ref(ctx->pkt, node->pkt) < 0) {
                av_packet_free(&node->pkt);
                free(node);
                return -1;
            }
            int64_t rank = node->is_video ? node->rank : -1;
            av_packet_free(&node->pkt);
            free(node);
            fill_packet_out(ctx, ctx->pkt, rank, out);
            return 1;
        }
        if (ctx->eof) {
            return 0;
        }

        av_packet_unref(ctx->pkt);
        int err = av_read_frame(ctx->fmt, ctx->pkt);
        if (err < 0) {
            if (err != AVERROR_EOF) {
                return -1;
            }
            ctx->eof = 1;
            /* Parser and EOF flush: the final picture completes here. */
            if (ctx->queue_last_video && ctx->queue_last_video->rank < 0) {
                uint8_t *ob = NULL;
                int ol = 0;
                av_parser_parse2(ctx->parser, ctx->parser_ctx, &ob, &ol,
                                 NULL, 0, AV_NOPTS_VALUE, AV_NOPTS_VALUE, 0);
                ctx->queue_last_video->rank = ctx->poc_max_rank + 1;
                ctx->poc_max_rank = ctx->queue_last_video->rank;
            }
            continue;
        }

        int is_video = (ctx->pkt->stream_index == ctx->parser_stream);
        AVStream *st = ctx->fmt->streams[ctx->pkt->stream_index];
        RiftQNode *node = NULL;
        if (queue_push(ctx, ctx->pkt, is_video, &node) < 0) return -1;
        if (is_video && node) {
            if (!ctx->have_first_video) {
                ctx->have_first_video = 1;
                const int64_t d = ctx->pkt->dts != AV_NOPTS_VALUE
                    ? ctx->pkt->dts : ctx->pkt->pts;
                ctx->first_video_seconds = ts_to_seconds(d, st->time_base);
            }
            /* Parsing this packet completes the PREVIOUS picture. */
            if (getenv("RIFT_DEMUX_DEBUG") && ctx->queue_last_video) {
                fprintf(stderr, "[feed] video packet dts=%.3f; completing rank of previous video node\n",
                        ts_to_seconds(ctx->pkt->dts, st->time_base));
            }
            parser_feed(ctx, ctx->pkt->data, ctx->pkt->size,
                        ctx->pkt->dts != AV_NOPTS_VALUE ? ctx->pkt->dts : 0,
                        ctx->pkt->pos, ctx->queue_last_video);
            ctx->queue_last_video = node;
        }
    }
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
    if (err >= 0) {
        /* Drop queued packets and stale POC state: the parser's picture
         * assembly and the rank base must restart at the seek target. */
        queue_flush(ctx);
        if (ctx->parser) {
            enum AVCodecID id =
                ctx->fmt->streams[ctx->parser_stream]->codecpar->codec_id;
            AVCodecParserContext *fresh_parser = av_parser_init(id);
            if (!fresh_parser) return -1;
            av_parser_close(ctx->parser);
            ctx->parser = fresh_parser;
        }
        ctx->poc_base = 0;
        ctx->poc_max_rank = -1;
        ctx->have_first_video = 0;
        ctx->eof = 0;
    }
    return err < 0 ? -1 : 0;
}

void rift_demux_close(RiftDemuxCtx *ctx) {
    if (!ctx) {
        return;
    }
    queue_flush(ctx);
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
