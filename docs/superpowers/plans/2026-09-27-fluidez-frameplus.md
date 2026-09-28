# Fluidez sostenida de Frame+ — Implementation Plan

> **For agentic workers:** Ejecutar secuencialmente con la habilidad disponible `executing-plans`, por tareas y con revisión entre módulos. No delegar sin autorización del usuario. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Aumentar la fluidez real y sostenida mediante cadencia correcta, entrega puntual y calidad adaptada al costo medido en cada equipo.

**Architecture:** Conservar el pipeline y las optimizaciones existentes. Separar medición, política temporal, motor MCFI y presentación; integrar cada API en una tarea posterior de UI. Resolver primero el cuello de botella observado, sin asumir que todo tirón viene del interpolador.

**Tech Stack:** Swift, Metal MCFI clásico, VideoToolbox, CVPixelBufferPool, AVSampleBufferDisplayLayer y AVSampleBufferRenderSynchronizer.

## Restricciones globales

- Interpolación en tiempo real sobre una ventana pequeña y acotada en memoria. Nunca copiar, transcodificar ni reescribir el video fuente completo.
- Sin dependencias nuevas, modelos neuronales ni rediseño Liquid Glass.
- Un módulo por tarea; prueba aislada y commit antes de integrar en otro módulo.
- Calibración por medición, nunca tablas de rendimiento por modelo de chip.
- Mantener HDR, sincronía A/V, controles de reproducción, subtítulos y PiP.
- No reabrir los artefactos de motion blur/bokeh ni eliminar protecciones de movimiento para obtener mejores cifras.
- Este documento define el plan; no autoriza publicación, ni afirma resultados de rendimiento aún no medidos.

## Punto de partida verificado

- `UI/Player/RiftPlayerState.swift` ya genera una cadencia uniforme en el modo de 60 FPS y contiene el control de carga sostenida. No implementar otra ruta paralela.
- `Core/Interpolation/Swift/MotionCompensator.swift` ya dispone de `interpolatePair(I0:I1:tValues:)`, que reutiliza luma y estimación de movimiento por par.
- `Core/Interpolation/Swift/InterpolationConfig.swift` contiene perfiles de trabajo base y de alta calidad. No equivalen a una calibración completa por dispositivo.
- `Core/Scheduler/Swift/FrameTiming.swift` y `FrameScheduler.swift` contienen políticas propias. Hay que verificar cuáles usa realmente el reproductor antes de modificarlas.
- El contador de UI puede mostrar la frecuencia nominal cuando el valor medido supera la mitad de ella. No utilizarlo como prueba de presentación real.
- El compositor PiP tiene un límite de 12 buffers. Aumentarlo fue una mitigación: no demuestra que el agotamiento fuera la causa de la intermitencia. El fallback actual puede mostrar un frame sin subtítulo.

## 1. Línea base reproducible — diagnóstico sin cambios funcionales

**Archivos a leer:** `UI/Player/RiftPlayerState.swift`, `Core/Scheduler/Swift/FrameTiming.swift`, `Core/Scheduler/Swift/FrameScheduler.swift`, `Core/Interpolation/Swift/MotionCompensator.swift`, `Rendering/Swift/HDRDisplayRenderer.swift`, `Rendering/Swift/SubtitleCompositor.swift`.

**Entregable:** `docs/diagnostics/frameplus-fluidez-baseline.md`.

- [ ] Registrar commit, chip real, RAM, macOS, pantalla/frecuencia, resolución, codec, HDR, FPS exactos del archivo y velocidad 1×.
- [ ] Seguir la ruta activa desde el par decodificado hasta el encolado. Identificar qué decisiones de Scheduler se usan y cuáles quedan fuera del camino real.
- [ ] Elegir tres intervalos reproducibles de los archivos locales: paneo, movimiento intenso y diálogo subtitulado. Registrar ruta e inicio/fin; no generar copias de video.
- [ ] Ejecutar cada intervalo durante 60 segundos, tres veces: nativo, Frame+, Frame+ con subtítulos y Frame+ con subtítulos/PiP. Separar arranque de régimen estable.
- [ ] Usar Instruments/Time Profiler y Metal System Trace para separar CPU, GPU, esperas y actividad de presentación. Complementar con contadores existentes; no equiparar llamadas a enqueue con frames mostrados.
- [ ] Registrar mediana/p95/p99 de costo por par, tiempos de composición, descartes, frames tardíos, ocupación del pool, memoria y desfase A/V medible. Marcar explícitamente cualquier dato que la instrumentación disponible no permita observar.
- [ ] Clasificar la primera limitación: decode, preparación/copia, MCFI, composición, espera de presentación o timestamps. Si no hay evidencia suficiente, ampliar solo la instrumentación correspondiente.

**Puerta de salida:** comparación reproducible con condiciones iguales y cuello de botella identificado. Commit documental independiente.

## 2. Entrega y métricas de presentación — Rendering

**Modificar:** `Rendering/Swift/HDRDisplayRenderer.swift`; `Rendering/Swift/SubtitleCompositor.swift` únicamente si las mediciones identifican su contribución.

**Entrada/salida existente:** `sampleBuffer(from:pts:duration:) -> CMSampleBuffer?`, `enqueue(_:)`, capa de presentación y sincronizador.

- [ ] Contar por separado intentos, muestras aceptadas, rechazos por saturación y fallos de composición. Mantener acumuladores acotados; evitar escribir archivos por frame en el camino crítico.
- [ ] Determinar mediante la línea base si se descartan muestras útiles al no estar lista la capa. Si ocurre, definir una entrega con capacidad y plazo máximos explícitos; nunca añadir una cola ilimitada.
- [ ] Exponer el resultado de admisión para que la integración posterior sepa si avanzó la presentación. Mantener compatibilidad con los consumidores existentes hasta completar esa integración.
- [ ] Ante saturación, conservar orden temporal y permitir cancelación al buscar o cerrar el video. No esperar bloqueando MainActor ni forzar flush durante reproducción normal.
- [ ] Si PiP domina el costo, reducir trabajo repetido de composición y retención medidos. Mantener originales intactos, límite de buffers y metadata HDR. Contabilizar explícitamente todo frame que pierda su subtítulo.
- [ ] Validar saturación y recuperación, orden de PTS, pausa/seek y agotamiento del pool. Comparar con la línea base a igualdad de contenido y calidad.
- [ ] Compilar con `swift build --product Rift`, revisar diff y crear commit de Rendering.

**Éxito:** ninguna pérdida silenciosa; entrega acotada y cancelable; sin regresión de memoria ni subtítulos. No ampliar el pool sin evidencia.

## 3. Cadencia y política adaptativa — Core/Scheduler

**Modificar:** `Core/Scheduler/Swift/FrameTiming.swift`, `Core/Scheduler/Swift/FrameScheduler.swift`, `Core/Scheduler/Tools/main.swift`.

- [ ] Derivar el presupuesto del intervalo real de origen y del número de salidas solicitadas. No usar 41,7 ms como supuesto universal ni comparar costo por frame con presupuesto por par.
- [ ] Validar una rejilla temporal racional continua para 23,976/24/25/29,97/30 FPS y destinos 50/59,94/60 FPS. Elegir destino según contenido, pantalla y capacidad; no forzar 60 en todos los casos.
- [ ] Para cada timestamp de salida dentro de un par, calcular `t = (salida - inicioPar) / (finPar - inicioPar)`. Conservar fase entre pares y restablecerla explícitamente tras seek o discontinuidad.
- [ ] Definir la política como datos: preferencia del usuario, perfil efectivo, frecuencia objetivo y motivo del cambio. Scheduler decide; no decodifica, compone ni ejecuta Metal.
- [ ] Introducir histéresis: excluir compilación/calentamiento, pausas, seeks y falta de suministro de las muestras de costo MCFI. Degradar por sobrecarga sostenida; recuperar tras un intervalo sano más largo. Ajustar ventanas usando la línea base, con parámetros documentados.
- [ ] Probar secuencias sintéticas de reloj: 10 minutos sin deriva acumulada, PTS estrictamente crecientes, ausencia de duplicados en fronteras, seek y pausa, pico aislado, sobrecarga sostenida y recuperación sin oscilación.
- [ ] Ejecutar `swift run SchedulerProbe`, verificar que los casos añadidos terminan con código cero y crear commit de Scheduler.

**Éxito:** presupuesto consistente y cadencia independiente del redondeo; la política no confunde una pausa con un Mac lento.

## 4. Optimización medida y perfiles — Core/Interpolation

**Modificar según evidencia:** `Core/Interpolation/Swift/MotionCompensator.swift`, `Core/Interpolation/Swift/WarpEngine.swift`, `Core/Interpolation/Swift/InterpolationConfig.swift`, `Core/Interpolation/Tools/main.swift`.

**API a preservar:** `interpolatePair(I0:I1:tValues:)` y su resultado por par.

- [ ] Separar costo de extracción de luma, ME, descarga de vectores, warp, reconstrucción de crominancia y sincronización CPU/GPU en el probe existente.
- [ ] Priorizar únicamente los pasos dominantes. Conservar la reutilización de ME existente; evitar reconstrucciones por salida cuando sus entradas son idénticas, y asignaciones repetidas que el perfil confirme.
- [ ] Introducir perfiles de resolución de trabajo acotados, respetando aspecto y alineación de bloques. Mantener la salida a resolución nativa.
- [ ] Medir los perfiles con pares representativos ya disponibles en memoria, incluyendo el número de salidas que exige cada destino. Excluir compilación Metal del costo estable y limitar la duración de calibración.
- [ ] No seleccionar calidad con pares estáticos que activan el fast-path. Si el contenido inicial no representa movimiento, elegir un perfil conservador y reevaluar con muestras útiles.
- [ ] Verificar extremos temporales, dimensiones, pixel format, attachments HDR, pares inválidos y reutilización segura de buffers retenidos. Comparar calidad visual en paneos, oclusiones y texto.
- [ ] Medir antes/después en el mismo chip y contenido, compilar y crear commit de Interpolation. No conservar una optimización sin mejora medida o con regresión visual.

**Éxito:** reducir el costo dominante o demostrar que no es el cuello de botella; perfiles utilizables con memoria estable, sin prometer 60 FPS para todo Mac/video.

## 5. Integración del reproductor — UI

**Modificar:** `UI/Player/RiftPlayerState.swift`, sin rediseñar los controles.

- [ ] Conectar las decisiones de Scheduler y los perfiles medidos del interpolador a la ruta activa. Retirar solo la política duplicada que quede reemplazada en esta integración.
- [ ] Aplicar cambios de perfil al completar el par actual; invalidar resultados antiguos tras seek/cambio de video y mantener audio como parte del mismo reloj.
- [ ] Bajo sobrecarga: reducir primero resolución de trabajo; después elegir una cadencia sostenible y finalmente reproducción nativa cuando sea necesario. Conservar la preferencia Frame+ y permitir recuperación sin toggles repetidos.
- [ ] Mostrar frecuencia objetivo y medición real con nombres distintos. Si solo hay métricas de encolado, etiquetarlas como tales y no como FPS presentados.
- [ ] Comprobar play/pause, seek por barra y ±10 s, cambio de archivo, velocidades disponibles, entrada/salida de PiP y selección de subtítulos. Reiniciar apropiadamente muestras de calibración tras cambios de velocidad.
- [ ] Compilar, repetir los intervalos de línea base y crear commit de integración UI.

**Éxito:** adaptación gradual y explicable, sin salto de tiempo, audio desincronizado ni desaparición inadvertida de subtítulos.

## 6. Validación sostenida y aceptación

**Entregable:** `docs/diagnostics/frameplus-fluidez-resultados.md`.

- [ ] Repetir exactamente la matriz inicial en una compilación de rendimiento comparable; registrar también flags de diagnóstico y configuración energética.
- [ ] Ejecutar 30 minutos de 4K HDR con Frame+, incluyendo subtítulos y PiP, para observar temperatura, memoria y cambios de perfil.
- [ ] Objetivos iniciales de aceptación: menos de 0,1 % de salidas tardías/descartadas en régimen estable; ninguna deriva de PTS en prueba sintética; desfase A/V absoluto máximo de 40 ms cuando sea medible; memoria sin crecimiento sostenido tras calentamiento.
- [ ] Reservar como objetivo de calibración un 20 % del presupuesto del par para variación y trabajo adicional. Confirmar el margen con costo total del pipeline; el tiempo de MCFI aislado no basta.
- [ ] Verificar subtítulos durante todo el intervalo de cada cue, sin etiquetas literales y tanto en ventana como en PiP. Si persiste intermitencia, abrir diagnóstico específico con timestamps antes de declararla resuelta.
- [ ] Probar en M1 y en el equipo de desarrollo cuando haya hardware disponible. Identificar cualquier máquina no probada; no generalizar resultados.
- [ ] Validar HDR visualmente en pantalla EDR real. Si no está disponible, mantener expresamente esa validación pendiente.
- [ ] Documentar resultados y limitaciones, y crear commit documental. Publicar únicamente tras una orden de publicación.

## Orden y revisión

Línea base → Rendering → Scheduler → Interpolation → integración UI → validación sostenida. Las optimizaciones de Rendering/Interpolation se ejecutan solo cuando la evidencia justifica cada una; cada módulo tiene su propia revisión y commit. Antes de escribir código se presenta el alcance concreto de la primera tarea conforme a AGENTS.md. Este plan no presupone ganancias ni sustituye esa medición.
