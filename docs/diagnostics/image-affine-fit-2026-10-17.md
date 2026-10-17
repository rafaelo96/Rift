# Image-fitted affine patches: useful isolated correction, failed acceptance

Scope Core/Interpolation, classical Swift/Metal, bounded frames, no new dependency or movie copy. Experimental checkpoint is preserved in Git before removal from the active runtime. Production defaults never enabled this mode.

A new source-gradient damped6-parameter patch fit estimates translation plus local affine deformation from image evidence rather than requiring an affine Jacobian from preexisting ME vectors. It tests the current patch and the original ME center seed, uses a6×6pivoted solve, accepts only reduced image cost with positive determinant0.25...4, and checks original-detail error. It is not a general nonrigid surface identity solver. Source-gradient additive updates are approximate, not an exact inverse-compositional affine update.

The coarse-only fit initially loses geometry during subsequent translation-only refinement: known0.5rad rotation/(-96,-24) supplied-motion fixture vectorMAE4.58369px, fails existing<3px assertion. Fitting at every level passes1.70260px/5.04245midpointMAE but costs49–55ms on the three real1152×480hidden references. It remains visually fragmented.

A hybrid uses image fitting on coarse levels and existing seed-supported affine geometry on finer levels. Known rotation returns0.08210px vectorMAE/0.85985pixelMAE, preserving the original oracle-seeded regression. The6-parameter linear solver has a direct Metal known-system and singular-rejection test. Full dense regressions pass with the hybrid: endpoints, static, deterministic output, translation, visibility and held/noisy neighbors.

Real four-source references at300s: baselineMAE23.35261/20.98821/34.38383 versus hybrid14.82963/11.42861/42.06792. At69s: baseline4.62505/4.69168/5.80404 versus4.91080/5.13901/6.35564. Hybrid analysis+synthesis around17–18ms here excludes native4K color reconstruction, decode, display and long-session effects. AppleM4 only. Neither these timings nor lower MAE establish60fps playback. Visual inspection of the adjacent300s midpoint still shows broken head/clothing contours. This fails acceptance and must not become the default or be packaged as a fix.

Hidden-frame MAE on held drawings also measures retiming error, not just geometry. Do not overinterpret an individual score: a desired smooth inbetween need not equal an actual held source image. Independent contour/trajectory and real playback review remain required.

## Cadence evidence, separate hypothesis

MVProbe now supports MV_CADENCE_REPORT=<json> with MV_PAIRS=2...31. It exports actualPTS and adjacent mean absolute/centered luma differences from a bounded decoded window, without estimating/interpolating or writing a movie. Data here uses13sourceframes each around69/300/1200s.

At300s source changes alternate65.45,6.18,87.26,4.87,54.82,6.11,31.67,6.41,19.10,2.05,9.69,2.36 in10bit work units. At69s changes are21.85–31.08 without the same alternating low-change intervals. At1200s a low-change run is interrupted by a large129.33change and later alternation. Thus a blanket duplicate policy is unsafe; cuts, moving camera and mixed cadence must be distinguished. Low MAD alone is not duplicate-frame truth.

Current adjacent-pair scheduling preserves every original hold. A distinct-drawing interval hypothesis could distribute motion across a detected retained run while keeping original distinct-framePTS, using bounded lookahead and existing uniform output cadence. This is not implemented in playback, not a proven deformation fix, and must not be used to claim fluidity or widen a deadline before validating repeat detection and source/audio timing. The next task is an isolated cadence-selection regression and real-window validation before scheduler/UI integration.

Reproduce bounded metadata: MV_CADENCE_REPORT=/tmp/cadence.json MV_PAIRS=12 MV_SEEK_SEC=300 MV_DUMP=0 .build/release/MVProbe. Experimental affine code is in the checkpoint history with RIFT_PATCH_IMAGE_AFFINE=1, solver checkMV_IMAGE_AFFINE_CHECK=1 and existing rotation/dense probes.
