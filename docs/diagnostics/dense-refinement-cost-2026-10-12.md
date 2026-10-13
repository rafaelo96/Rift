# Costo de refinamiento — 2026-10-12

Trabajo aislado en Core/Interpolation. Objetivo: reducir trabajo del prototipo de cuatro frames manteniendo la calidad medida. No se integra en Frame+ ni se modifica el archivo fuente.

## Caché de gradientes: retirada

Se evaluó precalcular gradientes por nivel y reutilizarlos en Lucas–Kanade. La versión RGBA32Float pasó el check comparativo sintético (MAE de salida 0.00163 contra gradientes directos), pero aumentó el costo de cuatro frames a ~79–83ms frente a ~60–61ms del cálculo directo en la misma sesión. Eliminar lecturas redundantes y conservar la fuente escalar bajó a ~62–69ms. Separar gradientes RG32Float del brillo escalar dio ~59.7–60.2ms, sin una mejora suficiente para justificar ~23.5MB adicionales de texturas. La variante RGBA añadía ~47MB.

Se retiraron implementación, API, flag y test de esa caché. No afirmar que precalcular siempre acelera: aquí el tráfico adicional compensó la reducción de operaciones. Los tiempos y las diferencias de imagen pueden reproducirse en los logs locales de los ensayos, pero la caché no queda en el código.

## Iteraciones del nivel fino

Se añadió `finestIterations` (1…8) al prototipo; el valor predeterminado sigue siendo 8. Los niveles gruesos siempre conservan ocho iteraciones. `MV_DENSE_FINE_ITERS=4` evalúa la reducción aislada, sin cambiar búsqueda, ventanas, pesos de síntesis o gates. Las entradas fuera de rango son rechazadas.

Apple M4, plano 1152×480, seis pares de Avatar, cuatro frames de entrada y tres salidas temporales:

| Ensayo | Costo análisis + tres salidas | MAE en las tres referencias de 69s | MAE en las tres referencias de 300s |
|---|---|---|---|
| Ocho iteraciones finas | ~60–61ms en esta sesión | 9.202 / 10.003 / 10.592 | 47.258 / 33.473 / 44.751 |
| Cuatro iteraciones finas | ~39.6–41.7ms | 9.155 / 9.973 / 10.506 | 48.545 / 34.539 / 44.419 |

La reducción baja el costo aproximadamente un tercio y no degrada las referencias de los bisontes; en la escena rápida empeora dos referencias en ~2.7% / ~3.2% y mejora una en ~0.7%. No hay evidencia para seleccionarla como mejora universal. La inspección visual muestra aún errores de contorno, especialmente en movimiento extremo. Por eso queda como opción de diagnóstico, con ocho como configuración original.

Checks: ambos conteos conservan extremos, estático, determinismo, ventana temporal conocida, tamaño impar, traslación y rechazo de entradas inválidas. Para cuatro iteraciones: referencia por capas MAE 7.010, traslación central error vectorial 0.00214px / MAE de detalle 0.00977 y traslación de cuatro frames MAE 1.74870, todos dentro de los criterios originales. No se relajaron tests para aceptar la optimización.

Reproducción:

```sh
swift build -c release --product MVProbe
MV_DENSE_CHECK=1 .build/release/MVProbe
MV_DENSE_CHECK=1 MV_DENSE_FINE_ITERS=4 .build/release/MVProbe
MV_DENSE=1 MV_DENSE_FOUR=1 MV_DENSE_FINE_ITERS=4 MV_DENSE_GROUND_TRUTH=1 \
MV_PIPELINE=0 MV_PAIRS=6 MV_SEEK_SEC=69 MV_DUMP=0 MV_LAMBDA=1 MV_TEMA=0 \
MV_DENSE_OUTPUT=/tmp/rift-four-iter4 .build/release/MVProbe
```

## Límite actual

Estos costos excluyen búsqueda inicial de bloques en ambos sentidos, descargas/scans de diagnóstico, decode y presentación. El driver mide ~13ms para la búsqueda en un sentido; hay una segunda búsqueda inversa para inicializar el flujo. No sumar tiempo de PNG ni el mensaje `pair ME` envolvente del driver como si fueran tiempos de reproducción. Incluso ~40ms de refinamiento no acredita tiempo real del pipeline completo frente a ~41.7ms por par fuente de 23.976fps.

La cobertura ampliada de búsqueda y la reducción de iteraciones responden a dos límites concretos, pero todavía no eliminan los errores de asignación de superficies. No se habilita ninguna variante en Frame+ a partir de estos resultados ni se afirma equivalencia con Motion².
