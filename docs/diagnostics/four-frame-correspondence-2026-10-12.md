# Correspondencias directas de cuatro imágenes

Experimento aislado Core/Interpolation, Apple M4. Producción intacta; M1, distribución y sesiones largas fuera de alcance por instrucción del usuario.

Hipótesis: bajo velocidad constante, un candidato debe explicar el par central y ambos intervalos vecinos. El costo acumula diferencias de luma transportada en cuatro imágenes igualmente espaciadas, usando los mismos candidatos que el refinamiento centrado (vecinos, +/-2px y cero). No estima aceleración ni detecta cambios de escena; no es una reconstrucción confirmada del algoritmo Splash.

Memoria adicional acotada: dos texturas r16Uint de tamaño del work-plane, reutilizables. Salida reutiliza un único campo. No retiene el video ni copia/transcodifica el archivo fuente. La API no cambia vectores/historial del motor normal.

`MV_FOUR_CHECK=1 .build/release/MVProbe`: pasó traslación conocida, cuatro frames estáticos, repetición determinista, preservación del campo original y rechazo de geometría inválida. Build release correcto. El probe tolera diferencias de intervalo menores de 1.1 ms (redondeo de MKV 41/42 ms); omite solo el experimento temporal si hay saltos reales. Los checks verifican intervalos redondeados, saltos, cero y lista vacía. No usar esta hipótesis en VFR sin tratar tiempos reales.

Avatar: `MV_FOUR=1 MV_PAIRS=6 MV_SEEK_SEC=69 MV_DUMP=0 MV_LAMBDA=1 MV_TEMA=2 .build/release/MVProbe`. Cuatro pares interiores con contexto suficiente (1...4); el inicio/final sin contexto se omiten. Comparación del mismo par 1 mediante `/tmp/rift-four-frame/{source,two,four}.png`: algunas deformaciones cambian, pero persisten parches y contornos incorrectos. Sin ground truth de Avatar no se afirma mejora cuantitativa de calidad.

Costo observado del refinamiento con uploads de contexto: 38.79,37.19,25.34,28.54 ms; excluye compilación inicial, ME, decode y warp. Este prototipo no demuestra viabilidad del pipeline completo en tiempo real. La prueba ejecutó además el diagnóstico de pipeline existente por defecto; no se probó reproducción GUI. Para futuras comparaciones exclusivamente de frames usar `MV_PIPELINE=0`.

Repetición final exclusivamente de frames con `MV_PIPELINE=0`: cuatro ventanas temporales válidas; terminó correctamente. Refinamiento 23.83,21.44,28.05,22.38 ms. El primer guard de tiempos, demasiado estricto frente a redondeo y precisión float, se corrigió antes del resultado final; no se relajaron filtros de calidad del interpolador.

Conclusión: la suma temporal de costos bajo velocidad constante no superó la validación visual en este caso. No integrar ni relajar protecciones para compensarlo. Una selección entre hipótesis de bloques sigue limitada por las correspondencias disponibles y la representación de movimiento; no atribuir una causa general confirmada sin evidencia adicional. Queda pendiente representación más rica de movimiento/oclusiones y evaluación de la secuencia generada, siempre dentro del stack clásico Metal.
