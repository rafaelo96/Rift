# Black screen / zero fps in the normal development launch

Evidence: LaunchServices identifies failing PID 7597 as `/Users/rafael/Documents/Rift/.build/out/Products/Debug/Rift`, rather than the separately verified Release test app. Its admission measured 66.52 ms per pair against 41.71 ms; renderer diagnostics subsequently show zero attempts/admissions while the clock advances. A twenty-second run of that Debug binary reproduces sustained `admittedFPS=0.0`.

The Interpolation target previously inherited unoptimized Swift Debug compilation. Its CPU frame preparation, input validation and illumination analysis are on the real-time path. Optimize this target with `-O` in Debug; keep other targets' development configuration intact. This changes compilation only, not the pixel algorithm or source-file behavior.

After rebuilding Debug, a sixty-second runtime probe with the same source and seek to 1214 s produces visible pipeline output: initially about 60 fps and subsequently about 48 fps after the existing presentation policy reduces the mode. Final renderer counters: 2,977 total, 41 dropped, zero corrupted; no sustained zero-output state. Strong super-resolution is enabled in this run. This does not establish sustained 60 fps or Motion²-quality imagery.

Debug native integration checks pass for eight/ten-bit, repeated output payload identity, endpoints, chroma and metadata. `bash -n distribution/build-local-app.sh` passes. Local packaging now defaults to Release (explicit Debug override remains available), preventing the normal installed app from accidentally using an unoptimized development build.

`~/Applications/Rift.app` rebuilt in Release and portable runtime repackaged (15 libraries), ad hoc signature verified. Existing pre-work UI edits are included in the local build but not committed with this fix. Habitual-app playback verification is pending independent runtime availability; another project-launched Rift instance was active during installation.

Logs: `/tmp/rift-black-zero-recent.log`, `/tmp/rift-black-debug-repro.log`, `/tmp/rift-debug-optimized-60.log`, `/tmp/rift-debug-native-check.log`, `/tmp/rift-habitual-release-build.log`, `/tmp/rift-habitual-portable.log`.
