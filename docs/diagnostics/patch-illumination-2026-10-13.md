# Iluminación y correspondencia

Diagnóstico `MV_DENSE_LIGHTING=1 .build/release/MVProbe`: traslación de cuatro píxeles sobre textura conocida, incremento uniforme de 120 unidades de diez bits, semillas de tres píxeles. El frame intermedio esperado conserva el detalle trasladado y suma 60. El check registra error y verifica valores finitos, no certifica resolución del fallo.

Antes: MAE vectorial 47.49165px, error del punto medio 267.3724. Normalizar la media por parche corrige movimiento a 0.00877px pero no el frame (15.72135); empeora las seis referencias reales (69 s: 5.61095/5.82026/6.53480; 300 s: 39.70835/40.20052/45.37669). Se descartó: pierde discriminación entre superficies de distinto brillo.

Compensación por media del frame completo: error vectorial 0.02444px, frame 18.48177. Sin cambio de iluminación, la traslación y el recorte alteran la media en -2.55859 unidades; esta compensación hace fallar el check existente de detalle (MAE 10.23047 >5). También empeora la tercera referencia de Avatar 300 s a 45.55054. Ensayo retirado. No se relajó el check de traslación para mantenerlo.

Ambos cambios de estimador fueron retirados. Se conserva el diagnóstico y no se presenta como una solución integrada. Los costes de búsqueda basados solo en luminancia siguen siendo ambiguos; quitar el brillo sin otra evidencia no resuelve qué superficie corresponde. Pendiente identificar regiones concretas y la información que permite distinguirlas, antes de otra modificación de matching.

Logs `/tmp/rift-patch-lighting-69.log`, `/tmp/rift-patch-lighting-300.log`, `/tmp/rift-global-lighting-300.log`; mediciones en Apple M4. Objetivo de calidad y fluidez comparable con Motion² abierto.
