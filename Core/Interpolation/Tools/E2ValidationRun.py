"""Reproduce one E2 validation phase after swift build -c release. No full-movie export."""
from pathlib import Path
import argparse,subprocess,os,shutil
p=argparse.ArgumentParser();p.add_argument('phase',choices=['quality','clips','playback','reset']);args=p.parse_args()
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'docs/diagnostics/assets/confidence-e2-2026-10-17';PROBE=ROOT/'.build/release/MVProbe'
CASES=['avatar69','avatar300','anime1082','spider180','spider900','spider3600']
SOURCE='/Users/rafael/Downloads/Avatar.Aang.el.ultimo.maestro.del.aire.2026.WEB-DL.4k.HDR-Dual-Lat.mkv'
if args.phase in ['quality','clips']:
 for case in CASES:
  source=(ROOT/'docs/diagnostics/assets/trajectory-survival-2026-10-17'/case) if case in CASES[:3] else OUT/case/'chunk0'
  env=dict(os.environ,RIFT_STATIC_MOTION_GUARD='1',MV_E2_WINDOW=str(source),MV_E2_OUTPUT=str(OUT/case/args.phase))
  if args.phase=='clips':env.update(MV_E2_WINDOW=str(OUT/case/'sequence'),MV_E2_CLIPS='1')
  print(args.phase,case,flush=True)
  with (OUT/f'{case}-{args.phase}.log').open('w') as log:subprocess.run([str(PROBE)],cwd=ROOT,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
else:
 app=Path('/tmp/Rift-e2-confidence.app')
 if args.phase=='playback':
  template=Path('/tmp/Rift-e1-confidence.app')
  if not template.exists():template=Path.home()/'Applications/Rift.app'
  if app.exists():shutil.rmtree(app)
  shutil.copytree(template,app);shutil.copy2(ROOT/'.build/release/Rift',app/'Contents/MacOS/Rift')
  subprocess.run(['codesign','--force','--deep','--sign','-',str(app)],check=True)
 runs=[(f'gui-{state}-{i}',state) for i in range(1,6) for state in ['off','on']] if args.phase=='playback' else [('gui-reset','on')]
 for name,state in runs:
  print(name,flush=True)
  command=['/usr/bin/open','-n','-W',str(app),'--stdout',str(OUT/(name+'.log')),'--stderr',str(OUT/(name+'.err'))]
  envs=dict(RIFT_E2='1' if state=='on' else '0',RIFT_STATIC_MOTION_GUARD='1',RIFT_PAIR_CONFIDENCE='0',RIFT_DIAGNOSTICS='1',RIFT_PAIR_TIMING='1',RIFT_AUTO_OPEN=SOURCE,RIFT_AUTO_MODE='motion4x',RIFT_AUTO_SUPERRES='strong',RIFT_AUTO_SEEK_AT='1',RIFT_AUTO_SEEK_TO='69',RIFT_FLUENCY_PROBE_SECONDS='30')
  if args.phase=='reset':
   envs.pop('RIFT_AUTO_SEEK_AT');envs.pop('RIFT_AUTO_SEEK_TO');envs.update(RIFT_FLUENCY_PROBE_SECONDS='30',RIFT_FLUENCY_PROBE_CONTROLS='pause-seek')
  for key,value in envs.items():command+=['--env',key+'='+value]
  subprocess.run(command,check=True)
