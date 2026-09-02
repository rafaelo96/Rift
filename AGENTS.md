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
4. Motor de interpolación (MCFI clásico: par de frames → frame generado, medido en ms). ⬜ En curso.
5. Scheduler + display (integración con timestamps, sin HDR primero).
6. HDR/color metadata.
7. Reconexión con la UI existente — solo al final, cuando el pipeline ya se probó solo.

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