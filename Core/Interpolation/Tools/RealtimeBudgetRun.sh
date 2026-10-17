#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
probe_dir=$(mktemp -d /tmp/rift-realtime-budget.XXXXXX)
trap 'rm -rf "$probe_dir"' EXIT
python3 - "$probe_dir" <<'PY'
from pathlib import Path
import sys
source=Path('Core/Interpolation/Swift/DenseMotionPrototype.swift').read_text()
source=source.replace('public final class DenseMotionPrototype {','public final class RealtimeBudgetDense {',1)
old='if sample>0 {\n                guard let nextCommand=queue.makeCommandBuffer()'
assert source.count(old)==1
source=source.replace(old,'if sample>0 && downloadResults {\n                guard let nextCommand=queue.makeCommandBuffer()',1)
old='nativeRenderer?(time,nativeCoordinates,nativeBlend,command)\n            command.commit(); command.waitUntilCompleted()\n            guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline(command.error?.localizedDescription ?? "Dense GPU failure") }'
assert source.count(old)==1
new='''nativeRenderer?(time,nativeCoordinates,nativeBlend,command)
            if downloadResults || sample==times.count-1 {
                command.commit(); command.waitUntilCompleted()
                guard command.status == .completed else { throw MotionSearchEngine.EngineError.pipeline(command.error?.localizedDescription ?? "Dense GPU failure") }
            }'''
source=source.replace(old,new,1)
Path(sys.argv[1],'RealtimeBudgetDense.swift').write_text(source)
PY
cp Core/Interpolation/Tools/RealtimeBudgetBatching.swift.txt "$probe_dir/RealtimeBudgetBatching.swift"
swiftc -O -parse-as-library Core/Interpolation/Swift/*.swift "$probe_dir/RealtimeBudgetDense.swift" "$probe_dir/RealtimeBudgetBatching.swift" -o "$probe_dir/probe"
"$probe_dir/probe"
