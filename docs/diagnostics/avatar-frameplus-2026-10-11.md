# Avatar / Frame+ — diagnóstico inicial, 2026-10-11

Alcance: medición aislada de Core/Interpolation, sin modificar motores ni parámetros.
Equipo real: Apple M4. No generalizar a M1 ni a sesiones térmicas largas.
Archivo: Avatar.Aang.el.ultimo.maestro.del.aire.2026.WEB-DL.4k.HDR-Dual-Lat.mkv;
HEVC 3832×1600, 23.976 FPS. Archivo leído en sitio, sin copia ni transcodificación.

Se ejecutó MVProbe release con MV_PAIRS=100, MV_DUMP=0, MV_PROFILE=fluid,
MV_PAIR_OUTPUTS=2 y MV_SEEK_SEC=2400, 3600 y 4941. El pipeline medido solicita
salidas t=0.4/0.8 y usa MotionCompensator de producción. Son ventanas cortas
tras seek, no mediciones de la película completa ni de frames mostrados.
Rift estaba abierto durante la medición: no se considera benchmark de máquina aislada.

| Inicio aproximado | Media total/par ms | p95 ms | Máximo ms | Pares con ME=0 |
| --- | ---: | ---: | ---: | ---: |
| 40:00 | 9.411 | 9.881 | 10.051 | 100/100 |
| 60:00 | 19.749 | 25.518 | 39.232 | 30/100 |
| 82:21 | 13.046 | 25.622 | 35.254 | 77/100 |

Usar Total(host), que incluye extracción y todas las salidas, no la suma GPU
ni el mensaje de margen de MVProbe, que puede subestimar el coste completo.
Presupuesto de entrada a velocidad 1×: 1000/23.976 ≈ 41.708 ms por par.
Ninguna de estas muestras demuestra saturación del motor, ni descarta retrasos
por decode, display, planificación, otro perfil o carga sostenida.

ME=0 es el camino estático: interpolatePair devuelve I0 para cada t pedido.
Es una causa posible de menor fluidez en movimiento tenue; los datos no prueban
falsos positivos del detector. No cambiar umbrales sin revisar la escena exacta.
La política fluid omite seguridad bidireccional y conserva guard catastrófico;
esto es diseño existente, no una regresión confirmada. motionAdaptive usa otra
política. Falta identificar el modo que el usuario tiene activo.

Las métricas de calidad generales impresas por MVProbe corresponden a su motor
auxiliar (lambda=4), no prueban la calidad del pipeline fluid (lambda=1).
No usarlas como veredicto de artefactos de producción.

Registros locales: /tmp/rift-avatar-diagnostic.log,
/tmp/rift-avatar-third-diagnostic.log y /tmp/rift-avatar-motion-diagnostic.log.

Pendiente: minuto exacto y modo reportados por el usuario; comparación visual
fuente/generado en esa escena y diagnóstico de cadencia presentada en tarea
separada. Respetar la investigación cerrada en mcfi-motion-blur-bokeh-artifacts.md:
no reabrir thresholds/blends descartados sin hipótesis y evidencia nuevas.
No se afirma resuelto el problema ni se modifica el algoritmo.
