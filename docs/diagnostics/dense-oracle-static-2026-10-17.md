# Dense oracle and static protection — 2026-10-17

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
RIFT_DENSE_ORACLE=1 RIFT_PATCH_TEMPORAL=1 RIFT_PATCH_AFFINE=0 \
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
