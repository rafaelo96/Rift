# F2 — selección delegada de máscaras y regularización offline — 2026-10-17

**Decisión: conservar el motor actual. No integrar esta regularización en reproducción.** Mejora algunas medidas dentro de las máscaras, pero empeora bordes/SSIM fuera de ellas y no muestra recuperación visual suficiente. E2 permanece apagada. Búsqueda, selección, protección estática, síntesis y código del reproductor no se modificaron.

El usuario delegó las decisiones tras F1 y autorizó avanzar a F2. Las máscaras siguientes son **principales elegidas por el asistente bajo esa delegación**, no una nueva anotación humana independiente ni verdad semántica certificada. Se congelaron antes de ejecutar la regularización; el compromiso `56598cc` conserva esa decisión.

## Máscaras principales y secundarias

| Caso | Principal | Píxeles | Secundaria | Motivo |
|---|---|---:|---|---|
| 69 s | Naranja F1 | 2.107 | Naranja F1 | No añadir el contorno borroso grande: también aparece en I5 real, y no hay evidencia para etiquetar todo el blur como deformación. |
| 300 s | Núcleo rojo F1 | 9.242 | Naranja F1 | Selección más exigente. No se excluye automáticamente fondo o cambio de pose: el residuo fragmentado en la posición antigua de la cabeza también puede ser error de síntesis. |
| 18:02 | Polígono manual ajustado al ave | 1.989 | Naranja F1, 53 px | Los datos muestran ave/paisaje, no boca/bigote/cabello. No se inventan etiquetas faciales. El polígono no implica que todos sus píxeles estén deformados. |

La superposición del polígono de 18:02 se mostró antes de utilizarlo. Coordenadas en work plane y hashes: `mask-decisions.json`. Las máscaras F1 originales permanecen sin cambiar; `primary-mask.png` y `secondary-mask.png` identifican explícitamente las usadas aquí.

- [69 s: principal sobre motor y central real](/Users/rafael/Documents/Rift/docs/diagnostics/assets/edge-field-f2-2026-10-17/avatar69/selected-overlay.png)
- [300 s: principal sobre motor y central real](/Users/rafael/Documents/Rift/docs/diagnostics/assets/edge-field-f2-2026-10-17/avatar300/selected-overlay.png)
- [18:02: principal sobre motor y central real](/Users/rafael/Documents/Rift/docs/diagnostics/assets/edge-field-f2-2026-10-17/anime1082/selected-overlay.png)

## Experimento y parámetros congelados

Solo archivos de `Core/Interpolation/Tools` y documentación. No se añadió una ruta nueva al motor de reproducción. `MV_F2_DIAGNOSTIC=1` abre el arnés offline; **`MV_F2_EDGE_REGULARIZE=1`** activa el filtro exclusivamente allí. Ausente/0 = no filtra. El arnés exige E2 apagada y protección estática aprobada encendida (`RIFT_STATIC_MOTION_GUARD=1`). No se alteró ninguna regla de esa protección.

Se reutiliza el callback diagnóstico existente de campo final (`diagnosticFlowOverride`, habilitado por `RIFT_DENSE_ORACLE=1` solo en este proceso). Aquí **no se inyecta un campo oráculo ni verdad de movimiento**: el callback recibe los campos ordinarios ya estimados/seleccionados/evaluados, aplica o no el filtro y los devuelve justo antes de proyección/síntesis. El control instrumentado devuelve los campos idénticos y usa las mismas descargas/reenvíos.

Filtro Metal, una pasada por dirección y por par, reutilizada entre subframes:

- Vecindario3×3 bloques8×8 (offsets −8/0/+8 píxeles), sin iteraciones ni estado temporal.
- Guía: luminancia media de cada bloque, normalizada por 1023. A para campo hacia B; B para el campo inverso, por simetría de sus coordenadas. No se utiliza RGB ni un modelo neuronal.
- Peso espacial gaussiano σ=1 bloque; peso de similitud de luminancia σ=.02. `w=exp(−(dx²+dy²)/2 − (ΔY/.02)²/2)`; w=0 si |ΔY|>.06. Peso central1. Umbrales comunes, sin ajuste por caso ni tras observar resultados.
- Mediana ponderada independiente de x/y. Se filtra cada píxel con vecinos en la misma posición relativa de bloques vecinos; no se reemplaza todo el bloque por un único vector central.
- Confidence/support z/w del vector central permanecen idénticos; no se vuelve a calcular selección, confianza ni protección. Ese metadata previo no se recalibra para el campo filtrado, limitación explícita del experimento.
- Se aplica a todo el campo, no solo a las máscaras: así se puede observar regresión fuera de las regiones de interés. Las máscaras no guían ni restringen el filtro.

La guía de luminancia no garantiza respetar fronteras de movimiento con igual luminancia ni bordes solo cromáticos. No se cambian estos parámetros para favorecer una máscara.

## Controles de igualdad y sintéticos

- Flag apagada: salida de luma y ambos campos finales exactamente iguales al motor ordinario, en los tres tripletes principales. Los PNG base también coinciden con las predicciones guardadas antes de F2.
- Los campos que entran al filtro son exactamente los finales del motor ordinario, comprobado en los tres casos.
- Campos uniformes de movimiento0 y paneo4 píxeles: invariancia exacta.
- Vector aislado20 píxeles en vecinos uniformes4, misma superficie: vuelve a4.
- Dos superficies con luminancia100/900 y movimiento+4/−4: campo exactamente preservado a través del borde.
- z/w conservados exactamente. Ninguna de estas pruebas sintéticas certifica que el movimiento físico real esté preservado en contenido ambiguo.

## Calidad: antes/después dentro y fuera

Triplete principal I4/I6→I5 real, 1152×480. Las imágenes/SSIM usan luma cuantizada a8 bits, exactamente la métrica F1 reutilizada; MAE en códigos8 bits, gradiente en códigos8 bits/píxel. Menor MAE/gradiente y mayor SSIM son mejores. Se verificó reproducción de la línea base F1 en las secundarias con tolerancia1e−10. No se usa la imagen E2 para evaluar.

### Máscara principal

| Caso | MAE antes → después | Error gradiente antes → después | SSIM antes → después |
|---|---:|---:|---:|
| 69 s | 2.670147 → 2.353583 | 2.367781 → 1.953675 | 0.895153266 → 0.915333383 |
| 300 s | 8.917983 → 8.631790 | 5.512697 → 4.624889 | 0.626614578 → 0.656692385 |
| 18:02 | 0.204625 → 0.204625 | 0.211392 → 0.209971 | 0.998179096 → 0.998179299 |

### Fuera de la principal: frame completo menos máscara

| Caso | MAE antes → después | Error gradiente antes → después | SSIM antes → después | Píxeles fuera con MAE mayor |
|---|---:|---:|---:|---:|
| 69 s | 1.279312 → 1.270767 | 0.592580 → 0.605493 | 0.959395552 → 0.958161809 | 2.864% |
| 300 s | 5.853453 → 5.879566 | 1.157309 → 1.208200 | 0.892037747 → 0.888844250 | 3.878% |
| 18:02 | 0.348929 → 0.354483 | 0.249720 → 0.254329 | 0.994492520 → 0.994156421 | 2.913% |

**No cumple ausencia de regresión fuera de máscara.** El gradiente y SSIM fuera empeoran en los tres casos; MAE fuera aumenta en 300 s/18:02. La mejora de MAE fuera en 69 s no oculta el empeoramiento estructural. Además se informa la fracción de píxeles empeorados: una media favorable no demostraría ausencia de daños locales.

### Secundarias estructurales

| Caso | MAE antes → después | Error gradiente antes → después | SSIM antes → después |
|---|---:|---:|---:|
| 69 s | 2.670147 → 2.353583 | 2.367781 → 1.953675 | 0.895153266 → 0.915333383 |
| 300 s | 7.481011 → 7.317539 | 3.550773 → 3.271288 | 0.735407125 → 0.746427329 |
| 18:02 | 1.490566 → 1.490566 | 1.225634 → 1.226215 | 0.984293470 → 0.984288183 |

`quality.json` conserva también el exterior limitado a las ROIs originales, fracción de píxeles cambiados y fracción con SSIM local peor. Las máscaras seleccionadas a partir del error base tienen sesgo de selección; la mejora dentro no constituye validación independiente.

## Inspección visual

- **69 s:** cambios en fragmentos pequeños y poca diferencia en el contorno borroso del bisonte. La reducción de error dentro de la principal no demuestra corregir el defecto original entre frames adyacentes.
- **300 s:** el mosaico sigue visible y cambia su distribución; persisten fragmentos y bordes rotos. No se recupera una silueta limpia aunque bajen medidas de error en el núcleo. Fuera de la máscara hay regresión estructural.
- **18:02:** el ave apenas cambia; el cambio de SSIM principal es de aproximadamente 0,000000203, sin mejora visible convincente. No se deduce ninguna corrección de una boca/bigote que no están en estos datos.

- [69 s / crossing-bison: actual frente a regularizado](/Users/rafael/Documents/Rift/docs/diagnostics/assets/edge-field-f2-2026-10-17/avatar69/crossing-bison-comparison.png)
- [300 s / face-contour: actual frente a regularizado](/Users/rafael/Documents/Rift/docs/diagnostics/assets/edge-field-f2-2026-10-17/avatar300/face-contour-comparison.png)
- [300 s / clothing-contour: actual frente a regularizado](/Users/rafael/Documents/Rift/docs/diagnostics/assets/edge-field-f2-2026-10-17/avatar300/clothing-contour-comparison.png)
- [18:02 / bird-contour: actual frente a regularizado](/Users/rafael/Documents/Rift/docs/diagnostics/assets/edge-field-f2-2026-10-17/anime1082/bird-contour-comparison.png)

## Movimiento en regiones de paneo

Se miden vectores finales antes/después en centros de bloques8×8, sobre48 pares adyacentes de las ventanas originales. Se excluye el par 6 de 18:02 por corte. Los campos previos de las corridas apagada/encendida son idénticos. Son estimaciones del motor en regiones conocidas de paneo, **no verdad física de movimiento**; no se presentan como desplazamientos reales certificados.

| Caso / región | Vector medio antes | Vector medio después | Magnitud media antes → después | Δ magnitud | p95 cambio vectorial por bloque |
|---|---:|---:|---:|---:|---:|
| 69 s / pan-background | (-16.89983, 0.34821) | (-17.13379, 0.35344) | 17.11693 → 17.32375 px | +1.208% | 3.37662 px |
| 18:02 / landscape-pan | (0.67261, -0.22060) | (0.67319, -0.22310) | 0.88802 → 0.88604 px | -0.224% | 0.13838 px |

No hay invariancia exacta en el paneo real: en 69 s la magnitud media aumenta 1,21%; en 18:02 disminuye 0,22%. La prueba sintética sí conserva exactamente 4 píxeles. `motion.json` y los ZIP de vectores por bloque permiten revisar la distribución; la media por sí sola no garantiza conservar cada trayectoria.

## Tiempo por etapa: cinco alternancias Release/M4

**Medición offline instrumentada, no p95 de reproducción nativa.** Mac Apple M4, 1152×480, tres subframes(.25/.5/.75) por par. Cinco alternancias apagado/encendido, cada una recorre48 pares×3 casos. Se retiran los primeros4 pares de cada caso:44 por caso y132 por variante/repetición. No se corre decode, Strong ni salida nativa en color; no se compara este total con los44,83/53,07 ms de E2 en reproducción a otro plano de trabajo.

Cada par se cronometra desde antes de las dos búsquedas semilla:

- **ME:** búsquedas semilla, estimación densa y assessment existentes, espera GPU y lectura diagnóstica del campo final.
- **Regularización:** ambas direcciones, construcción de guía, uploads, kernels, lectura de campos y verificaciones. Apagado solo deja el coste mínimo de las marcas de tiempo.
- **Síntesis:** reenvío/validación de campos, proyección y tres síntesis de luma, con lectura de resultados.

Son tiempos de pared secuenciales, incluyendo sobrecoste del callback diagnóstico en ambos controles, no solo duración pura de kernels. Se comprueba por par que ME+regularización+síntesis=total. p95 de cada etapa se calcula independientemente; **no se suman los p95**.

Una ejecución de la alternancia4 coincidió con un análisis CPU de imágenes. Se conserva como exploratoria y se reemplazó con la alternancia completa apagado/encendido sin esa actividad, con parámetros idénticos; no se eligió según resultados. Orden final1,2,3,5,4-repetida. Las cinco parejas aceptadas no tienen otro experimento GPU concurrente.

### Corpus de tres casos: mediana de los cinco p95

| Estado / etapa | Mediana p95 | Rango entre corridas | IQR | Desvío poblacional |
|---|---:|---:|---:|---:|
| off / ME | 58.375333 ms | 55.347792–60.872625 | 5.343583 | 2.432517 |
| off / Regularización | 0.000583 ms | 0.000541–0.000625 | 0.000042 | 0.000031 |
| off / Síntesis | 21.668416 ms | 21.084750–24.188708 | 1.058875 | 1.110213 |
| off / Total | 79.184875 ms | 74.484167–85.140792 | 6.269209 | 3.932252 |
| on / ME | 59.481792 ms | 56.942500–59.930542 | 1.750791 | 1.162870 |
| on / Regularización | 9.410209 ms | 8.751750–9.969750 | 0.438583 | 0.422029 |
| on / Síntesis | 21.622042 ms | 20.466375–24.476958 | 1.272459 | 1.437148 |
| on / Total | 88.994792 ms | 86.543375–91.933042 | 2.025958 | 1.864936 |

### p95 total por alternancia y variante

| Alternancia | Apagado | Regularizado |
|---|---:|---:|
| 1 | 85.140792 ms | 86.543375 ms |
| 2 | 74.484167 ms | 88.947167 ms |
| 3 | 82.020750 ms | 88.994792 ms |
| 4 | 79.184875 ms | 91.933042 ms |
| 5 | 75.751541 ms | 90.973125 ms |

Diferencia de medianas del p95 total: **+9.809917 ms**. Los resúmenes por caso y etapa con sus cinco corridas están en `timing-per-run.json` y `timing-summary.json`. Esto no establece presupuesto de tiempo real ni portabilidad a otros chips.

## Qué cambió y qué queda sin demostrar

Se añadieron selección delegada de máscaras, filtro y arnés **exclusivamente en herramientas offline**, registro de etapas desde el inicio y evaluación principal/secundaria/exterior. El script F1 recibió un guard `main` para reutilizar exactamente su métrica sin regenerar datos al importarlo; sus fórmulas, máscaras y resultados no cambiaron. El código de `Core/Interpolation/Swift` y shaders de producción permanecen sin cambios.

No se demuestra corrección visual general, ausencia de regresión exterior, conservación física de trayectorias, evaluación en RGB/HDR nativo, coste en reproducción con decode/Strong ni desempeño M1. Las máscaras son decisiones delegadas documentadas; no se confunden con anotaciones humanas independientes. Solo se verifica igualdad de luma/campos al apagar el experimento offline; el reproductor normal no contiene esta ruta nueva.

**Se conserva el motor actual y se termina el experimento aquí.** No se ajustan más parámetros ni se introduce este filtro en la aplicación para ocultar las regresiones.

Reproducción: compilar MVProbe Release; `EdgeFieldRuns.py quality`, `EdgeFieldRuns.py timing`, `EdgeFieldRuns.py motion` secuencialmente; `EdgeFieldReport.py` al terminar. `MV_F2_PHASE=synthetic` en el arnés ejecuta los controles. Los planos fuente existentes se leen en ventanas acotadas; ningún video fuente se copia o transcodifica. Los campos fuente siguen siendo los calculados por el motor; el callback de diagnóstico no altera la búsqueda/selección. Los hashes de construcción y máscaras están guardados junto a las mediciones.

La reutilización de la métrica F1 se comprobó además ejecutando su CLI tras el guard `main`: los 43 archivos F1 quedaron idénticos byte a byte (`scope-and-reuse-check.json`).
