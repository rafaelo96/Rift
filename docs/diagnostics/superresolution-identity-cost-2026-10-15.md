# Avoid resizing an already native-size enhancement input

Scope: Rendering. Avatar's 3832×1600 source stays at that size under the enhancement output-size policy, but the luma kernel still performed sixteen-tap bicubic reconstruction and chroma performed four-tap bilinear reconstruction for every output pixel. At 1:1 these reconstruct the source texel exactly. This extra work competes with Frame+ on every displayed frame.

Use a direct source texel for the luma base and direct chroma copy only when both dimensions match. Keep the existing strong detail filter, clamping, upscaling path, output pool and attachments. No enhancement mode is disabled and no source file is changed.

`Rendering/Tools/SuperResolutionIdentityCheck.swift` compiles with the existing processor/shader sources as a standalone check. It validates the native-size filter against a CPU mathematical reference at interior/crop-edge points, exact chroma, geometry and primaries for eight/ten-bit buffers. The check passes before and after. Twenty processed frames per format, Apple M4, 3840×1600, no adaptive bypass: median eight-bit 1.9535→1.5521 ms; ten-bit 1.9218→0.9411 ms. These short isolated costs do not include Frame+ or presentation.

Habitual Release app, Avatar, Frame+ requested 60 plus Strong enhancement, normal seek to 300 s. Matching warm window (seconds 10–60):

| | Before | After |
|---|---:|---:|
| Delivery median | 52.8 fps | 60.0 fps |
| Delivery mean | 46.44 fps | 59.85 fps |
| Delivery minimum sample | 4.7 fps | 55.0 fps |
| Renderer total at 60 s | 2719 | 3522 |
| Renderer dropped at 60 s | 202 | 108 |
| Corrupted | 0 | 0 |

System load varies, so these runs do not isolate an exact end-to-end speedup. Drop counts remain material; final Motion²-like quality and perfectly stable presentation are not established. Manual pause/seek begins after the after-run's 60 s comparison window; do not compare its whole ninety-second totals with continuous playback.

Logs `/tmp/rift-sr-identity-{before,after}.log`, `/tmp/rift-habitual-preroll-fixed-90.log`, `/tmp/rift-habitual-sr-fast-90.log`. Standalone command: `swiftc -O -parse-as-library Rendering/Swift/SuperResolutionShaders.swift Rendering/Swift/SuperResolutionProcessor.swift Rendering/Tools/SuperResolutionIdentityCheck.swift -o /tmp/rift-sr-identity-check` then run that executable. General upscaling behavior outside the identity branch was not separately revalidated in this task.
