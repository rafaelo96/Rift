# Refinamiento centrado experimental

Hardware: Apple M4. Compilación release de MVProbe. Archivo Avatar original, ventana acotada de 100 pares desde 69 s; 1152×480, bloques 8, lambda 1, EMA 2 px. Sin transcodificación ni modificación del archivo.

Comando: `MV_CENTERED=1 MV_PAIRS=100 MV_SEEK_SEC=69 MV_DUMP=0 MV_LAMBDA=1 MV_TEMA=2 .build/release/MVProbe`

Primera etapa: costo centrado bilineal en t=0.5, candidatos vecinos y +/-2 px alrededor del campo existente. Memoria adicional fija: un campo de vectores L0. No modifica los vectores, historial ni síntesis de producción.

Verificación: compilación release correcta; asserts de traslación conocida, imagen estática, determinismo y conservación del campo de producción; 100 pares sin incremento de su objetivo.

Resultados: residuo medio 17.35378 → 10.31719 (40.5%); costo adicional medio 5.22435 ms, p95 5.989 ms. Es costo de refinamiento, no del pipeline completo. Incluye espera de GPU; excluye compilación inicial y métricas CPU. No extrapolar a M1.

Inspección de `/tmp/rift-centered/baseline.png` y `centered.png`: persisten contornos deformados y parches. La reducción del objetivo NO demuestra mejor fluidez ni elimina oclusiones. No activar en producción con esta evidencia.

Siguiente hipótesis: regularizar respecto del predictor existente en vez de permitir cualquier candidato con menor residuo. El experimento sigue separado de la reproducción.

Segunda etapa: se añadió penalización por distancia L-infinito respecto del vector original, escalada por área de bloque y peso explícito experimental. Checks adicionales: penalización extrema conserva el predictor; peso 4 no aumenta el residuo original en traslación sintética. No se presume que un peso fijo sea óptimo para toda película.

Comando de comparación: igual que arriba con `MV_CENTERED_WEIGHT=4`. Imágenes de comparación en `/tmp/rift-centered-weight-4/`. La inspección conserva distorsiones en el objeto grande; el siguiente paso evalúa un candidato temporal derivado del par anterior, sin cambiar el estado de producción.

Tercera etapa: candidato derivado del campo refinado del par anterior (contexto de tres frames mediante vectores, no análisis directo de cuatro imágenes). Dos campos adicionales acotados; el probe reinicia su predictor cuando simula seek con `MV_TEMARESET_AT`. La API verifica dimensiones y no retiene historial entre llamadas. Checks: candidato temporal no empeora el objetivo original; tamaño incorrecto devuelve error. Comando: peso 4 más `MV_CENTERED_TEMPORAL=1 MV_TEMARESET_AT=50`. Esta prueba no valida seek en una sesión GUI ni demuestra que Splash use el mismo esquema.

| Variante | Pares / instante | Residuo original | Residuo refinado | Refinamiento medio ms |
|---|---|---:|---:|---:|
| Centrado | 100 / 69 s | 17.35378 | 10.31719 | 5.22435 |
| Predictor peso 4 | 100 / 69 s | 17.35378 | 14.12762 | 5.19182 |
| Predictor + temporal, reset en 50 | 100 / 69 s | 17.35333 | 14.05658 | 5.33958 |
| Predictor + temporal | 100 / 3600 s | 11.48140 | 10.74441 | 5.55643 |

El reset altera también la EMA del campo original: la tercera fila no es una ablación perfectamente idéntica. La mejora pequeña no justifica aún una ventana directa de cuatro imágenes. Pesos y umbrales son exploratorios, no preferencias de usuario ni parámetros finales.

Cuarta etapa: prueba de confianza por bloque comparando campos centrados forward/backward en las mismas coordenadas intermedias. Cierre máximo de 2 px por eje; regiones rechazadas copian el original, sin crossfade 50/50. Se verificaron aceptación de traslación consistente y copia exacta de una región inconsistente. En el primer par de 69 s aceptó 6565/8640 bloques (76.0%). El reverse pass se ejecutó solo para la imagen diagnóstica; su costo NO está incluido en las medias anteriores. Inspección de `regional.png`: introduce límites de bloque visibles y conserva deformaciones. No habilitar; no resuelve la limitación documentada de motion blur/bokeh.

Resultado de la ejecución: cuatro hipótesis exploradas, producción conservada. Falta una síntesis que preserve los contornos y una comparación temporal perceptual. No están validados reproducción GUI, cadencia sostenida, M1, HDR EDR ni equivalencia con Splash. Los PNG son diagnóstico de luma 10-bit reducido a 8-bit, no evaluación de color HDR. Todos los checks y la última compilación release pasaron; los experimentos reales terminaron con `OK — MVProbe finished`.
