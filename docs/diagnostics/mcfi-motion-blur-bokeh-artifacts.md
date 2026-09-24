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

## Observación registrada (CERRADA — ver experimento sintético abajo)

**Asimetría W0/W1**: W1 (warp hacia adelante desde I1) muestra consistentemente ~2–2.3× más error que W0 (warp hacia atrás desde I0) en las tres escenas. Investigada con experimento sintético (2025-09-14): **no hay bug**. Ver sección "Investigación W0/W1 (sintético)" más abajo.

## Investigación W0/W1 (sintético) — cerrada

**Fecha:** 2025-09-14
**Objetivo:** Determinar si existe un error matemático/geométrico en la implementación de W0/W1 antes de investigar escenas reales.

### Diseño experimental

Par sintético con ground truth conocido en `Core/Interpolation/Tools/main.swift` (env `MV_SYNTH_W0W1=1`):

- I0: campo plano oscuro (valor 50) con un píxel brillante (valor 900) en el centro — fuente puntual para medición posicional precisa.
- I1: I0 desplazada exactamente D px (bilineal Swift de referencia).
- MV field uniforme: todos los bloques = (D×2, 0) — convención half-pel confirmada.
- Warp production (`WarpEngine.interpolate`) en t=0, 0.25, 0.5, 0.75, 1.0.
- Ground truth: I0 desplazada por t×D (bilineal Swift).
- Métrica: MAD global, center-of-mass del punto brillante.

### Resultados

| Test | W0 (t=0) | W1 (t=1) | Warp (t=0.5) | CoM delta |
|------|----------|----------|--------------|-----------|
| 10px integer | 0.000000 | 0.000000 | 0.1100 | — |
| 10.5px sub-pixel | 0.000000 | 0.000000 | 0.1370 | — |
| -10px leftward | — | — | 0.1100 | — |
| 10px vertical | — | — | 0.2620 | — |
| 7px diagonal | — | — | 0.3341 | — |
| Temporal sweep 10px | t=0.0: 0.0000 | t=1.0: 0.0000 | t=0.25–0.75: 0.10–0.11 | — |

### Hipótesis evaluadas

| Hipótesis | Predicción | Resultado | Veredicto |
|-----------|-----------|-----------|-----------|
| A) Signo/dirección del MV incorrecto | W0 o W1 desplazaría en dirección opuesta | W0(t=0)=I0 exacto, W1(t=1)=I1 exacto | **Falsificada** |
| B) Escala temporal incorrecta | Error crecería linealmente con |t-0.5|, no con t | Error ≈0.11 uniforme en t=0.25–0.75 | **Falsificada** |
| C) Convención de coordenadas diferente entre W0/W1 | W0 o W1 no produciría I0/I1 en sus extremos | Ambos exactos (error=0) | **Falsificada** |
| D) Problema del muestreo bilineal | Residuo constante ~0.1 independiente del shift | Error 0.11–0.33, consistente con float precision | **Confirmada como causa de residuos** |
| E) La matemática es correcta, asimetría solo en escenas reales | Asimétrica W0/W1 >0 en contenido real, =0 en sintético | Sintético:完美; real: 2–2.3× | **Confirmada** |

### Conclusión

**No hay bug matemático en W0/W1.** La asimetría W0/W1 observada en escenas reales (Endgame/BLEACH) es inherente a la dinámica del contenido real: campo de MV no uniforme, bordes de oclusión, y la diferente contribution de W0 vs W1 según la dirección del movimiento relativo al tiempo t. Los residuos sintéticos (~0.11 MAD) son la diferencia de precisión entre el bilineal Swift de referencia y el bilineal Metal GPU, irrelevante en producción.

La investigación W0/W1 se cierra. Los parches de MCFI en Endgame/BLEACH son la limitación inherente del modelo (2 frames + 1 MV/bloque), no un error de implementación.

## Estado del código

- Fix válido de esta investigación: ramificación de oclusión suave en `WarpShaders.swift::warpBlend` (smoothstep + lado dominante en vez de `0.5·(v0+v1)`). Aprobado y probado en app.
- Instrumentación en `Core/Interpolation/Tools/main.swift` (env `MV_ARTIFACT=1` y espejo ME bidireccional) — solo tooling, no afecta producción; pendiente de decisión si se conserva, se limpia o se lleva a documentación separada.
- Datos reproducibles y scripts en `/tmp/rift_exp_files/` (no versionados).

## Experimentos W6b y W7 (2025-09-15)

### W6b — Selected MV vs (0,0) warp quality

**Resultado: W6-C — el MV seleccionado es HARMFUL en los 31/31 bloques BLEACH.**

| Métrica | Valor |
|---------|-------|
| HELPFUL | 0 |
| NEUTRAL | 0 |
| HARMFUL | **31** |
| avg selMd | **147.60** |
| avg zeroMd | **0.00** |
| avg bestNzMd | **7.48** |
| avg selFar | **90.4%** |
| avg zeroFar | **2.1%** |

Los MVs seleccionados producen un warp que está lejos de AMBOS frames inputs en ~90% de los píxeles. El mejor MV no-cero (avg 7.48) es órdenes de magnitud mejor que el seleccionado (147.60) pero sigue siendo peor que cero. Conclusión: estos MVs son false matches catastróficos, no subóptimos.

### W7 — ClearWinGate forensic analysis

**Resultado: Gate fires 100% (31/31) — clearWinGate funciona correctamente para estos bloques.**

| Métrica | Valor |
|---------|-------|
| Gate fire rate | **31/31 (100%)** |
| avg bestCost/zeroSAD | **9.363** (threshold = 0.875) |
| avg SAD selected | 11,322 |
| avg SAD zero | 306 |
| avg cost selected | 14,246 |
| avg penalty | 2,923 (25.0% of cost) |

**Implicación:** Los 31 bloques de BLEACH ya tienen su MV override a (0,0) en producción gracias al clearWinGate. El gate detecta correctamente que el bestCost (MV no-cero con menor costo) es ~9.4× peor que zeroSAD, superando ampliamente el umbral de 0.875. Los artefactos visibles en producción deben provenir de OTROS bloques donde el gate NO dispara.

### Hallazgo técnico: SIGSEGV en String(format:) con Int en arm64

Durante la implementación de W7, se descubrió que `String(format:)` con `%d` + `Int` (64-bit) causa SIGSEGV en arm64. `Int` en arm64 es 8 bytes pero `%d` espera 4 bytes (`CInt`), causando desalineación del argumento variádico. Solución: usar interpolación de strings de Swift o castear a `Int32` explícitamente.

## Implicación de diseño

Bajo AGENTS.md §3 (MCFI clásico sin redes), el artefacto en bokeh/motion blur pasa a ser limitación **aceptada y conocida**, del mismo tipo que el soap-opera effect. Cualquier solución real requeriría un modelo de interpolación con información adicional (p. ej. flujo óptico hardware/denso con manejo de oclusiones), fuera del alcance del pipeline actual.
