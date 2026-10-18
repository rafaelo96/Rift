#!/bin/bash
set -euo pipefail
exec "$(cd "$(dirname "$0")/.." && pwd)/script/build_and_run.sh" --f2
