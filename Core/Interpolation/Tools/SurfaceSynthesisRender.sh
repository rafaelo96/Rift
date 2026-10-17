#!/bin/sh
set -eu
root=$(CDPATH='' cd -- "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/rift-surface-render.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
cp "$root/Core/Interpolation/Tools/SurfaceSynthesisRender.swift.txt" "$work/SurfaceSynthesisRender.swift"
swiftc -O "$root/Core/Interpolation/Swift/DenseMotionShaders.swift" "$work/SurfaceSynthesisRender.swift" -o "$work/render"
"$work/render" "$@"
