# AGENTS.md — Reglas del proyecto Rift

> Este archivo es de lectura obligatoria antes de proponer o escribir cualquier cambio.
> Si una instrucción del usuario entra en conflicto con este documento, señálalo antes de proceder.

## 1. Qué es Rift

Reproductor de video nativo para macOS con interpolación de frames en tiempo real
(24fps → 120fps) usando un modelo tipo RIFE. Interfaz "Liquid Glass", soporte HDR
con tone-mapping, y compatibilidad de formatos vía FFmpeg. Se distribuye como
`.dmg` en GitHub y vía Homebrew tap.

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
- **Interpolación:** Core ML o MPSGraph sobre Metal, modelo tipo RIFE
- **Buffer de frames:** `CVPixelBufferPool`, ventana deslizante acotada (no crece indefinidamente)
- **Salida/sincronía:** `AVSampleBufferDisplayLayer` + `AVSampleBufferRenderSynchronizer`
- **UI:** SwiftUI / AppKit, estética Liquid Glass ya existente — no rediseñar sin que se pida

No introducir nuevas dependencias externas sin justificarlo explícitamente y pedir confirmación.

## 4. Estructura de módulos y límites de cada uno

```
Core/Demux/          → extrae paquetes del contenedor. No decodifica. No conoce Metal ni UI.
Core/Decode/         → paquetes comprimidos → CVPixelBuffer. No conoce interpolación ni UI.
Core/Interpolation/  → 2 CVPixelBuffer → 1 CVPixelBuffer generado. No conoce disco ni UI.
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

1. Demuxer aislado (extrae paquetes, sin decodificar).
2. Decoder (paquetes → CVPixelBuffer, verificable con un frame estático).
3. Sliding frame buffer (ventana en memoria, memoria estable medida).
4. Motor de interpolación (par de frames → frame generado, medido en ms).
5. Scheduler + display (integración con timestamps, sin HDR primero).
6. HDR/color metadata.
7. Reconexión con la UI existente — solo al final, cuando el pipeline ya se probó solo.