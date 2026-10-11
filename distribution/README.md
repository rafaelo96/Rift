# Local macOS file associations

Run `distribution/build-local-app.sh` to build and register `~/Applications/Rift.app`.
An optional first argument chooses another app path; `RIFT_BUILD_CONFIGURATION`
selects the SwiftPM configuration (default: debug).

The app declares a Viewer role with Alternate rank for MP4, MOV/QT, M4V, AVI,
MKV, WebM, MPEG/MPG/MPE and TS/M2TS/MTS. Matroska and WebM are imported UTIs.
Registration makes Rift available in Finder's Open With menu without explicitly
changing the user's default application. Finder > Get Info > Open With > Change
All can be used to make Rift the default for a chosen format.

This is a local development package, not a portable release: Homebrew FFmpeg
libraries and SwiftPM's resource build path must remain available. Release
packaging still needs portable resource lookup, bundled runtime libraries,
Developer ID signing and notarization. The script uses an ad-hoc signature.

Finder URL delivery uses the existing AppDelegate and ContentView handlers.
No playback pipeline changes are needed for these associations.
