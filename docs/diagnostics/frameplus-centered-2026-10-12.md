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
