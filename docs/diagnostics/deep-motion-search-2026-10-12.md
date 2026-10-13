# Alcance de búsqueda — 2026-10-12

Solo Core/Interpolation. Objetivo: comprobar si la inicialización limitada explica los desplazamientos grandes antes de modificar la síntesis. No cambia la configuración activa de Frame+ ni el archivo fuente.

El motor aceptaba especificaciones de más de cuatro niveles, pero `runPair` indexaba fuera de los siete contadores públicos. El check de cinco niveles reprodujo el fallo. Ahora los niveles adicionales acumulan su costo en los contadores gruesos L3; el formato de `PairTimes` se conserva. La configuración de cuatro niveles conserva sus índices y el matching no cambia. Una configuración de nivel único informa su búsqueda en L0, corrigiendo la etiqueta previa L3. El histograma del driver también necesitaba dimensionarse por el número real de niveles.

El ensayo `MV_DENSE_DEEP=1` añade 72×30 (bloque 8) y 36×15 (bloque 4) a la pirámide existente, con radio de 16px por nivel adicional. Alcance nominal acumulado ~984px a resolución de trabajo frente a ~212px. Las ventanas threadgroup permanecen dentro de los guards existentes; no se aumenta la reserva por encima del límite ni se elimina la protección. Sin dependencias nuevas.

Check aislado `MV_LARGE_CHECK=1 .build/release/MVProbe`: imagen texturada 512×128 trasladada 160px, scoring solo en bloques completamente visibles. Pirámide de cuatro niveles con alcance ~60px: error vectorial medio 165.257px. Añadiendo un nivel 32×8: error 0px. Se comprueba también que los tiempos tengan el formato público y valores finitos no negativos. El primer ensayo antes del fix terminaba por índice fuera de rango al añadir el quinto nivel.

En Avatar (Apple M4, 1152×480, seis pares), el resultado no es una mejora general:

| Referencias reales ocultas | Cuatro frames con búsqueda anterior | Cuatro frames con búsqueda ampliada |
|---|---|---|
| 69s | 9.202 / 10.003 / 10.592 | 9.202 / 10.003 / 10.652 |
| 300s | 47.258 / 33.473 / 44.751 | 47.785 / 39.095 / 45.233 |

Los valores son MAE en luma de 0…1023, no una medida de fluidez. Ampliar la cobertura recupera movimiento conocido cuando existe una correspondencia única, pero no resuelve superficies ambiguas, aparición de contenido ni cambios de trayectoria. La inspección visual sigue mostrando errores; el flag queda exclusivamente en el diagnóstico, desactivado por defecto.

Reproducción:

```sh
swift build -c release --product MVProbe
MV_LARGE_CHECK=1 .build/release/MVProbe
MV_DENSE=1 MV_DENSE_FOUR=1 MV_DENSE_DEEP=1 MV_DENSE_GROUND_TRUTH=1 \
MV_PIPELINE=0 MV_PAIRS=6 MV_SEEK_SEC=300 MV_DUMP=0 MV_LAMBDA=1 MV_TEMA=0 \
MV_DENSE_OUTPUT=/tmp/rift-deep-four .build/release/MVProbe
```

El siguiente límite es seleccionar una trayectoria respaldada por el contenido, no simplemente encontrar vectores más grandes. El tiempo de refinamiento de cuatro frames continúa alrededor de 56–58ms por par, excluyendo búsqueda inicial, descarga, decode y presentación. No se integra esta configuración como solución a los artefactos.
