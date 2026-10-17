# Surface synthesis: isolate ownership from missing correspondences

Scope: standalone diagnostic in Core/Interpolation, Apple M4. No production source, UI, decoder or movie file changes. No dependencies beyond Swift, Foundation and Metal. The harness compiles the **current production `denseMotionMSL`** and invokes `denseProject` and `denseSynthesize` directly. It bypasses estimation, pyramid aggregation and flow assessment to make their contribution distinguishable.

## Hypothesis

If the existing ownership/projection synthesis intrinsically tears a correctly moving surface, tearing must remain with exact motion and visibility supplied. Conversely, if the exact surface survives and assigning part of it to the background reproduces damage, changing final blending cannot generally recover missing correspondence information.

## Experiment

160×96 luminance plane; textured rectangle over textured background; foreground translation 0, 16, 40 or 72 pixels. The background remains static. Exact forward/reverse velocity is assigned separately to each visible surface. A negative `w` marks the endpoint counterpart hidden by the other surface, matching the existing shader contract. The endpoint at `t=1` is also tested with deterministic sinusoidal noise of amplitude 1/1023. Translation zero covers retained/repeated poses with noise; this is not a model of the real changing facial pose.

Render `t=0,.25,.5,.75,1`. Ground truth is the same analytic scene evaluated at each time. An error above 0.05 normalized luminance (about 51 ten-bit codes) counts as a materially damaged pixel. Compare four isolated synthesis variants:

- Current production projection and synthesis.
- Projection disabled, leaving existing local ownership candidates intact.
- Current projection, but require the already-computed `surface0 && surface1` membership in the paired local-candidate branch.
- Current projection, but prevent the final static guard from overriding an already-selected owner.

Repeat with the same images and a deliberately incorrect correspondence: a 20×32 rectangle within the foreground uses background velocity in both directions. This is a causal negative control, not an attempt to replicate the complete Avatar flow field. No thresholds are tuned against the result.

## Measurements

The table aggregates the 24 non-endpoint configurations for each variant. MAE is normalized luminance averaged over all pixels and all these configurations. Damaged pixels are summed over configurations, not unique spatial pixels.

| Field supplied | Synthesis | Mean MAE | Pixels with error >0.05 |
| --- | --- | ---: | ---: |
| Exact surfaces | Current | 0.000278598 | 0 |
| Exact surfaces | Projection disabled | 0.004352149 | 7,922 |
| Exact surfaces | Require both memberships | 0.000278598 | 0 |
| Exact surfaces | Owner before static guard | 0.000258889 | 0 |
| Wrong surface region | Current | 0.007274942 | 17,502 |
| Wrong surface region | Projection disabled | 0.010534079 | 25,027 |
| Wrong surface region | Require both memberships | 0.007274942 | 17,502 |
| Wrong surface region | Owner before static guard | 0.007278225 | 17,511 |

Endpoint MAE stays below 0.0005 for every test. Exact-field production output has zero damaged pixels in every test, asserted by the harness. Both negative controls must produce damage, also asserted. Small residuals include ten-bit quantization, interpolation and noisy endpoints.

## Consequence for the correction

Preserve the existing projected ownership mechanism: it prevents substantial damage even with accurate flows. The two small synthesis edits do not solve correspondence failure and must not be promoted as a fix.

The immediate correction belongs before this synthesis boundary: preserve/generate the appropriate surface trajectory through estimation and aggregation, plus endpoint visibility. A downstream owner cannot choose a surface whose motion was removed from both fields. This does **not** establish that synthesis is correct for all deformations, independently moving occluders, blur, subpixel contours or depth ordering. In particular, endpoint-visible trajectories that cross only between the two frames can leave the front/back order underdetermined. No new general depth estimator was tested here.

The synthetic result is an isolating regression, not real-video quality acceptance. Avatar still needs independent landmark/correspondence validation and hidden-frame reconstruction after a proposed upstream correction. No Motion² equivalence or realtime timing is claimed by this test. It compiles shaders and downloads each output; its elapsed time must not be interpreted as playback cost.

## Reproduce

Run `Core/Interpolation/Tools/SurfaceSynthesisRun.sh > /tmp/rift-surface-results.json` from the repository. The wrapper compiles in a temporary directory, cleans it on exit and emits all per-case measurements as JSON. The Swift source intentionally has `.swift.txt` extension: an extra standalone `@main` source inside the existing MVProbe directory would change SwiftPM entry-point discovery. No package edits are needed.
