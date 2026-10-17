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

## Follow-up: shared color cost in Metal — rejected for deployment

Implemented and measured an isolated opt-in Metal variant: RGBA work pyramid carries Y/U/V; patch search/propagation uses summed YUV SSD; aggregation uses local YUV residual plus patch penalty. Luminance gradients still propose subpixel updates, which the combined objective accepts/rejects. Temporal evidence remains luminance-based. Central UV is validated and uploaded from bounded diagnostic buffers only; no runtime caller was changed to enable it. This is a controlled translation-patch experiment, not a complete color optical-flow solver.

Regression fixture: equal periodic luminance, known8px translation, competing16px seeds. Existing luma route has8.0px flow error, color route0.0px; invalid chroma input rejected. Existing dense checks pass, including endpoints, static, deterministic traces, known translation and held/noisy neighbors. Release probe builds successfully.

Same executable, same Avatar300s six adjacent pairs and five hidden-frame reconstructions, Apple M4: four-source hidden pairs1/2/3 have MAE23.35261/20.98821/34.38383 without color versus23.48763/22.38853/34.23052 with color. Measured analysis+synthesis times for those references rise from14.48/13.57/14.31ms to39.05/40.37/41.15ms. Diagnostic CPU chroma extraction precedes those timings; decode, display and production native-color reconstruction are excluded. Thus these timings understate full playback cost. Adjacent pair4 midpoint still visibly fragments the face and clothing.

The combined objective is not a general visual improvement and does not meet the budget in this form. The analytic fixture is not sufficient acceptance evidence. Preserve the experiment in Git for reproducibility, then remove its opt-in runtime API/shader path from the active source. Keep the validated export/seed diagnostic and this record. Source-color information can distinguish one ambiguity but does not solve missing non-rigid surface correspondences.

Permanent compact measurements: `assets/patch-stage-2026-10-16/chroma-metal-results.json`. Reproduce in the experimental commit with `MV_CHROMA_CORRESPONDENCE_CHECK=1`; the real diagnostic uses `MV_DENSE_COLOR=1` alongside existing patch/four/ground-truth flags.

The next investigation must address correspondence topology across the changing pose, with independently visible landmarks and forward/reverse surface consistency; do not repeat a wider photometric search or promote lower endpoint residual as image-quality evidence.
