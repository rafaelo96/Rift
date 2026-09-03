// ffmpeg_audio.c — C shim over libavcodec for Core/DecodeAudio.
// See ffmpeg_audio.h for the contract.

#include "ffmpeg_audio.h"
#include <libavcodec/avcodec.h>
#include <libavutil/opt.h>
#include <libavutil/mem.h>
#include <string.h>
#include <stdlib.h>

struct RiftAudioDecCtx {
    AVCodecContext *dec_ctx;
    AVFrame *frame;
    AVPacket *pkt;
    char last_error[256];
    /* Interleaved float32 output buffer: planar float frames are converted
     * into this scratch so the consumer always gets channels interleaved. */
    float *interleave_buf;
    size_t interleave_buf_size; /* in floats */
};

RiftAudioDecCtx *rift_audio_decode_open(const char *codec_name,
                                        char *error_buffer, size_t error_buffer_size) {
    const AVCodec *dec = avcodec_find_decoder_by_name(codec_name);
    if (!dec) {
        if (error_buffer) {
            snprintf(error_buffer, error_buffer_size, "Decoder not found for %s", codec_name);
        }
        return NULL;
    }

    RiftAudioDecCtx *ctx = calloc(1, sizeof(RiftAudioDecCtx));
    if (!ctx) {
        if (error_buffer) snprintf(error_buffer, error_buffer_size, "OOM");
        return NULL;
    }

    ctx->dec_ctx = avcodec_alloc_context3(dec);
    if (!ctx->dec_ctx) {
        if (error_buffer) snprintf(error_buffer, error_buffer_size, "Failed to allocate codec context");
        free(ctx);
        return NULL;
    }

    /* Force decode to PCM float32 planar/interleaved as appropriate */
    ctx->dec_ctx->request_sample_fmt = AV_SAMPLE_FMT_FLT;

    int ret = avcodec_open2(ctx->dec_ctx, dec, NULL);
    if (ret < 0) {
        if (error_buffer) av_strerror(ret, error_buffer, error_buffer_size);
        avcodec_free_context(&ctx->dec_ctx);
        free(ctx);
        return NULL;
    }

    ctx->frame = av_frame_alloc();
    ctx->pkt = av_packet_alloc();
    if (!ctx->frame || !ctx->pkt) {
        if (error_buffer) snprintf(error_buffer, error_buffer_size, "OOM on frame/packet alloc");
        rift_audio_decode_close(ctx);
        return NULL;
    }

    return ctx;
}

int rift_audio_decode_packet(RiftAudioDecCtx *ctx,
                             const uint8_t *packet_data, int packet_size,
                             double packet_pts_seconds,
                             RiftAudioFrameC *out_frames, int max_frames) {
    if (!ctx || !ctx->dec_ctx) return -1;
    if (max_frames <= 0) return 0;

    av_packet_unref(ctx->pkt);
    if (packet_data && packet_size > 0) {
        av_new_packet(ctx->pkt, packet_size);
        memcpy(ctx->pkt->data, packet_data, packet_size);
        ctx->pkt->pts = av_rescale_q((int64_t)(packet_pts_seconds * 90000),
                                     av_make_q(1, 90000),
                                     ctx->dec_ctx->time_base);
    } else {
        /* flush packet */
        ctx->pkt->data = NULL;
        ctx->pkt->size = 0;
        ctx->pkt->pts = AV_NOPTS_VALUE;
    }

    int ret = avcodec_send_packet(ctx->dec_ctx, ctx->pkt);
    if (ret < 0) {
        return ret;
    }

    int count = 0;
    while (count < max_frames) {
        ret = avcodec_receive_frame(ctx->dec_ctx, ctx->frame);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) {
            break;
        } else if (ret < 0) {
            return ret;
        }

        RiftAudioFrameC *out = &out_frames[count];
        memset(out, 0, sizeof(RiftAudioFrameC));
        out->nb_samples = ctx->frame->nb_samples;
        out->sample_rate = ctx->frame->sample_rate;
        out->channels = ctx->frame->ch_layout.nb_channels;
        out->pts_90khz = ctx->frame->pts;
        /* Seconds: frame->pts is in dec_ctx timebase; if unknown we compute
         * from pkt_timebase if available, else assume time_base;
         * simplified: use pkt_timebase via av_rescale. */
        if (ctx->frame->time_base.num != 0 && ctx->frame->time_base.den != 0) {
            out->pts_seconds = ctx->frame->pts * av_q2d(ctx->frame->time_base);
        } else {
            out->pts_seconds = packet_pts_seconds;
        }

        /* Convert to interleaved float32. EAC3 decodes to planar float
         * (AV_SAMPLE_FMT_FLTP), so we interleave into a scratch buffer. */
        const float *pcmsrc = NULL;
        if (ctx->frame->format == AV_SAMPLE_FMT_FLT) {
            pcmsrc = (const float *)ctx->frame->data[0];
            out->pcm = pcmsrc;
            out->pcm_bytes = (size_t)out->nb_samples * out->channels * sizeof(float);
        } else if (ctx->frame->format == AV_SAMPLE_FMT_FLTP || ctx->frame->format == AV_SAMPLE_FMT_S16P || ctx->frame->format == AV_SAMPLE_FMT_S32P) {
            /* planar: de-plane into scratch */
            int chs = out->channels;
            int nsamples = out->nb_samples;
            size_t floats_needed = (size_t)nsamples * chs;
            if (ctx->interleave_buf_size < floats_needed) {
                free(ctx->interleave_buf);
                ctx->interleave_buf = malloc(floats_needed * sizeof(float));
                ctx->interleave_buf_size = floats_needed;
            }
            if (!ctx->interleave_buf) {
                av_strerror(ENOMEM, ctx->last_error, sizeof(ctx->last_error));
                return -ENOMEM;
            }
            float *dst = ctx->interleave_buf;
            for (int s = 0; s < nsamples; s++) {
                for (int c = 0; c < chs; c++) {
                    float v = 0.0f;
                    if (ctx->frame->format == AV_SAMPLE_FMT_FLTP) {
                        v = ((const float *)ctx->frame->data[c])[s];
                    } else if (ctx->frame->format == AV_SAMPLE_FMT_S16P) {
                        v = ((const int16_t *)ctx->frame->data[c])[s] / 32768.0f;
                    } else if (ctx->frame->format == AV_SAMPLE_FMT_S32P) {
                        v = ((const int32_t *)ctx->frame->data[c])[s] / 2147483648.0f;
                    }
                    dst[s * chs + c] = v;
                }
            }
            out->pcm = ctx->interleave_buf;
            out->pcm_bytes = floats_needed * sizeof(float);
        } else {
            snprintf(ctx->last_error, sizeof(ctx->last_error),
                     "unsupported sample format: %s", av_get_sample_fmt_name(ctx->frame->format));
            return AVERROR_INVALIDDATA;
        }

        count++;
    }

    return count;
}

int rift_audio_decode_flush(RiftAudioDecCtx *ctx,
                            RiftAudioFrameC *out_frames, int max_frames) {
    return rift_audio_decode_packet(ctx, NULL, 0, 0, out_frames, max_frames);
}

const char *rift_audio_decode_last_error(RiftAudioDecCtx *ctx) {
    return ctx ? ctx->last_error : "";
}

void rift_audio_decode_close(RiftAudioDecCtx *ctx) {
    if (!ctx) return;
    if (ctx->frame) av_frame_free(&ctx->frame);
    if (ctx->pkt) av_packet_free(&ctx->pkt);
    if (ctx->dec_ctx) avcodec_free_context(&ctx->dec_ctx);
    free(ctx);
}
