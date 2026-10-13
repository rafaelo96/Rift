# Flujo denso bidireccional — 2026-10-12

## Estado

Prototipo aislado en Core/Interpolation, no integrado en Frame+. Mejora una escena problemática de Avatar, pero **no resuelve la calidad general ni demuestra equivalencia con Splash**. No se modifican UI, decoder, scheduler, persistencia ni el archivo fuente. Sin nuevas dependencias, redes neuronales o pruebas M1/distribución.

## Implementación

`DenseMotionPrototype` recibe dos planos de luma UInt16 normalizados a 0…1023 y dos campos de bloques en medias unidades de píxel. Texturas Metal reutilizadas, cuatro niveles máximos, dos sentidos y dos buffers de flujo por nivel. Hasta cuatro salidas temporales por par, compartiendo la misma estimación; no guarda historia ilimitada.

El análisis usa filtro binomial y pirámides con antialiasing; la síntesis conserva la imagen original sin ese filtrado. Refinamiento Lucas–Kanade de 5×5 con regularización espacial. Variante opcional TV-L1 implementada matemáticamente en Metal, sin copiar código externo. Referencias de los métodos: [Lucas–Kanade piramidal](https://graphics.stanford.edu/courses/cs448a-00-fall/bouget00.pdf) y [TV-L1](https://www.ipol.im/pub/art/2013/26/).

La síntesis invierte `q + t·F(q) = p` mediante Newton amortiguado. Evalúa ambas trayectorias y candidatos de superficie local. Si una trayectoria visible solo existe en un extremo, transporta ese extremo en vez de mezclar una superficie tapada. El signo negativo del canal w identifica falta de cierre bidireccional; **es una heurística de oclusión, no prueba de visibilidad real**. Una estimación errónea también puede fallar el cierre y provocar selección incorrecta.

Errores concretos corregidos durante la evaluación:

- Inversión fija insuficiente en flujo afín: residuo >1px frente a <0.002px con Newton en la referencia analítica.
- Mezcla de campos en un borde ocultaba la discontinuidad a la condición de propiedad. Se inspecciona también el cierre de las trayectorias; la escena con flujo exacto pasa.
- Protección estática congelaba texturas casi periódicas trasladadas. Se exige que la coincidencia sin transporte sea competitiva con la compensada.
- Repetir la estimación para t=.25/.5/.75 triplicaba el costo innecesariamente. El lote comparte el flujo sin alterar los píxeles de cada salida.

## Checks aislados

`swift build -c release --product MVProbe`

`MV_DENSE_CHECK=1 .build/release/MVProbe`

`MV_DENSE_CHECK=1 MV_DENSE_TV=1 .build/release/MVProbe`

Ambas variantes pasan: inversión afín; capas de movimiento con ocultamiento; extremos exactos; imagen estática; determinismo; traslación desde semilla imperfecta; tamaños impares; rechazo de luma fuera de rango, NaN, geometría incorrecta y lotes vacíos/de más de cuatro muestras. El lote y las llamadas individuales producen los mismos píxeles.

Con campos exactos, MAE de la síntesis por capas (escala 0…1023): 0 en t=.25/.5 y 0.015625 en t=.75; ningún píxel difiere más de 10 unidades. Con estimación real, las tres MAE son 5.34/7.50/5.63, frente a 14.26/20.26/14.85 con warp por bloques. Este resultado sintético no asegura calidad en una película.

Traslación conocida: error vectorial medio 0.00199px y MAE de detalle 0.00130 sin TV; con TV 0.00301px y 0.69727. El residuo de transporte de un lado no usado en una oclusión puede ser alto; contabilizar ambos lados sin distinguir el visible no sirve como criterio único de rechazo.

## Avatar y rendimiento medido

Máquina: **Apple M4**. Plano de trabajo 1152×480. Seis pares por posición, 18 frames generados. Solo un tramo corto en memoria; no copia/transcodificación del video. Comando reproducible:

```sh
MV_DENSE=1 MV_DENSE_GROUND_TRUTH=1 MV_PIPELINE=0 MV_PAIRS=6 \
MV_SEEK_SEC=69 MV_DUMP=0 MV_LAMBDA=1 MV_TEMA=0 \
MV_DENSE_OUTPUT=/tmp/rift-dense-69 .build/release/MVProbe
```

La referencia oculta el frame central de tres frames decodificados y reconstruye en su PTS real, usando los otros dos. Esta separación de ~83ms es más difícil que interpolar entre frames adyacentes de ~42ms y puede incluir retenciones de animación, aceleración o cambios de escena.

| Posición | MAE por bloques | MAE densa | Resultado |
|---|---|---|---|
| 69s, cinco referencias | 15.02 / 15.35 / 15.81 / 17.58 / 17.42 | 10.49 / 10.52 / 11.37 / 12.37 / 12.18 | Mejora cercana al 30%; aún hay contornos incorrectos |
| 300s | 30.47 / 20.76 / 33.56 / 36.22 / 22.98 | 41.73 / 51.05 / 29.40 / 35.21 / 24.86 | Regresiones importantes; no pasa |
| 1800s | 1.00 / 1.99 / 0.75 / 2.60 / 2.98 | 1.49 / 1.82 / 0.70 / 3.22 / 3.12 | Resultado mixto; no pasa como mejora general |

En 69s, el frame adyacente intermedio reduce copias exactas de los extremos en zonas con cambio de ~53% a ~10%. Eso indica transporte adicional, **no demuestra corrección ni fluidez percibida**. La inspección visual muestra menos parches grandes que el warp por bloques, pero quedan errores de contorno. No se valida el producto a partir de confianza o MAE solamente.

Inspección de 300s: el personaje pasa del borde derecho a cubrir gran parte del encuadre entre frames adyacentes, mientras el fondo cambia poco. Hay movimiento muy superior al caso de 69s y regiones que solo existen en uno de los extremos. No se confirmó un error de orden/PTS: el driver ordena por el timestamp del callback, conserva una cola de reordenamiento acotada y exige tiempos crecientes. Esta observación no valida la decodificación entera ni permite descartar todas sus causas; sí impide tratar la falta de cierre como evidencia suficiente de oclusión recuperable.

Ablación de alcance `MV_DENSE_WIDE=1`: radio grueso de 16 a 30 píxeles (32→60 medias unidades), con un alcance nominal acumulado de ~212→324 píxeles a resolución de trabajo. MAE densa en 300s: 44.66 / 51.64 / 32.94 / 35.81 / 23.69; no corrige la regresión. Un radio de 64 píxeles en el nivel grueso fue rechazado por el guard de memoria threadgroup existente (ventana 144×144, 82,944 bytes). No se modificó esa protección ni la estructura del estimador. El resultado descarta esa ampliación limitada como solución, **no descarta** un estimador capaz de cubrir desplazamientos mucho mayores. El flag solo modifica el driver aislado, con el alcance original como valor predeterminado.

Costo antes del lote: ~26–28ms por salida, recalculando flujo. Con lote: ~30–32ms por par para análisis más tres síntesis; cada síntesis adicional ~1.7–2.6ms. Primera llamada ~45–54ms. TV: ~173–179ms por análisis/salida antes de compartir el flujo, sin mejora visual suficiente; no es la vía seleccionada.

Los tiempos incluyen subida de luma, comandos y espera GPU. **Excluyen lectura de resultados, scans CPU, búsqueda inicial de bloques, decode y presentación.** El modo diagnóstico descarga campos/imágenes y escribe PNG; no mide reproducción. No generalizar al M1 ni afirmar tiempo real del pipeline completo. El prototipo solo sintetiza luma de trabajo: color, CVPixelBuffer/HDR y conexión al renderer no están implementados aquí.

## Qué falta

La selección de superficies pasa con flujo conocido, pero la clasificación de oclusión depende de un flujo estimado que puede ser incorrecto. Resolver esa ambigüedad requiere evidencia adicional o un modelo de movimiento más consistente; marcar todo fallo de cierre como ocultamiento deja artefactos. No integrar esta variante ni reemplazar las salvaguardas de producción hasta superar las escenas desfavorables y verificar coherencia temporal. Se mantienen pendientes la síntesis nativa de color/HDR y el presupuesto completo; M1 y distribución siguen fuera del alcance actual.
