# Giro conocido y refinamiento local

Diagnóstico aislado `MV_DENSE_ROTATION=1 .build/release/MVProbe`: textura analítica 96×96, giro 0.2 rad, semillas por bloque obtenidas del movimiento real. El punto medio usa inversa de (I+R)/2, coherente con trayectorias lineales de MCFI, no R(angle/2). Se miden solo píxeles interiores. El check verifica valores finitos; registra precisión, no certifica calidad mediante ese assert.

Apple M4: LK anterior, MAE vectorial 1.19670 px y punto medio 1.18519 unidades de diez bits. Parches: 1.27617 px / 1.46914. La representación traslacional por parche tiene una limitación medible, pero este caso no reproduce las deformaciones severas de Avatar.

Ensayo: dos iteraciones LK centrales a resolución final después de agregar parches, sin regularización ni vecinos temporales. Giro: 1.30210 px / 1.44946; no mejora el campo conocido. Traslación sí mejora de MAE 0.94076 a 0.02083. La batería existente pasa.

Avatar con dos iteraciones: 69 s, MAE 5.65745 / 5.54815 / 6.62320, todos peores que 5.55211 / 5.50088 / 6.44829. 300 s: 20.22611 / 21.08450 / 43.05727, dos mejores y tercera peor. Inspección del cambio de pose sigue mostrando parches. Costo observado de análisis más tres síntesis 18.8–30.7ms, sin búsqueda inicial ni pipeline de reproducción. Logs `/tmp/rift-patch-local-69.log`, `/tmp/rift-patch-local-300.log`.

Se retiró el refinamiento adicional: no mejora suficientemente la calidad real y consume margen. Se conserva únicamente el diagnóstico de giro. Sigue pendiente encontrar correspondencias confiables en cambios de pose y sintetizar sin fragmentar superficies; ni la precisión de una traslación ni la imagen analítica prueban igualdad con Motion².
