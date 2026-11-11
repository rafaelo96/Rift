#ifndef RIFT_CAST_C_H
#define RIFT_CAST_C_H

#include <stddef.h>
#include <stdint.h>

/// Reempaquetado en memoria de un archivo de video a segmentos fMP4 para HLS.
/// Los paquetes comprimidos se copian tal cual (sin decodificar ni recodificar)
/// y cada segmento se genera bajo demanda; nada se escribe en disco.
typedef struct RiftCast RiftCast;

/// `audio_stream` es el índice de pista de audio del contenedor, o -1 para la
/// primera compatible. Devuelve NULL y un mensaje en `err` si el archivo no se
/// puede enviar (sin índice de keyframes, códec no admitido por HLS…).
RiftCast *rift_cast_open(const char *path, int audio_stream, char *err, int err_len);
void rift_cast_close(RiftCast *cast);

int rift_cast_segment_count(const RiftCast *cast);
/// Inicio del segmento en segundos; con `index == count` devuelve el final.
double rift_cast_segment_start(const RiftCast *cast, int index);

int rift_cast_width(const RiftCast *cast);
int rift_cast_height(const RiftCast *cast);
double rift_cast_frame_rate(const RiftCast *cast);
int64_t rift_cast_bit_rate(const RiftCast *cast);
/// 0 = SDR, 1 = PQ (HDR10), 2 = HLG.
int rift_cast_video_range(const RiftCast *cast);
/// Atributo CODECS de HLS, p. ej. "hvc1.2.4.L150.B0,ec-3".
const char *rift_cast_codecs(const RiftCast *cast);
/// Índice de la pista de audio enviada, o -1 si va sin audio.
int rift_cast_audio_stream(const RiftCast *cast);

/// Segmento de inicialización (ftyp + moov). El llamador libera con rift_cast_free.
int rift_cast_init_segment(RiftCast *cast, uint8_t **out, size_t *len);
/// Segmento de medios `index` (moof + mdat).
int rift_cast_media_segment(RiftCast *cast, int index, uint8_t **out, size_t *len);
void rift_cast_free(uint8_t *buffer);

#endif
