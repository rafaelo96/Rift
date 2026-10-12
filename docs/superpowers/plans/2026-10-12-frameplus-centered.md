# Frame+ — etapas de fluidez

Objetivo: aumentar la continuidad temporal sin ocultar distorsiones ni alterar el archivo fuente.
Arquitectura: MCFI clásico en Metal; ventanas acotadas, decodificación hardware existente. Sin dependencias nuevas.

## Etapa 1 — Core/Interpolation
- [x] Añadir refinamiento experimental de candidatos en el instante intermedio, reutilizando las texturas y vectores de MotionSearchEngine. Mantener el algoritmo de producción intacto.
- [x] Probar desplazamiento sintético y conservación del campo original en MVProbe.
- [x] Medir costo y residuo sobre pares acotados de Avatar; compilar con `swift build -c release --product MVProbe`.
- [x] Registrar resultados y commit exclusivo del módulo y documentación (`ac762f0`).

## Etapa 2 — Core/Interpolation
- [x] Comparar regularización respecto del predictor y candidatos espaciales usando el mismo conjunto de evaluación (`802e034`).
- [ ] Integrar solamente si disminuye artefactos sin sacrificar movimiento coherente: no superó la inspección visual.

## Etapa 3 — Core/Interpolation
- [x] Evaluar contexto temporal acotado mediante campo del par anterior (`878363f`), incluyendo reset simulado en el probe.
- [ ] Análisis directo de cuatro imágenes y estado de producción: no justificado todavía por la pequeña mejora medida del candidato temporal.

## Etapa 4 — Core/Interpolation; posteriormente Scheduler en tarea separada
- [x] Evaluar confianza por región y preservación de objetos/oclusiones con comparación visual y métricas. El fallback duro experimental introduce bordes; descartado para producción.
- [ ] Medir cadencia real y adaptación sostenida en Scheduler tras commit del interpolador. Validación M1 y EDR requiere hardware correspondiente.

Las etapas experimentales no equivalen a validación de fluidez perceptual. Una reducción de residuo por sí sola no autoriza activar el algoritmo en producción.

Resultados y limitaciones: `docs/diagnostics/frameplus-centered-2026-10-12.md`. Continúa pendiente una síntesis que conserve contornos, una comparación perceptual temporal y la integración con cadencia medida. No se presenta este trabajo como equivalencia con Splash.
