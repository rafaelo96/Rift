# Prueba F2 en Frame+ — 2026-10-17

Integración solicitada por el usuario para comparación visual, pese a las regresiones documentadas en F2. No es una corrección aceptada.

`RIFT_FRAMEPLUS_F2=1` activa la misma mediana ponderada guiada 3×3, bloques de 8, sigma espacial 1, sigma luma .02 y corte .06. Ausente/0 conserva la ruta anterior sin asignar recursos ni emitir kernels adicionales. Una pasada en ambas direcciones después de assessment y antes de proyección/síntesis, reutilizada entre subframes. Conserva z/w. No altera búsqueda, selección ni las reglas de protección estática. E2 y F2 simultáneas se rechazan en inicialización.

El filtro ahora usa texturas del work plane directamente en la misma cola/comando Metal: no hay descarga/reenvío CPU del campo ni esperas añadidas. Memoria acotada a dos campos y dos guías por instancia. Sin estado temporal adicional. Los parámetros y kernels coinciden con el experimento offline; la ruta de reproducción normal no usa el callback del oráculo.

Para probar: abrir `distribution/Probar Frame+ F2.command`, abrir un video y activar Frame+. Para comparar: `distribution/Probar Frame+ actual.command`. Ambos reinician Rift, compilan Release y abren `dist/Rift.app` con E2=0; el segundo fija F2=0. No cambian permanentemente preferencias ni el entorno global. Se conservan las modificaciones UI preexistentes del usuario en la compilación, sin editarlas en esta tarea. El botón Run ejecuta la versión actual sin F2.

Validación en Apple M4: compilación Release de MVProbe; tres tripletes principales con bandera apagada y encendida. Las seis imágenes resultantes coinciden byte por byte con las respectivas imágenes offline guardadas: apagada con la línea base y encendida con F2. El arnés comprueba además igualdad de campos y píxeles contra la ruta ordinaria. Evidencia en `assets/frameplus-f2-trial-2026-10-17/equivalence.json`. Esto verifica la conexión y fidelidad del filtro, no calidad mejorada ni presupuesto de reproducción. Se corrigió durante validación la accesibilidad de las texturas para la lectura del arnés; no se atribuye esa lectura a reproducción.

Quedan pendientes medición de coste en reproducción real con decode/Strong, revisión visual nativa color/HDR y los controles completos de estática/pausa/seek. Los resultados negativos de F2 fuera de las máscaras siguen vigentes. No se cambió el estado de la protección estática en los lanzadores: mantienen su configuración existente. No se procesa ni copia el video completo.
