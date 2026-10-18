# Temporal visibility offline Implementation Plan

> For agentic workers: execute inline using executing-plans; the user already authorized starting this experiment. No subagent or application integration is needed.

**Goal:** Compare a bounded four-source visibility reconstruction against frozen current pair fields, without modifying Frame+.

**Architecture:** A CPU Swift renderer consumes existing assessed central fields and separately estimated neighbor fields. An offline MVProbe entry point supplies immutable data and records the unchanged baseline. Python reuses the F1 structural metric for reporting. No temporal state enters production.

**Tech Stack:** Swift/Foundation/Metal engines already in project; existing NumPy/Pillow for report only.

## Global Constraints

Only Core/Interpolation/Tools and diagnostics/plans. No production Swift/shader, UI, search/selection, static policy or E2 change. No dependencies or complete source-video copying/conversion. Flags absent = no experiment. Costs are offline diagnostic costs, not playback acceptance. Parameters frozen before real-image measurement.

## Task 1 — classifier/renderer with deterministic synthetic checks

Files: create `Core/Interpolation/Tools/TemporalVisibility.swift` and `TemporalVisibilityCheck.swift`.
Interface: `TemporalVisibility.render(first:last:before:after:forward:backward:left:right:baseline:decisions:t:beforeInterval:afterInterval:enabled:)` returns pixels, per-pixel state and selection mask. Fields are `[SIMD4<Float>]`, image values `[Float]` in0…1023. Auxiliary left fields mean before→A / A→before; right fields mean B→after / after→B.

- [ ] Check deterministic static/translation/cover/uncover with analytic layer motion, auxiliary mismatch, absent neighbors, endpoints and disabled equality.
- [ ] Implement source projection with reciprocal neighbor support, central trajectory agreement and source visibility classification. Thresholds:1.5px closure/agreement, .02 normalized3×3 photometric error, .1 support. Bilinear splat coverage; compatible contributions combine pixel values, not different motion fields. Initial inverse-only implementation failed the analytic8px cover/uncover case(max error612 codes) and was replaced before real-image measurement. The check also exposed a missing contour-coverage veto: a unilateral background cannot fill a pixel covered by a geometrically paired central trajectory even when temporal patch evidence is absent at that contour. Such pixels retain baseline until supported paired evidence exists. Held neighbors provide no independent evidence. These are conservative experimental constants, not calibrated probabilities.
- [ ] Protect current still pixels. A baseline owned/fallback pixel may use a supported paired or unique unilateral hypothesis; competing surfaces and unsupported paths leave it unchanged. No fallback degradation or field smoothing added.
- [ ] Build/run self-checks and commit tool before evaluating real scenes. If a check fails, fix implementation rather than tune real-scene parameters.

## Task 2 — frozen baseline and bounded replay

Files: create `Core/Interpolation/Tools/TemporalVisibilityDiagnostic.swift`, modify only the MVProbe dispatch in `main.swift`.

- [ ] Add `MV_VISIBILITY_WINDOW`, `MV_VISIBILITY_OUTPUT` and `MV_VISIBILITY_RECONSTRUCT=1`; absent flag preserves baseline exactly.
- [ ] Validate source sizes, SHA256 and strictly increasing PTS. Use independent central and auxiliary engine instances; retain at most four adjacent auxiliary field pairs.
- [ ] Reuse49-frame69s/300s/18:02 fixtures and bounded49-frame991s/1201.7s exports. For span2 truth, do not pass the hidden central frame into either renderer or its auxiliary fields.
- [ ] Compare current production baseline against the tracing path and assert byte equality. Assert central fields stay unchanged, disabled output exact, current still pixels exact, and no temporal replacement without a supported neighbor.
- [ ] Save all48 adjacent and47 hidden-central comparisons per window, class/selection/changed coverage, timing scope, hashes and held/cut annotations. Distinguish pair output without real middle truth from span2 reconstruction with real middle truth.

## Task 3 — measurements and decision

Files: create `Core/Interpolation/Tools/TemporalVisibilityReport.py`, diagnostics and assets under `docs/diagnostics/*temporal-visibility*2026-10-18*`.

- [ ] Reuse F1 MAE/Sobel/SSIM formulas; existing principal masks for69/300/18:02. New scenes use explicitly labeled inspection ROIs rather than claiming validated defect masks. Report inside and outside, changed vs unchanged, median/p95/max substitution by case.
- [ ] Exclude known cuts from continuous-motion quality aggregates and report them separately. Label retained animation poses and overlapping-window limitations.
- [ ] Inspect A/B/current/candidate crops including largest changed/error pairs, not only favorable examples. Reject merely swapping tearing for double outlines, frozen slabs or blur.
- [ ] Record acceptance or rejection, unverified native color/temporal stability/runtime performance. Do not integrate unless a separate, supported next task is authorized. Commit measurements separately from implementation.
