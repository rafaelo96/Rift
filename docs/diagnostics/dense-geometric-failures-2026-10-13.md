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
