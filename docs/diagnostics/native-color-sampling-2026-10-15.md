# Native color sampling and sustained Frame+ cadence

Scope: Core/Interpolation. Apple M4. After rejecting cooperative patch search, opt-in per-stage profiling showed native color rendering was the largest individual aggregate GPU stage: 5.4–6.6 ms for three outputs. `RIFT_DENSE_PROFILE=1` submits/waits per stage for diagnosis; its wall times are deliberately intrusive and must not be treated as production budget measurements. Normal submission behavior is unchanged without that flag.

Replace manual integer-texture bilinear sampling with Metal linear filtering over normalized native input views. Keep integer output views, nearest motion-map hypotheses, ownership alpha, native geometry, quantization and existing HDR attachment propagation. Skip sampling the unused source when alpha is exactly zero or one. `RIFT_NATIVE_HARDWARE=0` retains manual sampling for A/B and rollback; hardware is now the default.

Independent CPU-reference check covers arbitrary fractional displacement, source borders, both color planes, ownership weights 0/.13/.5/.87/1, 8-bit NV12, 10-bit P010/P210, and 2×2 frames with one-pixel chroma planes. Limits fixed before candidate evaluation: max one eight-bit/two ten-bit source codes, MAE below .25 source codes. All pass; P010/P210 low six bits remain zero. Observed NV12 MAE .08160/max1; P010 .20030/max2; P210 .20101/max2. Manual sampling MAE/max0 on the same normal-sized test. Thus color precision differs slightly; trajectory maps do not change.

Standalone sequential same-binary A/B, synthetic 4K: NV12 manual 2.3767 ms → hardware 1.6158 ms; P010 1.9393 → 1.3871 ms. Timing varies with GPU load/frequency, and these are not universal device timings.

Habitual packaged app, same executable and Avatar source, Strong enhancement plus requested 60 fps, seek at one second to 300 s, ninety seconds each, sequential A/B:

| | Manual | Hardware |
|---|---:|---:|
| Warm delivery median (10–90 s) | 58.0 fps | 60.0 fps |
| Warm delivery mean | 54.44 fps | 59.92 fps |
| Warm minimum sample | 46.7 fps | 57.0 fps |
| Final mode target | 47.95 fps | 60.0 fps |
| Renderer total / dropped / corrupted | 4855 / 71 / 0 | 5336 / 11 / 0 |

Existing native NV12/P010 integration and dense patch regression checks pass, including repeated output payload identity. These runs support a cadence improvement in this window, not final Motion² equivalence or resolved visual deformation. Longer default-path validation follows. Source video is read-only; no copied/transcoded movie is produced.

Standalone check: `swiftc -O -parse-as-library -D NATIVE_SAMPLING_CHECK Core/Interpolation/Swift/WarpShaders.swift Core/Interpolation/Swift/WarpEngine.swift Core/Interpolation/Tools/NativeSamplingCheck.swift -o /tmp/rift-native-sampling-check`. Logs `/tmp/rift-sampler-{manual,hardware}-90.log`, `/tmp/rift-native-sampling-formats.log`, `/tmp/rift-sampling-ab-{manual,hardware}.log`, `/tmp/rift-stage-profile-69.log`.

Default-path packaged validation (no sampling environment override): 180 seconds, Strong plus pause/seek regression mode; the assertions for paused destination and resumed image delivery pass. Final renderer 10,461 total / 31 dropped / zero corrupted, with requested and active target remaining 60 throughout. Clock advances to the expected scene range after the controlled pause and +10 s seek. The run confirms this tested window, not a full-film stress test or fixed visual deformation. Log `/tmp/rift-native-default-180.log`.

Build integration correction: exclude the standalone `NativeSamplingCheck.swift` entry point from the MVProbe target. Xcode's build planning detected its conditional `@main` and selected library parsing for the whole probe, rejecting the existing top-level `main.swift`. The standalone compilation command remains unchanged. Release MVProbe builds successfully after the exclusion; this affects the diagnostic tool build, not the already verified Rift executable.
