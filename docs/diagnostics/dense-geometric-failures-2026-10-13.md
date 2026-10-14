# Correspondencia geométrica en cambios de pose

Añadido diagnóstico opt-in `MV_DENSE_EVIDENCE=1` para pares reales de cuatro frames. Cuenta plegamientos del mapa p+0.5F(p), confianza inferior a 0.05 y residuo de inversión superior a un píxel; exporta máscara de plegamientos. Las magnitudes cubren todos los píxeles interiores, incluidos fondos y límites de superficie; no son porcentajes directos de calidad visual.

Avatar 300 s, 1152×480, Apple M4:

| Par | Plegados | Sin soporte | Inversión >1px |
| --- | ---: | ---: | ---: |
| 1 | 35226 | 18864 | 332550 |
| 2 | 32378 | 114000 | 443678 |
| 3 | 16021 | 18720 | 284822 |
| 4 | 19168 | 86311 | 357120 |

Total 552960 píxeles por imagen. `/tmp/rift-geometry-300.log` y máscara `pair4_folded.png`: plegamientos concentrados en contornos de personajes. `pair4_four_t0.5.png` conserva parches severos.

Hipótesis probada: ampliar los mapas de proyección a todas las correspondencias bidireccionales verificadas y usarlas cuando falla la inversión, manteniendo prioridad del primer plano. Pasaron comprobaciones sintéticas, pero en el par 4 el residuo >1px cambió 357120→357121 y la imagen siguió deformada. No proporciona trayectorias alternativas suficientes; ensayo descartado. Logs `/tmp/rift-project-all-300.log`. No se mantiene el cambio de síntesis ni se integra en la aplicación.

La siguiente investigación debe localizar por qué el estimador acepta campos incompatibles y por qué hay tan pocas correspondencias verificadas para reemplazarlos. Corregir únicamente la inversión o proyectar más candidatos existentes no resolvió el caso. Mantener objetivo de calidad y tiempo real abierto.

## Separación de búsqueda y oclusión

El diagnóstico ahora compara el error fotométrico del seed por bloques y del campo refinado al transportar al segundo extremo (muestreo entero, indicador comparativo, no verdad vectorial). En pares 2 y 4: seed MAE 46.2105 / 32.5041; refinado 35.4391 / 19.8985. El refinamiento mejora el matching, pero siguen faltando correspondencias válidas en cambios de pose.

Ensayo de oclusión: exigir cierre de una trayectoria competidora y menor residuo para declarar una superficie oculta reduce fallos inversos del par 4 de 357120 a 170100; la imagen conserva fragmentos grandes y saltos al origen. Además empeora las referencias de 69 s de 8.3607/9.2850/10.2572 a 15.1805/15.7893/19.2982. Por tanto se retiró el criterio estricto: un campo competidor incorrecto no permite discriminar oclusión con fiabilidad. Datos en `/tmp/rift-endpoint-300.log`, `/tmp/rift-verified-occlusion-300.log` y `/tmp/rift-verified-occlusion-69.log`.

Siguiente hipótesis: el refinamiento LK por píxel, seguido de promedio local de vectores, conserva mínimos incorrectos y mezcla trayectorias sin volver a verificar el parche. Evaluar búsqueda inversa de parches solapados y agregación según residuo individual, manteniendo síntesis y oclusión sin cambios, permitiría separar esa causa y reducir trabajo redundante. Referencia clásica primaria: [Kroeger et al., Fast Optical Flow using Dense Inverse Search](https://arxiv.org/html/1603.03590v1), secciones 2.1 y 2.2. No se importará código ni una dependencia; los resultados publicados no se asumirán como rendimiento de Rift.
