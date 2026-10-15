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
