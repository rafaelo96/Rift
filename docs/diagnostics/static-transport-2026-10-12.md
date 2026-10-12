# Un píxel sin cambio no implica ausencia de movimiento

Hardware: Apple M4. Alcance: Core/Interpolation. Este hallazgo es independiente de la limitación conocida de motion blur/bokeh y del signo/escala de W0/W1.

## Reproducción y causa

Un punto brillante pasa de x=8 a x=16 en un fondo uniforme. Con el vector correcto (+8 px), debe aparecer en x=10,12,14 para t=0.25,0.5,0.75. El bypass previo comparaba únicamente I0(p) con I1(p): ambas muestras de fondo coincidían en esas posiciones y descartaba el punto. `MV_WARP_CHECK=1 .build/release/MVProbe` falló antes del cambio en t=0.25, error máximo 896/1023; t=0 sí era correcto.

## Corrección

Se exige soporte estático temporal también en p0 y p1, las posiciones compensadas. Coincidir solo en p ya no basta. Se conservan los umbrales relativos existentes, la oclusión suave y selección dominante; el snap final por oclusión exige el mismo soporte. La misma regla se aplica a work-plane luma/croma y a síntesis nativa luma/croma, sin cambios a buffers CVPixelBuffer, attachments ni persistencia.

No se desactiva protección estática: con I0==I1 y vectores espurios, todas las posiciones transportadas siguen coincidiendo entre frames y se copia exactamente el original.

## Validación

- Test del punto móvil: error máximo 0 en t=0,0.25,0.5,0.75,1.
- Contenido idéntico con vectores espurios: copia exacta.
- Kernels nativos luma, croma 4:2:0 y 4:2:2, y croma work-plane: movimiento/estático y cinco tiempos, en dos escalas numéricas (10-bit normalizado y valores multiplicados por 64). Este test de textura no valida formato CVPixelBuffer/HDR completo.
- Registro affine, centros de rejilla, límites y campo uniforme: pasó `MV_GRID_CHECK=1`.
- Release MVProbe y Rift compilaron; `git diff --check` sin problemas. Build local enlaza con FFmpeg de desarrollo; no se generó ni distribuyó un bundle nuevo.
- Avatar: 100 pares desde 69 s y otros 100 desde 3600 s terminaron correctamente, sin copiar/transcodificar el video.

## Resultados observados y límites

Comparación controlada de seis pares a 69 s, lambda 1, EMA 2, tras corregir la rejilla y antes/después de corregir bypass: warp genuino según métrica existente 43.7% → 55.2%; mediana de distancia temporal relativa al I0 0.103 → 0.443. Son indicadores de menor congelación, no ground truth ni prueba de calidad perceptual.

En 100 pares, warp work-plane: media 0.779 ms / p95 0.899 ms a 69 s; media 0.780 ms / p95 0.977 ms a 3600 s. Estos números excluyen decode, ME, uploads, sincronización, croma nativo y adaptación térmica. No extrapolar a M1.

PNG: `/tmp/rift-transport-after/69.png`, versus `/tmp/rift-grid-after/69.png`. Persisten deformaciones. En el pipeline de producción la protección de calidad sigue devolviendo originales en esos pares (Warp=0); no se han relajado gates para aparentar fluidez. Falta mejorar correspondencias/representación de movimiento antes de sostener interpolación útil en estas escenas. No están comprobados sesión GUI, cadencia prolongada, M1 ni EDR.
