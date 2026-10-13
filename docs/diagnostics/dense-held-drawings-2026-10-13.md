# Vecinos retenidos y validez de la referencia

La ventana de Avatar a 300 s alterna grandes cambios de pose y dibujos casi retenidos. Diferencias MAE sucesivas en diez bits: 65.45, 6.18, 87.26, 4.87, 54.82, 6.11. A 69 s los cambios son más uniformes: 21.85, 21.94, 23.06, 25.29, 26.49, 26.84.

Por ello, esconder un frame y medir su reconstrucción a velocidad constante no proporciona una referencia universal para la fluidez buscada: puede exigir reproducir una pose retenida. Esto no invalida las deformaciones observadas, pero separa error de cadencia y error geométrico.

Se añadió `MV_DENSE_EVIDENCE=1` para mostrar diferencias y exportar ambos extremos de cada referencia oculta. Evidencia acotada en `/tmp/rift-motion-evidence-300` y `/tmp/rift-motion-evidence-69`; no se modifica ni copia la película completa.

Un caso sintético con traslación de cuatro píxeles y vecinos idénticos reproduce contaminación temporal: MAE del punto medio 68.2858 frente a 0.00456 del par central. El prototipo ahora omite extrapolación cuando ambos vecinos son idénticos a sus respectivos extremos, después de validar todas las entradas. Resultado byte-idéntico al par central; comprobación por assert. También verificado con refinamiento TV.

Con ruido alterno de una unidad, el mismo fallo permanece: MAE 68.2878. El diagnóstico `DENSE NOISY HELD` registra este caso sin declararlo resuelto. Ensayos de ponderación por parecido a pose retenida redujeron el error a 37–46, pero no lo resolvieron; además, ampliar el soporte de visibilidad a poses estáticas rompió la comprobación de falsa oclusión. Se descartaron esos cambios de shaders.

La solución pendiente necesita distinguir cadencia y movimiento verificado por regiones antes de usar vecinos para imponer una trayectoria. No está integrado en el reproductor ni demuestra igualdad de fluidez o estabilidad con Motion². La regla de cierre sigue siendo calidad y tiempo real en reproducción, no una mejora de MAE del prototipo.
