# Propagación de correspondencias verificadas

Alcance Core/Interpolation; rama diagnóstica de parches, desactivada en el reproductor. Después de optimizar parches independientes se realizan dos pasadas sincrónicas por nivel: candidatos de los cuatro vecinos se evalúan sobre el parche actual; solo se acepta una reducción estricta del SSD. No se promedian velocidades ni se aplican cambios de oclusión o síntesis. Una textura scratch reutilizable por nivel mantiene memoria acotada.

Check directo: un parche inicializado a 0px recupera la traslación correcta de 4px desde un vecino; la correspondencia correcta original se conserva y su residuo permanece próximo a cero. Pasan las baterías predeterminada, parches y parches+TV, sin relajar asserts. La prueba de iluminación también pasa: MAE vectorial 0.01928px; punto medio +120 2.67122, cuatro vecinos 3.02930; -60/+60 2.65625/2.66406. Traslación sin iluminación: punto medio 0.55664 frente a 0.94076 anterior.

Avatar, misma luminancia 1152×480, Apple M4:

| Ventana | Antes | Propagación |
| --- | --- | --- |
| 69 s | 5.55211 / 5.50088 / 6.44829 | 5.10308 / 5.13065 / 6.05921 |
| 300 s | 22.10902 / 22.23173 / 42.40777 | 17.39512 / 17.86810 / 44.34723 |

Cinco referencias mejoran; tercera a 300 s empeora. Referencias ocultas en esa ventana contienen poses retenidas: estas cifras no equivalen a fluidez ni certifican forma del objeto. Inspección de `/tmp/rift-propagation-300/pair4_four_t0.5.png` sigue mostrando fragmentos grandes. No se declara solucionado ni se integra.

Costo observado de análisis más tres síntesis: 25.3–31.9ms a 69 s, 22.5–29.5ms a 300 s, excluyendo búsqueda inicial, decode, descarga y presentación. La mejora de correspondencia consume parte del margen; la calibración y el presupuesto completo siguen pendientes. Logs `/tmp/rift-propagation-69.log`, `/tmp/rift-propagation-300.log`.

El usuario confirmó que no dispone de Splash para comparación directa. La equivalencia visual con Motion² no está verificada; esto no impide completar diagnóstico, color/HDR e integración, pero tampoco autoriza afirmar equivalencia a partir de estas pruebas.

Preservación: etiqueta `codex/frameplus-checkpoint-20261013`, commit `07e939039a0b5052b981be05f0aa757cfa47f5f7`, guarda una snapshot de cambios tracked que estaban pendientes (incluida UI), sin quitarlos del checkout. Los cambios de cada etapa de interpolación tienen commits independientes. La etiqueta no incluye archivos untracked ni ignored.
