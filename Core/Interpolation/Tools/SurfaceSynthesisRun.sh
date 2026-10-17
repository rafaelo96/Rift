#!/bin/sh
# Compile outside MVProbe: an additional @main Swift source changes SPM entry-point discovery.
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rift-surface-synthesis.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
cp "$root/Core/Interpolation/Tools/SurfaceSynthesisCheck.swift.txt" "$work/SurfaceSynthesisCheck.swift"
swiftc -O "$root/Core/Interpolation/Swift/DenseMotionShaders.swift" "$work/SurfaceSynthesisCheck.swift" -o "$work/check"
"$work/check"
