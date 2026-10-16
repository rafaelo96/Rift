# Known affine seed loss — 2026-10-16

Core/Interpolation only; Apple M4. Extend the existing analytic rotation fixture with384×256,0.5rad rotation and displacement(-96,-24). Forward and backward block seeds come from the exact transform (half-pixel quantization). Midpoint truth uses inverse((I+R)/2), not rotation(angle/2). Score only source/end and midpoint inverse source/end positions safely inside both images. The large patch case asserts vector MAE<3px; this is a local regression gate, not Motion² acceptance.

Baseline: per-pixel LK vectorMAE2.80302, midpointMAE8.17931; patch vectorMAE17.02769, midpointMAE86.17749. Both receive accurate seeds. Earlier preliminary scores21.55/104.92 used a less restrictive ROI and are superseded. Diagnostic CLI: `MV_DENSE_ROTATION=1 MV_ROTATION_LARGE=1 .build/release/MVProbe`; baseline correctly fails this new regression (exit133).

Hypothesis: finer pyramid levels overwrite their initialization from expanded coarse flow and never reconsult original block seeds. Adding an original-seed alternative reduces vectorMAE to5.88472/pixelMAE14.22320 but still fails. Fitting a local affine seed from nine original blocks with <=1px fit residual, then reducing it to a translation at the patch center:5.10701/12.86054, still fails. Thus better center initialization alone is insufficient; the patch scorer still represents the region as one translation.

Real four-neighbor references for affine center reseeding:69s4.89857/4.91008/5.99613 versus current4.62505/4.69168/5.80404 (all worse);300s22.91140/20.11421/34.45474 versus23.35261/20.98821/34.38383 (two improve, third regresses). Not shipped.

Logs `/tmp/rift-affine-oracle-{before,reseed,reseed-fit}.log`, `/tmp/rift-affine-reseed{69,300}.log`, `/tmp/rift-affine-reseed-regression.log`. Next representation experiment must preserve the supported affine deformation across each patch when evaluating and aggregating it, instead of collapsing that evidence to one center vector. Synthesis and file access remain unchanged.
