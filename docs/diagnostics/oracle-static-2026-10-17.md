# Oracle injection and static protection — 2026-10-17

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

A separate opt-in `RIFT_PAIR_TIMING_OUTPUT=<csv>` records whole `MotionCompensator.interpolatePair` latency under GUI playback load. It defaults off; diagnostic file writing is excluded from the latency sample. Decode and Strong can be active concurrently, but this measurement does not add decode's separately executing duration to interpolation time or measure display-refresh latency. Preserve that distinction when reporting p95.
