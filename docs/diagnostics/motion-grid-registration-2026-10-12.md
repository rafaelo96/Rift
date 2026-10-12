# Registro de los vectores por bloque

Hardware: Apple M4. MCFI y shaders actuales; sin cambios a demux, decode, UI ni archivos de video.

`sampleMVBilinear` documentaba centros de bloques, pero usaba `p/blockSize`. Para bloques 8×8 cuyos píxeles son 0...7, el centro es 3.5. El test Metal de un campo affine produjo error máximo 3.5 px antes del cambio y 0 después. No es un error de signo ni de escala temporal W0/W1; la traslación uniforme no detecta este desfase.

Corrección: `(p + 0.5)/blockSize - 0.5`, acotado a la rejilla antes de calcular la fracción. El clamp evita extrapolar desde el primer centro hacia el segundo al muestrear fuera del dominio de centros.

Check reproducible: `MV_GRID_CHECK=1 .build/release/MVProbe`. Comprueba centros, interpolación affine, extremos y conservación de un campo uniforme. Build release correcto. El check anterior al cambio salió con código 3; después con código 0.

Comparación de seis pares desde 69 s de Avatar (`MV_PAIRS=6 MV_SEEK_SEC=69 MV_DUMP=1 MV_LAMBDA=1 MV_TEMA=2`): CSV de vectores idéntico antes/después; ambas corridas terminaron correctamente. PNG diagnósticos en `/tmp/rift-grid-before/69.png` y `/tmp/rift-grid-after/69.png`. Persisten deformaciones; la corrección no demuestra una solución general a contornos u oclusiones. Los checks del refinamiento centrado también pasaron tras corregir la rejilla.

No validado: sesión GUI, fluidez perceptual, cadencia sostenida, M1 ni EDR. El sampler compartido afecta luma/croma de las rutas nativa y work-plane; falta validación visual de color en video HDR real.
