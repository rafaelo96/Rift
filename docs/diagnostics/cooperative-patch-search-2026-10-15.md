# Cooperative patch-search experiment

Apple M4. Hypothesis: assigning all 64 pixels of an 8×8 inverse-search patch to a 64-thread group, reducing Hessian/SSD/RHS across SIMD groups, would reduce per-thread register pressure. Same candidates, eight iterations, acceptance and sampling; dynamic SIMD width, no chip-specific table. Opt-in `RIFT_PATCH_COOPERATIVE=1`, legacy remains default.

Correctness: patch/dense layered sequence, endpoint, held/noisy-held, deterministic, native NV12/P010, color/HDR metadata and coherent illumination checks pass without relaxing assertions. Translation MAE .00447455 px, original-detail midpoint .55664, illumination midpoint 2.67383.

Real native 4K Avatar, economy 768×320, three outputs per pair, twelve pairs at 69 s, alternating sequential runs. Medians excluding first warmup pair:

| Trial | Serial patch | Cooperative patch |
|---|---:|---:|
| 1 | 25.038 ms | 24.539 ms |
| 2 | 24.919 ms | 24.953 ms |
| 3 | 32.496 ms | 34.072 ms |

No reliable end-to-end saving. Do not enable or ship this experiment as a performance fix. Preserve the experiment commit, then remove the opt-in kernel and dispatch changes from the working implementation. Next diagnostic: measure GPU stages separately instead of assuming patch search dominates.

Logs `/tmp/rift-coop-{serial,parallel}-{1,2,3}.log`, `/tmp/rift-cooperative-check.log`, `/tmp/rift-coop-native-check.log`, `/tmp/rift-coop-lighting-check.log`. Source video was read only; no converted video files generated. Native app remains the previously packaged version.
