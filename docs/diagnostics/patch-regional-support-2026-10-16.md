# Regional support for two coarse proposals — rejected

Scope Core/Interpolation, Apple M4, 1152×480. Hypothesis: an independently generated coarse trajectory should replace the current trajectory only if it explains coherent surrounding patches, not merely an isolated duplicate. Preserve the original candidate and alternative separately, compare central SSD plus the two lowest neighboring support costs (four 8×8 patches displaced by8px); leave synthesis unchanged.

Synthetic96×64: an incorrect32px trajectory and correct8px trajectory have identical8×8 central patches. Baseline propagation picks32 (exit133); regional selector picks8. Existing dense and native8/10-bit regressions pass with the experimental route.

Real hidden-frame references, same lambda1/temporal gate0 and current integrated confidence route:

| Window | Current | Regional proposal |
|---|---|---|
|69s|4.62505 /4.69168 /5.80404|5.08528 /5.34666 /6.05426|
|300s|23.35261 /20.98821 /34.38383|22.31925 /17.13133 /45.52063|

Pair4 at300s still severely fragments: folded47285, unsupported248946, inverse residual over1px368187 (diagnostic counts, not visual-error percentages). At coarse patch(29,8), current(-111.30,-15.05) native px versus alternative(-208,-80). The regional criterion retains the first despite the second being near the manually estimated facial displacement; surrounding motion cannot be explained by the same rigid translation. Manual anchor is approximate, not flow ground truth. This indicates that increasing rigid spatial support is not a sufficient surface model; it does not prove every patch requires an affine model.

Alternative field histogram: static(0,0) dominates109 coarse patches; moving facial candidates span(-176…-240,-32…-96) and are sparse. Global translation voting alone would not select a general surface deformation. No replacement shipped. Experimental code and fixture preserved in41c9933 and reverted in216aec2. Permanent rejected image: `assets/patch-stage-2026-10-16/rejected-regional-midpoint.png`.

Logs `/tmp/rift-regional-{before,after,regression,native}.log`, `/tmp/rift-regional{69,300}.log`. Next isolation uses known affine motion and exact analytic block seeds to distinguish deformation refinement from missing correspondence.
