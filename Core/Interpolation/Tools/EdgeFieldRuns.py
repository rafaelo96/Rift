"""Bounded offline F2 comparisons; E2 always off, no source decoding or player changes."""
from pathlib import Path
import os,subprocess,argparse,json,hashlib
p=argparse.ArgumentParser();p.add_argument('phase',choices=['quality','timing','motion']);args=p.parse_args()
R=Path(__file__).resolve().parents[3];O=R/'docs/diagnostics/assets/edge-field-f2-2026-10-17';CASES=['avatar69','avatar300','anime1082']
for repeat in (range(1,6) if args.phase=='timing' else [0]):
 for state in ['off','on']:
  for case in CASES:
   out=O/case/(f'timing-{state}-{repeat}' if repeat else args.phase+'-'+state);out.mkdir(exist_ok=True);print(args.phase,repeat,state,case,flush=True)
   env=dict(os.environ,RIFT_E2='0',RIFT_PAIR_CONFIDENCE='0',RIFT_STATIC_MOTION_GUARD='1',RIFT_DENSE_PROFILE='0',MV_F2_DIAGNOSTIC='1',MV_F2_EDGE_REGULARIZE='1' if state=='on' else '0',MV_F2_PHASE=args.phase,MV_F2_OUTPUT=str(out),MV_F2_WINDOW=str(R/'docs/diagnostics/assets/trajectory-survival-2026-10-17'/case))
   with (out/'run.log').open('w') as log:subprocess.run([str(R/'.build/release/MVProbe')],env=env,cwd=R,stdout=log,stderr=subprocess.STDOUT,check=True)
if args.phase=='timing':
 (O/'timing-build.json').write_text(json.dumps(dict(configuration='Release',chip=subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),binarySHA256=hashlib.sha256((R/'.build/release/MVProbe').read_bytes()).hexdigest(),E2=False,stageScope='Offline work-plane; excludes source decode/Strong/native color. Same identity field hook in both arms; includes readback/reupload overhead.'),indent=2)+'\n')
