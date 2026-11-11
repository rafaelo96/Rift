#include "cast_c.h"

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/mathematics.h>
#include <libavutil/opt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/// Duración mínima de un segmento; los cortes caen en keyframes del índice.
#define RIFT_CAST_MIN_SEGMENT 4.0

struct RiftCast {
    AVFormatContext *ic;
    int video;            // índice de stream de video
    int audio;            // índice de stream de audio, o -1
    int64_t *starts;      // inicio de cada segmento en time_base del video; [count] = final
    int count;
    int64_t first_pts;    // primer keyframe, origen de la numeración de frames
    AVRational frame_rate;
    int delay;            // frames de reordenamiento (dts = pts - delay)
    char codecs[96];
    uint8_t *init;        // segmento de inicialización en caché
    size_t init_len;
};

static void set_error(char *err, int err_len, const char *message) {
    if (err && err_len > 0) snprintf(err, (size_t)err_len, "%s", message);
}

static int audio_codec_tag(enum AVCodecID id, const char **hls) {
    switch (id) {
    case AV_CODEC_ID_AAC:  *hls = "mp4a.40.2"; return 1;
    case AV_CODEC_ID_AC3:  *hls = "ac-3";      return 1;
    case AV_CODEC_ID_EAC3: *hls = "ec-3";      return 1;
    default: return 0;
    }
}

/// CODECS de HLS para el video, leído del hvcC / avcC del contenedor.
static int video_codec_string(const AVCodecParameters *par, char *out, size_t len) {
    const uint8_t *e = par->extradata;
    if (par->codec_id == AV_CODEC_ID_H264) {
        if (!e || par->extradata_size < 4 || e[0] != 1) return 0;
        snprintf(out, len, "avc1.%02X%02X%02X", e[1], e[2], e[3]);
        return 1;
    }
    if (par->codec_id == AV_CODEC_ID_HEVC) {
        if (!e || par->extradata_size < 13 || e[0] != 1) return 0;
        int space = e[1] >> 6, tier = (e[1] >> 5) & 1, profile = e[1] & 0x1F;
        uint32_t compat = ((uint32_t)e[2] << 24) | ((uint32_t)e[3] << 16) | ((uint32_t)e[4] << 8) | e[5];
        uint32_t reversed = 0;
        for (int i = 0; i < 32; i++) if (compat & (1u << i)) reversed |= 1u << (31 - i);
        char constraints[32] = "";
        int last = 5;
        while (last >= 0 && e[6 + last] == 0) last--;
        for (int i = 0; i <= last; i++) {
            char part[8];
            snprintf(part, sizeof part, ".%02X", e[6 + i]);
            strlcat(constraints, part, sizeof constraints);
        }
        const char *spaces[] = { "", "A", "B", "C" };
        snprintf(out, len, "hvc1.%s%d.%X.%c%d%s", spaces[space], profile, reversed,
                 tier ? 'H' : 'L', e[12], constraints);
        return 1;
    }
    return 0;
}

RiftCast *rift_cast_open(const char *path, int audio_stream, char *err, int err_len) {
    RiftCast *c = calloc(1, sizeof *c);
    if (!c) return NULL;
    c->audio = -1;
    av_log_set_level(AV_LOG_ERROR);
    if (avformat_open_input(&c->ic, path, NULL, NULL) < 0) {
        set_error(err, err_len, "cannot open file");
        free(c);
        return NULL;
    }
    if (avformat_find_stream_info(c->ic, NULL) < 0) {
        set_error(err, err_len, "cannot read stream info");
        goto fail;
    }
    c->video = av_find_best_stream(c->ic, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (c->video < 0) { set_error(err, err_len, "no video stream"); goto fail; }
    AVStream *vs = c->ic->streams[c->video];

    char video_codec[64];
    if (!video_codec_string(vs->codecpar, video_codec, sizeof video_codec)) {
        set_error(err, err_len, "video codec not supported for AirPlay");
        goto fail;
    }

    const char *audio_codec = NULL;
    if (audio_stream >= 0 && audio_stream < (int)c->ic->nb_streams &&
        c->ic->streams[audio_stream]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO &&
        audio_codec_tag(c->ic->streams[audio_stream]->codecpar->codec_id, &audio_codec)) {
        c->audio = audio_stream;
    } else {
        // La pista pedida no es compatible: la primera que sí lo sea.
        for (unsigned i = 0; i < c->ic->nb_streams && c->audio < 0; i++) {
            AVCodecParameters *par = c->ic->streams[i]->codecpar;
            if (par->codec_type == AVMEDIA_TYPE_AUDIO && audio_codec_tag(par->codec_id, &audio_codec))
                c->audio = (int)i;
        }
    }
    if (c->audio >= 0) snprintf(c->codecs, sizeof c->codecs, "%s,%s", video_codec, audio_codec);
    else snprintf(c->codecs, sizeof c->codecs, "%s", video_codec);

    c->frame_rate = vs->avg_frame_rate.num > 0 ? vs->avg_frame_rate : vs->r_frame_rate;
    if (c->frame_rate.num <= 0 || c->frame_rate.den <= 0) {
        set_error(err, err_len, "unknown frame rate");
        goto fail;
    }
    c->delay = vs->codecpar->video_delay;

    // Matroska lee su índice (Cues) en el primer seek.
    av_seek_frame(c->ic, c->video, vs->start_time != AV_NOPTS_VALUE ? vs->start_time : 0, AVSEEK_FLAG_BACKWARD);
    int entries = avformat_index_get_entries_count(vs);
    if (entries < 2) { set_error(err, err_len, "file has no keyframe index"); goto fail; }

    c->starts = calloc((size_t)entries + 1, sizeof *c->starts);
    if (!c->starts) goto fail;
    int64_t min_gap = av_rescale_q((int64_t)(RIFT_CAST_MIN_SEGMENT * 1000), (AVRational){1, 1000}, vs->time_base);
    for (int i = 0; i < entries; i++) {
        const AVIndexEntry *entry = avformat_index_get_entry(vs, i);
        if (!entry || !(entry->flags & AVINDEX_KEYFRAME)) continue;
        if (c->count == 0 || entry->timestamp - c->starts[c->count - 1] >= min_gap)
            c->starts[c->count++] = entry->timestamp;
    }
    if (c->count < 1) { set_error(err, err_len, "file has no keyframe index"); goto fail; }
    c->first_pts = c->starts[0];

    int64_t end = AV_NOPTS_VALUE;
    if (vs->duration != AV_NOPTS_VALUE && vs->duration > 0)
        end = (vs->start_time != AV_NOPTS_VALUE ? vs->start_time : 0) + vs->duration;
    else if (c->ic->duration != AV_NOPTS_VALUE)
        end = av_rescale_q(c->ic->duration, AV_TIME_BASE_Q, vs->time_base);
    if (end == AV_NOPTS_VALUE || end <= c->starts[c->count - 1])
        end = c->starts[c->count - 1] + min_gap;
    c->starts[c->count] = end;
    return c;

fail:
    rift_cast_close(c);
    return NULL;
}

void rift_cast_close(RiftCast *c) {
    if (!c) return;
    if (c->ic) avformat_close_input(&c->ic);
    free(c->starts);
    free(c->init);
    free(c);
}

int rift_cast_segment_count(const RiftCast *c) { return c->count; }

double rift_cast_segment_start(const RiftCast *c, int index) {
    if (index < 0) index = 0;
    if (index > c->count) index = c->count;
    return (c->starts[index] - c->first_pts) * av_q2d(c->ic->streams[c->video]->time_base);
}

int rift_cast_width(const RiftCast *c) { return c->ic->streams[c->video]->codecpar->width; }
int rift_cast_height(const RiftCast *c) { return c->ic->streams[c->video]->codecpar->height; }
double rift_cast_frame_rate(const RiftCast *c) { return av_q2d(c->frame_rate); }
int64_t rift_cast_bit_rate(const RiftCast *c) { return c->ic->bit_rate; }
const char *rift_cast_codecs(const RiftCast *c) { return c->codecs; }
int rift_cast_audio_stream(const RiftCast *c) { return c->audio; }

int rift_cast_video_range(const RiftCast *c) {
    switch (c->ic->streams[c->video]->codecpar->color_trc) {
    case AVCOL_TRC_SMPTE2084: return 1;
    case AVCOL_TRC_ARIB_STD_B67: return 2;
    default: return 0;
    }
}

void rift_cast_free(uint8_t *buffer) { av_free(buffer); }

/// Genera el segmento `index`. Con `want_init` devuelve el moov en vez del
/// fragmento. Cada segmento usa un muxer propio; `frag_discont` hace que el
/// tfdt lleve el tiempo real del segmento, así que son independientes entre sí.
static int build_segment(RiftCast *c, int index, int want_init, uint8_t **out, size_t *len) {
    AVFormatContext *oc = NULL;
    AVPacket *pkt = NULL;
    int result = -1;
    AVStream *vs = c->ic->streams[c->video];
    AVStream *as = c->audio >= 0 ? c->ic->streams[c->audio] : NULL;

    if (avformat_alloc_output_context2(&oc, NULL, "mp4", NULL) < 0 || !oc) return -1;
    AVStream *ov = avformat_new_stream(oc, NULL);
    if (!ov || avcodec_parameters_copy(ov->codecpar, vs->codecpar) < 0) goto done;
    // Apple solo acepta HEVC con el tag hvc1 (parámetros en el moov).
    ov->codecpar->codec_tag = vs->codecpar->codec_id == AV_CODEC_ID_HEVC ? MKTAG('h', 'v', 'c', '1') : 0;
    ov->time_base = vs->time_base;
    ov->avg_frame_rate = c->frame_rate;
    AVStream *oa = NULL;
    if (as) {
        oa = avformat_new_stream(oc, NULL);
        if (!oa || avcodec_parameters_copy(oa->codecpar, as->codecpar) < 0) goto done;
        oa->codecpar->codec_tag = 0;
        oa->time_base = as->time_base;
    }
    if (avio_open_dyn_buf(&oc->pb) < 0) goto done;

    AVDictionary *options = NULL;
    // delay_moov: EAC3 necesita ver paquetes antes de escribir el moov.
    av_dict_set(&options, "movflags", "frag_custom+delay_moov+default_base_moof+frag_discont", 0);
    av_dict_set(&options, "use_editlist", "0", 0);
    av_dict_set(&options, "video_track_timescale", "90000", 0);
    oc->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    int header = avformat_write_header(oc, &options);
    av_dict_free(&options);
    if (header < 0) goto done;

    int64_t start = c->starts[index];
    int64_t end = index + 1 < c->count ? c->starts[index + 1] : INT64_MAX;
    int64_t tolerance = av_rescale_q(2, (AVRational){1, 1000}, vs->time_base);
    int64_t lead = av_rescale_q(1000, (AVRational){1, 1000}, vs->time_base);
    int64_t target = start - lead > c->first_pts ? start - lead : c->first_pts;
    if (av_seek_frame(c->ic, c->video, target, AVSEEK_FLAG_BACKWARD) < 0) goto done;

    // Matroska no guarda dts. Se numeran los frames desde el primer keyframe
    // (cadencia constante) para que el dts continúe exacto de un segmento a otro.
    AVRational frame_tb = av_inv_q(c->frame_rate);
    int64_t frame_number = av_rescale_q_rnd(start - c->first_pts, vs->time_base, frame_tb, AV_ROUND_NEAR_INF);
    int64_t first_out = av_rescale_q(c->first_pts, vs->time_base, ov->time_base);
    // Todo se desplaza `delay` frames para que el primer dts no sea negativo
    // (el tfdt de fMP4 no tiene signo). El audio se desplaza lo mismo.
    int64_t shift = av_rescale_q(c->delay, frame_tb, ov->time_base);
    int64_t audio_shift = as ? av_rescale_q(c->delay, frame_tb, (AVRational){1, as->codecpar->sample_rate > 0 ? as->codecpar->sample_rate : 48000}) : 0;

    int64_t audio_start = as ? av_rescale_q(start, vs->time_base, as->time_base) : 0;
    int64_t audio_end = as && end != INT64_MAX ? av_rescale_q(end, vs->time_base, as->time_base) : INT64_MAX;

    pkt = av_packet_alloc();
    if (!pkt) goto done;
    int started = 0, video_done = 0, audio_done = as ? 0 : 1, written = 0;
    while (!(video_done && audio_done) && av_read_frame(c->ic, pkt) >= 0) {
        int keep = 0;
        if (pkt->stream_index == c->video && !video_done) {
            int key = pkt->flags & AV_PKT_FLAG_KEY;
            if (!started && key && pkt->pts != AV_NOPTS_VALUE && pkt->pts >= start - tolerance) started = 1;
            if (started && key && written > 0 && pkt->pts != AV_NOPTS_VALUE && pkt->pts >= end - tolerance) {
                video_done = 1;
            } else if (started && pkt->pts != AV_NOPTS_VALUE) {
                int64_t pts = av_rescale_q(pkt->pts, vs->time_base, ov->time_base) + shift;
                int64_t dts = first_out + av_rescale_q(frame_number, frame_tb, ov->time_base);
                if (dts > pts) dts = pts;
                pkt->pts = pts;
                pkt->dts = dts;
                pkt->duration = av_rescale_q(1, frame_tb, ov->time_base);
                pkt->stream_index = ov->index;
                frame_number++;
                keep = 1;
            }
        } else if (as && pkt->stream_index == c->audio && !audio_done && pkt->pts != AV_NOPTS_VALUE) {
            if (pkt->pts >= audio_end) {
                audio_done = 1;
            } else if (pkt->pts >= audio_start) {
                av_packet_rescale_ts(pkt, as->time_base, oa->time_base);
                pkt->pts += av_rescale_q(audio_shift, (AVRational){1, as->codecpar->sample_rate > 0 ? as->codecpar->sample_rate : 48000}, oa->time_base);
                pkt->dts = pkt->pts;
                pkt->stream_index = oa->index;
                keep = 1;
            }
        }
        if (keep) {
            pkt->pos = -1;
            if (av_interleaved_write_frame(oc, pkt) < 0) { av_packet_unref(pkt); goto done; }
            written++;
        }
        av_packet_unref(pkt);
    }
    if (written == 0) goto done;
    if (av_interleaved_write_frame(oc, NULL) < 0) goto done;

    // Primer vaciado: moov. Segundo: moof + mdat con todos los paquetes.
    uint8_t *moov = NULL;
    if (av_write_frame(oc, NULL) < 0) goto done;
    int moov_len = avio_close_dyn_buf(oc->pb, &moov);
    oc->pb = NULL;
    if (want_init) {
        *out = moov;
        *len = (size_t)moov_len;
        result = moov_len > 0 ? 0 : -1;
        goto done;
    }
    av_free(moov);
    if (avio_open_dyn_buf(&oc->pb) < 0) goto done;
    if (av_write_frame(oc, NULL) < 0) goto done;
    uint8_t *fragment = NULL;
    int fragment_len = avio_close_dyn_buf(oc->pb, &fragment);
    oc->pb = NULL;
    *out = fragment;
    *len = (size_t)fragment_len;
    result = fragment_len > 0 ? 0 : -1;

done:
    av_packet_free(&pkt);
    if (oc) {
        if (oc->pb) { uint8_t *rest = NULL; avio_close_dyn_buf(oc->pb, &rest); av_free(rest); oc->pb = NULL; }
        avformat_free_context(oc);
    }
    return result;
}

int rift_cast_init_segment(RiftCast *c, uint8_t **out, size_t *len) {
    if (!c->init) {
        uint8_t *data = NULL;
        size_t size = 0;
        if (build_segment(c, 0, 1, &data, &size) < 0) return -1;
        c->init = malloc(size);
        if (!c->init) { av_free(data); return -1; }
        memcpy(c->init, data, size);
        c->init_len = size;
        av_free(data);
    }
    *out = av_malloc(c->init_len);
    if (!*out) return -1;
    memcpy(*out, c->init, c->init_len);
    *len = c->init_len;
    return 0;
}

int rift_cast_media_segment(RiftCast *c, int index, uint8_t **out, size_t *len) {
    if (index < 0 || index >= c->count) return -1;
    return build_segment(c, index, 0, out, len);
}
