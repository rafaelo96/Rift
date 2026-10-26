# AGENTS.md — Reglas del proyecto Rift

> Este archivo es de lectura obligatoria antes de proponer o escribir cualquier cambio.
> Si una instrucción del usuario entra en conflicto con este documento, señálalo antes de proceder.

## 1. Qué es Rift

Reproductor de video nativo para macOS con interpolación de frames en tiempo real
(24fps → 60fps) usando compensación de movimiento clásica (MCFI). Interfaz "Liquid
Glass", soporte HDR con tone-mapping, y compatibilidad de formatos vía FFmpeg. Se
distribuye como `.dmg` en GitHub y vía Homebrew tap.

## 2. Objetivo técnico no negociable

**La interpolación ocurre en tiempo real durante la reproducción, sobre una ventana
pequeña de frames en memoria. El archivo fuente en disco NUNCA se copia, transcodifica
ni se reescribe completo, sin importar su tamaño (probado hasta 17GB, 4K HDR HEVC).**

Cualquier solución que implique "generar una copia del video con los frames
intermedios ya insertados" antes de reproducir está fuera de alcance y debe
rechazarse, aunque parezca más simple de implementar.

## 3. Stack tecnológico (fijo — no proponer alternativas sin aprobación explícita)

- **Lenguaje:** Swift
- **Demux de contenedor (MKV):** FFmpeg (solo para separar paquetes, no para decodificar ni transcodificar)
- **Decodificación de video:** `VTDecompressionSession` (hardware, HEVC)
- **Interpolación:** motion-compensated frame interpolation (MCFI) clásica, en Metal —
  estimación de movimiento por bloques (block matching / optical flow clásico) +
  generación del frame intermedio por compensación de movimiento. SIN redes
  neuronales, SIN modelos preentrenados, SIN dependencias de conversión (Core ML /
  MLX / PyTorch). Decisión tomada tras medir que RIFE (con flow-reuse ya optimizado)
  queda 4.7× sobre presupuesto de tiempo real incluso a 480p en Apple M4 — no viable
  en tiempo real en ningún Mac M soportado (M1+). Todo el prototipo/investigación de
  RIFE fue descartado y eliminado del repo.
- **Buffer de frames:** `CVPixelBufferPool`, ventana deslizante acotada (no crece indefinidamente)
- **Salida/sincronía:** `AVSampleBufferDisplayLayer` + `AVSampleBufferRenderSynchronizer`
- **UI:** SwiftUI / AppKit, estética Liquid Glass ya existente — no rediseñar sin que se pida

No introducir nuevas dependencias externas sin justificarlo explícitamente y pedir confirmación.

### Nota de trade-off de interpolación (no reabrir esta discusión sin nueva evidencia)

MCFI clásico produce el "soap opera effect" (fluidez aumentada — el objetivo
buscado) pero con más artefactos que una red neuronal como RIFE en escenas de
movimiento rápido u oclusiones (halos, distorsión). Es un trade-off aceptado
explícitamente por el usuario a cambio de viabilidad real-time en todo el rango
de hardware soportado (M1 en adelante). No se vuelve a evaluar RIFE u otro modelo
de deep learning para este propósito salvo que aparezca evidencia nueva de que
cabe en presupuesto de tiempo real en el chip más débil soportado.

## 4. Estructura de módulos y límites de cada uno

```
Core/Demux/          → extrae paquetes del contenedor. No decodifica. No conoce Metal ni UI.
Core/Decode/         → paquetes comprimidos → CVPixelBuffer. No conoce interpolación ni UI.
Core/Interpolation/  → 2 CVPixelBuffer → 1 CVPixelBuffer generado (MCFI). No conoce disco ni UI.
Core/FramePool/       → ventana de N frames en memoria. No decodifica ni interpola.
Core/Scheduler/       → timestamps y sincronía de reproducción. No decodifica ni interpola.
Rendering/            → presenta frames ya listos, maneja metadata HDR.
UI/                   → controles, Liquid Glass. No debe contener lógica de decode/interpolación.
```

**Regla dura:** un agente que trabaja en un módulo no edita archivos de otro módulo
en la misma tarea, salvo que la tarea lo requiera explícitamente y lo declare primero.

## 5. Qué SÍ puede hacer un agente

- Modificar un único módulo por tarea, con alcance acotado.
- Proponer un plan corto (3-4 líneas) antes de escribir código, y esperar confirmación.
- Escribir diffs/ediciones puntuales en vez de regenerar archivos completos.
- Añadir tests o mediciones (tiempo por frame, memoria) cuando el criterio de éxito lo requiera.
- Señalar si una tarea pedida requiere tocar más de un módulo, y pedir dividirla.

## 6. Qué NO puede hacer un agente

- Reescribir un archivo completo cuando el cambio es puntual.
- Tocar módulos fuera del alcance declarado de la tarea.
- Introducir cualquier paso que copie, transcodifique o genere un archivo derivado
  del video fuente completo.
- Cambiar el stack tecnológico de la sección 3 sin aprobación.
- Modificar la UI/Liquid Glass como efecto colateral de una tarea de pipeline de video.
- Asumir "mejoras" no pedidas (refactors amplios, cambios de arquitectura) sin proponerlos primero.

## 7. Flujo de trabajo esperado

1. Usuario da una tarea acotada a un módulo (usar la plantilla de la sección 8).
2. Agente responde con plan breve: qué archivos tocará, qué NO tocará.
3. Usuario confirma o ajusta.
4. Agente entrega el diff/cambio.
5. Se prueba el módulo de forma aislada antes de integrarlo con el resto.
6. Commit antes de pasar a la siguiente tarea, para que revertir sea un `git checkout` simple.

## 8. Plantilla de tarea (copiar y llenar por cada orden a un agente)

```
Módulo a trabajar: [ej. Core/Interpolation]
No tocar: [otros módulos]

Tarea: [descripción concreta]
Entrada esperada: [tipos exactos]
Salida esperada: [tipos exactos]
Restricción dura: no copiar/transcodificar el archivo fuente completo en ningún punto.
Criterio de éxito: [medible: tiempo, memoria o comportamiento observable]

Antes de escribir código: describe tu plan en 3-4 líneas y espera confirmación.
```

## 9. Orden de construcción del pipeline (para retomar desde cero)

1. Demuxer aislado (extrae paquetes, sin decodificar). ✅ Completado y validado.
2. Decoder (paquetes → CVPixelBuffer, verificable con un frame estático). ✅ Completado y validado.
3. Sliding frame buffer (ventana en memoria, memoria estable medida). ✅ Completado y validado.
4. Motor de interpolación (MCFI clásico: par de frames → frame generado, medido en ms). ✅ Implementado en `Core/Interpolation/Swift/` (MotionCompensator + MotionSearchEngine + WarpEngine + shaders MSL). API pública única: `MotionCompensator.interpolate(I0:, I1:, t:) -> CVPixelBuffer?` (conserva attachments HDR). Sin estado entre pares (stateless); recursos Metal reusables. **MVP cableado en UI: solo `.motion2x` funcional (24→48fps); `.motion4x` / `.motionAdaptive` / `.motion2Intense` caen a `.motion2x` con log**. Pendiente: implementación de los otros modos, auto-calibración del work plane por chip (ver sección "Rango de hardware soportado"), y fast-path 4K HDR (hoy re-extrae y re-ensambla CVPixelBuffer por par — funcional pero no óptimo). Verificación analítica de pausa/seek con interpolación activa (Tarea 3, commit `653a31d`): el motor es stateless, por lo que seek/pause/resume no requieren código adicional. **Pendiente prueba en sesión GUI real con `.motion2x` activo**.
5. Scheduler + display (integración con timestamps, sin HDR primero). ✅ AVSampleBufferDisplayLayer + AVSampleBufferRenderSynchronizer funcionando (24fps, ver el commit `RotatingVideoPlayerFallback` no se usa, el renderer activo es `HDRDisplayRenderer`).
6. HDR/color metadata. ✅ propagada de Decode → WarpEngine → HDRDisplayRenderer → CMSampleBuffer. **Pendiente validación en pantalla EDR real** (ver lista abajo).
7. Reconexión con la UI existente — ✅ Completado. Play/pause/seek/currentTime funcionales (confirmado por el usuario tras la sesión de debug 2025-09-02).

## Notas de implementación actuales (post-reconexión UI, 2025-09-02)

- **AVI legacy sin PTS (H.264 + B-frames, ej. `06.BlchSKhKt…avi`)**: AVI no
  guarda PTS de video en paquetes (solo contador de orden de decodificación),
  libavformat no puede derivarlos para H.264 (demux.c: "We skip H264
  currently") y FFmpeg 8 mantiene `AVStream.need_parsing` privado. Además
  **VTDecompressionSession entrega los frames en orden de decodificación**
  (no reordena por POC): los PTS correctos deben existir ANTES de decodificar
  para que el FramePool (que ordena por pts) produzca el orden de display.
  Fix: `Core/Demux` detecta container "avi" + H.264, corre un
  `AVCodecParser` (solo metadatos, no decodifica píxeles) en el shim C, y
  marca cada chunk AVI como access unit completa y asigna
  `pts = rank(POC/2) × intervalo` al mismo paquete. Los resets
  de POC en IDR se curan solo al completar keyframes (una regresión de POC
  dentro del GOP es normal en B-pyramid). Sin el fix, el video se reproduce en
  orden de decode = saltos locales ("tirones") con audio intacto. Diagnóstico del
  parser: env var `RIFT_DEMUX_DEBUG=1`. Trade-off aceptado: CFR (VFR en AVI
  legacy es prácticamente inexistente).
- **Corte de escena en Frame+**: la ruta Frame+ de `interpolatePair` retorna
  antes de los gates de la ruta clásica, así que tiene su propio gate
  (`SceneCutDetector`): si > 0.61 de los bloques de nivel 1 conservan residuo
  medio > 24/1023 tras compensar movimiento, repite el frame fuente más cercano,
  resetea el estado temporal y el par siguiente no usa contexto de 4 frames.
  Calibrado a mano sobre 2878 pares (anime 4K HDR, M4): 29/41 cortes, 0
  falsos positivos; los cortes que escapan tienen contenido similar a ambos
  lados. Coste ~0.17 ms/par. `RIFT_SCENE_CUT=0` lo desactiva (A/B). NO corrige
  los cambios de dibujo dentro de un plano (anime en 2s) — es otro problema.
- **Sostén del dibujo en Frame+ (anime en 2s)**: `DrawingHold` toma los píxeles
  del work-plane sin correspondencia en `denseSynthesize` (reliability < 0.02,
  fuera de una banda de 16 px en el borde del frame), calcula su densidad en una
  caja de 33×33 y aplica h = smoothstep(0.05, 0.15). Con ese peso lleva vectores
  y mezcla hacia el frame fuente más cercano: el personaje cambia de pose a mitad
  de intervalo, como en el original, en vez de despedazarse. Con h = 0 la salida
  es idéntica byte a byte. A/B (Avatar 4K HDR, M4, 2809 pares del mismo plano):
  en los pares dañados, "lejos de ambos" baja de 11.4 % a 1.9 %; en la mediana se
  sostiene el 1.7 % del frame. También sostiene contenido que no se puede
  interpolar, como la lluvia nocturna, que queda nítida a 24 fps en vez de una
  mezcla borrosa. Coste ~0.4–0.7 ms/par. `RIFT_DRAWING_HOLD=0` lo desactiva.
  Vista previa offline: MVProbe `MV_HOLD_NATIVE_PREVIEW=1`, A/B `MV_HOLD_AB=1`.
- **Deduplicación de frames repetidos (anime en 2s)**: con Frame+ y cadencia
  uniforme, `SlidingFramePool.reservePair(droppingRepeats:)` descarta el frame
  fuente idéntico al anterior (`RepeatedFrameDetector`: máximo por bloques de la
  diferencia media de luma < 4/1023, con un hueco medido entre ruido < 4 y
  movimiento ≥ 8). Así el par abarca 2 periodos y los 60 fps reparten el
  movimiento en vez de "quieto + salto doble". Descarta como máximo un repetido
  seguido (5 muestras sintéticas por par; `maxSamplesPerPair` = 6). La UI
  devuelve el permiso del frame descartado, no aplica el guardia de huecos a
  esos pares, acepta contexto temporal de 1–2 periodos y usa la duración real
  del par como presupuesto. Simulación: frames congelados 24–43 % → 6–31 % en
  tramos con repetidos. En la app (M4, 4K) se mantienen 60 fps sin frames
  atrasados. Con decode-ahead de 0.25 s solo cubría ~70 % de los repetidos (el
  pool tenía 2 frames al reservar); con el default actual de 0.35 s los cubre
  todos (109/109 y 105/105 en dos tramos de 40 s). `RIFT_DEDUP=0` lo desactiva. Confirmado por el usuario en
  pantalla (19:40, con frente a sin dedup): más fluido.
- **Modo "Fluidez máxima" (Ajustes → Frame+, apagado por defecto)**: desactiva
  el sostén del dibujo (`InterpolationConfig.usesDrawingHold = false`) y deja
  que FramePool descarte hasta 2 repetidos seguidos (`maxConsecutive: 2`), con
  pares de hasta 3 periodos y hasta 8 muestras sintéticas
  (`maxSamplesPerPair` = 8). Decodifica con ≥ 0.5 s de antelación para tener
  ~6 frames al reservar. Simulación: zona congelada en acción 22 % → 12 %,
  "lejos de ambos" 0.9 % → 2.9 % (vuelven los parches de cambio de pose).
  Sonda (M4, 4K): 60 fps, 0 frames atrasados, repetidos descartados 109 → 130
  y 105 → 141; frames perdidos en pantalla +3–5 sobre ~2330, casi todos al
  arrancar. `RIFT_AUTO_MAX_FLUIDITY=1/0` lo fuerza para pruebas.
- **Control de tiempo (`currentTime`)**: poll cada 100ms con Timer en `startDisplayLoop`/`togglePlay`, leyendo `scheduler.synchronizer.currentTime()`. No usar la fecha absoluta, no usar contadores locales.
- **Pause/resume**: `sched.synchronizer.setRate(0 | 1, time: t)` en `togglePlay()`. El `displayLoop` no consume ni encola frames mientras `rate == 0`.
- **Seek**: `seek(to:)` → `demuxer.seek(to:)`, `decoder.flush()`, `framePool.flush()`, `render.displayLayer.flush()`, `synchronizer.setRate(...)` al nuevo pts, y **restaurar cupo del semáforo** con 4 señales del coordinator (si no, decode loop se bloquea tras flush).
- **Pacing real**: lo ejerce el synchronizer con `atHostTime` en `startDisplayLoop`; el sleep de `1s/24` en el loop es solo un yield.
- **Pantalla negra inicial** = comportamiento correcto del archivo (fade-in del MKV, pts 0–2s). No es un bug; no "arreglar" sin grabar captura real.

## Limitaciones conocidas pendientes (no dejar pasar sin documentar)

- **Barra/seek ±10s** no se ha confirmado que funcione con el seek actual (solo se probó click directo en la barra). Debe probarse tras este commit.
- **NSOpenPanel (`Cmd+O` / "Open Video...")** funciona en sesión de usuario pero NO en corridas no GUI (headless CI o CLI sin WindowServer) — limit conocido, by design.
- **Pantalla negra+pantalla solo en una ventana pequeña** fue resuelto con `HDRDisplayView`+`NSViewRepresentable`; no reducir el area del displayLayer.
- **Parpadeo sutil en texto/superficies planas con interpolación activa**: ruido residual de vectores de movimiento del MCFI clásico, ya mitigado por mediana 3×3 + gates (`smoothL0`/`gateL0`/`clearWinGate`, `mvMedian3` en MotionShaders.swift). Diagnosticado (determinismo byte-idéntico descarta regresión de Fase B). Es un trade-off inherente aceptado (ver §3); NO "arreglarlo" por otra vía sin propuesta nueva.

## Limitaciones conocidas del interpolador

> **MCFI / motion blur / bokeh:** El modelo actual de 2 frames + 1 MV por bloque + warp bilineal presenta artefactos de parche en determinadas regiones de motion blur/bokeh. La investigación reproducible determinó que el problema aparece durante la síntesis temporal y no se resuelve de forma general mediante ajustes de ME, thresholds, crossfade regional o pesos de blend. No reabrir estas líneas de investigación como solución al mismo artefacto sin una hipótesis nueva. Ver `docs/diagnostics/mcfi-motion-blur-bokeh-artifacts.md`.
>
> **`warpBlend` / oclusión:** La oclusión suave mediante `smoothstep` y selección del lado dominante es intencional. No reemplazarla por el antiguo fallback 50/50 para intentar corregir los parches de motion blur/bokeh; esos artefactos restantes no corresponden a ese problema.
>
> **W0/W1:** Investigada con experimento sintético (2025-09-14): **no hay bug**. W0(t=0)==I0 y W1(t=1)==I1 son exactos (error=0); el residuo ~0.11 en t=0.5 es la diferencia de precisión bilineal Swift vs Metal. La asimetría 2–2.3× observada en escenas reales es inherente al contenido real (MV field no uniforme, oclusiones). Ver `docs/diagnostics/mcfi-motion-blur-bokeh-artifacts.md` sección "Investigación W0/W1 (sintético)". Cerrada.

## Rango de hardware soportado

Rift debe funcionar en cualquier Mac Apple Silicon (M1 en adelante),
no solo en el hardware de desarrollo. La interpolación de frames debe
ser adaptativa: el pipeline detecta la capacidad del chip en tiempo de
ejecución y ajusta el objetivo (multiplicador de fps y/o resolución de
trabajo de interpolación) en vez de asumir un target fijo. En el chip
más débil soportado, la app debe degradar con elegancia (menor
multiplicador, o interpolación desactivada) en vez de fallar o ir
entrecortada. Toda medición de rendimiento debe reportar el chip real
donde se corrió, y no se generaliza un número de un chip a toda la
línea M sin verificarlo o al menos acotarlo con un argumento explícito
(ej. proporción de núcleos GPU).

No se asumen ni se codifican tiempos de rendimiento por modelo de chip
(no hay tabla fija "M1 → tier X"). En su lugar, el pipeline de
interpolación se auto-calibra: mide el costo real de interpolar en la
máquina del usuario (benchmark corto, primera apertura de video o bajo
demanda) y elige el multiplicador de fps / resolución de trabajo según
ese resultado medido, no según el modelo de chip reportado por el
sistema. Ningún número de rendimiento medido en el hardware de
desarrollo (M4 mini) se generaliza a otros chips sin esta calibración
en vivo. La calibración de arranque no captura variación térmica
(throttling en sesiones largas de 4K sostenido) — limitación conocida
a resolver en `Core/Scheduler` si el costo real observado se desvía
mucho del calibrado.

## Validación pendiente: HDR en pantalla real
Rendering (HDRDisplayRenderer) está implementado según la documentación de Apple (wantsExtendedDynamicRangeContent, propagación correcta de CVBufferAttachments HDR10 BT.2020/PQ desde Decode y desde el buffer interpolado de Interpolation tras el fix en WarpEngine.swift), pero NO se ha podido verificar visualmente que el HDR se muestra correctamente en una pantalla real, porque el hardware de desarrollo (Mac mini M4) no tiene pantalla EDR (maxEDR=1.0, SDR only).

Antes de considerar el pipeline de HDR como validado (no solo "código correcto en teoría"), se necesita probar en una pantalla EDR real (MacBook Pro con XDR, Pro Display XDR, o cualquier Mac con maxEDR > 1.0) y confirmar visualmente que los highlights se ven con más rango que la versión SDR aplastada. Hasta entonces, tratar el HDR como "implementado pero no verificado visualmente" en cualquier decisión de release.
