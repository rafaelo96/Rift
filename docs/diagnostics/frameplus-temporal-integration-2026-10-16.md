# Frame+ temporal integration — 2026-10-16

## Scope and behavior

`MotionCompensator.interpolatePair` accepts an optional native `InterpolationTemporalContext`. It checks format, dimensions and finite interval ratios; invalid/missing context uses the existing two-source path. Up to four source lumas are reduced concurrently and normalized consistently before dense interpolation. Native color reconstruction still uses the central pair. `RIFT_PATCH_TEMPORAL=0` restores the previous production two-source path, including its cost.

The playback coordinator retains one previous source in its display-loop generation and obtains the future source from the existing eight-frame pool. Context is accepted only across contiguous timestamps. It does not wait indefinitely for a future frame or grow the pool. A new display loop after seek discards the previous generation's source. Admission calibration also receives neighboring frames, so the measured cost includes temporal work. Beginning/end or unavailable neighbors use two frames.

This connects the coarse temporal candidate selector to ordinary Frame+ playback by default. The older full-resolution temporal confidence assessment is restricted to the separate non-patch prototype. It is an integration for testing, not a declaration that large deformations are solved or that Motion² equivalence is verified.

## Checks

- Release builds of Rift and MVProbe pass.
- Native NV12/P010 checks pass for endpoints, color/chroma/HDR attachments, held context determinism, moving-context output, and invalid-context fallback.
- Dense patch regression and identical-surface/misleading-neighbor fixtures pass.
- Updated `/Users/rafael/Applications/Rift.app`, portable bundled runtime (15 libraries), ad hoc signature verified with `codesign --verify --deep --strict`.
- Runtime: Apple M4, Avatar 3832×1600, Frame+ motion4x, Strong, early seek to300s; 90-second diagnostic with pause at8s, paused seek at9s, verification at12s, resume13s and recovery verification20s. No simultaneous GPU benchmarks.
- GUI screenshot confirms video output; visible deformation remains. The post-resume counter briefly falls before recovery. Whole-film visual quality and sustained thermal performance have not been validated.

Runtime log: `/tmp/rift-temporal-live90.log`. Tests: `/tmp/rift-context-{native,regression,selection}.log` and `/tmp/rift-context-final-native.log`.

Runtime result: 90 seconds completed, exit0 (pause/seek/recovery assertions passed). From second20: median 58.1, mean 47.58, minimum 1.3 admitted fps. Target set: [47.95, 60.0]. Final metrics: PRESENTATION second=90 total=4020 dropped=130 corrupted=0 delay=1.936666666666667e-05. Temporal-context diagnostic observed: True. Delivery counters are not physical display refresh measurements.

## Runtime correction

The first run above exposed a real integration regression: passing context also activated the older full-resolution `denseTemporalAssess` post-pass, beyond the new candidate selector. Patch interpolation now keeps central bidirectional confidence and uses neighbors only to select coarse trajectories. The separate non-patch research path retains its existing temporal assessment. Native context and dense regression checks pass after this change. A second same-settings 90-second run is recorded in `/tmp/rift-temporal-select-only-live90.log`.

Corrected run: 90 seconds completed with exit0; pause/seek/recovery assertions pass. From second20: median 60.0, mean 60.15, minimum 56.7 admitted fps. Target set: [60.0]. Final metrics: PRESENTATION second=90 total=5045 dropped=25 corrupted=0 delay=1.0116666666666667e-05. Temporal-context activation observed: True. No claim of resolved visual distortions or whole-film validation.
