# Diagnóstico: artefactos MCFI en motion blur / bokeh (investigación cerrada)

**Fecha:** 2025-09-13
**Hardware:** Apple M4
**Escenas analizadas:** `Avengers.endgame.2019.2160p.x265.hdr…mkv` @ 79:55 y 82:21; `BLEACH.Thousand-Year.Blood.War…E48.mkv` (1080p 8-bit)
**Alcance:** diagnóstico solamente. No es una implementación ni un cambio de comportamiento. Sin commits asociados.

## Conclusión

> Con el modelo actual de dos frames + un MV por bloque + warping bilineal, existen regiones de motion blur/bokeh donde la información temporal disponible es insuficiente para reconstruir fielmente el contenido intermedio. El artefacto aparece dentro de los warps individuales, antes del blend, por lo que seguir ajustando ME, thresholds o pesos de blend no puede recuperar la información ausente.

## Evidencia principal (métricas reproducibles)

- Los endpoints son exactos: `warp(t=0) == I0` al byte (0.002% residual, preexistente), `round-trip estático = 0.00/255`, y el 100% de las zonas malas ocurre en contenido con movimiento real (`I0 ≠ I1`).
- Los parches existen únicamente en **t=0.5** (producidos por la síntesis temporal, no por el warp en sí).
- En los bloques malos la SAD del match es *muy buena* (ratio SAD_conMV/SAD_cero mediana 0.08–0.37) → el ME encuentra correspondencias fotométricamente correctas pero semánticamente ambiguas (síntomas del bokeh).
- El campo de MV en los bloques malos es *más* coherente espacialmente que en los clean.
- `cycleError` correlaciona con daño, pero al normalizar por `|MV|` la señal desaparece: es proxy de la magnitud, no una señal nueva.
- `W0` (warp de I0) y `W1` (warp de I1) ya contienen individualmente el artefacto (far-from-both 25–60% / 67–85% en bloques sólidos); el blend solo los mezcla.

## Vías de solución descartadas por experimentación

| Vía | Experimento (resumen) | Resultado |
|---|---|---|
| λ adaptativa por textura (v1) | `lambdaEff = lambdaPx·(1+min(15, 14/σ))` en `motionSearch` | Reduce MVs grandes como se pretendía, pero los artefactos **empeoran** (sólidos 835→1180 en 82:21; forzar MV≈0 crea NUEVAS zonas far-from-both). Revertida bytewise. |
| Gating por occ + \|MV\| | Sweep OFFLINE de 3 umbrales | No separa malos de limpios (precisión ≤0.42; hasta 2× más falsos positivos que verdaderos). |
| Fallback regional | Reemplazar región 32×32 por I0 | Convierte parches en slabs congelados: frozEn% sube 5.7–13pp. Intercambia artefacto por judder. |
| Mezcla conservadora regional (α·interp + (1−α)·I0) | α = 0.25/0.50/0.75 | No mueve métricas y reduce contraste local (~−34%) = blur residual. |
| Thresholds basados solo en MV/SAD/occ | Offlines | SAD y occ no certifican correspondencia en zonas planas. |
| Cambio de pesos del blend | Descomposición W0/W1 | El artefacto vive en cada warp antes de la mezcla; cambiar el blend no lo elimina. |
| Modificar `occ`, fallback 50/50, snap | Solo aprobado para el caso puro de ghosting (ver abajo) | Ese subproblema quedó resuelto (ghost 21.5%→0.002%), distinto de estos parches. |

## Observación registrada (NO investigar ahora)

**Asimetría W0/W1**: W1 (warp hacia adelante desde I1) muestra consistentemente ~2–2.3× más error que W0 (warp hacia atrás desde I0) en las tres escenas. Posible asimetría en el muestreo forward o en la formulación de consistencia. Candidata a investigación futura independiente.

## Estado del código

- Fix válido de esta investigación: ramificación de oclusión suave en `WarpShaders.swift::warpBlend` (smoothstep + lado dominante en vez de `0.5·(v0+v1)`). Aprobado y probado en app.
- Instrumentación en `Core/Interpolation/Tools/main.swift` (env `MV_ARTIFACT=1` y espejo ME bidireccional) — solo tooling, no afecta producción; pendiente de decisión si se conserva, se limpia o se lleva a documentación separada.
- Datos reproducibles y scripts en `/tmp/rift_exp_files/` (no versionados).

## Implicación de diseño

Bajo AGENTS.md §3 (MCFI clásico sin redes), el artefacto en bokeh/motion blur pasa a ser limitación **aceptada y conocida**, del mismo tipo que el soap-opera effect. Cualquier solución real requeriría un modelo de interpolación con información adicional (p. ej. flujo óptico hardware/denso con manejo de oclusiones), fuera del alcance del pipeline actual.
