# Ventana de cuatro frames en flujo denso — 2026-10-12

## Alcance y estado

Implementado únicamente en el prototipo de Core/Interpolation. No modifica Frame+, UI, decoder, scheduler ni el archivo fuente. Sin nuevas dependencias ni modelos neuronales. **No es una solución definitiva ni está integrado en reproducción.** No se confirmó que Splash use exactamente cuatro frames.

Hipótesis nueva respecto al ensayo previo de cuatro frames por bloques: usar correspondencia temporal por píxel para refinar el flujo denso y distinguir un fallo de cierre de una oclusión recuperable. No se reabre el ajuste de thresholds del warp por bloques como solución al problema de bokeh.

## Implementación

`DenseMotionPrototype.TemporalContext` aporta anterior y posterior, más sus intervalos relativos a la duración del par central. La llamada recibe cuatro planos de luma UInt16, dos campos iniciales centrales en medias unidades de píxel y hasta cuatro tiempos de salida. Los intervalos se validan como finitos, positivos y acotados (0.25…4); la luma de los vecinos también debe estar normalizada a 0…1023.

Se reutilizan cuatro pirámides de imagen y dos campos de flujo centrales. Los vecinos contribuyen al sistema de Lucas–Kanade en cada nivel y dirección. Sus gradientes se escalan por el intervalo temporal: anterior `-a`, posterior `1+b` para el sentido adelante; `1+a` y `-b` para el inverso. El término central conserva su peso y los vecinos usan pesos robustos de apariencia/residuo. No se fuerza una coincidencia cuando la trayectoria sale de la imagen.

Después del refinamiento, una comprobación temporal por parches exige apoyo de al menos un vecino antes de considerar recuperable una correspondencia central sin cierre bidireccional. Una discrepancia en ambos vecinos reduce la confianza y elimina la marca de oclusión recuperable. Esto es evidencia fotométrica bajo **velocidad constante**, no prueba absoluta de visibilidad. Texturas ambiguas, aceleración, retenciones de animación, cortes y movimiento fuera del alcance pueden invalidar esa hipótesis.

No hay historial persistente de pares: los cuatro planos se aportan por llamada, y el flujo se comparte entre las muestras temporales del mismo par. Una llamada sin contexto no consume las texturas vecinas. La memoria Metal tiene cantidad fija de recursos; los planos adicionales y sus pirámides suman aproximadamente 12.5MB a 1152×480, sin medir aquí el RSS total del proceso. La integración futura necesita un frame fuente adicional de anticipación (~42ms a 23.976fps) y una tarea separada para el pipeline.

## Checks

```sh
swift build -c release --product MVProbe
MV_DENSE_CHECK=1 .build/release/MVProbe
MV_DENSE_CHECK=1 MV_DENSE_TV=1 .build/release/MVProbe
```

Ambas variantes pasan los checks funcionales anteriores y los nuevos:

- Shader temporal con trayectorias conocidas: rechaza una falsa oclusión en fondo estático; conserva el objeto trasladado y el fondo con trayectoria correcta.
- Extremos exactos y contenido estático con contexto.
- Traslación de cuatro frames desde semilla imperfecta: MAE de detalle 1.98177 sin TV / 1.10352 con TV (escala 0…1023; criterio <5).
- Sin contaminación entre llamadas: después de usar cuatro frames, una llamada sin contexto produce píxeles y campos idénticos a una instancia nueva.
- Rechazo de contexto con tamaño incorrecto e intervalo NaN, además de los checks compartidos de entrada, determinismo, lote y geometría.

Referencia por capas con estimación real: MAE intermedia 7.069 frente a 7.502 con dos frames; con TV 7.604 frente a 7.475, por lo que no es una mejora universal. Que un check funcional pase no significa que desaparezcan todos los artefactos.

## Experimentos separados

Hardware: **Apple M4**, plano 1152×480. Primero se añadió solamente comprobación temporal; después refinamiento temporal. Un tercer ensayo redujo el vecindario temporal de 5×5 a 3×3, conservando su peso agregado. La variante completa de 5×5 queda en el prototipo porque el objetivo actual prioriza calidad; ninguna variante cumple todavía el presupuesto completo de reproducción.

| Ensayo en 69s | MAE de tres frames reales ocultos | Costo del par + tres salidas |
|---|---|---|
| Dos frames | 10.518 / 11.370 / 12.373 | ~30–32ms |
| Cuatro, solo comprobación | 9.758 / 10.673 / 11.788 | ~31–33ms |
| Cuatro, refinamiento 5×5 y comprobación | 9.202 / 10.003 / 10.592 | ~57.5–58.2ms |
| Cuatro, refinamiento compacto 3×3 | 10.015 / 10.451 / 11.563 | ~42.4–47.2ms |

La variante completa reduce el error medio ~13% respecto al flujo denso de dos frames **en esas tres referencias**. Inspección visual de frames adyacentes: menos parches en el personaje desenfocado, pero aún errores en sus contornos. No es una medida de fluidez percibida.

En 300s, donde el personaje entra rápidamente al encuadre, el refinamiento completo obtiene MAE 47.258 / 33.473 / 44.751, frente a 51.046 / 29.405 / 35.214 con dos frames. Mejora una referencia y empeora dos. Las deformaciones siguen siendo visibles. El ensayo compacto tampoco resuelve ese caso. Más frames no compensan una inicialización fuera de alcance ni garantizan el modelo de velocidad constante.

Comando reproducible (usar `MV_SEEK_SEC=300` para la escena desfavorable):

```sh
MV_DENSE=1 MV_DENSE_FOUR=1 MV_DENSE_GROUND_TRUTH=1 MV_PIPELINE=0 \
MV_PAIRS=6 MV_SEEK_SEC=69 MV_DUMP=0 MV_LAMBDA=1 MV_TEMA=0 \
MV_DENSE_OUTPUT=/tmp/rift-four-dense .build/release/MVProbe
```

El driver compara dos y cuatro frames con los mismos campos iniciales. Respeta los PTS reales, incluidos intervalos 41/42ms. Para la referencia real se oculta un frame central, sin proporcionárselo a ninguno de los estimadores; los vecinos están antes y después de los extremos. Hay tres referencias elegibles porque ese diagnóstico requiere cuatro entradas y una quinta imagen como verdad conocida. La separación de los extremos es ~83ms, más difícil que un par adyacente de ~42ms. Dumps `pairN_four_t0.5.png` y `groundN_four.png`; los originales comparativos conservan sus nombres anteriores.

Los tiempos incluyen subida y comandos/espera GPU, pero excluyen descarga de resultados, validaciones/scans CPU, búsqueda inicial de bloques, decode, disco diagnóstico y presentación. A 23.976fps hay ~41.7ms por par fuente: 58ms ya excede ese presupuesto, incluso antes del resto del pipeline. No se generaliza al M1; no se hicieron pruebas de distribución ni sesiones largas.

## Siguiente problema concreto

Los cuatro frames aportan evidencia y mejoran una escena, pero sigue pendiente recuperar movimiento grande sin convertir una estimación incorrecta en superficie visible. La búsqueda actual y la hipótesis de velocidad constante son límites distintos. Debe ampliarse la cobertura de inicialización y comprobar retenciones/aceleración antes de integrar. No habilitar la variante ni relajar las salvaguardas de producción para aparentar fluidez.
