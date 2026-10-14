# Iluminación y correspondencia

Diagnóstico `MV_DENSE_LIGHTING=1 .build/release/MVProbe`: traslación de cuatro píxeles sobre textura conocida, incremento uniforme de 120 unidades de diez bits, semillas de tres píxeles. El frame intermedio esperado conserva el detalle trasladado y suma 60. El check registra error y verifica valores finitos, no certifica resolución del fallo.

Antes: MAE vectorial 47.49165px, error del punto medio 267.3724. Normalizar la media por parche corrige movimiento a 0.00877px pero no el frame (15.72135); empeora las seis referencias reales (69 s: 5.61095/5.82026/6.53480; 300 s: 39.70835/40.20052/45.37669). Se descartó: pierde discriminación entre superficies de distinto brillo.

Compensación por media del frame completo: error vectorial 0.02444px, frame 18.48177. Sin cambio de iluminación, la traslación y el recorte alteran la media en -2.55859 unidades; esta compensación hace fallar el check existente de detalle (MAE 10.23047 >5). También empeora la tercera referencia de Avatar 300 s a 45.55054. Ensayo retirado. No se relajó el check de traslación para mantenerlo.

Ambos cambios de estimador fueron retirados. Se conserva el diagnóstico y no se presenta como una solución integrada. Los costes de búsqueda basados solo en luminancia siguen siendo ambiguos; quitar el brillo sin otra evidencia no resuelve qué superficie corresponde. Pendiente identificar regiones concretas y la información que permite distinguirlas, antes de otra modificación de matching.

Logs `/tmp/rift-patch-lighting-69.log`, `/tmp/rift-patch-lighting-300.log`, `/tmp/rift-global-lighting-300.log`; mediciones en Apple M4. Objetivo de calidad y fluidez comparable con Motion² abierto.

## Iteración que supera el caso reproducido

La compensación ahora exige que el desplazamiento medio de brillo domine su variación espacial: medias de diferencia en bloques 8×8, media² > varianza entre bloques. Si no hay evidencia de cambio coherente, offset cero. Esto evita compensar el cambio de media por recorte que hizo fallar el ensayo anterior. Es una heurística de exposición uniforme, no una solución a sombras locales, ganancias de contraste, recorte de highlights o cortes de escena.

El offset se aplica únicamente al análisis y a la comparación fotométrica de proyección/síntesis/soporte temporal. Las muestras originales de salida conservan el brillo de cada extremo. Segundo fallo identificado: el bypass estático congelaba puntos de una textura casi periódica durante el cambio de exposición, pese a existir un parche móvil verificado. En presencia de exposición compensada, cierre bidireccional <1px, confianza de ambos lados >0.5 y movimiento >1px, esa igualdad puntual no anula el movimiento. Los casos sin compensación conservan el bypass anterior.

Verificación con asserts: traslación cuatro píxeles y +120, error vectorial 47.49165→0.02444px, punto medio 267.3724→3.3125; cuatro vecinos 4.19987. Amplitudes -60/+60: 3.26628/3.28971. Todos los casos móviles requieren MAE<5; el caso +120 requiere también error vectorial<0.1px. Iluminación +120 sin movimiento conserva exactamente cada píxel del punto medio esperado, pese a semillas imperfectas.

Pasan las baterías predeterminada, parches y parches+TV, incluidos estáticos, vecinos retenidos con ruido, entradas inválidas, extremos, batch, determinismo y oráculos de visibilidad. No se relajaron los checks existentes.

Las seis referencias de Avatar mantienen exactamente los MAE anteriores de parches por superficies: 69 s 5.55210865/5.50088252/6.44829463; 300 s 22.10902054/22.23173286/42.40777452. Logs `/tmp/rift-coherent-final-69.log`, `/tmp/rift-coherent-final-300.log`. En Apple M4, análisis más tres síntesis observado a 300 s 16.5–23.5ms, incluye estimación CPU del offset, excluye seeds iniciales, decode, descarga y presentación. Los parches de cambios de pose siguen siendo un problema diferente; esta corrección no valida integración ni equivalencia con Motion².
