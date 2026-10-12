#!/usr/bin/env python3
"""Bundle the existing FFmpeg runtime and audit a local test distribution."""
import json, plistlib, re, shutil, subprocess, sys
from pathlib import Path

app = Path(sys.argv[1]).resolve()
frameworks = app / 'Contents/Frameworks'
frameworks.mkdir(parents=True, exist_ok=True)
exe = app / 'Contents/MacOS/Rift'

def run(*args):
    return subprocess.check_output(args, text=True)

def dependencies(path):
    return [line.strip().split(' (')[0] for line in run('otool', '-L', str(path)).splitlines()[1:]]

def system(path):
    return path.startswith(('/usr/lib/', '/System/Library/'))

copied = {}
queue = [exe]
records = []
while queue:
    binary = queue.pop(0)
    for dep in dependencies(binary):
        if system(dep) or dep.startswith('@'):
            continue
        original = Path(dep).resolve(strict=True)
        name = original.name
        if name in copied and copied[name] != original:
            raise RuntimeError(f'Conflicting libraries: {name}')
        if name not in copied:
            target = frameworks / name
            shutil.copy2(original, target)
            target.chmod(0o755)
            copied[name] = original
            queue.append(target)
            records.append({'library': name, 'origin': str(original)})
        replacement = ('@executable_path/../Frameworks/' if binary == exe else '@loader_path/') + name
        subprocess.run(['install_name_tool', '-change', dep, replacement, str(binary)], check=True)

minimum = (14, 0)
for binary in [exe, *frameworks.iterdir()]:
    if binary != exe:
        subprocess.run(['install_name_tool', '-id', '@loader_path/' + binary.name, str(binary)], check=True)
    build = run('vtool', '-show-build', str(binary))
    for version in re.findall(r'minos\s+([\d.]+)', build):
        minimum = max(minimum, tuple(map(int, version.split('.'))))
    for dep in dependencies(binary):
        if not system(dep) and not dep.startswith(('@loader_path/', '@executable_path/')):
            raise RuntimeError(f'Nonportable dependency: {binary.name}: {dep}')
    if 'arm64' not in run('lipo', '-archs', str(binary)):
        raise RuntimeError(f'Missing arm64: {binary}')

plist = app / 'Contents/Info.plist'
info = plistlib.loads(plist.read_bytes())
info['LSMinimumSystemVersion'] = '.'.join(map(str, minimum))
plist.write_bytes(plistlib.dumps(info))
resources = app / 'Contents/Resources'
# Preserve provenance for the recipient; it is not a runtime dependency.
(resources / 'BundledRuntime.json').write_text(json.dumps(records, indent=2))
(resources / 'Runtime-notice.txt').write_text('''Local test build. Apple Silicon; macOS ''' + info['LSMinimumSystemVersion'] + ''' or later.
FFmpeg 9.0.2 and its runtime dependencies are bundled, not downloaded at launch.
The installed FFmpeg build reports GPL v3 or later. This test packaging does not
constitute a public release licensing review. Corresponding source and license
materials must be prepared before wider distribution.
No Developer ID certificate is configured; this build is ad-hoc signed and is
not notarized. Do not describe it as an App Store or public-release build.
''')
for binary in frameworks.iterdir():
    subprocess.run(['codesign', '--force', '--sign', '-', str(binary)], check=True)
subprocess.run(['codesign', '--force', '--sign', '-', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print(f'Portable runtime: {len(copied)} libraries; macOS {info["LSMinimumSystemVersion"]}+')
