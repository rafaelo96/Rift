"""Evaluate frozen principal/secondary masks, outside error, motion and offline stage traces."""
from pathlib import Path
import json,math,zipfile,csv
import numpy as np
from PIL import Image,ImageDraw,ImageEnhance
from StructuralMaskCandidates import structure,metrics
R=Path(__file__).resolve().parents[3];O=R/'docs/diagnostics/assets/edge-field-f2-2026-10-17';F=R/'docs/diagnostics/assets/structural-masks-f1-2026-10-17';CASES=['avatar69','avatar300','anime1082']
quality=[];movement=[];timing=[]
def dispersion(v):return dict(median=float(np.median(v)),minimum=float(min(v)),maximum=float(max(v)),IQR=float(np.quantile(v,.75)-np.quantile(v,.25)),std=float(np.std(v)))
def percent95(v):return float(sorted(v)[math.ceil(.95*len(v))-1])
for case in CASES:
 folder=O/case;a=np.array(Image.open(folder/'quality-off/prediction.png')).astype(float)/255;b=np.array(Image.open(folder/'quality-on/prediction.png')).astype(float)/255;t=np.array(Image.open(folder/'quality-off/truth.png')).astype(float)/255
 ordinary=np.array(Image.open(folder/'quality-on/ordinary.png'));assert np.array_equal(a*255,ordinary)
 reference=Image.open(R/f'docs/diagnostics/assets/confidence-e2-2026-10-17/{case}/quality/span2-pair4-before.png');assert np.array_equal(np.array(reference),ordinary)
 sa,ga=structure(a,t);sb,gb=structure(b,t);primary=np.array(Image.open(folder/'primary-mask.png'))>0;secondary=np.array(Image.open(folder/'secondary-mask.png'))>0;roi=np.array(Image.open(F/case/'roi.png'))>0
 for label,mask in [('principal',primary),('secondary',secondary),('outsidePrincipalFullFrame',~primary),('outsidePrincipalWithinROI',roi&~primary)]:
  before=metrics(a,t,sa,ga,mask);after=metrics(b,t,sb,gb,mask);ea=abs(a-t)*255;eb=abs(b-t)*255;n=mask.sum()
  quality.append(dict(case=case,mask=label,before=before,after=after,changedFraction=float((a[mask]!=b[mask]).mean()) if n else None,worsePixelMAEFraction=float((eb[mask]>ea[mask]+1e-9).mean()) if n else None,worseLocalSSIMFraction=float((sb[mask]<sa[mask]-1e-9).mean()) if n else None))
 rois=json.loads((R/f'docs/diagnostics/assets/trajectory-survival-2026-10-17/{case}/regions.json').read_text())
 for r in rois:
  x,y,w,h=r['rect'];canvas=Image.new('RGB',(w*6,h*3+45),'white');d=ImageDraw.Draw(canvas)
  for k,(path,label) in enumerate([(folder/'quality-off/prediction.png','Motor actual'),(folder/'quality-on/prediction.png','Regularizado')]):
   im=ImageEnhance.Brightness(Image.open(path).convert('RGB')).enhance(1.8).crop((x,y,x+w,y+h)).resize((w*3,h*3),Image.Resampling.NEAREST);canvas.paste(im,(k*w*3,22));d.text((k*w*3+3,4),label,fill='black')
  d.text((3,h*3+27),'Triplete I4/I6 -> I5; E2 OFF; luma x1.8',fill='black');canvas.save(folder/(r['name']+'-comparison.png'))
 # Same F1 metric implementation must reproduce the frozen original baseline on its sensitive mask.
 original=next(x for x in json.loads((F/'baseline.json').read_text()) if x['case']==case and x['region']=='union' and x['mask']=='candidate');actual=metrics(a,t,sa,ga,secondary)
 for key in ['MAE8bitCodes','gradientVectorError8bitCodesPerPixel','localSSIMMean']:assert abs(actual[key]-original[key])<1e-10
 if (folder/'motion-on/block-motion.f32').exists():
  off=np.fromfile(folder/'motion-off/block-motion.f32',dtype='<f4').reshape(-1,7);on=np.fromfile(folder/'motion-on/block-motion.f32',dtype='<f4').reshape(-1,7);assert np.array_equal(off[:,:5],on[:,:5]);assert np.array_equal(off[:,3:5],off[:,5:7])
  for r in rois:
   if r['name'] not in ['pan-background','landscape-pan']:continue
   x,y,w,h=r['rect'];sel=(on[:,1]>=x)&(on[:,1]<x+w)&(on[:,2]>=y)&(on[:,2]<y+h)
   if case=='anime1082':sel&=on[:,0]!=6
   a0=on[sel,3:5].astype(float);b0=on[sel,5:7].astype(float);aa=np.linalg.norm(a0,axis=1);bb=np.linalg.norm(b0,axis=1);change=np.linalg.norm(a0-b0,axis=1)
   movement.append(dict(case=case,region=r['name'],blockPairObservations=len(a0),meanVectorBefore=a0.mean(axis=0).tolist(),meanVectorAfter=b0.mean(axis=0).tolist(),meanMagnitudeBefore=float(aa.mean()),meanMagnitudeAfter=float(bb.mean()),meanMagnitudeRelativeDeltaPercent=float((bb.mean()/aa.mean()-1)*100) if aa.mean() else None,meanVectorChange=float(change.mean()),p95VectorChange=percent95(change.tolist()),changedBlocksFraction=float((change>.001).mean()),scope='Estimated final vectors, not physical motion truth. Known anime cut pair6 excluded.'))
  for state in ['off','on']:
   path=folder/f'motion-{state}/block-motion.f32'
   with zipfile.ZipFile(path.with_suffix('.zip'),'w',zipfile.ZIP_DEFLATED) as z:z.write(path,path.name)
for state in ['off','on']:
 for run in range(1,6):
  corpus=[]
  for case in CASES:
   path=O/case/f'timing-{state}-{run}/metrics.json'
   if not path.exists():continue
   records=json.loads(path.read_text())['records'];steady=[r for r in records if r['first']>=4];assert len(steady)==44
   corpus+=steady
   timing.append(dict(state=state,run=run,case=case,pairs=44,**{key:percent95([r[key] for r in steady]) for key in ['MEms','regularizationMS','synthesisMS','totalMS']}))
  if len(corpus)==132:timing.append(dict(state=state,run=run,case='all',pairs=132,**{key:percent95([r[key] for r in corpus]) for key in ['MEms','regularizationMS','synthesisMS','totalMS']}))
summary=[]
for case in [*CASES,'all']:
 for state in ['off','on']:
  rows=[r for r in timing if r['case']==case and r['state']==state]
  if len(rows)==5:summary.append(dict(case=case,state=state,runs=5,stages={key:dispersion([r[key] for r in rows]) for key in ['MEms','regularizationMS','synthesisMS','totalMS']}))
for name,data in [('quality',quality),('motion',movement),('timing-per-run',timing),('timing-summary',summary)]: (O/(name+'.json')).write_text(json.dumps(data,indent=2,allow_nan=False)+'\n')
print(json.dumps({'quality':quality,'motion':movement,'timing':summary},indent=2))
