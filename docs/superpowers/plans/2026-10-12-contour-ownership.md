# Movimiento por hipótesis en contornos

Objetivo: evitar velocidades inexistentes al combinar fondo y primer plano. Swift/Metal clásico; tarea acotada a Core/Interpolation/Tools.

- [x] Añadir shader experimental que selecciona hipótesis vecinas mediante correspondencias temporales de un parche por píxel, sin cambiar producción.
- [x] Comparar contra ground truth de dos movimientos; conservar endpoints y estático.
- [x] Inspeccionar outputs reales de Avatar con vectores idénticos y medir costo únicamente para verificar viabilidad real-time; no pruebas M1/distribución.
- [x] Documentar y commit aislado. No superó calidad visual; no integrar.
