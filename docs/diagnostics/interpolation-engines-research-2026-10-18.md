# Investigación de interpoladores clásicos y Motion² — 2026-10-18

Investigación documental y lectura de código público, contrastadas con los ensayos locales. No se modificó el motor, no se instalaron dependencias y no se ejecutaron benchmarks de otros productos. Las prestaciones comerciales y los resultados publicados no equivalen a una comparación del mismo clip contra Rift.

La conclusión es que conviene separar tres problemas: correspondencias equivocadas, visibilidad/oclusión e incertidumbre sin información suficiente. Una única confianza que autoriza o prohíbe todo el warp no distingue esos casos. Esto es una interpretación de las fuentes y de nuestros experimentos, no una descripción del algoritmo secreto de Motion².

## Qué está publicado

### Motion² / Mirillis Splash

El manual oficial de Splash2, página22 del PDF (índice21), distingue niveles1–5 que duplican la frecuencia y6–10 que producen60p. Una comparación24→48 no evalúa el mismo problema que24→60. La distribución de originales e interpolados y la fase temporal de cada muestra también deben igualarse. [Manual oficial](https://mirillis.com/pdf/user-manual/Splash-free-hd-video-player-manual.pdf).

Mirillis describe ejecución con CPU/GPU, pero la página técnica consultada no especifica búsqueda, número de imágenes, visibilidad, reconstrucción o fallback. No hay fundamento aquí para afirmar que Motion² use cuatro frames,3DRS, redes, un filtro concreto o cierto algoritmo de oclusión. [Picture²](https://mirillis.com/picture2).

Una respuesta identificada como **Mirillis Team**, de2011, reconoce artefactos y explica que niveles mayores permiten más artefactos a cambio de suavidad. Otra respuesta del equipo, de2010, describe60p condicionado por un nivel aceptable de artefactos. Es evidencia histórica de una concesión de producto; no certifica cómo decide una versión actual. Se excluyeron las opiniones de usuarios del foro como explicación técnica autorizada. [Respuesta del equipo sobre artefactos](https://mirillis.com/forum/viewtopic.php?p=5514), [niveles y modos](https://mirillis.com/forum/viewtopic.php?start=90&t=465).

**Consecuencia:** Motion² sirve como referencia visual de producto cuando podamos comparar el mismo material. No se ha demostrado equivalencia, ni que sea infalible, ni conocemos su implementación. Los ensayos locales anteriores ya registraban que no había una comparación directa con Splash disponible: [integración nativa](frameplus-native-integration-2026-10-14.md).

### SVP clásico / SVPflow

SVPflow documenta matching jerárquico, predictores, penalización de coherencia y refinamiento. En síntesis distingue máscaras cover/uncover, calidad de vectores y algoritmos con información temporal adicional. El algoritmo23 añade vectores vecinos al21. El modo adaptativo puede cambiar la pauta de interpolación según la calidad global. El renderizador svpflow2 es cerrado; los parámetros publicados no permiten reconstruir todos sus detalles. [Documentación SVPflow](https://www.svp-team.com/wiki/Manual:SVPflow).

El manual de usuario explica que el enmascaramiento fuerte reduce fluidez y nitidez, e incluso puede generar bordes triples. Por tanto, más supresión no implica siempre mejor imagen. Esto describe la ruta clásica documentada, no cualquier backend neuronal que el producto pueda ofrecer. [Perfiles SVP](https://www.svp-team.com/wiki/Manual:FRC).

**Aplicación a Rift:** separar máscara de oclusión de máscara de fallo de matching. Copiar sus umbrales numéricos carecería de fundamento: cambian escalas, resolución y normalización. Tampoco disponer de cuatro buffers demuestra ejecutar el mismo algoritmo.

### MVTools / MFlowFps

La documentación distingue compensación desde ambos extremos, máscaras direccionales de oclusión y un modo que añade vectores de intervalos vecinos para reducir halos. MBlockFps ofrece compensación por bloques y advierte de blocking sin solapamiento. Son estrategias de reducción de error, no garantías sobre identidad de objetos. [Manual de MVTools2](https://avisynth.org.ru/mvtools/mvtools2.html).

El código consultado confirma máscaras dependientes de la fase temporal (`MakeVectorOcclusionMaskTime`) y una ruta `FlowInterExtra` con campos auxiliares. La lectura se hizo sobre `master`, no sobre una versión instalada y medida. [MVFlowFps.cpp](https://github.com/pinterf/mvtools/blob/master/Sources/MVFlowFps.cpp).

**Diferencia verificable:** emplear campos temporales auxiliares al reconstruir una región oculta es distinto de usarlos solo para ayudar a escoger un vector central. No prueba que el método resuelva nuestros cambios de pose; identifica una comparación pertinente que todavía falta.

### FFmpeg / minterpolate

La documentación ofrece OBMC, solapamiento adaptativo AOBMC, estimación bidireccional o bilateral y bloques variables en contornos. Los cortes detectados pueden sustituir la interpolación por originales repetidos. Estos controles no garantizan eliminar el motion blur. [Documentación minterpolate](https://ffmpeg.org/ffmpeg-filters.html#minterpolate).

En el código, `bilateral_obmc` calcula pesos y registra contribuciones de movimiento para los píxeles; `set_frame_data` forma la imagen. Es reconstrucción mediante contribuciones solapadas, no simplemente una mediana del campo final. [Código FFmpeg](https://github.com/FFmpeg/FFmpeg/blob/master/libavfilter/vf_minterpolate.c).

**Aplicación a Rift:** un ensayo AOBMC tendría que comparar predicciones de imagen, con pesos y límites de superficie, frente al renderer actual. No justificaría promediar indiscriminadamente movimientos de fondo/personaje. Tampoco se propone integrar libavfilter: el stack de Rift conserva FFmpeg solo para demux y VT para decode.

### NVIDIA FRUC basado en optical flow

La guía pública describe: flujo adelante/atrás, validación recíproca, reconstrucción de vectores rechazados, interpolación y relleno de huecos de imagen. Así distingue reparación del campo de reparación de píxeles sin cobertura. El detalle de sus técnicas de relleno no se publica allí. Requiere hardware NVIDIA y CUDA; no es una dependencia utilizable en Apple Silicon ni evidencia de coste en M4. [Guía FRUC](https://docs.nvidia.com/video-technologies/optical-flow-sdk/nvfruc-programming-guide/index.html).

**Aplicación a Rift:** rechazar un vector sin dar una política explícita al hueco posterior es una solución incompleta. Tampoco basta rellenar todos los huecos con cualquier vecino: eso puede copiar otra superficie.

### Literatura clásica de true motion

De Haan y de Biezen describen candidatos espaciales, temporales y de un modelo paramétrico global dentro de búsqueda recursiva3D. El objetivo es estimar movimiento con pocas operaciones. Esto aporta una vía clásica para explicar movimiento de cámara, no una relación demostrada con Motion² ni una solución a la pose no rígida. [Publicación original,1998](https://research.tue.nl/nl/publications/an-efficient-true-motion-estimator-using-candidate-vectors-from-a/).

## Qué nos dicen los resultados de Rift

| Evidencia local | Interpretación que sí permite | Lo que no demuestra |
|---|---|---|
| Búsqueda ampliada recupera traslación sintética pero no mejora generalmente Avatar | Alcance insuficiente existe en algunos casos; no explica todos | Que aumentar radio o resolución resolverá el combate |
| «Oráculo denso» de mínimos fotométricos sigue fragmentando | Un mínimo SAD/SSD no certifica trayectoria física | Que un campo físicamente exacto también fallaría |
| Superficies sintéticas con flujo y visibilidad exactos se reconstruyen bien; introducir correspondencia de fondo produce daño | Correspondencia/visibilidad pueden ser causas suficientes | Que toda síntesis real sea correcta |
| Cuatro imágenes pueden contener dibujos retenidos | Cuatro buffers no son cuatro observaciones independientes | Que mirar más lejos baste; el ensayo de mayor distancia fue mixto |
| E1/E2 dejan errores de alta confianza sin marcar | El ranking actual no es un certificado de seguridad | Que bajar su umbral reparará esas regiones |
| F2 y rechazos de ownership mejoran alguna zona y regresan69s | Filtrar o descartar puede destruir transporte legítimo | Que todo rechazo de oclusiones esté condenado |
| Fallback de luma y coordenadas nativas discrepaban | Había un defecto de implementación concreto, ya corregido | Que el resto del mosaico fuera el mismo bug |

Fuentes locales: [búsqueda](deep-motion-search-2026-10-12.md), [oráculo](dense-oracle-static-2026-10-17.md), [superficies exactas](surface-synthesis-2026-10-16.md), [identidad/regiones y contexto](region-surface-2026-10-17.md), [auditoría de confianza](confidence-mask-audit-2026-10-17.md), [F2](edge-field-f2-2026-10-17.md), [fallback y regresiones](native-fallback-2026-10-18.md).

El código actual ya tiene parches solapados, agrupación restringida a velocidades próximas, selección temporal y proyección/ownership. No parte de cero. Sin embargo, la agregación conserva una hipótesis ganadora y el renderer termina trabajando con dos campos centrales. Tener esos componentes no equivale a conservar el uso de campos auxiliares de MVTools en el punto de oclusión.

## Recomendación para el siguiente experimento

**Prioridad1: comparación offline de reconstrucción con visibilidad explícita y campos auxiliares conservados.** Es una hipótesis distinta de volver a bajar confianza o de suavizar el campo final. Primero deben fijarse las entradas del estimador y comparar renderizadores sobre ellas; si falla por falta de correspondencia correcta, se registra y no se atribuye el fallo a los pesos.

Separar, como estados de diagnóstico, superficie respaldada en ambos extremos, visible solo desdeA, visible solo desdeB, y región sin correspondencia suficiente. En los casos unilaterales, un desacuerdo adelante/atrás no debe convertirse automáticamente en «vector incorrecto»: puede describir oclusión real. Conservar campos de intervalos vecinos para comprobar qué lado tiene apoyo temporal. Si las imágenes son dibujos retenidos, anotar esa falta de evidencia; no inventar movimiento.

Esto no define todavía un clasificador fiable ni una fórmula de reparación aceptada. Las máscaras de visibilidad exactas se validan primero en sintéticos de capas, cobertura, giro y zoom. En video real, reconstruir centrales ocultos mide calidad, pero no proporciona por sí solo verdad de movimiento o profundidad. Comparar contra una referencia clásica documentada ayudaría a distinguir un límite del material de un límite de nuestra implementación; aún no se ha ejecutado esa comparación.

**Prioridad2: AOBMC como control de reconstrucción.** Mantener candidatos de superficies distintas separados y ensayar contribuciones solapadas en la imagen. Esta comparación puede mostrar cuánto proviene de decisiones espaciales abruptas. Puede producir halos o doble borde: se rechaza si solo esconde el defecto con blur. No es una promesa de reemplazo del renderer.

**Prioridad3: representación del movimiento rápido.** Si los controles anteriores muestran pérdida de correspondencias, investigar partición adaptable y candidatos de cámara/transformación local conservados durante matching y síntesis. Ya fallaron propuestas afines colapsadas a una traslación central: [regresión afín](affine-patch-seed-regression-2026-10-16.md). No basta renombrar o repetir ese ensayo. Necesita una hipótesis y evidencia diferentes antes de tocar búsqueda o selección.

Una política de seguridad similar a los controles de fluidez de otros productos sería una decisión separada: repetir originales o mezclar en una escena ambigua puede reducir daño, pero debe contabilizar pérdida de movimiento, dobles bordes y píxeles afectados. No se presenta como reconstrucción correcta ni se activa E2 como atajo.

## Criterio de decisión

Antes de integrar: comparar69s,300s,16:32 y20:02, y mantener18:02 ave/paisaje como control (no fingir que es una cara). Mostrar A/B, central real cuando exista, motor actual y candidato. Medir MAE/bordes/SSIM dentro y fuera de máscaras, estabilidad temporal, controles estáticos y fracción de salida sustituida. Los fotogramas retenidos de animación deben identificarse y los cortes separarse de movimiento continuo.

Solo después de ventaja visual sin regresión se mide implementación Metal, una vez por par, recursos acotados y reutilización entre subframes. Cinco alternancias Release/M4 con decode, adquisición temporal y Strong reales, comparadas con la línea base de esa tanda. Ninguna velocidad externa ni cifra deM4 se transfiere aM1; la calibración por equipo sigue siendo necesaria. Se conserva el stack clásico sin redes ni nuevas dependencias.

**Decisión de esta investigación:** no atribuir a Motion² un secreto no publicado y no continuar ajustes de umbral sin mecanismo verificable. La comparación de visibilidad y reconstrucción temporal es el siguiente experimento mejor fundamentado; su éxito en Rift y su coste siguen sin demostrar. No se implementa en esta tarea.
