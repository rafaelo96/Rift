# Playback UI validation — 2026-10-10

Scope: UI playback coordination, preferences and local file access. No decode,
interpolation or rendering pipeline changes; no source video rewrite.

## Findings and changes

- A source-based reproduction confirmed that an obsolete asynchronous opening
  could replace the most recent opening. Request identifiers now reject stale
  installation, including after the coordinator suspension point.
- The live app exposed two Rift windows sharing one player. The main scene is
  now a singleton and the production preview fallback window was removed.
- Finder URLs queue only until the player subscribes. Last-session restoration
  honors the selected ask/resume/restart behavior and saves on orderly quit.
- Native security-scoped bookmarks retain access while readers run and resolve
  renamed files. Existing path-based records remain compatible.
- Preferences include subtitle size, inset, contrast, delay, default visibility,
  track-selection memory and opening behavior.

## Verification

- `swift build --product Rift`: passed (existing package warnings remain).
- `git diff --check`: passed.
- Live local app: Avatar reopened at saved 23:09 and later 24:42 with visible
  moving video. The recovery sheet displayed the saved time and progress.
  Clicking the actual minimize control activated PiP (main player showed the
  PiP placeholder). Accessibility clicks on native window controls sometimes
  did not perform the action; those attempts are not counted as passing tests.
- Temporary native/controller harnesses passed: automatic PiP window/app events,
  unrelated-window isolation and observer teardown; return deminiaturizes and
  preserves playback/layer; close pauses and leaves the main window minimized.
- Recovery harness passed continue/restart/cancel, latest live position, near EOF,
  per-file track roundtrip, missing tracks, subtitles off, external subtitles
  and legacy defaults.
- Native bookmark test persisted a bookmark, renamed a temporary file, recreated
  the store and resolved/read the renamed file successfully.
- Source-based race harness reproduced stale installation before the guard and
  rejected it after the guard. It does not simulate hardware decoding.

## Remaining validation

The original intermittent black-screen incident cannot be uniquely attributed
from the available evidence. The two demonstrated UI causes were corrected;
this is not proof that every black-screen cause is eliminated.

Full end-to-end track restoration after process restart and repeated real PiP
return/close cycles still need a stable GUI test session. Harness results should
not be represented as completion of those manual checks.

Bookmark access is verified in the local build, not an App Store sandbox build.
Subtitle appearance preferences affect the main/fullscreen overlay; PiP uses
its existing renderer appearance. Delay applies to both. Rendering appearance
changes require their own module scope. Multi-hour and EDR-display validation
remain separate release checks.
