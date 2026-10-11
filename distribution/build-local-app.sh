#!/bin/bash
# Local development package: requires the same Homebrew FFmpeg runtime as SwiftPM.
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-$HOME/Applications/Rift.app}"
configuration="${RIFT_BUILD_CONFIGURATION:-debug}"
cd "$project_root"
swift build -c "$configuration" --product Rift
bin_path="$(swift build -c "$configuration" --show-bin-path)"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_path/Rift" "$app_path/Contents/MacOS/Rift"
cp distribution/Info.plist "$app_path/Contents/Info.plist"
# SwiftPM assets use the local build fallback; this package is for this Mac.
cp -R "$bin_path/Rift_Rift.bundle" "$app_path/Contents/Resources/"
icon_dir="$(mktemp -d)/Rift.iconset"
mkdir -p "$icon_dir"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" UI/Assets/Rift-icon.png --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" UI/Assets/Rift-icon.png --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_dir" -o "$app_path/Contents/Resources/Rift.icns"
rm -r "$(dirname "$icon_dir")"
plutil -lint "$app_path/Contents/Info.plist"
codesign --force --deep --sign - "$app_path"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app_path"
printf 'Registered: %s\n' "$app_path"
