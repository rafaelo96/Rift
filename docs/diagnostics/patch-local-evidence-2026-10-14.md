# Local evidence for ambiguous patch trajectories

Scope: Core/Interpolation. Existing aggregation selected a trajectory from single-pixel intensity plus the patch's stored residual. A deterministic synthetic case gives 0 px and 8 px candidates identical center intensity and stored cost; only 8 px matches the surrounding texture. Before: selected 0 px and assertion fails. After: selected 8 px. Compatible subpixel candidates still aggregate; separate 0/8 px surfaces never average into 4 px.

The candidate score and compatible-candidate weight now use a 3×3 local mean absolute residual. Reuse the nine source samples and four candidate residuals within the pixel. No new temporal state, dependencies or source-file writes.

Same-run baseline A/B, Apple M4, 1152×480, six source pairs, default probe seed settings (lambda=4):

| Window | Four-frame hidden references, before | After |
|---|---|---|
| 69 s | 4.91017 / 5.39302 / 6.48748 | 4.86715 / 5.38952 / 6.44249 |
| 300 s | 23.58795 / 29.13333 / 45.37052 | 23.46473 / 29.13186 / 45.24615 |

These figures are not directly comparable to earlier reports using other seed settings. All six references improve slightly, but inspection of `pair4_four_t0.5.png` still shows major fragmentation. Hidden-frame error is not proof of fluidity or correct shape, particularly for held animation poses.

Existing patch, standard dense, native 8/10-bit and illumination checks pass. Illumination +120: vector MAE .01931 px / midpoint 2.67383, compared with .01928 / 2.67122 before (small regression recorded, no assertion relaxed). A separate experiment requiring surface membership in both paired synthesis candidates changed real results negligibly and was removed.

Corrected production harness, actual three outputs per pair at 69 s, economy 768×320, 12 pairs: median 24.493 ms, maximum 27.660 ms, all buffer-count assertions pass. This is interpolation including native input scaling/output, excluding decode/display. Runtime load differs from the earlier exploratory tests; do not infer a precise speedup from those comparisons. Sustained app playback must be rechecked after packaging this shader update.

Logs: `/tmp/rift-ambiguity-before.log`, `/tmp/rift-local-evidence-check.log`, `/tmp/rift-local-baseline-{69,300}.log`, `/tmp/rift-local-evidence-{69,300}.log`, `/tmp/rift-correct-three-69.log`. Objective remains incomplete; Motion² visual equivalence has not been demonstrated.

Packaged shader update revalidated for 60 seconds with a normal seek to 300 s. Final renderer metrics: 3,517 total / 5 dropped / 0 corrupted; delivery around 60 fps, no progressive collapse, zero subtitle composition failures. Log `/tmp/rift-fluency-local-final.log`. Test app signature and independent identifier verified. This confirms the measured window only; it does not remove the documented visual fragmentation.
