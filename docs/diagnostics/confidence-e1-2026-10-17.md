# E1 — read-only confidence versus real reconstruction error

Scope: E1 only. No degradation, fallback, feathering, hysteresis, temporal smoothing or reset state is implemented. Production search/selection and the reapplied static-protection shader are unchanged. All quality/performance runs retain `RIFT_STATIC_MOTION_GUARD=1`. The default-off switch is `RIFT_PAIR_CONFIDENCE=1`; it only computes a diagnostic buffer. No shader reads that buffer to change synthesis. Disk output belongs to the offline tool, never the interpolation module.

## Measurements and definitions

Inputs are the existing bounded 49-frame luma windows at 69s, 300s and 18:02, verified against the committed SHA256 manifests. They yield the original **144 adjacent pairs** (48/case), plus **141 real triplets** (47/case): hide index i+1, synthesize it from i and i+2 at its actual relative PTS, and compare against the hidden decoded frame. The real central frame never enters search, synthesis, temporal context or feature calculation. Adjacent-pair signals are measured with the same available external temporal context; triplet synthesis uses **only its two endpoints**.

All three windows depict **animation from the same source film**. The earlier case names do not establish live-action content. Animation is reported both pooled and per window; **live-action has zero samples**, so no live-action predictive performance is claimed.

There are 8,640 nonoverlapping 8×8 blocks per 1152×480 plane, including image borders. Each diagnostic record is computed once after final field assessment, before projection/synthesis, and reused for .25/.5/.75 outputs. Exact enabled/disabled comparisons check pixels, forward/backward fields, reliability and mapping residuals. The observer fires once for each pair; a disabled observer never fires. The engine itself performs no diagnostic readback when there is no observer.

| Signal | Exact operational definition |
| --- | --- |
| Forward/backward inconsistency | Mean of reciprocal closure lengths at the two canonical midpoint inverse anchors; work-plane pixels. |
| Normalized SAD | Mean absolute compensated A/B luma difference over the transported 8×8 block, with the existing exposure offset, divided by transported A's population standard deviation plus 1/1023. Texture uses stable Welford accumulation. |
| Fold indicator | Fraction of five probes (center and four ±3px corners) where either midpoint transport Jacobian determinant is ≤.05. This samples folds; it does not exhaust every pixel. |
| Inversion residual | Mean length of q+.5v(q)−p for the two canonical midpoint inversions using the existing inverse solver; pixels. |
| Temporal-vector disagreement | Mean distance between final central forward/reverse vectors and independent block-search velocities inferred from A→previous and B→next, sign-corrected and scaled by actual PTS intervals to the central pair interval. The external neighbors never include the hidden center. Missing boundary evidence is NaN, not “zero disagreement.” |
| A–B difference | Mean absolute **uncompensated** endpoint luma difference over the destination block, normalized to 0…1. It includes motion/exposure/cut differences. |
| Existing risk comparator | 1 minus mean assessed forward/reverse confidence at the canonical anchors. This existing confidence is observed, not modified. |

All features refer to the **canonical midpoint** and fixed block geometry, rather than being recomputed per requested subframe. Closure/inversion use the block-center anchors; SAD uses the corresponding translated 8×8 footprint. They are diagnostic approximations, not a pixel-exact decomposition of all synthesis paths. Reads outside the image use the existing clamped sampler. The response is each destination block's real **10-bit luma MAE**, not a photometric endpoint minimum or the previous exhaustive oracle.

Temporal-vector acquisition uses extra, offline-only calls to the unchanged block matcher. They do not feed the production estimators or selection. The runtime diagnostic hook accepts those vectors as optional evidence; **the player does not yet acquire them**, so its temporal signal is unavailable. Runtime timing below therefore measures the diagnostic kernel/allocation overhead with missing temporal vectors, not the cost of acquiring live temporal evidence or E2's eventual full pipeline.

## Calibration and validation protocol

For every window, triplet first indices **0…17** calibrate empirical feature distributions; indices **27…46** are held out for evaluation. Indices 18…26 form an embargo. External-neighbor footprints do not overlap across this split. There are 54 calibration pairs, 60 evaluation pairs and 27 embargoed pairs. Pixels within blocks and neighboring blocks are not independent samples; this is a within-film temporal holdout, not independent-title validation.

The combination is a predeclared **equal mean of six empirical mid-CDF ranks**: closure, normalized SAD, folds, inversion, temporal disagreement and A–B difference. Distributions are fit only on calibration signals; unavailable temporal ranks are omitted. Existing confidence is a separate comparator. There is no neural model, dependency installation, label-based weight tuning or use of held-out truth for scoring. Reported coverage thresholds target 1/2/5/10/20/30/50% of calibration blocks; ties and distribution shift can produce different actual coverage.

Correlation is Pearson and tied-rank Spearman against real block MAE. ROC/AUROC use **MAE >16 ten-bit codes** as the primary positive event, with >8 and >32 sensitivity checks. CSV curves report TPR, FPR, precision and marked-pixel coverage at 101 calibration-derived thresholds plus endpoints. Missing evidence is excluded from correlation/AUROC; for operating curves it abstains and remains unmarked, with availability reported. All blocks contain 64 pixels, so block and pixel coverage fractions coincide.

The cut between frames 6 and 7 at 18:02 affects triplets starting at 5 and 6; neither is in the held-out segment. Their forced reconstructions remain in the raw diagnostic data, not evidence that the live player should interpolate a scene cut. Primary reference crops use triplet4, which is **calibration**, and are labeled as such. They show the unchanged engine, real center and a hypothetical marked-block overlay; **actual degraded pixels remain zero**.

## Predictiveness on held-out animation

1,218,240 triplet blocks were measured; the held-out set contains 518,400 blocks (60 pairs). These large block counts are **not** independent trial counts. Pooled high-error prevalence (>16 codes MAE) is 13.92%.

| Signal | Pearson r | Spearman ρ | AUROC, MAE >16 |
| --- | ---: | ---: | ---: |
| Forward/backward inconsistency | .5794 | .4172 | .9298 |
| Texture-normalized SAD | .4066 | .4149 | .9208 |
| Fold fraction | .4317 | .4717 | .8270 |
| Inversion residual | .5371 | .4444 | .8857 |
| Temporal-vector disagreement | .5450 | .4539 | .9109 |
| A–B difference | .7101 | .7709 | .8996 |
| Existing assessed-confidence risk | .4286 | .6500 | .8572 |
| **Six-signal combination** | **.5507** | **.5939** | **.9464** |

A–B difference correlates most strongly with the continuous MAE magnitude, while the combination ranks the primary high-error event best in this holdout. Those are different questions. Combination AUROC by case is .9197 (69s), .8905 (300s), .9983 (18:02). The last figure has only **136 positive blocks** out of 172,800; it must not be read as proof of reliable detection at an arbitrary threshold. Temporal evidence is available for 95% of held-out blocks; the combination omits that term for the remaining boundary pairs.

[Full correlations/AUROC at >8, >16, >32](assets/confidence-e1-2026-10-17/statistics.json) · [ROC curves, animation](assets/confidence-e1-2026-10-17/roc-animation.svg) · [All signal operating curves](assets/confidence-e1-2026-10-17/curves.csv).

| Combination calibration target | Score threshold | Held-out TPR | Held-out FPR | Precision | Held-out pixels marked |
| --- | ---: | ---: | ---: | ---: | ---: |
| Top 5% | .905459 | 38.17% | 1.52% | 80.20% | 6.63% |
| Top 10% | .844213 | 65.11% | 3.91% | 72.95% | 12.43% |
| Top 20% | .718732 | 87.49% | 9.24% | 60.51% | 20.13% |

At the **top-10% calibration threshold**, held-out TPR/FPR/coverage are: 69s **44.38% / 1.82% / 6.00%**; 300s **71.64% / 12.39% / 31.29%**; 18:02 **0% / 0% / 0%**. A high AUROC therefore does not establish transferable calibration: the 18:02 positives are ranked well but all lie below that threshold. At a top-20% calibration threshold, 18:02 TPR is 41.18%, FPR .0226%, coverage .0550%. No threshold was retuned using those held-out labels.

## Coverage on the original 144 adjacent pairs

Values below use the **same globally calibrated triplet score thresholds**, applied unchanged to the original adjacent intervals. They are hypothetical marks, not degraded output pixels. The different frame spacing matters: this is an explicit transfer test rather than an assumption of identical distributions.

| Calibration target | 69s mean pixels marked | 300s mean pixels marked | 18:02 mean pixels marked |
| --- | ---: | ---: | ---: |
| Top 2% | .023% | 2.076% | .279% |
| Top 5% | .221% | 5.561% | .985% |
| Top 10% | 1.045% | **11.241%** | 1.671% |
| Top 20% | 6.720% | 18.951% | 2.544% |

At top 5%, all three **window means** are below 10%, but maximum individual adjacent pairs reach **3.30%, 52.43%, 47.30%**, respectively. The 18:02 maximum includes the forced scene-cut pair. Top 10% maxima are 9.63%, 81.34%, 80.14%. Thus neither setting proves a per-pair <10% limit, and no cap or degradation was applied to make it pass. All thresholds (1/2/5/10/20/30/50%), both interval lengths, means/maxima and individual-pair coverage are preserved in [coverage.json](assets/confidence-e1-2026-10-17/coverage.json) and [per-pair CSV](assets/confidence-e1-2026-10-17/per-pair-coverage.csv).

**Visual checks:** at 300s the hypothetical mask covers much of the fragmented head; it does not repair it. At 69s, the blurred crossing contour can differ visibly from the real center while remaining unmarked at this threshold—pixel-MAE discrimination is not a guarantee of catching every visible contour artifact. At 18:02, the reference bird remains close and largely unmarked. Saved crops show A, B, unchanged prediction, real central frame and hypothetical overlay. [69s](assets/confidence-e1-2026-10-17/avatar69/crossing-bison-comparison.png) · [300s](assets/confidence-e1-2026-10-17/avatar300/face-contour-comparison.png) · [18:02](assets/confidence-e1-2026-10-17/anime1082/bird-contour-comparison.png). All seven original ROIs are preserved. These are luma previews at uniform ×1.8 brightness, not HDR/color validation.

## Behavior, static controls and runtime cost

**All 573 synthesized outputs are identical with the diagnostic switch off/on**, including the associated forward/reverse fields, reliability and mapping residuals. The three canonical adjacent-pair midpoint PNGs also exactly reproduce the pre-E1, D-enabled saved outputs. A deterministic flat test asserts zero diagnostic signals and one observer call for a three-subframe batch. Existing dense and native regression fixtures pass with diagnostics enabled. The unchanged static-protection harness again passes all **12 stationary controls at exactly 0% jitter**, defined consistently with D as the fraction exceeding one ten-bit code from the stationary source. This is not a long-sequence perceptual jitter measurement.

No blocks, including those called “unreliable,” receive different synthesis. **Trusted-block output is identical because every block's output is identical; degraded fraction is exactly 0%.** Search, selection and D's static shader were not edited. The only production-file additions are the optional read-only diagnostic helper and its once-per-pair hook.

Fresh sequential 45-second native GUI sessions, **Release / actual Apple M4**, use decode + `motion4x` + Strong, D guard enabled, and identical renderer telemetry. The first 10 seconds and startup calibration planes are excluded; p95 uses empirical nearest rank. Actual calibrated work plane is **736×320**, source 3832×1600 HEVC. Each session records five `SUPERRES mode=strong ... processed=true bypass=false` samples. This confirms effective Strong processing at those samples; continuous absence of adaptive bypass is not established.

| Pair diagnostic flag | Samples | p50 ms | p95 ms | Maximum ms |
| --- | ---: | ---: | ---: | ---: |
| Off | 810 | 32.709834 | **43.147458** | 48.453833 |
| On | 813 | 32.296000 | **43.715041** | 51.157125 |

Enabled p95 is **+.567583ms** versus the fresh control, and **+1.485041ms** versus the specified 42.23ms reference: below the **44.23ms** limit by .514959ms. This is a finite-session result, not a thermal guarantee. The original 35ms goal remains unmet. Raw logs, filtered pair CSVs and [performance.json](assets/confidence-e1-2026-10-17/performance.json) are preserved.

**Timing scope:** whole `interpolatePair` under concurrent decode/Strong/presentation load, not summed decode/render or display latency. GUI runs compute the diagnostic buffer without an observer: no disk dump/readback is included. **Offline temporal-vector acquisition is not included**, since the player has not been wired to acquire it. The score study uses 1152×480 while GUI timing uses the existing calibrated 736×320; pixel-unit score calibration at that runtime resolution is also unproven. Therefore this does **not** establish E2's full runtime budget or a deployment-ready confidence threshold.

## Reproduction and stop point

Build `swift build -c release`, then run `MV_CONFIDENCE_CHECK=1 RIFT_STATIC_MOTION_GUARD=1 .build/release/MVProbe`. Restore the existing bounded source fixtures from their committed per-case archives if necessary. For each case:

```sh
RIFT_PAIR_CONFIDENCE=1 RIFT_STATIC_MOTION_GUARD=1 \
MV_CONFIDENCE_WINDOW="$PWD/docs/diagnostics/assets/trajectory-survival-2026-10-17/avatar69" \
MV_CONFIDENCE_OUTPUT="$PWD/docs/diagnostics/assets/confidence-e1-2026-10-17/avatar69" \
.build/release/MVProbe
```

Run `python3 Core/Interpolation/Tools/ConfidenceReport.py` using the already available NumPy/Pillow environment to reproduce calibration, statistics, curves, coverage, masks and crops. The analysis has assert-based checks for ties, perfect/reversed AUROC, constant correlation, dataset/split sizes and finite signals. No app dependency was added. `signals.zip` per case losslessly preserves all 95 raw per-pair tables; manifests give column order, PTS, temporal availability, observer counts and identity counts. Original decoded work-plane source hashes remain in the preceding fixture manifests. No whole source movie is copied or transcoded.

**E1 complete; E2 not started.** The signals do predict real block reconstruction error on this within-film animation holdout, and the combination improves primary-event ranking over assessed confidence. Still unproven: independent-film/live-action transfer, score calibration for native adjacent spacing and runtime work-plane resolution, reliable detection of every visible low-contrast deformation, a per-pair <10% marking bound, live temporal-evidence acquisition cost, the complete E2 +2ms budget, HDR/color fidelity, long-session jitter/performance and other chips. High AUROC alone is insufficient evidence to enable degradation.
