"""Summarize paired native replay runs and bounded 10-second interventions."""
from pathlib import Path
import json,math,zipfile
import numpy as np
ROOT=Path(__file__).resolve().parents[3];OUT=ROOT/'docs/diagnostics/assets/confidence-e2-2026-10-17'
CASES=['avatar69','avatar300','anime1082','spider180','spider900','spider3600']
def coverage():
 rows=[]
 for case in CASES:
  folder=OUT/case/'clips'
  if not (folder/'metrics.json').exists():continue
  m=json.loads((folder/'metrics.json').read_text());r=m['records'];v=np.array([x['markedPixelFraction'] for x in r]);a=np.fromfile(folder/'block-errors.f32',dtype='<f4').reshape(len(r),-1,6);weights=a[:,:,2]
  changes=np.abs(np.diff(weights,axis=0));toggles=np.diff(weights>0,axis=0)!=0
  rows.append(dict(case=case,content='animation' if case in CASES[:3] else 'live-action',seconds=10,frames=m['clipFrames'],pairs=len(r),trustedPixelIdentity=m['trustedPixelIdentity'],median=float(np.median(v)),p95=float(np.quantile(v,.95,method='higher')),maximum=float(max(v)),meanWeight=float(weights.mean()),rawBlockWeightChangeP95=float(np.quantile(changes,.95)),rawBlockToggleFraction=float(toggles.mean()),caveat='Raw fixed-grid changes include motion and cuts; not a perceptual flicker proof. SDR grayscale diagnostic clips, not native HDR/color.'))
  with zipfile.ZipFile(folder/'block-errors.zip','w',zipfile.ZIP_DEFLATED) as z:z.write(folder/'block-errors.f32','block-errors.f32')
 (OUT/'clip-summary.json').write_text(json.dumps(rows,indent=2)+'\n');return rows
def timing():
 rows=[]
 for state in ['off','on']:
  for i in range(1,6):
   err=OUT/f'gui-{state}-{i}.err';log=OUT/f'gui-{state}-{i}.log'
   if not err.exists():continue
   data=[]
   for line in err.read_text(errors='replace').splitlines():
    if line.startswith('RIFT_PAIR_TIMING,'):
     p=line.split(',');data.append((int(p[1]),int(p[2]),int(p[3]),int(p[4]),float(p[5])))
   if not data:continue
   first=data[0][0];subset=[x for x in data if x[0]>=first+10_000_000_000]
   if not subset:continue
   geometry=max(set((x[1],x[2]) for x in subset),key=lambda g:sum((x[1],x[2])==g for x in subset));v=sorted(x[4] for x in subset if (x[1],x[2])==geometry)
   text=log.read_text(errors='replace');p95=v[math.ceil(.95*len(v))-1]
   rows.append(dict(state=state,run=i,p95MS=p95,pairs=len(v),workPlane=geometry,warmupSeconds=10,temporalAcquisitionEvidence='E2_TEMPORAL actual=1' in text,strongEvidence='processed=true' in text and 'strong' in text.lower()))
 groups={}
 for state in ['off','on']:
  v=[r['p95MS'] for r in rows if r['state']==state]
  if v:groups[state]=dict(runs=len(v),medianP95MS=float(np.median(v)),minP95MS=min(v),maxP95MS=max(v),iqrMS=float(np.quantile(v,.75)-np.quantile(v,.25)),stdMS=float(np.std(v)))
 result=dict(runs=rows,groups=groups,scope='Release actual M4; native GUI decode/Strong active; interpolation pair wall time includes temporal searches; not decode-to-display end-to-end latency.')
 if len(groups)==2:result.update(deltaMedianMS=groups['on']['medianP95MS']-groups['off']['medianP95MS'],passesPlus2MS=groups['on']['medianP95MS']<=groups['off']['medianP95MS']+2)
 (OUT/'playback-timing-summary.json').write_text(json.dumps(result,indent=2)+'\n');return result
if __name__=='__main__':print(json.dumps(dict(clips=coverage(),timing=timing()),indent=2))
