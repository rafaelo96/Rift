# Registro espacial de la rejilla de movimiento

Objetivo: comprobar que el sampler obtiene cada vector en el centro del bloque donde se estimó, también con movimiento variable.
Alcance: Core/Interpolation, Swift/Metal. No nuevas dependencias ni cambios al archivo fuente.

- [x] Reproducir mediante `MV_GRID_CHECK=1 .build/release/MVProbe`: centros, interpolación affine y clamp de bordes. El test falló antes del cambio.
- [x] Corregir únicamente el registro de coordenadas de `sampleMVBilinear` tras confirmar el error.
- [x] Validar traslación uniforme y comparar renders con los mismos vectores en escenas reales. Endpoints y estático comprobados con el posterior test de transporte; no atribuir a este cambio la solución general de motion blur/bokeh.
- [x] Compilar, registrar mediciones en Apple M4 y crear commit exclusivo del módulo.
