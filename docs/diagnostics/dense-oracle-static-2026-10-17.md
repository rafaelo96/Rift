# Dense oracle and static protection — 2026-10-17

**Final disposition:** C completed; D reapplied and accepted under the adjusted crop/MAE/jitter/43.29ms criteria, behind a default-off flag. The separate 35ms goal remains unmet.

Scope: steps C/D only, Core/Interpolation and offline evidence. Production search, candidate selection, temporal blending, confidence maps, UI and other modules are untouched. The existing source movie is never copied, transcoded or rewritten. Diagnostic inputs are the previously committed 49-frame work-plane fixtures per case, not a derived full movie.

## C — full spatial and temporal coverage

Release on Apple M4. Each 2-second window has 48 adjacent pairs, each rendered at t=.25/.5/.75: 144 pairs, 432 intermediate outputs. Every pair receives a forward and independently searched reverse field covering **all 1152×480 pixels**, with no evaluability mask. The field is piecewise constant on a complete 144×60 lattice of nonoverlapping 8×8 patches (8,640 vectors/direction); this is full coverage, not an independently optimized vector at each pixel or physically certified motion truth.

For each patch and direction, the offline GPU tool exhausts every integer displacement in [-256,+256]² whose target 8×8 patch fits the image. It uses the same exposure normalization and 5×5 analysis blur as production, followed by mean 8×8 SSD at level zero. Exact cost ties prefer the smaller vector norm, then displacement index. No pyramid pruning, eligibility threshold, retained production xy or skipped ambiguous patches. Source patches tile the entire frame, including borders; target footprints must remain in bounds. Bounds on radius are explicit, so “exhaustive” does not mean unbounded search or subpixel truth.

Minimal regularization is one synchronous pass: consider the exhaustive winner and four adjacent winners, forbid >1% SSD degradation (+1e-10 numerical floor), and add 1e-7 times truncated (1px) vector disagreement. Neighbor weights fall to zero at source-patch mean absolute intensity difference .01. No vector averaging, iterative diffusion, or propagation across a photometric discontinuity. Deterministic synthetic checks cover +8px translation, flat ties choosing zero, finite coverage in both directions and a +8/-8 motion boundary. This protects that synthetic discontinuity; it cannot certify every real object boundary or resolve occlusion.

Only xy of the final assessed production fields is replaced through the existing offline callback. z/w confidence/visibility, projection and synthesis remain unchanged. `RIFT_DENSE_ORACLE=1` is required; playback never installs this callback. An independent engine constructed with the flag **off** receives the same callback and must reproduce normal output pixels and both fields exactly at all three times on every pair. Diagnostic timings include exhaustive search and are excluded from playback performance.

A controlled pair4 ablation retains A's exact original sparse substitutions while filling only the previously untouched regions with the complete reference field. A second ablation masks the new dense field using A's spatial mask. These distinguish missing coverage from changed vectors. Confidence remains production-derived in all variants; independent forward/reverse photometric minima can disagree. A failed dense experiment cannot prove that a physically correct field would fail.

### Reproduction

Build `swift build -c release --product MVProbe`. Restore the existing bounded source fixtures from their per-case `sources.zip` if necessary. Run `MV_FULL_ORACLE_CHECK=1 .build/release/MVProbe`, then for each of `avatar69`, `avatar300`, `anime1082`:

```sh
RIFT_DENSE_ORACLE=1 RIFT_STATIC_MOTION_GUARD=0 RIFT_PATCH_TEMPORAL=1 RIFT_PATCH_AFFINE=0 \
MV_FULL_ORACLE_WINDOW="$PWD/docs/diagnostics/assets/trajectory-survival-2026-10-17/avatar69" \
MV_FULL_ORACLE_OUTPUT="$PWD/docs/diagnostics/assets/dense-oracle-static-2026-10-17/avatar69" \
.build/release/MVProbe
```

`MV_FULL_ORACLE_START/END` restrict pair indices for diagnostic replay (defaults 0/47). Cached grids validate the two source hashes, radius and algorithm version. Reuse a new output directory after changing the oracle algorithm. `DenseOracleReport.py` assembles crops and archives the two reference grids for all pairs. Primary pair4 is used for the directly comparable A/B/current/oracle crops; pair6 across the 18:02 cut is preserved separately and must not be interpreted as continuous motion.

### C results

| Case | Changed pixels at pair4, t=.25/.5/.75 (of 552,960) | Visual category and observation |
| --- | --- | --- |
| 69s | 156,723 / 199,835 / 175,333 | **Worsens locally.** Complete coverage introduces granular/block fragments along the blurred crossing silhouette and parts of the bison/background. The original sparse small square substitutions do not become a clean, coherent contour when gaps are filled. The 48-midpoint sheet shows repeated fragmentation during the blurred foreground crossing. |
| 300s | 176,999 / 266,116 / 290,954 | **Worsens at the original pair4 reference; mixed over the window.** The face is still absent/fragmented at pair4, with additional pieces in the head/background region. Some earlier face contours (e.g. pair2) improve, while later motion produces new fragments. No general disappearance of deformation. |
| 18:02 | 68,825 / 88,751 / 87,607 | **No material change at the original pair4 bird/landscape crops.** Bird wings and cliff contours remain close, with small edge differences. The later post-cut shot has other changed pixels; it does not establish improvement of the original bird deformation. The forced synthesis across pair6's scene cut is shown separately, not treated as valid motion truth or as evidence of a live-player cut bug. |

Changed pixel counts measure intervention size, **not error or quality**. Both normal-engine pair4 PNGs and the reproduced legacy sparse A PNGs match the prior phase's saved PNG pixels exactly at all nine case/time combinations. All 432 disabled-callback outputs/fields match their ordinary-engine baseline. Synthetic checks pass. See [step-c.json](assets/dense-oracle-static-2026-10-17/step-c.json), [execution](assets/dense-oracle-static-2026-10-17/c-execution.json), per-case `all-pairs.json`, source hashes and lossless `reference-grids.zip`.

**69s mask conclusion:** the exact-A/gaps-filled ablation and fully independent dense field both still show fragments despite having no oracle/non-oracle gaps. Thus missing coverage is **not a sufficient explanation** of the artifacts and filling it does not cure them. The mask can contribute local discontinuities, but this experiment cannot assign the cause of every original square individually, or prove physical correctness of the exhaustive minima. The complete 8×8 lattice itself, ambiguous/occluded matches, inconsistent bidirectional minima and retained assessment metadata remain limitations; none was changed to force a favorable result.

[69s crossing: A/B/current/dense](assets/dense-oracle-static-2026-10-17/avatar69/crossing-bison-t0.5.png) · [69s exact-A mask ablation](assets/dense-oracle-static-2026-10-17/avatar69/crossing-bison-legacy-ablation.png) · [300s face](assets/dense-oracle-static-2026-10-17/avatar300/face-contour-t0.5.png) · [18:02 bird](assets/dense-oracle-static-2026-10-17/anime1082/bird-contour-t0.5.png). All seven original ROIs have t=.25/.5/.75 crops and all-48-midpoint sheets alongside these files. Native color/HDR and perceptual video playback quality are not established by these luma previews.

## D — second static-protection candidate reapplied

**Accepted under the user's adjusted criteria; opt-in, defaults off.** Exact reapplication of `d17c7ad`'s `rejected-patch-guard.patch` (the second candidate). The active MSL equals the archived second-candidate snapshot. `RIFT_STATIC_MOTION_GUARD=1` enables its compile-time shader variant; unset/0 preserves existing behavior. No default UI setting or installed application bundle was changed.

The existing point-intensity tests can falsely label reciprocal moving patches as still. The bounded correction only overrides that decision at zero exposure offset when both flow lengths exceed 1px, both closure errors are <1px, both confidences exceed .5, and the compensated 8×8 L1 patch cost is <80% of the unwarped cost. Noise-level ties retain static protection. No candidate generation, ranking, search, selection, temporal mix or confidence-map change.

The baseline was measured before applying the patch. After reapplication, the same fresh baseline/candidate/disabled runs replayed the three cases and all existing hidden-frame references. `StaticCandidateRun.py before|after|disabled` reproduces these sequential Release runs; `StaticCandidateReport.py` asserts the numeric criteria and assembles crops. GPU diagnostic work and GUI playback were never run concurrently.

| Check | Before → after | Result |
| --- | --- | --- |
| Six real sampled transport offsets | Six statically overridden → six nonzero transport offsets, still=false | 6/6 recovered |
| Known synthetic 4px displacement | 960/3840 frozen pixels → 0; inverse-source error .5px → 0 | Pass |
| Synthetic normalized luma MAE | .00318246016427 → .000242059545985 | Improves |
| Twelve stationary controls | 0% → 0% pixels differing from stationary truth by >1 ten-bit code | All exactly 0%, not merely <1% |
| Existing reference MAE | 24 comparisons; 23 improve, one increases | All within +.5% |
| Worst reference (300s, two-source pair0) | 12.136308232060186 → 12.162286603009258 | **+.21405497%**, accepted |
| Flag off | Synthetic pixels/coordinates exact; all 9 real synthesis SHA256 values match baseline; 204 PNGs match; 24 MAEs exact | Pass |
| Existing dense/native fixtures | Layered motion, endpoints, static/noisy holds, determinism, invalid input, translation; native 10-bit/chroma/metadata | Pass |

The flag-off shader, after removing the undefined conditional blocks, is **text-identical** to baseline MSL. The disabled full-engine reference runs preserve every saved PNG and MAE. See [step-d.json](assets/dense-oracle-static-2026-10-17/step-d.json), [six recovered offsets](assets/dense-oracle-static-2026-10-17/six-static-recovered.json), [six crops](assets/dense-oracle-static-2026-10-17/six-static-crops.png), [24 reference measurements](assets/dense-oracle-static-2026-10-17/reference-mae.json), and [execution/source hashes](assets/dense-oracle-static-2026-10-17/d-execution.json).

**Visual review at 300s:** inspected both face and clothing in all eight hidden-frame references, plus the original pair4 at .25/.5/.75. Before/after retain the same large fragmented contours; small grain/edge differences do not reveal a new visible deformation. In particular, the numerically worse pair0 does not show a new visible contour break in these crops. This meets the requested crop criterion, not a claim that the existing fragmentation is solved. [Face references](assets/dense-oracle-static-2026-10-17/avatar300/static-reference-face-contour-all.png) · [Clothing references](assets/dense-oracle-static-2026-10-17/avatar300/static-reference-clothing-contour-all.png) · [Pair4 face](assets/dense-oracle-static-2026-10-17/avatar300/static-face-contour-t0.5.png).

### D performance — separate from the 35ms goal

Actual **Apple M4**, Release; real native GUI playback, hardware decode and Strong configured. Existing renderer diagnostics report `SUPERRES mode=strong ... processed=true bypass=false` for five sampled frames in each comparable session. This confirms real processing at those samples, not continuous absence of adaptive Strong bypass throughout playback. Work plane is **736×320**, selected by the existing calibration; source is 3832×1600 HEVC. Each run lasts 45 seconds, excludes the first 10 seconds and other calibration planes, and uses empirical nearest-rank p95 of whole `interpolatePair` latency. Counts include calls with two/three scheduled outputs (including endpoints), not two/three generated frames.

| Session | Samples | p50 ms | p95 ms | Maximum ms |
| --- | ---: | ---: | ---: | ---: |
| Baseline preflight, without Strong telemetry | 808 | 33.362875 | 43.668042 | 50.830542 |
| Baseline, Strong telemetry enabled | 817 | 32.348583 | **41.265125** | 46.448666 |
| Reapplied candidate, same telemetry | 812 | 32.585583 | **42.231083** | 48.932458 |

The first baseline run is retained, not discarded: it was repeated to verify effective Strong processing with the existing diagnostic switch. The comparable before/after sessions use the same switch/profile. The candidate p95 is **.965958ms higher** than the fresh comparable baseline, so this does **not** demonstrate a speed improvement; it is within the adjusted **43.29ms** limit by 1.058917ms. Baseline variation itself is visible across runs. These are finite sessions, not a sustained thermal guarantee.

**Separate goal:** 42.231083ms remains 7.231083ms above 35ms. As instructed, that pre-existing target gap does not reject D. The metric measures interpolation-call latency under concurrent decode/Strong/presentation load; it does not sum decode/render durations or establish end-to-end display latency. [All sessions and filtered CSVs](assets/dense-oracle-static-2026-10-17/performance-comparison.json); raw GUI/timing logs are adjacent.

## Stop point and remaining unknowns

C/D complete. D remains an explicit opt-in correction; normal flag-off output is preserved. Production search and selection have not changed. No work on temporal blending or a confidence map was started.

Still unproven: a physically correct dense oracle (integer photometric minima on 8×8 blocks are not motion truth), general removal of the deformations, every individual sparse patch's causal origin, native-color/HDR perceptual improvement, temporal jitter over real long sequences, continuously active Strong without adaptive bypass, sustained thermal p95 or the 35ms goal, and performance on chips other than this M4. The 12 zero-jitter controls are deterministic stationary synthesis tests with an explicit >1-code metric, not a real-video temporal stability guarantee.
