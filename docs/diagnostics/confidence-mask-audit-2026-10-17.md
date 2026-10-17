# Auditoría de confianza sobre las regiones de Fase 1 — 2026-10-17

Solo se leyeron datos guardados. No se ejecutó Rift, Metal ni decodificación; no se activó E2 ni se modificó código del motor. Se añadieron un análisis offline, tablas y recortes derivados de las imágenes existentes. No se proponen correcciones.

**Límite de la verdad disponible:** Fase 1 guardó `regions.json` y `region-mask.png` como rectángulos manuales de inspección, no máscaras píxel a píxel de deformaciones certificadas ni seguimiento de superficies. El documento original lo declara explícitamente. Por tanto, los números de abajo son **recall y precisión espacial respecto a esas ROIs**, no recall/precisión semánticos de todas las deformaciones reales. Un píxel marcado fuera de ellas no queda certificado como falso positivo. En 18:02 tampoco se había identificado el píxel deformado exacto denunciado inicialmente.

## 1. Recall y precisión

Work plane 1152×480. Se reconstruye la unión binaria de los rectángulos originales, sin ampliar ni corregir las máscaras. Áreas: 65.536 píxeles en 69 s, 40.960 en 300 s y 34.304 en 18:02. Cada rectángulo está alineado a bloques8×8; no se confunde la cuadrícula de puntos del PNG con una etiqueta de defecto.

- Recall = píxeles de la ROI marcados / píxeles de la ROI.
- Precisión espacial = píxeles marcados dentro de la ROI / todos los píxeles marcados de la imagen.
- E1: score combinado de seis mid-CDF, calibración original starts0–17, umbrales originales sin reajuste. «Top10» es el umbral usado para la máscara diagnóstica E1, no una cuota del10% forzada en cada imagen.
- E2: **peso guardado w>0**, incluyendo histéresis, suavizado, plumeado y corte de pesos mínimos. No se sustituye por score≥umbral. Se muestran la versión inicial y la final separadamente.
- Sin predicción positiva, la precisión es indefinida (—), no cero.

### Par principal4, extremos I4/I5 y síntesis t=0,5

Cada celda es **recall / precisión**.

| Caso | E1 top10 | E1 top5 | E2 inicial | E2 final |
|---|---:|---:|---:|---:|
| 69 s | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / 0.00% |
| 300 s | 57.66% / 10.71% | 14.22% / 5.76% | 2.50% / 2.41% | 13.44% / 5.56% |
| 18:02 | 0.00% / 0.00% | 0.00% / — | 0.00% / — | 0.00% / — |

E2 final marca 384 píxeles totales en 69 s (ninguno dentro de las ROIs), 99.008 en 300 s (5.504 dentro), y ninguno en 18:02. En300 s la cobertura por región es 17,50% de cara y 9,375% de ropa. El componente marcado mayor de la ROI de cara se ubica sobre todo en la franja de fondo; no equivale a recuperar el rostro deformado.

### Triplete principal4: extremos I4/I6, verdad I5

Este experimento permite error verdadero, pero **no es el mismo instante** que el intermedio I4/I5 anterior. Las ROIs mantienen sus coordenadas; no se inventa verdad real para el instante entre frames consecutivos.

| Caso | E1 top10 R/P | E1 top5 R/P | E2 inicial R/P | E2 final R/P |
|---|---:|---:|---:|---:|
| 69 s | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / — | 0.00% / 0.00% |
| 300 s | 50.62% / 9.23% | 13.12% / 4.91% | 3.75% / 2.25% | 35.62% / 8.33% |
| 18:02 | 0.00% / 0.00% | 0.00% / 0.00% | 0.00% / — | 0.00% / — |

Se calcularon también **todos los umbrales E1 guardados**: top1=.9583563381, top2=.9439189586, top5=.9054585465, top10=.8442130102, top20=.7187323489, top30=.6019473464, top50=.4472580708. Tabla completa con numeradores y denominadores en `coverage.csv/json`. E2 inicial: entrada/pleno/salida top2/top1/top5; E2 final: top5/top2/top10. Se conservan las máscaras efectivas, no solo esos tres umbrales.

### Ventana completa: cobertura de rectángulos fijos, no defectos seguidos

Ventana original de 49 frames (unos 2 s), distinta de los clips E2 de 10 s. 48 pares adyacentes; intersecciones sumadas y denominadores sumados, no promedio de precisiones por imagen. La cara u otra superficie puede salir del rectángulo. Estas cifras no amplían la certificación de deformación más allá del par inspeccionado.

| Caso | E1 top10 R/P | E1 top5 R/P | E2 final R/P |
|---|---:|---:|---:|
| 69 s | 0.85% / 9.65% | 0.13% / 7.08% | 0.20% / 8.34% |
| 300 s | 13.06% / 8.60% | 6.91% / 9.20% | 7.11% / 9.06% |
| 18:02 | 1.66% / 6.15% | 0.96% / 6.04% | 0.93% / 5.97% |

El par 6 de 18:02 cruza un corte; permanece en la tabla descriptiva de cobertura, no se interpreta como movimiento continuo. El archivo por par indica qué pares/tripletes cruzan ese corte.

## 2. Error verdadero y confianza dentro de ROIs no marcadas

MAE exacta de luma de 10 bits, usando los registros originales por bloque y el frame central real; no se aproxima el error a partir de PNG de 8 bits. Se comprueba igualdad exacta de la MAE base E1/E2 en los 47 tripletes por caso. Las regiones y las máscaras binarias efectivas abarcan bloques completos; los pesos varían dentro del bloque, pero w>0 no deja fracciones de bloque en estos datos.

Definiciones operativas, sin recalibrarlas:

- «Equivocado»: MAE del bloque >16 códigos, la definición positiva ya usada en E1. Sensibilidad >8 y >32 queda en el JSON.
- «Alta confianza relativa»: riesgo <.8442130102, es decir, por debajo del umbral E1 top10 que también sirve como salida de la histéresis E2 final.
- El score es **rango de riesgo, no probabilidad**. Se muestra también el conteo más estricto con proxy de confianza 1−riesgo≥.5; tampoco es una probabilidad calibrada.
- Los scores de E2 en zonas no marcadas no se volcaron: el mapa guardado pone sus canales a cero. Se **reconstruyen offline** con las señales E1 y la tabla CDF congelada E2. En los bloques marcados donde sí hay score guardado, diferencia máxima verificada 1,55×10⁻⁷. Las fórmulas y señales son las mismas; no se afirma lectura directa del score GPU de los bloques no marcados.

### Triplete principal4

N = bloques no marcados dentro de la ROI. Error corresponde a toda esa zona. «Error+alta» es el subconjunto con error>16 y riesgo bajo el umbral anterior.

| Caso | Máscara | N | MAE | Riesgo mediano | Proxy confianza mediana | Error>16 | Error+alta | Error+proxy≥.5 |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| 69 s | E1-top10.0 | 1024 | 1.1032 | 0.5220 | 0.4780 | 4 | 4 | 2 |
| 69 s | E2-final | 1024 | 1.1032 | 0.5220 | 0.4780 | 4 | 4 | 2 |
| 300 s | E1-top10.0 | 316 | 6.9939 | 0.7713 | 0.2287 | 33 | 33 | 0 |
| 300 s | E2-final | 412 | 8.7560 | 0.7924 | 0.2076 | 64 | 33 | 0 |
| 18:02 | E1-top10.0 | 536 | 0.5284 | 0.3641 | 0.6359 | 0 | 0 | 0 |
| 18:02 | E2-final | 536 | 0.5284 | 0.3641 | 0.6359 | 0 | 0 | 0 |

Para E2, los bloques «error+alta» cubren respectivamente **256, 2.112 y 0 píxeles de soporte**. Eso no significa que cada uno de esos píxeles tenga error>16: la etiqueta es del bloque8×8. A umbrales de error>8/>32, los bloques no marcados equivocados son 69 s:10/2;300 s:117/26;18:02:0/0.

En E2, el riesgo de los bloques no marcados recorre69 s:.0706–.8417;300 s:.1737–.9066;18:02:.1291–.5706. Que algunos bloques no marcados superen la entrada actual es compatible con el peso mínimo y la dinámica de estado; «no marcado» no es sinónimo de «score bajo». La MAE baja de una ROI tampoco descarta una deformación visible de bajo contraste.

### 47 tripletes, mismos rectángulos sin seguimiento

Se cuentan **observaciones bloque×triplete**, no bloques/píxeles distintos seguidos por el video.

| Caso / selección | N no marcados E2 | MAE | Error>16 | Error+alta |
|---|---:|---:|---:|---:|
| 69 s / all47 | 47357 | 4.1467 | 2813 | 2113 |
| 300 s / all47 | 24413 | 8.2138 | 2626 | 1875 |
| 18:02 / all47 | 24594 | 2.4016 | 452 | 202 |
| 18:02 / withoutKnownCut | 24120 | 1.3455 | 110 | 110 |

Se excluyen los tripletes5/6 de 18:02 en la fila sin corte porque sus extremos cruzan6→7. Estos errores demuestran fallos de reconstrucción en ROIs fijas, no que todas esas observaciones sean las deformaciones originalmente denunciadas. E1 y las dos selecciones completas están en `window-truth.json`.

## 3. Comparación visual de lo marcado

Recortes derivados exclusivamente de los PNG existentes: actual/E2, exposición uniforme×1,8, nearest-neighbor, luma8 bits. Se guardan ROI completa, superposición roja de w>0 y detalle del mayor componente marcado con 4 px de contexto. No es validación HDR/color ni del parpadeo en video.

| Caso | Clasificación en par principal | Lo observado |
|---|---|---|
| 69 s | **Igual; no hay sustitución dentro de la máscara** | Fondo, bisonte y primer plano son iguales en los PNG; E2 no los marca. No existe una zona marcada dentro de estas ROIs sobre la que evaluar un fallback. |
| 300 s | **Mejor parcial en ropa; igual en cara** | En la componente marcada de ropa reaparece un tramo diagonal ausente/aplanado en el actual. La transición queda blanda y en el triplete conserva una mancha oscura; no recupera toda la silueta. En cara el mosaico permanece y la diferencia es tenue, principalmente en la franja de fondo. No se clasifica toda la deformación como resuelta. |
| 18:02 | **Igual; no hay sustitución dentro de la máscara** | Ave y paisaje no están marcados, y los PNG dentro de ambas ROIs son iguales. No permite calificar la calidad de una sustitución que no ocurrió. |

En el triplete 300 s, solo dentro de bloques marcados, MAE cara 23,2973→22,6913 y ropa 56,3259→29,1079. Es apoyo cuantitativo de la mejora local, no sustituto del juicio visual ni prueba de ausencia de nuevos bordes.

- [69 s / crossing-bison: actual frente a E2](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-mask-audit-2026-10-17/avatar69-crossing-bison-span1.png)
- [300 s / clothing-contour: actual frente a E2](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-mask-audit-2026-10-17/avatar300-clothing-contour-span1.png)
- [300 s / face-contour: actual frente a E2](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-mask-audit-2026-10-17/avatar300-face-contour-span1.png)
- [18:02 / bird-contour: actual frente a E2](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-mask-audit-2026-10-17/anime1082-bird-contour-span1.png)
- [300 s / detalle de ropa efectivamente marcado](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-mask-audit-2026-10-17/avatar300-clothing-contour-marked-detail.png)

[300 s: contexto del triplete actual/E2/frame real](/Users/rafael/Documents/Rift/docs/diagnostics/assets/confidence-mask-audit-2026-10-17/avatar300-clothing-truth-context.png)

## 4. Coste: qué se puede recuperar

**No es posible desglosar los +8,24 ms por etapa con los datos existentes.** Se auditaron los diez logs de las cinco alternancias Release/M4. `RIFT_PAIR_TIMING` tiene solo seis campos: etiqueta, uptime, ancho, alto, número de subframes y tiempo total del par. Hay cero registros de tiempo de adquisición/confianza/mezcla y cero líneas `DENSE GPU PROFILE`. Las líneas E2_TEMPORAL prueban búsquedas/reutilización, pero no guardan duración. Los microbenchmarks nativos separados no son estas alternancias ni aíslan el coste de E2, y no se usan para inventar atribuciones.

| Componente | Mediana | Dispersión |
|---|---|---|
| Adquisición temporal | No registrada | No registrada |
| Cálculo de confianza/mapa | No registrado | No registrado |
| Mezcla | No registrada | No registrada |

Los totales sí se reproducen desde los logs originales, quitando10 s de calentamiento y usando el plano736×320, p95 por nearest rank. No se corrió ninguna tanda nueva ni se activó E2 en esta auditoría.

| Alternancia | p95 apagado | p95 E2 | Diferencia del par de p95 |
|---|---:|---:|---:|
| 1 | 44.962 ms | 55.097 ms | +10.135 ms |
| 2 | 44.825 ms | 53.070 ms | +8.245 ms |
| 3 | 44.460 ms | 53.129 ms | +8.668 ms |
| 4 | 44.081 ms | 52.559 ms | +8.478 ms |
| 5 | 45.238 ms | 52.425 ms | +7.187 ms |

| Grupo | Mediana de p95 | Rango | IQR | Desvío poblacional |
|---|---:|---:|---:|---:|
| Apagado | 44.825 ms | 44.081–45.238 ms | 0.501 ms | 0.403 ms |
| E2 | 53.070 ms | 52.425–55.097 ms | 0.569 ms | 0.961 ms |

Diferencia de medianas: **+8.245 ms**. Mediana de las cinco diferencias emparejadas: **+8.478 ms**, IQR 0.424, desvío 0.947, rango 7.187–10.135 ms. Son estadísticos distintos. No se suman p95 de etapas ni se asigna la diferencia total a una etapa sin registros.

## Archivos y límites finales

`ConfidenceMaskAudit.py` reproduce solo análisis CPU de datos existentes. `input-sha256.json` identifica fuentes; los NPZ nuevos preservan sin pérdida los canales de mapas guardados necesarios para repetir el análisis sin los f32 locales ignorados por Git. `coverage`, `truth`, `window-truth`, `fixed-roi-per-pair`, `visual`, `calibration-checks` y `cost-audit` conservan cifras y verificaciones. Los assert comprueban denominadores, ausencia de predicción, alineación8×8, identidad del error base y correspondencia de scores donde el mapa los conserva.

Quedan sin poder demostrarse con estos datos: recall semántico píxel a píxel de deformaciones certificadas; error real del instante entre frames consecutivos; clasificación visual de una sustitución inexistente en 69 s/18:02; scores GPU no marcados leídos directamente; desglose temporal por etapa de las cinco alternancias. Esta auditoría termina aquí, sin activar E2 ni proponer o implementar correcciones.
