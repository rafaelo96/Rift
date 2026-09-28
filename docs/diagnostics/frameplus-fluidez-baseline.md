# Línea base de fluidez — 2026-09-27

Base: `1c121c4`, compilación `swift build -c release --product Rift`.
Equipo: Mac mini Apple M4, GPU de 10 núcleos, 16 GiB, macOS 27.0 (26A428),
Samsung U32J59x 3840×2160 a 60 Hz. No se valida HDR EDR en esta pantalla.
Archivo local: Avengers.endgame.2019.2160p.x265.hdr.5.1-dual-lat-cinecalidad.to.mkv;
HEVC 3840×1608, PQ/BT.2020, 24000/1001 FPS. No se copia ni transforma el archivo.

## Reproducción real inicial

Arranque mediante RIFT_AUTO_OPEN, RIFT_AUTO_MODE=motion4x,
RIFT_AUTO_SEEK_AT=3, RIFT_AUTO_SEEK_TO=2403. Se usó el ejecutable release.
Time Profiler registró 15 segundos de la aplicación (PID 58362), guardados
localmente en `/tmp/rift-fluidez-baseline-20260927.trace`.
Los registros preexistentes de /tmp contienen otras sesiones: no se presentan
sus agregados como resultados de esta ejecución.

Muestras recientes de esta sesión: promedio por ventana de interpolación
11,68–36,67 ms; enqueueLoop 0,69–5,15 ms. La disponibilidad de la capa fue falsa
en el 15–38,3 % de ciertas ventanas; el helper esperó y registró cero timeouts
en esas ventanas. Estas cifras NO son percentiles ni prueba de frames mostrados.
RSS observado a los 40 segundos: 261296 KiB; no es huella total GPU/IOSurface.

## Hallazgos comprobables en código

1. La UI activa hace pacing, síntesis y construcción de salidas. `schedule_24to60`
   del Scheduler no es la rejilla activa. Cambiar solo ese método no arreglaría
   el reproductor.
2. `delta = max(second.pts-first.pts, 1/24)` estira intervalos de 25/30 FPS.
   La paridad fija 0,4/0,8 y 0,2/0,6 solo representa la relación 24→60.
3. El contador divide entre 1 segundo aunque la ventana dure más y sustituye
   cualquier valor superior a la mitad del objetivo por el objetivo nominal.
4. `enqueuePaced` no devuelve éxito/fracaso. Se avanza previousEnqueuedPTS
   incluso después de timeout. `HDRDisplayRenderer.enqueue` cuenta intentos
   como encolados y entrega aunque la capa no esté lista.
5. La instrumentación abre/escribe/cierra archivos por frame. No está desactivada
   en producción. Se separará diagnóstico detallado de ejecución normal.
6. WarpEngine fija un mínimo de pool, no un máximo; el diccionario de wrappers
   retiene buffers, dificultando su reciclado. Es necesario validar retención
   con prueba aislada antes de cambiarlo.

## Alcance de evidencia y secuencia

Se pueden corregir y probar los defectos temporales y de contabilidad sin
suponer una ganancia de GPU. La saturación intermitente no demuestra que sea el
cuello de botella dominante: conservar el pacing acotado existente.
La optimización del motor queda sujeta a medición aislada de pares reales.
La matriz de tres escenas × cuatro modos × tres repeticiones, PiP visual,
desfase A/V y sesión térmica de 30 minutos siguen pendientes de ejecución.
No se declara cumplido el objetivo de <0,1 % de frames tardíos.
