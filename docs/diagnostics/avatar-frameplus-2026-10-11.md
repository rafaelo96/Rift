# Avatar / Frame+ — diagnóstico inicial, 2026-10-11

> Corrección posterior: las tres mediciones iniciales usaban frames en orden de
> decodificación, con PTS no monótonos. Son costes de esos pares artificiales,
> no representan pares consecutivos de reproducción. Retirar las conclusiones
> sobre presupuesto y frecuencia de fallback en reproducción basadas en ellas.


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

## Reproducción de la escena reportada: 1:09

La captura del usuario permitió repetir desde 69 s. MVProbe tenía un defecto:
retenía orden de entrega de VTDecoder, con secuencia 69.07, 69.03, 69.15, 69.11.
La herramienta ahora recoge 16 frames adicionales, ordena conjuntamente lumas,
buffers y PTS, conserva los primeros N+1 e impone PTS estrictamente crecientes.
No se cambió el decoder ni el reproductor; este diagnóstico no demuestra un
defecto de orden en la app. El tail de 16 es acotado y no garantiza todos los codecs.

Verificación release de 12 pares, perfil fluid, dos salidas: PTS de contact
69.03, 69.07, 69.11, 69.15, 69.19, 69.24. Media total 24.206 ms, p95 25.265 ms.
La hoja de contacto solicita t=0.4/0.8; exporta la primera salida de cada par.

Comparación visual del par 0 a t=0.5 mediante MV_ARTIFACT: a_fullres_cur.png
tiene contornos limpios; a_fullres_interp.png presenta duplicación/deformación
de bisontes y primer plano. Confirma daño en síntesis de producción fluid en
esta escena, aunque no identifica aún un cambio algorítmico que lo resuelva.
Exports de luma diagnóstica, no representan color HDR ni película transcodificada.

Artefactos locales: /tmp/rift-avatar-69-ordered/contact_sheet.png,
/tmp/rift-avatar-69-source/a_fullres_cur.png,
/tmp/rift-avatar-69-source/a_fullres_interp.png.
Logs: /tmp/rift-avatar-69-ordered.log y /tmp/rift-avatar-69-source.log.

La calidad no se certifica por mostrar 59/60 fps. Falta medir presentación real
y contrastar la política de seguridad existente en esta misma escena. No
reabrir la investigación de motion blur/bokeh como si fuera un bug nuevo.

## Corrección de seguridad aplicada

A/B en escena 69 s: default rechazó seis de seis pares del contact y devolvió
fuentes limpias; fluid anterior generaba warps dañados. Se habilita la misma
comprobación bidireccional existente en fluid, fluidHighQuality y fluidEconomy.
No se cambian umbrales, shaders ni el fallback. No se introduce mezcla regional.

Verificación: seis PNG del contact fluid corregido coinciden byte a byte con
el contact default seguro. Pares ordenados por PTS y dos salidas por par.
100 pares fluid desde 69 s: media total 22.304 ms, p95 23.859 ms.
100 pares fluid desde 3600 s: media 17.194 ms, p95 24.832 ms.
12 pares hq desde 69 s: media 29.565 ms, p95 30.589 ms; todos rechazados por
seguridad (ME>0, warp=0). Equipo Apple M4; no valida M1 ni thermal throttling.

La mitigación evita los warps rechazados en esta escena y sacrifica incremento
de fluidez en ellos. No significa síntesis sin artefactos en toda la película,
ni 60 frames visualmente distintos: conservar fuentes no produce movimiento
intermedio. Falta medir cadencia realmente presentada en reproducción larga.
La app release se recompiló para prueba; no se certifica resuelto ese síntoma.

Logs: /tmp/rift-avatar-69-fixed.log, /tmp/rift-avatar-3600-fixed.log,
/tmp/rift-avatar-69-hq-safe.log. Contact: /tmp/rift-avatar-69-fixed/.
