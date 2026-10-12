# Correspondencias con cuatro imágenes

Objetivo: evaluar si soporte temporal directo reduce matches ambiguos. Core/Interpolation, MCFI clásico Metal; ventana de cuatro frames igualmente espaciados, nunca video derivado completo.

- [x] Añadir costo temporal de tres intervalos bajo hipótesis de velocidad constante; mismas hipótesis candidatas que el refinamiento de dos frames, sin modificar producción.
- [x] Checks aislados de traslación conocida, estático, determinismo, preservación de campo original y geometría inválida.
- [x] Comparar dos/cuatro sobre el mismo par de Avatar y examinar imagen generada, no solo costo. M1 y distribución siguen fuera de alcance.
- [x] Documentar resultado, restricciones por aceleración/oclusiones/cortes y commit. No superó calidad visual; no integrar.
