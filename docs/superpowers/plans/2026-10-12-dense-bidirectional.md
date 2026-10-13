# Dense bidirectional motion implementation plan

**Goal:** evaluar flujo por píxel y reconstrucción con visibilidad real de ambos sentidos.
**Architecture:** prototipo aislado que reutiliza los vectores de bloques como inicialización, refina con Lucas–Kanade piramidal y sintetiza mediante inversión del transporte y cierre forward/backward.
**Tech Stack:** Swift, Metal; sin redes ni nuevas dependencias.

## Global constraints

Solo Core/Interpolation. Ventana de un par; texturas reutilizadas y cantidad fija. Nunca modificar/copiar/transcodificar el archivo fuente completo. Sin UI, M1 ni distribución. No integrar sin evidencia visual.

## Task 1: algoritmo y driver aislado

Files: `Swift/DenseMotionShaders.swift`, `Swift/DenseMotionPrototype.swift`, `Tools/DenseMotionCheck.swift`, `Tools/main.swift` bajo Core/Interpolation.
Interface: `DenseMotionPrototype.init(width:height:blockSize:)`; `interpolate(first:Data,last:Data,forward:[SIMD2<Int32>],backward:[SIMD2<Int32>],time:Float)` produce luma UInt16, confianza por píxel y costo.

- [x] Implementar pirámides float con antialiasing, flujo rgba32Float por píxel, 8 refinamientos LK por nivel y sentido y regularización espacial.
- [x] Implementar inversión de transporte con Newton amortiguado (la inversión fija de tres iteraciones dejó errores >1px en el caso afín), cierre bidireccional y selección local de superficies. Extremos exactos y protección estática conservada.
- [x] Ejecutar checks aislados: traslación, capas/oclusiones con flujo conocido, inversión afín, extremos, estático, determinismo, tamaños impares, entradas inválidas y lote acotado.
- [x] Compilar MVProbe y examinar Avatar en 69s, 300s y 1800s; generar referencias mediante eliminación de un frame y reconstrucción en su PTS real.
- [x] Reutilizar el flujo bidireccional entre hasta cuatro muestras temporales; verificar igualdad con llamadas individuales.
- [x] Evaluar TV-L1 aislado: no seleccionar para producción por costo y ausencia de mejora suficiente.
- [x] Documentar resultados en `docs/diagnostics/dense-bidirectional-2026-10-12.md`. El prototipo no supera el criterio visual general y no se integra en la app.

Siguiente requisito de calidad: distinguir falta de correspondencia por oclusión de falta de correspondencia por estimación incorrecta. Actualmente ambos casos pueden activar la selección unilateral; la prueba con flujo exacto pasa, pero el estimador real no garantiza esa clasificación. No resolver relajando gates ni confundiendo confianza con exactitud.
