"""Replay committed, bounded diagnostic inputs. Runs GPU work sequentially in Release."""
import argparse
import hashlib
import gzip
import json
import os
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[3]
ASSETS = ROOT/'docs/diagnostics/assets/trajectory-survival-2026-10-17'


def run(args, log, **settings):
    with log.open('w') as output:
        subprocess.run(args, cwd=ROOT, env=dict(os.environ, **settings),
                       stdout=output, stderr=subprocess.STDOUT, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    if not args.skip_build:
        run(['swift','build','-c','release','--product','MVProbe'], ASSETS/'build.log')
    binary = str(ROOT/'.build/release/MVProbe')
    for enabled in ['0','1']:
        run([binary], ASSETS/f'check-{enabled}.log',
            MV_TRAJECTORY_CHECK='1', RIFT_DENSE_CANDIDATES=enabled)
    hashes = [(ASSETS/f'check-{enabled}.log').read_text().split('sha256=')[-1].strip() for enabled in ['0','1']]
    assert hashes[0] == hashes[1], 'Diagnostic compile variant changed synthetic output'
    run([binary], ASSETS/'dense-regression.log',MV_DENSE_CHECK='1',MV_DENSE_PATCH='1',RIFT_DENSE_CANDIDATES='0')
    run([binary], ASSETS/'native-regression.log',MV_NATIVE_PATCH_CHECK='1',RIFT_DENSE_CANDIDATES='0')
    folders = []
    for name in ['avatar69','avatar300','anime1082']:
        folder = ASSETS/name
        if not (folder/'source_0.u16').exists():
            with zipfile.ZipFile(folder/'sources.zip') as archive:
                # Only known flat fixture filenames may be restored inside this folder.
                assert all('/' not in n and n.startswith('source_') and n.endswith('.u16') for n in archive.namelist())
                archive.extractall(folder)
        manifest=json.loads((folder/'manifest.json').read_text())
        for i, expected in enumerate(manifest['sha256']):
            assert hashlib.sha256((folder/f'source_{i}.u16').read_bytes()).hexdigest()==expected, 'Fixture checksum mismatch'
        for pair in [2,3,4,5,6]:
            run([binary],ASSETS/f'{name}-trace{pair}.log',MV_TRAJECTORY_REPLAY=str(folder),
                MV_TRAJECTORY_PAIR=str(pair),RIFT_DENSE_CANDIDATES='1',RIFT_PATCH_TEMPORAL='1',RIFT_PATCH_AFFINE='0')
            trace=folder/f'pair_{pair}'
            (trace/'stages.json.gz').write_bytes(gzip.compress((trace/'stages.json').read_bytes(),mtime=0))
            folders.append(str(trace))
    run(['python3',str(ROOT/'Core/Interpolation/Tools/TrajectorySurvivalReport.py'),'--selfcheck',*folders],ASSETS/'summary.log')
    sources = ['Core/Interpolation/Swift/DenseMotionShaders.swift',
               'Core/Interpolation/Swift/DenseMotionPrototype.swift',
               'Core/Interpolation/Tools/TrajectoryDiagnostic.swift',
               'Core/Interpolation/Tools/TrajectorySurvivalReport.py']
    info = {'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),
            'chip':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
            'sha256':{p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in sources},
            'configuration':{'build':'Release','workPlane':[1152,480],'lambda':1,'temporal':True,'affine':False,
                             'oracleRadius':256,'oracleLattice':'integer','oracleGap':0.1,'vectorTolerance':1.5},
            'scope':'Offline forward-reference experiment. Timings excluded. No GUI performance/quality acceptance.'}
    (ASSETS/'execution.json').write_text(json.dumps(info,indent=2)+'\n')
    print('Trajectory traces, selfchecks and regressions saved in',ASSETS)


if __name__ == '__main__':
    main()
