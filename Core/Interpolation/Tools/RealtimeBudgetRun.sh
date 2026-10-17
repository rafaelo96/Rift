#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
probe_dir=$(mktemp -d /tmp/rift-realtime-budget.XXXXXX)
trap 'rm -rf "$probe_dir"' EXIT
python3 - "$probe_dir" <<'PY'
from pathlib import Path
import subprocess,sys
baseline=subprocess.check_output(['git','show','ad19cd9:Core/Interpolation/Swift/DenseMotionPrototype.swift'],text=True)
baseline=baseline.replace('public final class DenseMotionPrototype {','public final class RealtimeBudgetBaseline {',1)
Path(sys.argv[1],'RealtimeBudgetBaseline.swift').write_text(baseline)
comp=Path('Core/Interpolation/Swift/MotionCompensator.swift').read_text()
comp=comp[comp.index('public final class MotionCompensator {'):]
comp='import Foundation\nimport CoreVideo\nimport Metal\nimport Accelerate\n'+comp.replace('public final class MotionCompensator {','public final class RealtimeBudgetOriginalCompensator {',1).replace('DenseMotionPrototype','RealtimeBudgetBaseline')
Path(sys.argv[1],'RealtimeBudgetOriginalCompensator.swift').write_text(comp)
PY
cp Core/Interpolation/Tools/RealtimeBudgetBatching.swift.txt "$probe_dir/RealtimeBudgetBatching.swift"
swiftc -O -parse-as-library Core/Interpolation/Swift/*.swift "$probe_dir/RealtimeBudgetBaseline.swift" "$probe_dir/RealtimeBudgetOriginalCompensator.swift" "$probe_dir/RealtimeBudgetBatching.swift" -o "$probe_dir/probe"
"$probe_dir/probe"
