# Búsqueda inversa por parches solapados

Ensayo aislado, opt-in `MV_DENSE_PATCH=1`, dentro de Core/Interpolation. Inspirado en búsqueda inversa y densificación de [Kroeger et al.](https://arxiv.org/html/1603.03590v1), no una reproducción completa de DIS ni de Motion². Sin código importado, redes ni dependencias.

Parches de 8×8 con paso cuatro. Cada parche evalúa seed heredado, cuatro vecinos y movimiento cero por SSD; ocho iteraciones como máximo con gradientes/Hessiano del origen calculados una vez. Solo acepta actualizaciones que reduzcan SSD. Agregación de parches solapados ponderada por residuo por píxel. Reutiliza buffers acotados por nivel. No cambia síntesis, proyección ni oclusión.

La rama de parches no utiliza los vecinos temporales durante la búsqueda; los utiliza únicamente en la evaluación posterior de soporte. No debe describirse como estimación conjunta de cuatro frames. También conserva límites conocidos: brillo sin normalización por parche, desplazamiento traslacional por parche y promedios de vectores al densificar. El flag permanece desactivado por defecto; no está conectado al reproductor.

Verificación: build release; `MV_DENSE_CHECK=1 MV_DENSE_PATCH=1 .build/release/MVProbe` y versión predeterminada pasan, sin relajar asserts. Traslación conocida: error vectorial 0.00809 px, MAE de reconstrucción 0.90234; vecinos retenidos con ruido MAE 0.94076. Pasan extremos, entrada inválida, batch, aislamiento de contexto, estáticos, determinismo y oráculos de visibilidad. Se corrigió el test de instancia fresca para usar el mismo estimador en ambas instancias; el primer fallo era comparación entre configuraciones distintas.

Avatar, luminancia 1152×480 en Apple M4, mismos frames:

| Ventana | MAE cuatro vecinos anterior | Ensayo de parches |
| --- | --- | --- |
| 69 s | 8.3607 / 9.2850 / 10.2572 | 6.3881 / 7.3733 / 7.7014 |
| 300 s | 42.9163 / 30.8278 / 44.9443 | 24.1714 / 25.0993 / 41.8175 |

Análisis compartido más tres síntesis: 15.9–23.3 ms a 69 s y 17.7–28.3 ms a 300 s. Excluye búsqueda inicial de seeds en ambas direcciones, transferencia de resultados, decode y presentación. No demuestra cumplimiento del presupuesto del pipeline completo. Las referencias ocultas a 300 s tienen poses retenidas, por lo que MAE no mide directamente calidad del movimiento deseado.

La inspección de `/tmp/rift-patch-300/pair4_four_t0.5.png` muestra parches grandes todavía visibles, pese a mejorar costo y cifras. No se integra ni se declara objetivo cumplido. Siguiente trabajo: correspondencias de regiones ambiguas, mezcla de superficies durante densificación y coherencia de síntesis; conservar la evaluación de tiempo real completa como requisito.
