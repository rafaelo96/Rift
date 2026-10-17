# Presupuesto en tiempo real: agrupar la síntesis del par

Fecha: 2026-10-16. Dispositivo medido: Apple M4. Estado: candidato aislado; **no integrado en Frame+**.

## Causa localizada

La ruta nativa ya calcula una sola estimación para todas las posiciones `t` del par y no descarga los mapas a CPU. Sin embargo, `DenseMotionPrototype.interpolate` termina y espera un command buffer por cada posición. Para tres imágenes hay tres esperas CPU/GPU aunque la CPU no usa los resultados intermedios. `nativeCoordinates`, `nativeBlend` y los buffers de ownership se pueden reutilizar secuencialmente dentro de un mismo command buffer: los encoders conservan el orden y las dependencias de recursos rastreados.

Propuesta mínima: conservar el mismo command buffer entre posiciones si `downloadResults == false`, codificar síntesis y consumidor nativo de cada posición en orden, y esperar una sola vez al final. Mantener las esperas actuales cuando hay descarga diagnóstica. Las salidas nativas siguen siendo buffers distintos y la ventana continúa limitada a cuatro posiciones como máximo.

El parche exacto está en `Core/Interpolation/Tools/RealtimeBudgetCandidate.patch`. Es una propuesta para integrar por el agente coordinador, no una modificación del código de producción.

## Prueba reproducible

Ejecutar desde el proyecto:

```
Core/Interpolation/Tools/RealtimeBudgetRun.sh
```

El runner compila el motor original y una copia temporal renombrada con el parche. No cambia archivos existentes ni procesa películas. La plantilla `.swift.txt` evita introducir otro `@main` en el target MVProbe. Requiere únicamente Swift, Metal y Python estándar; no instala dependencias.

La prueba genera dos planos sintéticos 768×320 normalizados a 10 bits, usa la ruta de patches con inverseSearch, y compara 1, 2, 3 y 4 posiciones. Un blit captura por separado los mapas de coordenadas y mezcla antes de su reutilización. En las 32 comparaciones esos datos son byte-idénticos. La ruta con descargas mantiene también píxeles, fiabilidad y residuo de mapeo idénticos para tres posiciones.

Se alternó el orden original/candidato por iteración. Se descartó una iteración inicial y se tomaron siete muestras por variante para el caso de tres posiciones:

| Variante | Mediana del par sintético |
| --- | ---: |
| Original | 12,288250 ms |
| Una espera final | 12,051458 ms |
| Diferencia | 0,236792 ms (1,93 %) |

Una primera corrida sin alternar orden daba 13,97→10,89 ms, y otra a 384×160 daba 2,73→2,28 ms. **No se adopta esa mejora grande**: la repetición controlada evidencia variabilidad y no permite atribuir tres milisegundos al parche. Registro final: `/tmp/rift-realtime-budget768-alternating.log`.

## Límites y trabajo de integración

- El consumidor del harness copia mapas; no ejecuta la reconstrucción de color nativa, decoder, presentación, audio ni sesión prolongada. No mide reproducción ni demuestra 60 fps.
- La identidad de mapas implica que la entrada geométrica del mismo shader nativo se conserva, pero todavía hay que verificar los CVPixelBuffer finales de 8/10 bits y la vida de wrappers IOSurface en la integración real.
- La semántica de `Result.milliseconds` por salida cambia si se difiere la espera: antes de integrar debe conservarse una contabilidad explícita del coste completo del par. El consumidor de producción actual usa elapsed externo y descarta esos resultados diagnósticos; otros consumidores no deben confundirse.
- Mantener el modo diagnóstico con descargas sin batching; revisar también `RIFT_DENSE_PROFILE` y `diagnosticObserver`, que introducen barreras deliberadamente y no sirven para estimar rendimiento normal.
- `MotionCompensator.meMS` empieza después de scaledLuma, pero `RiftPlayerState` ya mide la llamada completa por fuera. No se encontró un error de admisión por ese motivo.
- El coste adicional de correspondencias por color (aproximadamente 14→40 ms en el experimento anterior) no se resuelve con esta mejora pequeña.
- No modifica la elección de superficies: **las deformaciones visuales pendientes siguen siendo problema independiente**. Este candidato libera una pequeña parte del presupuesto; no demuestra equivalencia con Motion².
