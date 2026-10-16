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

## Refinement and rejected variant

Applying the selector at all pyramid levels was rejected: 69s three-output batches rose to 31.9–33.3ms (versus ~21–22ms), while the 300s pair-2 reference regressed to 19.3264 MAE and pair-3 to 44.3264. Coarse-level scope is retained.

A central-fit guard now requires candidate SSD not to exceed the original patch SSD beyond squared two-code-value tolerance (`4/1023²`). Temporal evidence can resolve ambiguity without sacrificing the existing central correspondence. A second synthetic fixture gives misleading before/after evidence favoring 16px while the central pair favors 8px. Without the guard it fails (exit133); with the guard it passes. The original identical-surface ambiguity still passes. Dense patch regressions also pass with the guarded selector.

Extended sequential 69s comparison (16 pairs, 13 hidden-frame references) improves 12/13 references: average MAE 5.796337 → 5.704943. Median shared-analysis/three-output times 21.4420 → 21.9228ms; observed maxima 32.5882 → 30.6336ms. These short runs are diagnostic, not sustained performance proof. 300s guarded reference MAEs are 16.117752 / 17.575615 / 44.100591: the third remains worse than existing four-frame 44.056134, and substantially worse than two-frame 33.718164. Large cloth/head motion and pose holds remain unresolved. No flag default or app integration changed.

Logs: `/tmp/rift-temporal-fine{69,300}.log`, `/tmp/rift-temporal-guard{69,300}.log`, `/tmp/rift-temporal-extended-{base,guard}.log`, `/tmp/rift-temporal-{unguarded,restored}-check.log`.
