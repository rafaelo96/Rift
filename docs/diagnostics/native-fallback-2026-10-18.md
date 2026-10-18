# Native fallback coordinate mismatch — 2026-10-18

Preserves DeepSeek changes through 9b49e06. Fix1: when weights<=1e-4 and no ownership hypothesis applies, the luma diagnostic computes an unwarped A/B crossfade but previously exported rejected q0/q1 motion coordinates to native rendering. Reset both to the destination pixel for that branch. Search, selection, thresholds, static protection and E2 are unchanged.

Deterministic reproduction: `swiftc -O -parse-as-library -D NATIVE_FALLBACK_CHECK Core/Interpolation/Swift/*.swift Core/Interpolation/Checks/NativeFallbackCheck.swift -o /tmp/rift-native-fallback-check`; run the executable. Forced low-confidence, nonzero motion; compare actual GPU native render to the luma fallback. Before: fails first NV12 case, maximum difference590 in10-bit code units. After:9 cases (NV12/P010/P210 × t .25/.5/.75),27,648 fallback pixels; maximum2 for NV12,1 for10-bit. This is sampling/quantization agreement, not zero interpolation error.

Release/M4 native integration regression checks also pass (8/10-bit endpoints, metadata, chroma, repeated batch/single identity). Combat 1201.7–1203.0 seconds remains visibly damaged in some pairs after this fix: the ownership branch can override generic weights. This fix alone is not a solution to the screenshots. No playback p95 or HDR screen validation claimed.
