# Patch-stage tracing — 2026-10-16

Scope: Core/Interpolation, diagnostic callback and MVProbe only. `diagnosticObserver` synchronizes and downloads completed RGBA32Float stage fields; unset by default. It is intentionally intrusive and its timings must not be used as runtime budget evidence. The callback receives data; disk I/O belongs to the tool. Dense regression verifies traced/untraced pixels and forward/backward fields are byte/value identical.

Command: `MV_DENSE=1 MV_DENSE_PATCH=1 MV_DENSE_FOUR=1 MV_DENSE_TRACE_PAIR=4 MV_DENSE_GROUND_TRUTH=1 MV_DENSE_EVIDENCE=1 MV_LAMBDA=1 MV_TEMA=0 MV_PAIRS=6 MV_SEEK_SEC=300 MV_DUMP=0 MV_DENSE_OUTPUT=/tmp/rift-current-trace300 .build/release/MVProbe`.

Current integrated route, 1152×480, Apple M4: pair4 still has 40410 folded positions and 360006 inverse residuals over1px (diagnostic counters, not visual-error percentages). Forty-two stage snapshots capture seeds, search, propagation, aggregation, expansion and assessment in both directions. There is no temporal-selector pass in this pair: neighbors are classified as held poses.

At source location(955,268) in the forehead region: coarse seed(-1.5,-5.5) native pixels; coarse patch propagation(-111.30,-15.05); final aggregate(-103.04,-58.77). At(950,385) the final vector is(-142.95,-13.11). Visually identifiable facial features move roughly(-220,-70), with local pose change; this is a manual approximate anchor, not exact per-pixel ground truth.

Across the entire coarse forward seed, most-negative x is-96.0; after coarse search-154.7; final forward field-175.9. Thus no candidate in those recorded outputs reaches the approximate facial displacement. Evidence favors missing initialization/candidates for this particular region, not a synthesis-only problem. It does not prove every deformation has this cause. Earlier globally deeper search was not a general solution and remains rejected as a blanket fix.

Artifacts: `/tmp/rift-current-trace300` and `.log`; observer regression `/tmp/rift-trace-check.log`. Next controlled hypothesis: an independent coarse photometric proposal may recover a correspondence absent from regularized seeds; evaluate it without changing synthesis or visibility and reject if it only lowers photometric error while degrading shapes.

## Independent coarse proposal: rejected

An opt-in compile-time `RIFT_PATCH_GLOBAL=1` experiment supplies a coarse sparse photometric proposal independently of the block seed. It recovers candidates close to the approximate facial displacement: coarse(-215.37,-68.69), final(-220.36,-69.35). However, it also introduces implausible unrelated matches (final minimum x about-799.5) and worsens fragmentation. Three 300s hidden references: current23.35261/20.98821/34.38383; global24.70225/21.88309/44.65329. At69s: current4.62505/4.69168/5.80404; global5.25465/5.52557/6.42376.

A mutual independent reverse-search check (return within two coarse pixels) was also tested. It fails the overall quality gate: 300s22.41598/24.18352/47.67503;69s4.72658/4.71569/5.63838. Correct-looking large vectors exist, but accepting one photometric winner still loses surface identity. This is not a solution and must not be enabled in the app. The experiment is preserved in Git history and removed from active source afterwards.

Permanent bounded evidence: `assets/patch-stage-2026-10-16/` contains the two central inputs, current midpoint, rejected global midpoint and stage measurements at three anchor positions, including all forward stages' minimum-x displacement. These are small grayscale diagnostic frames; the source movie is unchanged. Raw full field dumps remain temporary. Native-scale manual facial anchor is only an approximate diagnostic reference, not exact optical-flow ground truth.

The observer regression passes with exact traced/untraced output and flow equality. No app package update is made for these rejected proposals. Next implementation requires surface-aware retention/selection of distinct proposals rather than more unconstrained global replacements; every improvement must be checked against both windows and runtime budget.
