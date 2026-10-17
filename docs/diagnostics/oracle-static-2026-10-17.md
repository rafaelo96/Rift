# Oracle injection and static protection — 2026-10-17

**Final disposition:** A completed. B reproduced and tested, but **no correction accepted**: the first candidate regressed static noise, and the second regressed one existing reference. Both were removed from the runtime. Search and selection remain untouched. The p95<35 ms acceptance condition is also unmet. This is an experimental result, not a resolved quality bug.

## A — final-field oracle experiment

Only Core/Interpolation and diagnostic evidence are in scope. Search, propagation, temporal selection, aggregation, UI and other modules are unchanged. Apple M4; `swift build -c release`. Baseline engine: `fb62a93` plus opt-in diagnostic plumbing, before any static-protection correction.

`RIFT_DENSE_ORACLE=1` permits an offline callback to replace the final assessed fields just before projection/synthesis. The player never installs that callback. Normal launches have no callback and the flag defaults off. The test writes the exhaustive integer reference into each **evaluable sampled 8×8 source patch**, and its negative into the corresponding transported reverse patch. Unsampled gaps and z/w confidence/visibility remain unchanged. Reverse-footprint collisions use deterministic point order. This is the requested sparse reference substitution, not a complete or semantically verified oracle field.

Three outputs per pair: t=0.25/0.5/0.75. These runs use primary adjacent pair4 from each persistent window. Original decoded work-plane luma is preserved at 10 bits; PNG previews are 8-bit, with the same brightness multiplier for all comparison columns. No complete source movie is copied or converted.

| Case | Evaluable source patches | Changed output pixels, t=.25/.5/.75 | Visual outcome at midpoint |
| --- | ---: | --- | --- |
| 69s | 50 | 1118 / 1579 / 1167 | **Worsens locally**: small new square/edge fragments in the foreground and background bison. The large blurred silhouette remains similar. |
| 300s | 25 | 1982 / 2408 / 2217 | **No material improvement**: head, face and clothing contours remain severely fragmented; scattered substitutions do not restore the face. |
| 18:02 | 41 | 173 / 238 / 227 | **No visible overall change** at this crop scale: bird and landscape remain very close to the current engine. Tiny pixel changes are not evidence that a deformation disappeared. |

The categories concern these saved sparse-injection crops, not every pixel/scene in the movie. The current-field mask is sparse, confidence was deliberately retained, and integer patch minima are not physical motion truth. Failure of this experiment does not prove that a complete correct motion field would fail.

[69s comparison](assets/oracle-static-2026-10-17/avatar69/oracle-comparison.png) · [300s comparison](assets/oracle-static-2026-10-17/avatar300/oracle-comparison.png) · [18:02 comparison](assets/oracle-static-2026-10-17/anime1082/oracle-comparison.png)

Disabled-flag runs assert equal pixels and both final fields against ordinary synthesis at all three times; enabled and disabled runs also have identical unmodified reference-engine PNGs. Midpoint PNGs reproduce the preceding phase1 evidence exactly. See `step-a.json`.

Replay a case after building Release:

```sh
RIFT_DENSE_CANDIDATES=1 RIFT_DENSE_ORACLE=1 \
MV_TRAJECTORY_REPLAY="$PWD/docs/diagnostics/assets/trajectory-survival-2026-10-17/avatar300" \
MV_TRAJECTORY_ORACLE_OUTPUT="$PWD/docs/diagnostics/assets/oracle-static-2026-10-17/avatar300/oracle-on" \
.build/release/MVProbe
```

Use `RIFT_DENSE_ORACLE=0` and a separate output directory to verify inert injection. The prior fixture runner restores lossless source planes if they have not yet been extracted. Output data needed for offline B are final `forward.f32`/`backward.f32` and exact `source0.u16`/`source1.u16`; these are ignored local intermediates, reproducible by the command.

## B — reproduction before correction

The six prior samples are reproduced with the exact production upload, projection and synthesis kernels, using saved final fields. Baseline midpoint PNGs are **byte-identical** to normal engine PNGs for all three cases. Compile-only instrumentation in the offline harness records each predicate without adding a diagnostic kernel to the application. Predicate values are in `six-static-predicates.json`.

The existing protection requires three relative point-intensity differences to pass a 1/16 brightness bound, followed by a fourth comparison against the compensated endpoint difference plus one 10-bit code value. Every recorded margin is <=0 in all six samples, so all four tests pass. Fields have length>1px, forward/reverse closure<1px and confidence>0.5, yet the existing moving-field exemption is disabled because the exposure offset is **zero**. Thus it overwrites compensated coordinates with p,p.

A deterministic cosine texture translated exactly4px reproduces this ambiguity: at endpoint-intensity crossings A(p)==B(p), while the true halfway sample is different. With exact reciprocal fields and confidence1, current synthesis freezes960/3840interior pixels (25%), mean inverse-source error0.5px and normalized pixel MAE0.00318246. This is a failing known-motion control, not an inference from movie appearance. Baseline and candidate are initially identical before a correction.

The same harness includes stationary content, zero or intentionally wrong reciprocal moving fields, and +/-1 ten-bit code noise. Its jitter metric is the fraction of interior pixels differing from the stationary source by **more than one10-bit code value**; the required limit is<1%. This does not by itself measure multi-frame perceptual shimmer.

The opt-in timing tap records whole `MotionCompensator.interpolatePair` latency under GUI playback load. It defaults off; diagnostic output is excluded from the latency sample. The saved sessions used the earlier CSV tap. The final tap uses `RIFT_PAIR_TIMING=1` and emits `RIFT_PAIR_TIMING,...` to stderr, so the caller redirects diagnostics and the interpolation engine does not open/write files. Decode and Strong can be active concurrently, but this measurement does not add decode's separately executing duration to interpolation time or measure display-refresh latency. Preserve that distinction when reporting p95.

## B — candidates, measurements and rejection

One candidate was tested at a time, with a reset to the baseline shader between experiments. There were no changes to motion search, candidate selection, blend weights, or temporal state.

1. **Quantization-budget exemption — rejected.** For zero exposure change, retain supported reciprocal motion if its 3×3 patch fits within one code value of the static patch. This recovered the six sampled lookups and fixed the exact-translation fixture, but an added stationary quantization-noise control with an intentionally wrong reciprocal field produced **12.5% jitter**, versus zero before. The candidate was removed. Preserve it only as `rejected-quantization-guard.patch` and its measurement folders; do not reintegrate that rule.
2. **8×8 patch evidence — rejected.** Offline measurements showed that sample69/51 has slightly worse compensated cost in 3×3, yet better cost over its 8×8 support. The second candidate therefore required supported reciprocal flow plus an 8×8 compensated L1 cost below80% of the static-patch cost. Noise-level ties remained protected. It recovered all six lookups, fixed known motion, and passed twelve stationary controls. However, one existing real reference regressed; therefore this candidate was also removed, rather than averaging the regression away.

The second candidate remains as an **offline shader snapshot** (`rejected-patch-guard.metal`) and an exact source patch for auditing the measured temporary test binary. The final `DenseMotionShaders.swift` and `DenseMotionPrototype.swift` are byte-identical to checkpoint `1d1ae55`; neither candidate is enabled or retained in those runtime sources. The surviving changes are diagnostic tools/evidence and the opt-in timing tap.

### Exact six-sample condition

At zero exposure offset, the original `still` condition is the conjunction of:

- `16*abs(A(p)-B(p)) <= A(p)+B(p)`;
- `16*abs(A(q0)-B(q0)) <= A(q0)+B(q0)`;
- `16*abs(B(q1)-A(q1)) <= B(q1)+A(q1)`;
- `abs(A(p)-B(p)) <= 2*abs(A(q0)-B(q1)) + 1/1023`.

All four margins are nonpositive in each of the six captures. The moving-field exemption additionally requires nonzero exposure offset, so it does not apply to any of them. Forward/reverse flow lengths exceed1 px, closure is below1 px and confidence exceeds0.5. The existing final `if(still)` then replaces q0/q1 with p/p. Exact margins, confidence, distances and destination pixels are saved in `six-static-predicates.json`; this is a predicate reproduction, not inference from a screenshot.

| Case / sampled point | Forward / reverse length, px | Closures, px | Original still | Second candidate still |
| --- | --- | --- | --- | --- |
| 69 / 7 | 3.300 / 3.549 | .250 / .252 | true | false |
| 69 / 24 | 37.312 / 37.520 | .225 / .215 | true | false |
| 69 / 47 | 40.983 / 41.163 | .383 / .337 | true | false |
| 69 / 51 | 44.987 / 44.975 | .025 / .026 | true | false |
| 1082 / 0 | 2.036 / 2.456 | .420 / .431 | true | false |
| 1082 / 29 | 1.320 / 1.363 | .072 / .078 | true | false |

The second candidate's final offsets agree with the original compensated inverses at those samples. That proves recovery of the estimated lookup, not the physical correctness of the estimated vector. These are six **sample points**, four in69s and two in1082s, not six independent sequences. None is in the300s face ROI.

### Synthetic and stationary controls

| Metric | Baseline | Second candidate |
| --- | ---: | ---: |
| Known4px translation: frozen interior pixels | 960/3840 (25%) | 0/3840 |
| Mean inverse-source error | .5px | 0px |
| Normalized midpoint MAE | .003182460 | .000242060 |
| Maximum measured stationary jitter over12 controls | 0% | 0% |

Stationary controls cover textured signal with correct/incorrect reciprocal fields and0/±1LSB noise, plus flat, gradient, low-contrast edge and quantized noise profiles with an incorrect reciprocal field, both without and with±1LSB noise. Jitter is the proportion of interior pixels more than one10-bit code away from the known stationary source. These are deterministic single-pair controls; they do not establish perceptual or geometric jitter for every static real sequence.

[Known-motion comparison, with identical contrast enhancement](assets/oracle-static-2026-10-17/synthetic-comparison.png) · [All six magnified sample crops](assets/oracle-static-2026-10-17/six-static-crops.png)

The synthetic before-image has erroneous stripe phases at endpoint-intensity coincidences; the candidate reproduces the known midpoint pattern up to quantization. In the real crops, sample69/24 loses a small vertical discontinuity and69/51 has a smoother low-contrast patch, while47 and the1082 samples show little visible change at this display scale. The300s face remains severely fragmented; this change is not a face-deformation fix. No broad improvement or universal no-regression conclusion follows from these crops.

[69s B comparison](assets/oracle-static-2026-10-17/avatar69/static-comparison.png) · [300s B comparison](assets/oracle-static-2026-10-17/avatar300/static-comparison.png) · [18:02 B comparison](assets/oracle-static-2026-10-17/anime1082/static-comparison.png)

### Existing real references — the failing gate

Release probes were run sequentially with six adjacent pairs per window, patch interpolation, temporal context when available, lambda1 and the existing hidden-frame checks. All24 reference rows are reported separately in [reference-mae.md](assets/oracle-static-2026-10-17/reference-mae.md); the underlying logs and `reference-mae.json` are preserved. There is no aggregate score hiding the failure:

- 23 measured references reduce MAE.
- Avatar300s, **two-source hidden reference0**, changes **12.136308 → 12.162287**, an increase of **0.025978** ten-bit work-plane units. This fails the requested no-regression gate.
- The three four-source references at300s change23.352608→23.314225,20.988207→20.958679 and34.383829→34.335241. Those improvements do not cancel the failing two-source case.

[Failing hidden-reference comparison](assets/oracle-static-2026-10-17/regression-selected/comparison.png). Both reconstructions retain severe geometric damage. The slight numerical regression is not claimed to be a proven perceptual worsening; hidden-frame error can also measure retained-pose retiming. It is nevertheless not dismissed to approve the candidate under the user's strict no-regression rule.

The isolated dense/endpoints/determinism/held-neighbor/visibility and NV12/P010 checks passed with the second candidate. After reverting the candidates, those checks pass again with the final runtime. Disabled candidate compilation reproduces the baseline synthetic pixels/metrics. The A flag-off real runs retain their exact equality assertions.

## GUI latency with decode and Strong active

Apple M4, Release, same native4K Avatar source, requested `motion4x`, requested Strong, seek to69s,45-second runs. No concurrent GPU benchmark. The admission system selected a measured736×320 work plane; do not label it768×320. Exclude the first10seconds. CSVs report complete interpolation-call latency, including all requested outputs and native reconstruction. They do **not** sum the concurrently executing decoder's own wall time, Strong's presentation duration, or display-refresh latency. File/log output is outside the measured interval.

| Variant | Samples | p50, ms | p95, ms | Max, ms | p95<35ms |
| --- | ---: | ---: | ---: | ---: | --- |
| Baseline | 809 | 33.782 | 43.288 | 50.421 | **Fail** |
| Rejected quantization budget | 806 | 33.038 | 42.021 | 49.347 | **Fail** |
| Rejected8×8 patch | 806 | 32.743 | 42.563 | 49.937 | **Fail** |

These are short sequential sessions with normal system/load variation, not proof that either candidate makes interpolation faster. GUI logs show video playback near the60fps target, but admitted/presented counts are not proof of physical display refresh or of the35ms budget. `performance-comparison.json` retains output-count distributions; two/three requested buffers can include an original endpoint, so those counts must not be relabeled as generated-frame counts. GUI screenshots/logs and candidate-binary hashes are preserved.

Neither performance nor universal visual no-regression is established. The inherited baseline already exceeds the requested budget, and optimizing unrelated pipeline work would exceed this task's scope.

## Reproducing B without changing the player

The rejected second candidate can be tested **offline only**, from its saved Metal source:

```sh
RIFT_STATIC_MOTION_GUARD=1 MV_STATIC_CHECK=1 \
MV_STATIC_EXPECT_FIXED=1 MV_STATIC_STRICT_STATIONARY=1 \
MV_STATIC_CANDIDATE_MSL="$PWD/docs/diagnostics/assets/oracle-static-2026-10-17/rejected-patch-guard.metal" \
MV_STATIC_BASELINE="$PWD/docs/diagnostics/assets/oracle-static-2026-10-17/baseline.metal" \
MV_STATIC_OUTPUT="$PWD/docs/diagnostics/assets/oracle-static-2026-10-17/synthetic-patch" \
.build/release/MVProbe
```

`RIFT_STATIC_MOTION_GUARD` is now used only by the offline harness; final runtime sources contain no such switch/correction. For the disabled compile check use0 and omit `MV_STATIC_EXPECT_FIXED`. For a real-pair replay, replace `MV_STATIC_CHECK` with `MV_STATIC_REAL=<case>/oracle-on` and use a separate output directory; regenerate ignored fields with A's command if necessary.

The final timing tap is enabled with `RIFT_PAIR_TIMING=1`; redirect stderr at launch and select `RIFT_PAIR_TIMING,` lines. Opening/redirecting files belongs to the caller, not to Core/Interpolation. The saved GUI sessions used the earlier CSV capture on the measured temporary binaries; both capture the same interpolation-call boundary and exclude diagnostic-output time.

## What changed, and what remains unproven

Kept: optional offline final-field injection, exact synthesis/predicate harness, deterministic static/motion controls, opt-in timing output, bounded evidence and reproduction instructions. Reverted: both attempted static-protection runtime changes. Search, selection, other modules and preexisting user UI changes were preserved.

Still unproven/unmet: an acceptable B correction that fixes the six samples without a reference regression; p95<35ms with decode/Strong active; complete physically correct oracle motion; native-color/HDR image-quality improvement; long-session temporal/perceptual jitter, pause/seek/resume/EOF and hardware other than this M4. No source movie conversion, full-file rewrite, neural dependency or Motion²-equivalence claim was introduced. Stop here after A/B as requested.
