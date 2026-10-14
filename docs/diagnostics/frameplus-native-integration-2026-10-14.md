# Integración experimental de parches en Frame+

Solicitada por el usuario para comprobar reproducción real antes de terminar la calidad. Alcance Core/Interpolation y su harness; sin editar UI, Decode, Scheduler ni Rendering. La app de prueba incluye los cambios de UI que ya estaban presentes en el checkout, preservados por el checkpoint anterior.

`MotionCompensator.interpolatePair` y `interpolateWithTimings` seleccionan ahora el motor por parches. `RIFT_FRAMEPLUS_PATCH=0` conserva la implementación anterior para comparación/reversión. Inicialización y recursos se reutilizan; los seeds forward/reverse usan la misma geometría sin EMA. El contrato de `CVPixelBuffer` continúa igual.

La síntesis densa publica coordenadas relativas de ambos extremos y su peso temporal por píxel. El callback nativo consume esos mapas antes de reutilizarlos y sin descargar los arrays diagnósticos de luminancia/flujo. `WarpEngine` aplica las decisiones a ambos planos nativos, con muestreo bilineal de imagen, selección de mapa sin mezclar hipótesis vecinas, cuantización 8/10-bit y pool existente con límite de 32. Conserva tamaño, formato y attachments mediante la función existente de propagación HDR. Los extremos devuelven los buffers originales; entrada inválida o fallo produce un batch vacío.

La API de reproducción recibe dos frames; el contexto opcional de cuatro del prototipo todavía no se alimenta desde Scheduler. Esta entrega prueba el motor integrado de pares y su síntesis de color, no una integración completa del contexto temporal de cuatro. No se afirma que los artefactos estén resueltos.

Verificación: build release MVProbe y Rift; `MV_NATIVE_PATCH_CHECK=1 .build/release/MVProbe` pasa para buffers NV12 de 8 bits y P010 de 10 bits: batch completo, extremos idénticos, canales Cb/Cr dentro de los rangos esperados, formato/dimensiones, metadatos e input NaN rechazado. `MV_DENSE_CHECK=1 MV_DENSE_PATCH=1` continúa pasando después de añadir los mapas. La app arranca y presenta su ventana Open Video, comprobada en la UI nativa.

Avatar 4K, Apple M4, dos salidas por par: perfil 1152×480, tres pares, 83.433 / 76.198 / 56.883ms completos de interpolación. Perfil economy 768×320, seis pares: 45.934 / 43.411 / 44.169 / 41.892 / 38.840 / 33.295ms. Estas mediciones incluyen extracción y escalado, ambos seeds, estimación/síntesis densa, render nativo y asignación; excluyen decode y presentación. No certifican 60fps sostenidos. La admisión y degradación existentes de la app siguen midiendo el costo real. Los tamaños/formato y conjuntos de keys HDR del output 4K coinciden con los de entrada; no es validación visual EDR.

App local portable y firmada ad hoc: `/Users/rafael/Applications/Rift Frame+ Test.app`, identificador independiente `com.rift.player.frameplus-test`, icono Rift y dependencias FFmpeg incluidas. No reemplaza el ejecutable de la app habitual. El runtime empaquetado exige macOS 27+, compatible con el host de prueba 27.2; no se ha validado en otros sistemas.

Para comprobar: abrir la app de prueba, elegir el mismo video y activar Frame+. Comparar la escena difícil alrededor de 5:00 y la escena de cámara alrededor de 1:09. Se requieren aún la observación de usuario, sesiones sostenidas, pausa/seek y la comparación directa con Motion² (el usuario no dispone de Splash actualmente).

Logs: `/tmp/rift-native-pipeline-69.log`, `/tmp/rift-native-economy-69.log`, `/tmp/rift-test-app-build.log`, `/tmp/rift-native-app-package.log`. Comprobación `codesign --verify --deep --strict` completa. Objetivo global de calidad, tiempo real e integración definitiva no terminado.
