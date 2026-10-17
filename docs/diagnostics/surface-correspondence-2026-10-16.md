# Local correspondence topology: necessary, not sufficient

Scope: new offline Core/Interpolation diagnostic only. No production Swift/Metal files, playback state, UI, dependencies, or complete source videos are changed. The experiment uses existing NumPy/Pillow and a bounded pair of exported 1152×480 source frames from Avatar around300s. CPU timings are measurements on Apple M4, not a prediction of Metal runtime performance.

## Hypothesis

Committing to the nearest local descriptor independently discards the correct match when repeated facial contours have similar gradients. Retain four distinct target features per source and use neighboring correspondences to select a locally consistent surface. Unlike a global affine hypothesis, the graph permits local stretch and rotation and therefore can represent a smooth nonrigid change of pose. The diagnostic reuses the existing gradient descriptor helper; it is not SIFT or a complete optical flow implementation.

For source edges12–96px long, graph affinity favors target/source length ratios near1 and local orientation preservation. The admissible ratio is0.45–2.2 and orientation difference is below60degrees. These are explicit model limits, not calibrated product thresholds. Twenty-four rounds combine descriptor likelihood and neighboring candidate support. A greedy one-to-one assignment requires support from at least three weighted neighbors. No facial ROI, manually chosen displacement, or semantic label enters matching.

A second check counts orientation reversals in source-local triples whose signed doubled area exceeds64px². It iteratively removes the least-supported correspondence implicated in the most reversals. This demonstrates the limitation of a topology-only repair: it can remove folds by deleting useful information. Independently recomputing the reverse matching tests whether the retained assignments are actually reciprocal.

## Reproducible checks

```
python3 Core/Interpolation/Tools/SurfaceCorrespondenceGraph.py --selfcheck
python3 Core/Interpolation/Tools/SurfaceCorrespondenceGraph.py \
  docs/diagnostics/assets/patch-stage-2026-10-16/input0.png \
  docs/diagnostics/assets/patch-stage-2026-10-16/input1.png \
  --out /tmp/surface-correspondence-avatar300.json
```

The analytic synthetic fixture has36grid controls, smooth sinusoidal nonrigid deformation, and deliberately misleading descriptors:34of36independent nearest choices are wrong. Local geometric voting recovers36of36known correspondences with zero coordinate error and zero reversed local triples. A deliberately reflected triangle is detected. Empty and insufficient-support input are rejected. This fixture validates the selector, not automatic image landmark extraction or visual interpolation quality.

For the real pair,280/112features create1120forward proposals. The graph selects52matches. However,1410of3740eligible local triples reverse orientation. Pruning leaves18matches and zero reversals among50remaining tested triples. Running the whole procedure independently backward leaves only2mutually consistent matches. The result is preserved in `assets/surface-correspondence-2026-10-16/avatar300.json`. Full forward/reverse diagnostic runtime is about2.28seconds offline.

The remaining matches include large displacement hypotheses on the head, but some visibly associate different anatomical contours. No dense midpoint is synthesized because eighteen unilateral points and two reciprocal points do not provide a trustworthy nonrigid surface map. Reporting the zero remaining inversion count as a visual fix would be incorrect. Near-zero support can also result from poor coverage, so match count and tested-triangle count accompany inversion count.

## Decision and concrete integration boundary

Do not port this graph into the realtime path as a repair. It proves that local geometry can resolve a deliberately ambiguous smooth deformation, but changing three-dimensional pose, visibility, repeated contours and missing features defeat the image-derived candidates. A topology constraint cannot manufacture identity evidence that is absent from its proposals. Relaxing descriptor or topology gates until a large foreground cluster appears would conceal that failure.

A safe native integration must retain separate motion hypotheses until both source-to-target and target-to-source evidence identifies the same visible surface; then test its generated midpoint against independent held-frame references and its end-to-end cost. Where this graph currently has only two reciprocal landmarks it must not create an affine/mesh foreground fit. Triangle sign can be an additional diagnostic or rejection condition after sufficient correspondence coverage, never the sole acceptance criterion. This experiment changes no Frame+ defaults and makes no claim of Motion² equivalence.
