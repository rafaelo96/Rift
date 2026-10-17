# E2 — implementada, apagada por defecto; aceptación no alcanzada

Scope: Core/Interpolation, bounded offline diagnostic tools and evidence. Search, selection and reapplied static-protection shader remain unchanged. UI reset callers already invalidate/reset the interpolator on pause, seek, load and close, so no UI edits are needed.

Change 1: opt-in real temporal acquisition (`RIFT_E2=1`). A dedicated matcher uses the same existing block search without sharing or mutating production matcher state. The preceding reverse seed is reused only when both source planes prove adjacency; otherwise a separate before search is made. The after-neighbor search is always real. Missing context remains missing. The existing reset clears this bounded two-plane/one-field cache. Native endpoints, 8/10-bit chroma, held/moving contexts, invalid-context fallback and output reuse pass before adding any degradation. `temporal-native-check.log` records actual searches. This commit does not change output synthesis.

Change 2 (`5aecfea`): continuous degradation, feather, hysteresis and temporal state, native luma/chroma postpass. Initial enter/full/exit = E1 top2/top1/top5. All 12 static controls have zero jitter above one 10-bit code; reset replay exact. Trusted pixel equality holds in 285 replay pairs. Forced native fallback endpoint/blend and zero-weight equality pass for NV12, P010 and P210, hardware/manual sampling. Initial 300s face ROI max score .9431439 stayed below enter .943918959; 69s bison ROI max .801967 stays below even top10. Initial results retained under initial-quality.

Change 3: enter/full/exit relaxed one calibrated band to top5/top2/top10 (.905458547/.943918959/.844213010), to permit intervention on the measured 300s face ROI. Combination and search/selection/static protection unchanged. No claim this addresses the 69s low-score deformation. Must remeasure coverage/quality/cost before acceptance.

## Reproducibility and scope

`RIFT_E2=1` is read once on interpolator creation. Default is absent/off. No UI preference was added. Keep `RIFT_STATIC_MOTION_GUARD=1` in both arms to retain the approved static candidate. Production search/selection and `DenseMotionShaders.swift` are unchanged. Dedicated temporal evidence uses an isolated instance of the existing matcher.

Calibration: only the E1 training signal distributions (starts 0–17 of the three animation fixtures) enter the equal-weight mid-CDF combination. The generated quantile table preserves high-mass ties; maximum individual-feature CDF approximation error is 0.000860. No held-out truth labels were used to fit the combination. Threshold relaxation used a measured ROI score, so revised results are development measurements, not an independent blind validation. Pixel-valued signals at other work sizes are scaled by the square root of area ratio; calibration transport to the smaller runtime work plane remains approximate.

Weight: smoothstep between enter/full, rise EMA .35/fall .15; active state held down to exit, confidence gate forces zero below exit. History is advected with the unchanged forward motion. Bilinear spatial feather plus inward 2-pixel taper at zero-weight neighbors. Zero-weight blocks remain byte-identical. A–B difference chooses temporal/nearest fallback over 1–3% normalized luma with an instantaneous smoothstep of current A–B difference (no mode EMA). Very small weights below 1/1023 are zeroed. The map is prepared once per pair and shared by every subframe; work luma and native luma/chroma use the same map.

Reset: `MotionCompensator.resetTemporalState()` clears confidence history and temporal acquisition cache. Existing pause/seek/load callers reset an idle instance or invalidate a busy instance; close destroys it. No UI files were changed in this task. Static reset replay checks equality; this does not by itself prove every lifecycle transition in GUI.

Truth experiments: 49 real source frames per fixture; 48 adjacent pairs plus 47 span-two triplets per case. The real center is excluded from synthesis and feature calculation; external temporal context is outside the endpoint span. The first/last pair can lack an external neighbor and omits temporal disagreement exactly as E1. Errors are 10-bit normalized luma absolute differences at 1152×480. Degraded/trusted block groups use nonzero mean weight; partial feather pixels still contribute to their block's MAE. Trusted *pixels* are also asserted equal across every generated subframe. Live-action controls use the supplied MKV at 180, 900 and 3600 seconds, all 23.976 fps.

Clips are **bounded 10-second, 60 fps, 1152×480 grayscale SDR diagnostic previews**, with the same ×1.8 brightness in both arms and no audio. They use the work-plane synthesis, not native HDR/color reproduction. VT decodes the small source windows, AVAssetWriter writes only these previews. The source movies are never copied or rewritten in full. Each decode process is capped at 49 frames; synthesis accesses only the local frame neighborhood and keeps bounded writer pools. Raw diagnostic source planes are excluded from Git.

Runtime timing protocol: Release on the actual Mac mini M4, native GUI playback with VT decode, motion4x and Strong requested, five off/on alternations of 30 seconds each. No offline GPU experiment runs concurrently. Ten seconds warmup are removed from each run; report dominant work-plane p95 separately per session, then median/range/IQR/std across sessions. Pair wall time includes real temporal acquisition inside interpolation, plus native output synthesis. Decode and Strong execute concurrently in reproduction; the timer is not an end-to-end decode-to-display latency measurement. Runtime Strong can adaptively bypass work, so logs must support the actual observed mode.

Change 4 (`92cb61f`): removed the extra EMA on fallback *mode*. For current A–B difference >=3%, the block now selects the nearest endpoint immediately; below 1% it selects temporal blend. The confidence weight still has spatial feather, hysteresis and temporal EMA. The earlier mode EMA could retain a temporal blend after an abrupt content change, contrary to the requested nearest-endpoint fallback. Prior quality/clips are preserved under mode-smoothed-*; the incomplete runtime batch (two on runs) is exploratory only and is not the final five-run comparison. All quality, clips, static controls and five alternating native runs are repeated for this final version.

Coverage p95 uses NumPy quantile(method="higher"); per-session runtime p95 uses empirical nearest rank ceil(.95*N)-1.

Final runtime runs last 30 s each, with 10 s warmup removed (about 20 s of steady playback per run). All ten final sessions use the same duration/content/flags; the interrupted exploratory sessions used 45 s and are not pooled with them. Existing user UI changes remain unmodified in the tested working tree; binary hashes identify the exact builds.

E1 calibrates span-two triplets; E2 also applies the same CDFs to adjacent-frame playback. That cadence/domain transport, as well as spatial resolution transport, is not independently calibrated. A high E1 correlation with luma error does not imply that every perceptually deformed region is low-confidence.

## Resultados medidos — versión final 92cb61f

No se demuestra una degradación visual menos visible en los tres casos. La implementación permanece exclusivamente opt-in (`RIFT_E2=1`), no se integra como opción activa por defecto y no se avanza a otra etapa.

### Área degradada durante 10 s

Todo píxel con **w > 0** cuenta como degradado, incluso con peso pequeño. 240 pares por caso, 600 frames por variante, 10 s a 60 fps. Mediana/p95/máximo se calculan por par, sin excluir cortes. El peso medio se muestra aparte y no reemplaza la fracción pedida.

| Tipo / caso | Mediana | p95 | Máximo | Peso medio |
|---|---:|---:|---:|---:|
| animation / avatar69 | 0.000% | 18.484% | 48.785% | 0.00538 |
| animation / avatar300 | 0.000% | 47.766% | 67.338% | 0.01533 |
| animation / anime1082 | 0.000% | 3.484% | 66.944% | 0.00303 |
| live-action / spider180 | 0.000% | 0.000% | 71.053% | 0.00124 |
| live-action / spider900 | 0.000% | 0.787% | 75.775% | 0.00501 |
| live-action / spider3600 | 0.000% | 0.046% | 44.178% | 0.00099 |

El objetivo inicial <10% no se cumple para animación69/300. Live-action tiene p95 bajo, pero máximos grandes. Los máximos de Spider180/900 se verificaron en A/B y coinciden con cortes de plano; no se eliminan de la estadística.

### Verdad real: error antes/después

47 tripletes reales × 8.640 bloques por caso; 2.436.480 bloques en seis casos. Cada ventana de verdad real es de unos 2 s (49 frames), distinta del análisis de cobertura de 10 s. Son códigos de luma normalizados de 10 bits. «Degradados» agrupa bloques con peso medio >0. Un bloque parcialmente plumeado aporta todos sus píxeles a su MAE de bloque; el JSON separa además los errores de píxeles degradados/confiables.

| Caso | MAE global antes → E2 | Δ global | MAE bloques degradados antes → E2 | MAE confiables antes = después |
|---|---:|---:|---:|---:|
| avatar69 | 6.4349 → 6.4766 | +0.648% | 59.6558 → 61.4996 (9,180) | 5.2039 (396,900) |
| avatar300 | 18.9801 → 18.8556 | -0.656% | 70.3135 → 69.5055 (62,581) | 9.6278 (343,499) |
| anime1082 | 3.7620 → 3.8148 | +1.403% | 84.6095 → 86.8537 (9,550) | 1.8149 (396,530) |
| spider180 | 8.9096 → 8.9096 | +0.000% | sin bloques degradados | 8.9096 (406,080) |
| spider900 | 25.3670 → 25.3895 | +0.089% | 202.5254 → 202.8417 (28,859) | 11.8137 (377,221) |
| spider3600 | 0.8718 → 0.8718 | +0.000% | sin bloques degradados | 0.8718 (406,080) |

El JSON conserva cuentas de bloques mejorados/empeorados y evaluación separada starts27–46 de E1. En ese subconjunto 18:02 no degrada ningún bloque: el resultado global de ese caso incluye el corte inicial. Los resultados revisados son mediciones de desarrollo, no una nueva validación ciega.

### Qué se ve en los recortes

- **69 s:** fondo, bisonte y primer plano del par4 permanecen iguales en las previsualizaciones de 8 bits. La deformación no se atenúa en esos recortes; el error del conjunto aumenta.
- **300 s:** hay cambios tenues en cara y parte de la ropa; la silueta principal sigue deformada. Puede atenuarse algo de mancha/grano local, pero no hay evidencia suficiente de mejora visible sin nuevos bordes de transición en toda la secuencia.
- **18:02:** ave y paisaje del par4 permanecen iguales. El error global tampoco mejora con el fallback final. No se demuestra una degradación menos visible del contorno.
- **Live-action:** 180/3600 no activan E2 en los tripletes iniciales. En acción900 el fallback final no mejora la MAE global; el p95 de cobertura de 10 s es bajo, pero no prueba conservación perceptual del movimiento en todos los cortes.

Recortes A/B/actual/E2 por región y láminas de muestras de 0 a 9 s están en cada carpeta. Los recortes primarios se evalúan a t=0,5. Las imágenes estáticas y las métricas no prueban ausencia de parpadeo al reproducir 10 s; esa aceptación queda pendiente. `clip-summary.json` incluye variación y activaciones por bloque en cuadrícula fija; también responden a movimiento y cortes.

### Rendimiento durante reproducción real

Release en Mac mini **Apple M4**, 16 GB. Cinco alternancias apagado/encendido de 30 s; se excluyen 10 s iniciales de cada sesión. Decode VT y Strong activos; todas las corridas registran Strong procesado sin bypass en sus cinco muestras diagnósticas. Las cinco corridas E2 registran adquisición temporal real y reutilización del campo anterior cuando corresponde. La telemetría de Strong está limitada a esas muestras: no demuestra que nunca haya bypass posterior. Plano dominante 736×320 en todas las sesiones; diagnóstico offline 1152×480. No se extrapola a otros chips.

| Repetición | p95 apagado (ms) | p95 encendido (ms) |
|---|---:|---:|
| 1 | 44.962 | 55.097 |
| 2 | 44.825 | 53.070 |
| 3 | 44.460 | 53.129 |
| 4 | 44.081 | 52.559 |
| 5 | 45.238 | 52.425 |

| Grupo | Mediana de p95 | Mínimo–máximo | IQR | Desvío estándar |
|---|---:|---:|---:|---:|
| Apagado | 44.825 ms | 44.081–45.238 ms | 0.501 ms | 0.403 ms |
| Encendido | 53.070 ms | 52.425–55.097 ms | 0.569 ms | 0.961 ms |

Diferencia de medianas: **+8.245 ms**; criterio +2 ms: **no cumple**. Comparación contra la línea base de esta misma tanda, no contra 42,23 ms ni otra sesión. El objetivo histórico de 35 ms es una cifra separada; no se usa para ocultar ni sustituir el criterio de incremento. El tiempo por par incluye adquisición temporal y salida nativa, con decode/Strong concurrentes; no es latencia completa decode→display. No se ejecutaron experimentos GPU offline durante estas diez corridas.

### Igualdad, estáticos y ciclo de vida

- Flag apagada: tres midpoints canónicos de luma coinciden con D (`disabled-canonical.json`); el camino nuevo no se crea ni despacha. La comprobación nativa de mapa cero conserva los bytes de luma y cromas en NV12/P010/P210, con sampling hardware y manual. No se afirma haber comparado todos los frames de los archivos completos.
- Confiables: igualdad de píxeles de trabajo en todos los subframes de 570 pares de calidad y 1.440 pares de clips; igualdad de MAE de todos los bloques con peso cero. Native cero también probado directamente.
- Estáticos: 12/12 controles con 0% de error >1 código de luma en la zona interior, usando ruido 0/±1 código y campos erróneos conocidos; reset/replay idéntico. Esta definición heredada de jitter tolera un código y no significa igualdad absoluta con I0 cuando existe ruido de entrada.
- Regresión de modo: test sintético de señales de alto riesgo y A–B=0,5 comprueba que el primer par ya elige nearest (modo=1), además de peso continuo >0,3. El antiguo EMA de modo falla esa condición.
- GUI: pausa→seek pausado→reanudar pasa las precondiciones a los segundos12/20 y finaliza 30 s. El reset explícito es determinista. Load/close se revisaron por sus rutas de reset/destrucción; no se ejercitaron todos los órdenes posibles de recarga/cierre ni se inspeccionó historia GPU tras cada evento.

### Qué sigue sin demostrar

Mejora visual suficiente en los tres recortes; ausencia de nuevos artefactos de transición o parpadeo durante 10 s; conservación perceptual del movimiento live-action; calibración transportable entre cadencias/resoluciones; validación nativa en color/HDR de estos clips; error verdadero durante los 10 s completos; todos los ciclos GUI de recarga/cierre. El presupuesto de coste solo se considera alcanzado si la tabla final cumple +2 ms; los fallos visuales y de cobertura impiden aceptar E2 igualmente. No se cambia búsqueda, selección ni protección estática, y no se inicia otra etapa.

### Clips de 10 s para comparar

MP4 local, 60 fps, 1152×480, luma SDR ×1,8, sin audio. Ambas variantes usan la misma exposición. La igualdad se comprueba en buffers crudos antes de codificar: los MP4 son con pérdida y no sirven como prueba de igualdad de bytes. Son previews diagnósticos; no una copia ni conversión completa del video fuente.

| Caso | Apagado | E2 |
|---|---|---|
| avatar69 | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/avatar69/clips/off.mp4) | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/avatar69/clips/on.mp4) |
| avatar300 | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/avatar300/clips/off.mp4) | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/avatar300/clips/on.mp4) |
| anime1082 | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/anime1082/clips/off.mp4) | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/anime1082/clips/on.mp4) |
| spider180 | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/spider180/clips/off.mp4) | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/spider180/clips/on.mp4) |
| spider900 | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/spider900/clips/off.mp4) | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/spider900/clips/on.mp4) |
| spider3600 | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/spider3600/clips/off.mp4) | [Reproducir](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-e2-2026-10-17/spider3600/clips/on.mp4) |

### Evidencia y reproducción

`quality-summary.json`, `clip-summary.json`, `playback-timing-summary.json`, `clip-metadata.json`, `runtime-build.json`, logs por corrida y `block-errors.zip` conservan los resultados. Datos iniciales: `initial-quality`, `mode-smoothed-quality` y sus resúmenes. Los clips exploratorios y PNG por segundo permanecen localmente; se versionan los doce videos finales y las láminas resumen, sin duplicar videos exploratorios ni planos fuente.

Después de compilar Release: `python3 Core/Interpolation/Tools/E2ExportWindows.py`, `E2ValidationRun.py quality`, `E2ValidationRun.py clips`, `E2ValidationRun.py playback`, `E2ValidationRun.py reset`; luego `E2Report.py` y `E2PlaybackReport.py`. Las fases de calidad/performance deben ejecutarse secuencialmente.

Cambios separados: `d853866` adquisición temporal; `3cf64e3` lectura NV12 offline; `5aecfea` E2 inicial; `8139a20` ajuste de umbrales; `92cb61f` nearest inmediato. La documentación/mediciones se añaden en un commit aparte.
