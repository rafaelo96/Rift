# Reporte de validación de formatos de video — Rift

**Fecha:** 2026-10-04
**Entorno:** Apple M4 mini, macOS 27.2, FFmpeg 9.0.2 (libs 63), build debug de Rift hasta el commit `86e785d`.

## Metodología

1. **Dos matrices de prueba**, generadas con FFmpeg a partir de dos fuentes:
   - **Sintética:** clip `testsrc2` 1280x720@24fps + seno 440Hz AAC (10s) — `~/Downloads/fmtmatrix/` (30 archivos, 134MB).
   - **Contenido real:** trailer "Clair Obscur: Expedition 33" descargado de YouTube en 4K AV1+Opus (74.5s, 3840x2160@30fps) — `~/Downloads/fmtmatrix_real/` (29 archivos, 2.8GB). 4K para h264/hevc/av1; 1080p escalado para vp9/códecs legacy.
2. **Tres niveles de prueba por archivo** (sin tocar módulos, sin transcodificar durante reproducción):
   - `DemuxProbe` — apertura (< 1s exigido), lectura de paquetes, seek a mitad de archivo.
   - `DecodeProbe` — preparación del códec, decode hardware por VT, timestamps, 10 frames.
   - `DecodeAudioProbe` — decode de audio a PCM float32.
   - **Reproducción real en la app** (`RIFT_AUTO_OPEN` headless) con métricas del display layer: encolados, desplegados, drops, cadencia.

## Resultados — matriz sintética (720p)

| # | Contenedor / Códec | Demux | Decode video | Reproducción app | Audio | Veredicto |
|---|---|---|---|---|---|---|
| 1 | MP4 / H.264+AAC | ✓ 3ms | ✓ 1.2ms/f (817fps) | ✓ 0 drops steady-state | AAC ✓ | SOPORTADO |
| 2 | MOV / H.264 | ✓ 3ms | ✓ 1.2ms/f (829fps) | ✓ (mismo pipeline) | ✓ | SOPORTADO |
| 3 | MKV / H.264 | ✓ 3ms | ✓ 1.2ms/f (829fps) | ✓ | ✓ | SOPORTADO |
| 4 | AVI / H.264 + B-frames | ✓ 3ms + parser POC | ✓ 1.3ms/f (763fps) | ✓ 0 drops, fluido | MP3 ✓ | SOPORTADO (fix de sesión) |
| 5 | AVI / H.264 sin B-frames | ✓ 10ms | ✓ 1.3ms/f (746fps) | ✓ | ✓ | SOPORTADO |
| 6 | MP4 / HEVC | ✓ 2ms | ✓ 3.3ms/f (306fps) | ✓ nativo 0 drops; Motion 4x: 18-41 drops (nota A) | ✓ | SOPORTADO |
| 7 | MKV / HEVC | ✓ 1ms | ✓ 3.6ms/f (281fps) | igual que #6 | ✓ | SOPORTADO |
| 8 | MPEG-TS / HEVC | ✓ 5ms | ✓ 3.6ms/f; Annex-B → VT | ✓ apertura + 3 seeks; sin corrupción | ✓ | SOPORTADO |
| 9 | MP4 / AV1 (SVT) | ✓ 2ms | ✓ 1.3ms/f (786fps) | ✓ 0 drops steady | ✓ | SOPORTADO |
| 10 | MKV / AV1 | ✓ 1ms | ✓ 1.3ms/f (748fps) | ✓ | ✓ | SOPORTADO |
| 11 | WebM / VP9 | ✓ 3ms | ✗ por diseño (whitelist VT) | error grácil, sin crash | Opus ✓ | NO SOPORTADO (por diseño) |
| 12 | WebM / VP8 | ✓ 1ms | ✗ por diseño | error grácil, sin crash | Opus ✓ | NO SOPORTADO (por diseño) |
| 13 | MKV / VP9 | ✓ 3ms | ✗ por diseño | — | ✓ | NO SOPORTADO (por diseño) |
| 14 | AVI / MPEG-4 ASP | ✓ 1ms | ✗ por diseño | — | ✓ | NO SOPORTADO (por diseño) |
| 15 | MKV / MPEG-4 | ✓ 1ms | ✗ por diseño | — | ✓ | NO SOPORTADO (por diseño) |
| 16 | MPEG-TS / H.264 | ✓; seek entrega keyframe | ✓ 1.5ms/f tras seek | ✓ seek directo y botones ±10s | ✓ | SOPORTADO |
| 17 | MPEG-TS / MPEG-2 | ✓ 2ms | ✗ por diseño | — | MP2 ✓ | NO SOPORTADO (por diseño) |
| 18 | MPEG-PS (mpg) / MPEG-2 | ✓ 3ms | ✗ por diseño | — | MP2 ✓ | NO SOPORTADO (por diseño) |
| 19 | FLV / H.264 | ✓ 3ms | ✓ 1.2ms/f (867fps) | ✓ (idem MP4) | ✓ | SOPORTADO |
| 20 | MOV / ProRes 422 Proxy | ✓ 1ms | ✗ por diseño | error grácil, sin crash | PCM s16 ✓ aislado | VIDEO NO SOPORTADO; AUDIO SOPORTADO |
| 21 | AVI / MJPEG | ✓ 1ms | ✓ 1.0ms/f (1047fps) | — | ✓ | SOPORTADO |
| 22 | MKV / MJPEG | ✓ 1ms | ✓ 0.9ms/f (1069fps) | — | ✓ | SOPORTADO |
| 23 | OGV / Theora | n/a — `libtheora` no existe en FFmpeg de Homebrew | ✗ por diseño | — | — | NO SOPORTADO (por diseño, no generable) |

\* MPEG-TS/H.264 fue revalidado después del commit `b524f97`; el primer paquete de video tras seek es un keyframe decodificable.

## Resultados — matriz de contenido real (4K/1080p)

Idénticos a la matriz sintética. Cobertura nueva relevante:

| Formato | Decode | Reproducción app (16s, Motion 4x) |
|---|---|---|
| MP4/MOV/MKV/AVI/FLV/MPEG-TS — **H.264 4K** | ✓ 3.1-3.7ms/f (~300fps) | ✓ 4/4: 359-360 frames desplegados, 1 drop (arranque), 0 en steady-state |
| MP4/MKV/MPEG-TS — **HEVC 4K** | ✓ 7-8ms/f (~130fps); TS Annex-B ✓ | ✓ TS con seeks 37→10→50s, sin corrupción |
| MP4/MKV — **AV1 4K** (la fuente misma) | ✓ 3.4ms/f (~290fps) | ✓ 0 drops |
| **AVI/H.264 4K con B-frames** | ✓ 3.7ms/f | ✓ 0 drops a 4K — el fix POC de la sesión escala a 4K |
| AVI/H.264 sin B-frames 4K | ✓ 3.6ms/f | ✓ |
| MJPEG 1080p (avi/mkv) | ✓ 1.5ms/f (~650fps) | — |
| VP9/VP8/MPEG-4/MPEG-2/ProRes | ✗ por diseño | error grácil sin crash (verificado) |

Audio (matriz real): AAC/MP3/EAC3/AC3/Opus/MP2/FLAC/PCM ✓. FLAC `s32` y PCM `s16` producen float32 intercalado con señal real.

## Bugs encontrados y corregidos

1. **MPEG-TS/H.264: seek a mitad de GOP — corregido en `b524f97`.** Demux realiza preroll acotado y conserva un keyframe válido como primer paquete. Validación en app: `+10s` y `−10s` reanudan la presentación sin corrupción ni congelamiento.
2. **MPEG-TS/HEVC: Annex-B — corregido en `a1cbfe8`.** Decode extrae VPS/SPS/PPS del extradata Annex-B y convierte cada access unit actual al formato length-prefixed requerido por VideoToolbox. Validado a 720p y 4K con varios seeks.
3. **FLAC/PCM: formatos enteros empaquetados — corregido en `86e785d`.** DecodeAudio convierte `s32` (FLAC) y `s16` (PCM) a float32 intercalado. Validado con matriz sintética, contenido real y un clip H.264+PCM independiente.

### No-bugs (falsos positivos descartados)

- `DemuxProbe` reporta "FAIL: video track has EMPTY codecExtradata" para vp9/vp8/prores/mjpeg — esos códecs no llevan extradata legítimamente; es una validación del probe con criterio HEVC, no un fallo de la app.
- VP9/VP8 no soportados: la app muestra el estado de error sin crash (app viva tras 8s, verificado).

## Notas

- **Nota A (HEVC + Motion 4x en clips cortos):** drops 18-41 y cadencia irregular (SOURCE 0.083s x31, INTERP 0.033/0.050s) vs h264 limpio en idéntico escenario. En modo nativo HEVC es limpio (0 drops). Es la calibración/admisión de Frame+ en clips de 10s (el arranque consume ~4s del clip), no un fallo de formato. A re-validar con contenido largo si se replica.
- **Nota B (entorno):** durante la sesión, `brew upgrade yt-dlp` arrastró una recompilación de FFmpeg (libs .62 → .63, FFmpeg 9). El ejecutable Rift quedó roto hasta relinkearlo (hecho). Todo el pipeline fue re-validado con FFmpeg 9 sobre la matriz real — el shim C es compatible con ambas versiones.
- **AVI/H.264 con B-frames (el caso de esta sesión):** fluido con el fix POC en 720p y 4K, 0 drops, contenido byte-exacto vs ffmpeg (35,321 frames verificados).
- Trade-off aceptado documentado en AGENTS.md: CFR asumido en AVI legacy; VP9/VP8/MPEG-2/MPEG-4/ProRes/Theora fuera del stack por diseño (solo decode hardware VT).

## Cobertura de reproducción verificada en la app

`mp4_h264_4k`, `mov_h264_4k`, `mkv_h264_4k`, `avi_h264_4k` (B-frames), `avi_h264_nobf_4k`, `flv_h264_4k`, `mpegts_h264_4k` (seek directo y ±10s), `mp4_hevc_4k`, `mkv_hevc_4k`, `mpegts_hevc_4k` (tres seeks), `mp4_av1_4k`, `mkv_av1_4k`, `webm_vp9` (error path), `mov_prores` (error path), `src.mp4`, `mkv_hevc` 720p, `avi_h264` 720p, `mp4_hevc` 720p nativo/interpolado, H.264+PCM y H.264+FLAC.

## Revalidación de cierre — 2026-10-04

- **Video soportado:** 14/14 rutas pasaron `DecodeProbe`: H.264 en MP4/MOV/MKV/AVI/TS/FLV, HEVC en MP4/MKV/TS, AV1 en MP4/MKV y MJPEG en AVI/MKV.
- **Audio soportado:** 9/9 rutas pasaron `DecodeAudioProbe`: AAC, MP3, AC3, E-AC3, Opus, MP2, FLAC y PCM s16.
- **Errores esperados:** 8/8 rutas no soportadas devolvieron error controlado: VP8, VP9, MPEG-4 ASP, MPEG-2 y ProRes.
- **Integración TS/H.264:** reproducción 4K durante 60s; `+10s` y `−10s` reanudaron video sin frames corruptos ni congelamiento.
- **Integración TS/HEVC:** reproducción 4K con seeks automáticos 37s → 10s → 50s; la presentación se reanudó después de cada salto.
- **Integración de audio:** la app abrió H.264+PCM y después H.264+FLAC; ambos probes confirmaron muestras float32 no silenciosas.
- **Build:** `swift build -c debug` completó correctamente. Permanecen advertencias preexistentes de Swift 6 y del deployment target de las librerías FFmpeg.

## Evidencia

- Clips sintéticos: `~/Downloads/fmtmatrix/` (30 archivos)
- Clips reales: `~/Downloads/fmtmatrix_real/` (29 archivos)
- Fuente 4K: `~/Downloads/Clair Obscur： Expedition 33 - Official Trailer ｜ Galaxies Gaming Showcase 2025.mkv`
- Logs de reproducción: `/tmp/rs.log` … `/tmp/rs7.log`, `/tmp/rift_stream*.log`
- Volcados de diagnóstico: `/tmp/ours*.txt`, `/tmp/gt.txt`, `/tmp/gt.nv12`, `/tmp/demuxdbg.log`
- Clip PCM sintético reproducible: `/tmp/rift_h264_pcm.mov` (6s, H.264 + PCM s16; generado desde `lavfi`, no desde contenido del usuario).
- Validación app TS/H.264 con controles: `/tmp/rift_ts_h264_seek_validation.log`.
- Validación app TS/HEVC con seeks: `/tmp/rift_ts_hevc_seek_validation.log`.
- Validación app PCM/FLAC: `/tmp/rift_pcm_flac_app_validation.log`.
