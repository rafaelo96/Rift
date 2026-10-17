# E2 — local confidence degradation (in progress)

Scope: Core/Interpolation, bounded offline diagnostic tools and evidence. Search, selection and reapplied static-protection shader remain unchanged. UI reset callers already invalidate/reset the interpolator on pause, seek, load and close, so no UI edits are needed.

Change 1: opt-in real temporal acquisition (`RIFT_E2=1`). A dedicated matcher uses the same existing block search without sharing or mutating production matcher state. The preceding reverse seed is reused only when both source planes prove adjacency; otherwise a separate before search is made. The after-neighbor search is always real. Missing context remains missing. The existing reset clears this bounded two-plane/one-field cache. Native endpoints, 8/10-bit chroma, held/moving contexts, invalid-context fallback and output reuse pass before adding any degradation. `temporal-native-check.log` records actual searches. This commit does not change output synthesis.
