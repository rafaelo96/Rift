# Frame+ search submission batching — 2026-10-14

Hardware: Apple M4. Native 4K Avatar source; economy work plane 768×320; two generated frames per source pair. No source file conversion or modification.

## Cause and change

Motion search submitted and waited for every pyramid/search/filter stage in both directions. Encode the same kernels in dependency order into one command buffer per direction instead. Preserve the synchronous legacy path when temporal CPU state is enabled. Fail the batch if encoder creation or GPU completion fails. Skip comparing the first image with itself for illumination offset (exactly zero).

## Verification

`MV_NATIVE_PATCH_CHECK=1 .build/release/MVProbe` passes: one/four-level raw and filtered motion vectors are identical between separate and batched submissions; native NV12/P010 integration passes. `MV_DENSE_LIGHTING=1` passes existing illumination checks.

Sequential same-binary A/B: `MV_PROFILE=economy MV_PIPELINE=1 MV_PAIR_OUTPUTS=2 MV_PAIRS=12 MV_SEEK_SEC=69 MV_DUMP=0 .build/release/MVProbe`, legacy selected by `RIFT_PATCH_BATCH_SEARCH=0`.

| Search submissions | Median total/pair | Maximum | Pairs over 41.7 ms |
|---|---:|---:|---:|
| Separate | 39.611 ms | 45.523 ms | 5/12 |
| Batched | 27.812 ms | 30.571 ms | 0/12 |

At 300 s, batched median is 28.814 ms, maximum 69.101 ms; the first two warmup pairs exceed budget (69.101/49.140 ms), remaining ten are below 34 ms. These totals include native input scaling and interpolation/output, exclude decode/display. Existing app admission warms the selected work profile before restarting its playback clock.

## Remaining validation

Benchmark improvements do not establish sustained GUI framerate or Motion² equivalence. Rebuild the separate test app and verify playback. Important deformation cases remain under investigation; no direct Splash comparison is available.

## GUI reproduction and second correction

The first test app sustained a visible decline (60 initially, then 17/3 fps delivery). Detailed runtime stages measured approximately 41–42 ms interpolation per pair, with late samples discarded. Thus the initial twelve-pair/two-output benchmark was insufficient.

A hardware-filtering experiment in native color sampling was rejected: single-output median remained 46.441 ms versus 50.364 ms in the preceding isolated manual-sampling run; it did not provide the needed headroom. The original sampling shader is retained.

Additional changes within Interpolation:
- Independently resample the two read-only source luma planes concurrently, with per-call vDSP scratch and locked result collection. No cross-pair source cache or unbounded buffer is introduced.
- Encode native color rendering immediately after dense synthesis into the same command buffer. Wait once per output; retain CVMetalTexture wrappers through GPU completion. Clear all output buffers on command failure. With a shared command, reported warp time covers encoding only; GPU color execution is included in aggregate analysis/total time.

Sequential 12-pair, single-output tests at 69 s (Apple M4, same source/work size): serial scaling/separate synthesis-color submission median 50.364 ms; parallel scaling 37.997 ms; parallel scaling/shared submission 35.561 ms, p95 40.212 ms, maximum 43.756 ms. These are short runs with differing system load and must be checked against sustained playback.

Native integration checks pass for 8/10-bit, including repeated three-output batches: midpoint payload stays byte-identical to the standalone midpoint, and earlier output buffers remain unchanged. Illumination regression metrics remain unchanged. Sustained GUI revalidation follows; these measurements do not establish final visual quality.

## Sustained app results after the second correction

Rebuilt/repackaged separate test app, signature verified. Built-in `RIFT_FLUENCY_PROBE_SECONDS` runtime probe, real 4K Avatar, requested `motion4x`, normal subtitle composition, Apple M4; admission measured and selected economy. No other video benchmark ran concurrently.

- 120-second playback run: warm delivery samples 58–62 fps, median 60; final AVSampleBufferVideoRenderer metrics 7,150 total / 4 dropped / 0 corrupted. No progressive collapse. RSS observed approximately 194 MB at ~101 s (single observation, not a long-term memory proof).
- 90-second run with normal seek to 300 s: warm delivery approximately 60 fps; final renderer metrics 5,342 total / 6 dropped / 0 corrupted. Drop count remained at 6 from the 15 s sample through the end. Timeline progressed to 388.4 s; subtitle composition failures stayed zero.

The renderer metrics support sustained presentation through these windows, but are not an external physical-display capture or a full-film stress test. Significant visual deformation cases remain; the Motion² quality objective is not complete.

Runtime logs: `/tmp/rift-fluency-shared-120.log`, `/tmp/rift-fluency-shared-300.log`; build/package logs `/tmp/rift-test-app-build.log`, `/tmp/rift-native-app-package.log`. The separate test app contains commits `00f4323` and `a8ae44e` plus the pre-existing UI checkout changes described in the integration report.

## Harness correction

`MV_PAIR_OUTPUTS=3` previously fell through to the single-output path. The 50.364 / 37.997 / 35.561 ms exploratory measurements above therefore measure **one output**, not three; their labels have been corrected. They cannot establish the three-output budget. Initial `MV_PAIR_OUTPUTS=2` A/B results and the two sustained app probes are unaffected. The harness now accepts 1–4 outputs, prints the actual requested count, and asserts the complete generated buffer count. Repeat the three-output benchmark with the corrected harness.
