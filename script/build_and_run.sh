#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
f2=0
case "${1:-}" in
    --f2) f2=1 ;;
    --baseline|"") ;;
    *) echo "Usage: $0 [--f2|--baseline]" >&2; exit 2 ;;
esac
app_path="$project_root/dist/Rift.app"
# Restart only Rift; no other application is touched.
pkill -x Rift || true
"$project_root/distribution/build-local-app.sh" "$app_path"
/usr/bin/open -n "$app_path" --env "RIFT_FRAMEPLUS_F2=$f2" --env RIFT_E2=0
printf 'Frame+ F2=%s; E2=0\n' "$f2"
