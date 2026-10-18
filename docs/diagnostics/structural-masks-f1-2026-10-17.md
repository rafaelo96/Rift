# F1 — máscaras estructurales candidatas y línea base — 2026-10-17

**Estado: pendientes de validación del usuario. F2 no iniciado.** Solo diagnóstico CPU sobre imágenes existentes. No se ejecutó Rift, Metal ni una nueva decodificación; no se cambió búsqueda, selección, protección estática ni E2. E2 permanece apagada. No se añadió ninguna bandera ni dependencia.

## Datos y alcance

Para cada caso se usa el triplete principal: extremos I4/I6, central real I5. La predicción es `quality/span2-pair4-before.png` (motor sin E2) y la verdad `span2-pair4-truth.png`, guardadas durante E2. Work plane 1152×480; luma cuantizada a8 bits por el exportador anterior. No se usan las imágenes `after` ni una mezcla E2 para crear las máscaras.

Los siete rectángulos originales de Fase1 se conservan. Las candidatas son máscaras por píxel derivadas de error dentro de esos rectángulos, no simples rectángulos ni máscaras de confianza. Tampoco son todavía etiquetas certificadas de deformación. El triplete no coincide con el instante intermedio de I4/I5 de las capturas adyacentes originales; aquí sí existe un central real con el que comparar. No se extrapolan a otros pares ni se siguen superficies por el video.

Los valores se miden en los PNG guardados, **no en buffers originales de10 bits**: la MAE se informa en códigos de8 bits y no se presenta como la MAE exacta de10 bits de los informes previos. La cuantización puede ocultar diferencias pequeñas, especialmente en69 s y18:02. No se valida color/HDR.

## Construcción de candidatas — parámetros congelados para los tres casos

Se calcula sobre el frame completo y después se recorta a la unión de ROIs, para evitar crear bordes artificiales al filtrar cada recorte.

1. Luma normalizada a[0,1]. Gradientes Sobel3×3, división por8, padding reflect. Error estructural de gradiente por píxel: `G = sqrt((gx_pred−gx_real)^2 + (gy_pred−gy_real)^2)`. Se expresa como `255*G`, códigos de8 bits por píxel de trabajo. Penaliza posición, intensidad y orientación del borde; no es distancia geométrica pura entre contornos.
2. SSIM local: ventana gaussiana11×11, σ=1,5; momentos poblacionales ponderados; C1=.01² y C2=.03² para rango1. `SSIM=((2μpμr+C1)(2cov+C2))/((μp²+μr²+C1)(varp+varr+C2))`. Mapa limitado a[-1,1]; pérdida `D=1−SSIM`. La ventana alcanza5 píxeles alrededor de cada centro, también fuera de la máscara o ROI.
3. **Sensible (naranja):** D≥.01 **y** 255G≥.5. Se retiran componentes conexas de4 vecinos menores de8 píxeles. No se dilata, no se rellenan huecos ni se amplía ninguna ROI. La máscara previa a ese filtro también se guarda.
4. **Núcleo exigente (rojo):** subconjunto de la sensible con D≥.10 **y** 255G≥2. No se fuerza un mínimo de área ni un porcentaje por caso. Puede quedar vacío.

Umbrales diagnósticos elegidos antes de observar las salidas, comunes a los tres casos; no fueron optimizados frente a una anotación humana ni modificados para cubrir una deformación concreta. La selección no usa MAE. No se consideran validadas ni se emplean para evaluar una regularización.

## Máscaras entregadas

| Caso | Área ROI | Sensible | % de ROI | Núcleo | Componentes sensibles |
|---|---:|---:|---:|---:|---:|
| 69 s | 65,536 | 2,107 | 3.215% | 279 | 22 |
| 300 s | 40,960 | 16,694 | 40.757% | 9,242 | 28 |
| 18:02 | 34,304 | 53 | 0.155% | 0 | 4 |

Observaciones para la revisión, sin certificar etiquetas:

- **69 s:** el error fuerte está concentrado en fragmentos pequeños; en el recorte del bisonte aparece sobre todo en la esquina superior izquierda y un punto inferior. La candidata no abarca la mayor parte de la gran transición borrosa visible. No se asume que ese contorno quede validado por esta máscara.
- **300 s:** el mosaico alrededor de la cabeza y parte del contorno de ropa reciben bastante cobertura. Hay píxeles de fondo entre las regiones marcadas; hace falta decidir visualmente cuáles corresponden a la deformación que interesa medir.
- **18:02:** solo53 píxeles sensibles, sin núcleo exigente; una pequeña marca junto al ave. En este triplete el error estructural medido es bajo. La máscara no certifica el defecto originalmente denunciado ni se amplía artificialmente para aparentar detección.

Las imágenes de revisión muestran motor actual, central real, candidata sobre motor y candidata sobre real, con exposición×1,8 igual en todos los paneles. Naranja = sensible, rojo = núcleo. Los realces y ampliaciones nearest-neighbor son solo visuales; las métricas se calculan sin ellos. Las máscaras PNG binarias tienen tamaño original y no incluyen rótulos ni realce.

- [69 s: revisar todas sus ROIs](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/avatar69/case-review.png) · [Superposición en motor, frame completo](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/avatar69/prediction-overlay.png) · [Máscara sensible](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/avatar69/candidate.png) · [Núcleo](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/avatar69/core.png)
- [300 s: revisar todas sus ROIs](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/avatar300/case-review.png) · [Superposición en motor, frame completo](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/avatar300/prediction-overlay.png) · [Máscara sensible](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/avatar300/candidate.png) · [Núcleo](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/avatar300/core.png)
- [18:02: revisar todas sus ROIs](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/anime1082/case-review.png) · [Superposición en motor, frame completo](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/anime1082/prediction-overlay.png) · [Máscara sensible](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/anime1082/candidate.png) · [Núcleo](/Users/rafael/Documents/Rift/docs/diagnostics/assets/structural-masks-f1-2026-10-17/anime1082/core.png)

## Métrica de evaluación y línea base del motor

Para cada caso se fija la **misma terna de medidas**, evaluada sobre la máscara que se valide:

- Error medio del vector gradiente `mean(255G)` — menor es mejor.
- SSIM local medio `mean(SSIM)` — mayor es mejor; se guarda también `mean(1−SSIM)`.
- MAE `mean(abs(pred−real))*255` — menor es mejor, códigos8 bits.

No se reduce esta terna a una suma con pesos arbitrarios. Se informan también los valores de la ROI completa para que la selección por error no oculte su sesgo: estas candidatas se seleccionan a partir de la propia predicción base, por lo que es esperable que sus errores sean mayores que los de la ROI. Las cifras siguientes son **línea base provisional sobre candidatas no validadas**, no una mejora ni una evaluación F2. Si la validación cambia la máscara, estas medidas deben asociarse a esa versión final, manteniendo los mismos mapas fuente.

### Unión de las candidatas sensibles

| Caso | Píxeles | Error gradiente | SSIM local | MAE8 bits |
|---|---:|---:|---:|---:|
| 69 s | 2,107 | 2.36778 | 0.895153 | 2.67015 |
| 300 s | 16,694 | 3.55077 | 0.735407 | 7.48101 |
| 18:02 | 53 | 1.22563 | 0.984293 | 1.49057 |

### ROI completa, como referencia sin selección por error

| Caso | Error gradiente | SSIM local | MAE8 bits |
|---|---:|---:|---:|
| 69 s | 0.21036 | 0.993853 | 0.29083 |
| 300 s | 1.52446 | 0.874512 | 4.41421 |
| 18:02 | 0.15399 | 0.998399 | 0.13080 |

`baseline.csv/json` conserva además cada ROI por separado y el núcleo exigente; el núcleo vacío de18:02 tiene métricas nulas, no error0 ni SSIM1 inventados.

## Verificación y archivos

`StructuralMaskCandidates.py` reproduce F1 usando solo NumPy/Pillow ya disponibles. Comprueba identidad (SSIM1/error gradiente0), sensibilidad a un borde desplazado y eliminación de componentes pequeñas; comprueba que las candidatas están dentro de la ROI y el núcleo dentro de la sensible. `input-sha256.json` identifica predicciones, verdad real y coordenadas originales. `parameters.json` fija la receta y marca el estado como no validado. Los mapas numéricos de SSIM/gradiente se guardan sin normalización por imagen en `maps.npz`; los PNG de calor usan escalas comunes: blanco en pérdida SSIM≥.3 o gradiente≥8 códigos/píxel.

No hubo cambio del motor y por tanto no se presenta una comparación antes/después de una corrección, ni nuevas medidas de rendimiento. No se implementó regularización, no se activó E2, y no se usaron estas candidatas para decidir si un cambio mejora. **La siguiente acción queda reservada a la validación visual del usuario; F1 se detiene aquí.**
