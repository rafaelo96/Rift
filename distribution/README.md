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

## Self-contained local test package

Build into a fresh destination, then bundle the existing runtime:

```sh
RIFT_BUILD_CONFIGURATION=release distribution/build-local-app.sh /path/to/Rift.app
python3 distribution/package-portable.py /path/to/Rift.app
```

The packager copies the complete non-system library dependency graph into
Contents/Frameworks, rewrites load paths, checks arm64, raises the declared
minimum macOS to the actual library requirement and signs libraries plus app.
It retains the SwiftPM resource bundle in Contents/Resources, the first runtime
resource lookup location. It fails on unresolved nonportable load paths.

The runtime installed on the development Mac currently requires macOS 27.0.
Bundling does not make those binaries compatible with older systems. Supporting
older macOS requires rebuilding FFmpeg and its dependencies for that target.
This is an ad-hoc-signed test package, not a notarized public release. Public
release also requires preparation/review of bundled-library licenses and
corresponding source (the current FFmpeg build reports GPLv3-or-later).
