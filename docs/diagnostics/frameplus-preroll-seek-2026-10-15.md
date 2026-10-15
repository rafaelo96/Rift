# Seek during Frame+ preparation

The rebuilt habitual Release app reproduced a second failure with `RIFT_AUTO_MODE=motion4x RIFT_AUTO_SUPERRES=strong RIFT_AUTO_SEEK_AT=1 RIFT_AUTO_SEEK_TO=300 RIFT_FLUENCY_PROBE_SECONDS=90`: `isPlaying=false` during initial preroll was captured as pause intent; after the seek, time stayed 300.000 for ninety seconds and only one frame was presented. This is separate from slow unoptimized Debug execution.

Preserve autoplay intent as soon as the loaded session is ready, while keeping the synchronizer stopped until admission. After a playing seek, gather four frames and run Frame+ admission before resuming. Paused seeks retain their existing one/two-frame requirement. Admission checks current play intent before starting the clock, so a pause made during preparation is respected.

Rebuilt and packaged habitual app passes the same early-seek reproduction: clock advances to 388.401 s and image is visible. With Strong enhancement, the full ninety-second run remains over budget at intervals: final renderer 3,913 total / 306 dropped / zero corrupted. Thus the frozen-preroll condition is corrected, but combined enhancement/interpolation fluency is not resolved. No claim of final quality or 60 fps stability.

Logs `/tmp/rift-habitual-strong-90.log` (before) and `/tmp/rift-habitual-preroll-fixed-90.log` (after). All pre-existing unrelated UI instrumentation remains unstaged; only the three playback lifecycle hunks belong to this change.
