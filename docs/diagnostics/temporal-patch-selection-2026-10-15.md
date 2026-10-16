# Temporal patch selection experiment — 2026-10-15

Scope: Core/Interpolation and its diagnostic tools. Apple M4; 1152×480 analysis plane.

Hypothesis: the central pair alone can assign an identical texture to the wrong surface. Before/after frames can disambiguate neighboring candidate trajectories. `RIFT_PATCH_TEMPORAL=1` enables a post-propagation selector at pyramid levels >=2; production default is unchanged. The selector compares central photometric error plus robust evidence along each candidate's temporal trajectory. Globally held/noisy copies are excluded from extrapolation.

Reproduction: `MV_PATCH_TEMPORAL_CHECK=1 .build/release/MVProbe`. Two identical sprites admit central displacements 8 and 16 pixels. Before the selector, the test failed with 16; after it selects 8. Dense patch regression (including held/noisy neighbors), native NV12/P010 integration, and illumination checks pass.

Same binary, sequential real-scene comparisons: `MV_DENSE=1 MV_DENSE_PATCH=1 MV_DENSE_FOUR=1 MV_DENSE_GROUND_TRUTH=1 MV_LAMBDA=1 MV_TEMA=0 MV_PAIRS=6 MV_DUMP=0`, temporal flag 0 versus 1.

| Seek | Pair | Existing four-frame MAE | Temporal selector MAE |
|---|---:|---:|---:|
| 69s | 1 | 4.962905 | 4.774642 |
| 69s | 2 | 5.140108 | 4.918323 |
| 69s | 3 | 5.985699 | 5.850637 |
| 300s | 1 | 17.490046 | 16.378311 |
| 300s | 2 | 17.962285 | 17.799674 |
| 300s | 3 | 44.056134 | 44.172777 |

These references hide a decoded frame and reconstruct its timestamp; they do not establish perceptual equivalence with Motion². The last 300s reference regresses slightly; ordinary pair 4 at 300s remains substantially folded/unmapped (unchanged by this selector). At 69s shared analysis plus three syntheses takes 21.1–22.3ms with selection; 300s reaches 27.9ms. This excludes native full-resolution color and presentation. No production integration or claim of resolved deformities is justified by this experiment.

Logs: `/tmp/rift-temporal-{baseline,selected}{69,300}.log`; synthetic `/tmp/rift-temporal-selection-{before,after}.log`; regressions `/tmp/rift-temporal-{regression,native,lighting}.log`. Frames are bounded diagnostic samples, not a movie conversion.
