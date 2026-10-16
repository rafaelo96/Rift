# Preserving affine deformation inside patches — experimental

Scope Core/Interpolation and its tools. Apple M4. No UI, source movie, stack or dependency changes. Not enabled by default and not packaged into the habitual app.

## Representation and controlled evidence

The previous failed experiment fit an affine model to nine original motion seeds but collapsed it to a single translation at the patch center. The new opt-in `RIFT_PATCH_AFFINE=1` keeps the spatial derivatives, uses them when scoring the whole patch, and evaluates each candidate at its actual pixel position during aggregation. The original translational hypothesis remains available. Affine proposals require <=1 original-work-plane pixel fit residual across all nine original blocks; this is a model-consistency heuristic, not proof of surface identity. Jacobian textures are allocated only for this experiment, reused per direction/level, and remain bounded. Synthesis is unchanged.

Known384×256 scene:0.5rad rotation plus(-96,-24) translation, exact analytic block seeds quantized to half-pixels. Interior visibility restrictions apply to both original motion and midpoint reconstruction. The correct midpoint uses inverse((I+R)/2).

| Route | Vector MAE(px) | Midpoint MAE(10-bit codes) |
|---|---:|---:|
|Previous patch baseline|17.02769|86.17749|
|Original center seed restored|5.88472|14.22320|
|Affine seed collapsed to center|5.10701|12.86054|
|Affine patch and aggregation|0.08210|0.86059|
|Separate older pixel-LK route|2.80302|8.17931|

The explicit <3px vector gate fails before and passes with affine patches. Small0.2rad fixture also improves to0.08732px /0.70731 codes (before detail verification). This isolates a real representation/refinement defect when reliable motion is supplied; it does not establish reliable motion estimation for Avatar.

## Independent acceptance checks

`MV_PATCH_AFFINE_CHECK=1` protects three cases:
- A stored temporal/joint score must not be compared directly against a central-only SSD. Initially the model selected0px instead of a perfect8px central match (exit133). Recompute the incumbent's central cost before comparing.
- A discontinuity between block-motion layers must not become a continuous affine model. The Jacobian remains zero in the boundary fixture.
- A match favored only by the softened analysis image must not override original-detail evidence. Initially this fixture selected0 instead of8px (exit133). New proposals must also reduce SSD on the pre-analysis-blur work-plane originals, with exposure offset accounted for. This is not native4K detail verification.

Native NV12/P010 endpoint, chroma, metadata, held/moving-context and invalid-context checks pass with the flag. Dense layered visibility, translation, held/noisy neighbors, invalid input, deterministic output and intrusive observer equality checks pass. Illumination tests and default-route regressions also pass. No assertion was relaxed.

## Real-scene gate remains unmet

Same source and settings, lambda1, temporal gate0,1152×480. Current production confidence route, not the older full-resolution temporal-assessment prototype.

| Hidden-frame references | Current | Affine with detail verification |
|---|---|---|
|69s pair1|4.62505|4.60913|
|69s pair2|4.69168|4.68439|
|69s pair3|5.80404|5.81212|
|300s pair1|23.35261|23.35345|
|300s pair2|20.98821|20.97348|
|300s pair3|34.38383|34.38048|

Extended69s:13 hidden references, only4 improve; average5.536486 ->5.542162 (small regression). Before detail verification5/13 improved, average5.541186. The controlled affine fix is substantial, but real motion seeds often do not describe the missing foreground surface. Thus this is a useful experimental capability, not an accepted general quality improvement. Do not enable it in the habitual app yet or declare Motion² equivalence.

Short native-input/output cost comparison uses `MV_PROFILE=economy MV_PIPELINE=1 MV_PAIR_OUTPUTS=3 MV_PAIR_CONTEXT=1 MV_PAIRS=12 MV_SEEK_SEC=69 MV_DUMP=0` and affine flag0/1, sequentially, same binary. The harness now passes real neighboring CVPixelBuffers and interval ratios, falling back to two frames only at window edges. Counts are asserted at three generated outputs. Decode, display/Strong and sustained thermals are excluded; no full-app fluency claim is justified. The separate earlier two-frame-only trial should not be presented as a four-source runtime measurement.

Artifacts/logs: `/tmp/rift-affine-model-final{69,300}.log` (before detail check), `/tmp/rift-affine-detail-{before,after,oracle,regression,native,lighting}.log`, `/tmp/rift-affine-detail-extended69.log`, `/tmp/rift-affine-detail300.log`, `/tmp/rift-current-extended69.log`, `/tmp/rift-affine-context-budget-{base,model}.log`. The large synthetic gate command is `MV_DENSE_ROTATION=1 MV_ROTATION_LARGE=1 RIFT_PATCH_AFFINE=1 .build/release/MVProbe`.

Next remaining task is correspondence: derive and retain supported surface/deformation candidates from images when original block seeds do not contain that motion. Repeating global photometric replacement, rigid-region voting, or center-only reseeding is not justified by these results. Keep the objective open until both real visual quality and sustained runtime meet it.
