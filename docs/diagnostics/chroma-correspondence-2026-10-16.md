# Chroma correspondence: bounded diagnostic, not a shipped fix

Scope: Core/Interpolation diagnostic tooling. The native estimator currently matches luminance; native UV channels are used at reconstruction. This experiment asks whether UV distinguishes plausible face/background matches. NumPy/Pillow are existing offline tools, not runtime dependencies. No complete source video is copied or transformed.

## Verified inputs

`MV_DIAGNOSTIC_CHROMA_CHECK=1 .build/release/MVProbe` passes constant-channel extraction/resampling for NV12, P010 and P210, including actual padded row strides and separate UV channels. Diagnostic extraction exports central-frame UV at half work-plane dimensions. The luma PNG quantizes ten-bit values to eight bits, so Python costs are approximations to native costs.

`python3 Core/Interpolation/Tools/chroma_correspondence_probe.py --selfcheck` passes a deliberately ambiguous equal-luminance pair: two candidates have zero luminance cost, while UV selects the known 8px translation. CLI rejects mismatched dimensions, non-grayscale maps and input outside the bounded size limits.

## Real Avatar pair at 300s

The stored adjacent pair4 is 1152×480. A 5×5 UV sample at source(950,385) differs by about1.01 code units from a plausible facial destination at displacement(-220,-70), versus8.03 at the current wrong-background destination(-103,-59). These destinations are manually approximate landmarks, not ground-truth optical flow. Other points do not separate so cleanly.

A global coarse 8×8-patch search with luminance versus luminance+UV produced seed candidates for both directions. Equal channel weights are an ablation, not a calibrated production metric. Each proposal was injected into pair4 only and processed by the same existing native four-source refinement and synthesis. Both resulting midpoints remain severely fragmented. Seed-only color matching is therefore rejected as a sufficient fix.

Counts from the same experiment (not quality ground truth): luminance seed run folded45916/unsupported231256; color seed run folded46619/unsupported229680. Lower endpoint residual on some supported pixels does not establish correct geometry. Do not promote these proposals into the app.

## Where information is lost

Per-stage fields are preserved in `assets/patch-stage-2026-10-16/chroma-stage-traces.json`. Samples use nearest grid points and represent different patch centers across scales; do not interpret a single row as exact tracking of one surface. Some wrong choices are already present in initialization; others replace a plausible candidate during aggregation.

An independent coarse aggregation ablation evaluates the same four propagated candidates with local3×3 Y residual versus Y+UV residual, retaining the stored luminance patch penalty. At integer coarse source(116,32), the luminance-proposal run selects native(-96,-32) with Y but(-215.37,-68.69) with Y+UV. The latter is near the approximate facial displacement. Two other inspected points do not show the same recovery; color-derived proposals also fail this point. The input blur/quantization and CPU bilinear implementation make this an approximate diagnostic, not byte-identical Metal parity.

## Decision

Do not discard chroma merely because a seed-only experiment fails: subsequent native search and aggregation still ignore it. The next isolated hypothesis is a shared Y/UV correspondence objective during candidate evaluation and aggregation, tested on known-surface ambiguity and multiple real reference pairs before a default runtime change. The missing/incorrect proposals and non-rigid pose changes remain separate requirements. Full affine patches already solve the analytic seeded rotation fixture but have not improved the real validation set broadly enough.

Measured here on Apple M4. Python coarse proposal generation took about0.37s offline; this is neither realtime nor a projection of Metal cost. No Motion² equivalence is claimed. The app remains on the previously validated runtime route.

Reproduce the proposal: `python3 Core/Interpolation/Tools/chroma_correspondence_probe.py /tmp/rift-chroma300 --out /tmp/rift-chroma-proposals300`. Diagnostic injection: set `MV_EXTERNAL_SEED_PAIR=4` and `MV_EXTERNAL_SEEDS_PREFIX=/tmp/rift-chroma-proposals300/luma` (or `/color`) with the existing `MV_DENSE_FOUR=1`, pair300s probe. Invalid seed byte counts are rejected before loading vectors.
