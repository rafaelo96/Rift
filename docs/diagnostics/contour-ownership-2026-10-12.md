# Hipótesis de movimiento en contornos

Prototipo aislado en Core/Interpolation/Tools; producción sin modificar. Apple M4, release MVProbe. No pruebas M1 ni distribución.

En vez de promediar velocidades de objetos distintos, se elige una hipótesis de bloques vecinos mediante residuo transportado de parche 3×3 por píxel. Una segunda variante transporta centros de bloques al instante intermedio y conserva tres candidatos adicionales por celda. Memoria de candidatos acotada a cuatro campos; no copia el video fuente.

`MV_CONTOUR_CHECK=1 .build/release/MVProbe`: dos objetos/capas sintéticos con ground truth. MAE del campo en coordenadas intermedias: baseline 20.5433, selección 2.6048. Con campo en coordenadas del primer frame: baseline 20.2630, proyección 8.9014. Endpoints, estático y campo uniforme conservados. Checks de rejilla y transporte existentes también pasan.

Avatar, seis pares desde 69 s, lambda 1, EMA 2: CSV de vectores idéntico entre variantes. PNG `/tmp/rift-contour/{baseline,candidate,projected}.png`. Persisten deformaciones y parches: ninguna variante está autorizada por la evidencia para producción. Menor error sintético no equivale a calidad real ni fluidez perceptual.

Warp experimental: selección vecina media 3.540 ms, p95 4.017; proyección media 5.698 ms, p95 5.880. Excluye creación de candidatos CPU, decode, ME, croma/HDR y presentación. Se midió únicamente viabilidad del algoritmo, no pruebas de hardware ni sesiones largas.

Siguiente hipótesis: correspondencias apoyadas directamente en cuatro imágenes reales. Los candidatos derivados de solo dos imágenes siguen sin representar correctamente ciertas superficies; la elección local no puede recuperar una hipótesis ausente o incorrecta. Esto es una hipótesis de investigación, no una causa general ya confirmada.
