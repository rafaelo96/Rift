# Selección de superficies proyectadas — 2026-10-13

## Causa reproducida

La búsqueda inversa local no descubre una superficie que atraviesa un píxel ocupado por el fondo en ambos extremos. Con movimiento perfecto, un objeto de cuatro píxeles que avanza dieciséis desaparecía: MAE 14.33268 y 64 píxeles con error superior a diez unidades. Otra regresión descartaba superficies visibles cuyo destino quedaba fuera del encuadre (MAE 17.05794 en fondo móvil).

## Corrección aislada en Core/Interpolation

El prototipo proyecta candidatos desde ambos frames al instante intermedio. Usa evidencia de oclusión y correspondencia bidireccional para priorizar primer plano. Dos mapas UInt32 reutilizables ocupan ocho bytes por píxel; el máximo atómico de claves enteras resuelve empates de manera determinista. Se limpian por muestra. La ventana de entrada sigue acotada.

La síntesis conserva muestras visibles aunque su contraparte esté fuera del encuadre. La pertenencia unilateral a una superficie rechaza velocidades creadas por mezclar dos capas y admite variaciones afines continuas. No se exige esta pertenencia adicional a correspondencias verificadas en ambos frames: ese ensayo empeoró las referencias reales y fue descartado.

`MV_DENSE_OWNERSHIP=0` desactiva la proyección para diagnóstico; conserva las correcciones de recorte y pertenencia, por lo que no equivale al código anterior completo.

## Verificación

Build release y comprobaciones del prototipo completadas. Configuraciones de ocho iteraciones, cuatro iteraciones y refinamiento TV verificadas. Quince combinaciones de escena/instante cubren cruce de capas, primer plano inmóvil, entrada y salida del encuadre; MAE máximo 0.015625, sin píxeles con error superior a diez. También pasan extremos, par estático, salida determinista, traslación, inversión afín, pertenencia afín, batch, contexto temporal y entradas inválidas.

Avatar: se oculta un frame real y se reconstruye con cuatro vecinos, a resolución de trabajo 1152×480. Valores MAE en luminancia de diez bits; menor es mejor. Baseline de `dense-four-frame-2026-10-12.md`, mismas referencias y ocho iteraciones:

| Ventana | Referencia | Antes | Ahora |
| --- | --- | ---: | ---: |
| 69 s | 1 | 9.20230 | 8.56684 |
| 69 s | 2 | 10.00305 | 9.79801 |
| 69 s | 3 | 10.59195 | 10.52312 |
| 300 s | 1 | 47.25792 | 46.57416 |
| 300 s | 2 | 33.47267 | 32.54585 |
| 300 s | 3 | 44.75136 | 44.66275 |

Artefactos temporales: `/tmp/rift-ownership-final2-69` y `/tmp/rift-ownership-final2-300`, logs con el mismo nombre y extensión `.log`. La inspección de `ground3_four.png` a 300 s muestra deformaciones importantes frente a `ground3_truth.png`; la mejora numérica no equivale a calidad suficiente.

## Límites y siguiente problema

Medido en Apple M4: análisis compartido más tres síntesis cuesta 59.7–62.5 ms a 69 s y 67.3–73.9 ms a 300 s. No incluye búsqueda inicial por bloques, descodificación, descarga ni presentación. Supera el período de entrada de 41.7 ms: no está listo para integración de tiempo real.

Se corrigió un fallo concreto de selección con movimientos conocidos. El resultado real demuestra que también quedan movimientos incorrectos o ambiguos: seleccionar bien entre candidatos no basta cuando falta la trayectoria correcta. El siguiente diagnóstico debe separar error del campo de movimiento y error de visibilidad en las regiones deformadas, antes de cambiar más criterios.

Este prototipo procesa luminancia; no está conectado a Frame+ del reproductor ni valida color/HDR. No modifica el archivo fuente ni genera una película derivada. No demuestra equivalencia con Motion² ni elimina todas las deformaciones.
