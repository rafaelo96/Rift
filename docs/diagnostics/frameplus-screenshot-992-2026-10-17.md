# Captura 16:32: diagnóstico de Frame+ / F2

Se investigó la captura suministrada por el usuario sin modificar el motor. Se extrajeron con VT únicamente 49 planos de luminancia entre 991.032 y 993.034 segundos de Avatar. Es la escena del personaje con gafas; no se afirma haber identificado el subframe exacto de la captura ampliada. Plano de trabajo 1152×480, no captura nativa RGB/HDR.

Se reprodujeron 48 pares adyacentes a t=.5 y 47 tripletes reales, ambos con Frame+ actual y F2. En tripletes el central real es la referencia; en pares adyacentes no existe central real. Mismas semillas, parámetros y contexto en ambas variantes; E2=0. La protección estática se mantuvo en la configuración de las instancias abiertas (variable ausente, equivalente a 0); no se modificó su implementación. Esta medición no sustituye los anteriores controles con la protección activada.

## Evidencia

Los frames fuente muestran contornos limpios a esta escala. Frame+ actual introduce fragmentos en boca/bigote y contornos; F2 también los presenta y redistribuye. La pareja adyacente23 ofrece una comparación A/B/actual/F2 y el triplete23 permite compararlos con el central real. No son comparaciones de tiempos arbitrarios entre reproducciones. El defecto ya se reproduce en la salida del interpolador de luma, antes del muestreo nativo de color, Strong y display. Esto no identifica todavía si el error preciso se origina en estimación, proyección o las reglas de síntesis; no se deduce un bug concreto de un recorte.

ROI facial fija [360,30,400,410], elegida por la escena, no máscara semántica validada. Promedios sobre los47 tripletes; MAE en códigos8 bits, gradiente Sobel en códigos8 bits/píxel, SSIM local11×11 sigma1.5, fórmulas F1. No son probabilidades ni medidas del screenshot HDR.

| Región | Medida | Actual | F2 |
|---|---|---:|---:|
| Cara | MAE | 2.939016 | 2.937187 |
| Cara | Error de bordes | 1.001694 | 1.013336 |
| Cara | SSIM | .918256 | .917133 |
| Exterior | MAE | 2.382106 | 2.385945 |
| Exterior | Error de bordes | .460944 | .471493 |
| Exterior | SSIM | .968177 | .967358 |

F2 empeora error de bordes facial ~1.16%, y el MAE facial empeora en28/47 tripletes pese al promedio casi idéntico. Las tres medidas exteriores empeoran. No se adopta como corrección de esta escena.

Había dos procesos Rift: `dist/Rift.app` con F2=1 y `/Users/rafael/Applications/Rift.app` sin esa bandera. No hay evidencia para atribuir retrospectivamente la captura a uno. Se cerraron ambos y se abrió una sola instancia de la compilación Release local con F2=0 y E2=0. El filtro experimental sigue disponible mediante su lanzador explícito; la ejecución ordinaria no lo activa. No se alteraron preferencias, búsqueda, selección ni protección estática.

## Archivos / reproducción

- `assets/frameplus-screenshot-992-2026-10-17/comparison-span1-pair23.png`: A, B, actual y F2.
- `comparison-span2-pair23.png`: central real, actual, F2.
- `comparisons-lossless.zip`: todas las comparaciones PNG sin seleccionar solo resultados favorables y métricas originales.
- `structural-summary.json`: medidas por triplete y promedios.
- `source-manifest.json`: PTS, hashes y fuente de los49 planos, sin copiar el archivo fuente completo.

Herramientas: compilar MVProbe Release; exportar la ventana con `MV_PAIRS=48 MV_SEEK_SEC=991 MV_TRAJECTORY_EXPORT=<carpeta> MVProbe <fuente>`; ejecutar `MV_SCREENSHOT_AUDIT_WINDOW=<carpeta> MV_SCREENSHOT_AUDIT_OUTPUT=<salida> RIFT_STATIC_MOTION_GUARD=0 MVProbe`; analizar con `FramePlusScreenshotReport.py <salida>`.

Verificado: compilación Release/M4,95comparaciones (48pares+47tripletes),hashes de entrada,imágenes y métricas,arranque de la variante ordinaria. No medido aquí: p95 de reproducción, color/HDR, equivalencia exacta con el subframe de la captura, causa matemática específica ni corrección del defecto. No se implementó un nuevo fallback ni ajuste sin evidencia.
