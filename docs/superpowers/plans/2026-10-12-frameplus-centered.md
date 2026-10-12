# Frame+ — etapas de fluidez

Objetivo: aumentar la continuidad temporal sin ocultar distorsiones ni alterar el archivo fuente.
Arquitectura: MCFI clásico en Metal; ventanas acotadas, decodificación hardware existente. Sin dependencias nuevas.

## Etapa 1 — Core/Interpolation
- [ ] Añadir refinamiento experimental de candidatos en el instante intermedio, reutilizando las texturas y vectores de MotionSearchEngine. Mantener el algoritmo de producción intacto.
- [ ] Probar desplazamiento sintético y conservación del campo original en MVProbe.
- [ ] Medir costo y residuo sobre pares acotados de Avatar; compilar con `swift build -c release --product MVProbe`.
- [ ] Registrar resultados y commit exclusivo del módulo y documentación.

## Etapa 2 — Core/Interpolation
- [ ] Comparar regularización respecto del predictor y candidatos espaciales usando el mismo conjunto de evaluación. Integrar solamente si disminuye artefactos sin sacrificar movimiento coherente.

## Etapa 3 — Core/Interpolation
- [ ] Evaluar contexto temporal acotado frente a dos frames. No añadir estado a producción sin demostrar ventaja y definir reset de seek.

## Etapa 4 — Core/Interpolation; posteriormente Scheduler en tarea separada
- [ ] Evaluar confianza por región y preservación de objetos/oclusiones con comparación visual y métricas.
- [ ] Medir cadencia real y adaptación sostenida en Scheduler tras commit del interpolador. Validación M1 y EDR requiere hardware correspondiente.

Las etapas experimentales no equivalen a validación de fluidez perceptual. Una reducción de residuo por sí sola no autoriza activar el algoritmo en producción.
