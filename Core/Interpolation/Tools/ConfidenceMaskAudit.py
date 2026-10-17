"""Read-only audit of saved E1/E2 arrays. Never launches Rift, Metal or video decoding."""
from pathlib import Path
import json,csv,zipfile,hashlib,re
import numpy as np
from PIL import Image,ImageDraw,ImageEnhance
ROOT=Path(__file__).resolve().parents[3];ASSETS=ROOT/'docs/diagnostics/assets'
E1=ASSETS/'confidence-e1-2026-10-17';E2=ASSETS/'confidence-e2-2026-10-17';PHASE=ASSETS/'trajectory-survival-2026-10-17';OUT=ASSETS/'confidence-mask-audit-2026-10-17';OUT.mkdir(exist_ok=True)
CASES=['avatar69','avatar300','anime1082'];W,H=1152,480;GW,GH=W//8,H//8
thresholds=json.loads((E1/'summary.json').read_text())['thresholds'];inputs={}
def record(p):inputs[str(p.relative_to(ROOT))]=hashlib.sha256(p.read_bytes()).hexdigest()
def signals(case,span,i):
 with zipfile.ZipFile(E1/case/'signals.zip') as z:return np.frombuffer(z.read(f'span{span}-pair{i}.f32'),dtype='<f4').reshape(-1,10)
def blocks(case):
 with zipfile.ZipFile(E2/case/'quality/block-errors.zip') as z:return np.frombuffer(z.read('block-errors.f32'),dtype='<f4').reshape(-1,6)
train=np.concatenate([signals(c,2,i)[:,:6] for c in CASES for i in range(18)])
trains=[np.sort(train[:,j][np.isfinite(train[:,j])]) for j in range(6)]
source=(ROOT/'Core/Interpolation/Swift/E2Calibration.swift').read_text();record(ROOT/'Core/Interpolation/Swift/E2Calibration.swift')
spans=[tuple(map(int,x)) for x in re.findall(r'SIMD2\((\d+),(\d+)\)',source.split('static let values')[0])]
table=np.fromstring(source.split('static let values: [Float] = [')[1].split(']')[0].replace('\n',''),sep=',',dtype='f4').reshape(-1,2)
assert len(spans)==6

def scores(a):
 exact=[];approx=[]
 for j,t in enumerate(trains):
  x=a[:,j];valid=np.isfinite(x);y=np.full(len(x),np.nan);z=y.copy()
  y[valid]=(np.searchsorted(t,x[valid],'left')+np.searchsorted(t,x[valid],'right'))/(2*len(t))
  offset,count=spans[j];v=table[offset:offset+count];z[valid]=np.interp(x[valid],v[:,0],v[:,1],left=0,right=1)
  exact.append(y);approx.append(z)
 return np.nanmean(exact,axis=0),np.nanmean(approx,axis=0)
def counts(mark,mask):
 tp=float(np.sum(mark*mask));n=float(mask.sum());p=float(mark.sum())
 return dict(maskPixels=n,markedPixels=p,intersectionPixels=tp,recall=tp/n if n else None,precision=tp/p if p else None)
def errors(a,risk,mark,mask):
 unmarked=mask & ~mark;err=a[:,8];bad=err>16;high=risk<float(thresholds['0.1']);strict=risk<=.5
 x=err[unmarked];r=risk[unmarked]
 return dict(maskBlocks=int(mask.sum()),unmarkedBlocks=int(unmarked.sum()),unmarkedPixels=int(unmarked.sum()*64),MAE10bit=float(x.mean()) if len(x) else None,riskMedian=float(np.median(r)) if len(r) else None,riskMin=float(r.min()) if len(r) else None,riskMax=float(r.max()) if len(r) else None,confidenceProxyMedian=float(np.median(1-r)) if len(r) else None,wrongUnmarkedBlocks=int((unmarked & bad).sum()),wrongHighConfidenceBlocks=int((unmarked & bad & high).sum()),wrongHighConfidencePixelSupport=int((unmarked & bad & high).sum()*64),wrongStrictConfidenceBlocks=int((unmarked & bad & strict).sum()),wrongAbove8=int((unmarked & (err>8)).sum()),wrongAbove32=int((unmarked & (err>32)).sum()))
record(E1/'summary.json')
coverage=[];truth=[];neighborhood=[];visual=[];checks=[]
for case in CASES:
 for p in [E1/case/'signals.zip',E2/case/'quality/block-errors.zip',PHASE/case/'regions.json']:record(p)
 rois=json.loads((PHASE/case/'regions.json').read_text());mask=np.zeros((H,W),bool)
 for roi in rois:
  x,y,w,h=roi['rect'];assert all(v%8==0 for v in [x,y,w,h]);mask[y:y+h,x:x+w]=True
 bm=mask.reshape(GH,8,GW,8).all(axis=(1,3)).reshape(-1);assert bm.sum()*64==mask.sum()
 Image.fromarray(mask.astype('u1')*255).save(OUT/f'{case}-roi-union.png')
 data=blocks(case)
 for span in [1,2]:
  a=signals(case,span,4);risk,gpuRisk=scores(a)
  maps={}
  for version,folder in [('E2-final','quality'),('E2-initial','initial-quality')]:
   path=E2/case/folder/f'span{span}-pair4-weights.f32';cache=OUT/f'{case}-span{span}-{version}-map.npz'
   if path.exists():
    record(path);m=np.fromfile(path,dtype='<f4').reshape(H,W,4);np.savez_compressed(cache,weight=m[:,:,0],risk=m[:,:,2])
   else:
    saved=np.load(cache);m=np.zeros((H,W,4),dtype='f4');m[:,:,0]=saved['weight'];m[:,:,2]=saved['risk']
   record(cache)
   marked=m[:,:,0]>0;fr=marked.reshape(GH,8,GW,8).mean(axis=(1,3)).reshape(-1);assert np.all((fr==0)|(fr==1))
   if version=='E2-final':
    known=m[:,:,2].reshape(GH,8,GW,8)[:,0,:,0].reshape(-1);delta=float(abs(known[fr>0]-gpuRisk[fr>0]).max()) if (fr>0).any() else 0;assert delta<2e-6;checks.append(dict(case=case,span=span,maxReconstructedRiskDifference=delta))
   maps[version]=marked
   coverage.append(dict(case=case,span=span,first=4,method=version,threshold='actual saved weight >0',**counts(marked,mask)))
   if span==2:truth.append(dict(case=case,method=version,**errors(a,gpuRisk,fr>0,bm)))
  for q,t in thresholds.items():
   marked=np.repeat(np.repeat((risk>=t).reshape(GH,GW),8,axis=0),8,axis=1)
   coverage.append(dict(case=case,span=span,first=4,method='E1-top'+str(float(q)*100),threshold=t,**counts(marked,mask)))
   if span==2 and q in ['0.05','0.1']:truth.append(dict(case=case,method='E1-top'+str(float(q)*100),**errors(a,risk,risk>=t,bm)))
  for suffix in ['before','after']:record(E2/case/'quality'/f'span{span}-pair4-{suffix}.png')
  for roi in rois:
   x,y,w,h=roi['rect'];roiMark=maps['E2-final'][y:y+h,x:x+w];before=Image.open(E2/case/'quality'/f'span{span}-pair4-before.png').convert('RGB');after=Image.open(E2/case/'quality'/f'span{span}-pair4-after.png').convert('RGB')
   canv=Image.new('RGB',(w*4,h*2+48),'white');draw=ImageDraw.Draw(canv)
   for k,(image,label) in enumerate([(before,'Motor actual'),(after,'E2 final')]):
    im=ImageEnhance.Brightness(image).enhance(1.8).crop((x,y,x+w,y+h)).resize((w*2,h*2),Image.Resampling.NEAREST);canv.paste(im,(k*w*2,24));draw.text((k*w*2+3,5),label,fill='black')
   draw.text((3,h*2+30),f'E2 marked in ROI: {roiMark.mean()*100:.3f}%; luma x1.8; pair4 span{span}',fill='black');name=f'{case}-{roi["name"]}-span{span}.png';canv.save(OUT/name)
   overlay=ImageEnhance.Brightness(before).enhance(1.8).crop((x,y,x+w,y+h));arr=np.array(overlay);arr[roiMark]=(arr[roiMark].astype(float)*.5+np.array([255,50,0])*.5).astype('u1');Image.fromarray(arr).resize((w*3,h*3),Image.Resampling.NEAREST).save(OUT/f'{case}-{roi["name"]}-span{span}-marked.png')
   if span==1 and roiMark.any():
    cells=roiMark.reshape(h//8,8,w//8,8).any(axis=(1,3));remaining=set(map(tuple,np.argwhere(cells)));largest=[]
    while remaining:
     todo=[remaining.pop()];component=[]
     while todo:
      yy,xx=todo.pop();component.append((yy,xx))
      for point in [(yy-1,xx),(yy+1,xx),(yy,xx-1),(yy,xx+1)]:
       if point in remaining:remaining.remove(point);todo.append(point)
     if len(component)>len(largest):largest=component
    ys,xs=zip(*largest);box=(x+max(0,min(xs)*8-4),y+max(0,min(ys)*8-4),x+min(w,(max(xs)+1)*8+4),y+min(h,(max(ys)+1)*8+4));cw=box[2]-box[0];ch=box[3]-box[1]
    detail=Image.new('RGB',(cw*8,ch*4+40),'white');dd=ImageDraw.Draw(detail)
    for col,(image,label) in enumerate([(before,'Motor actual'),(after,'E2')]):detail.paste(ImageEnhance.Brightness(image).enhance(1.8).crop(box).resize((cw*4,ch*4),Image.Resampling.NEAREST),(col*cw*4,20));dd.text((col*cw*4+2,3),label,fill='black')
    dd.text((2,ch*4+24),'Mayor componente marcada; 4px contexto; x1.8',fill='black');detail.save(OUT/f'{case}-{roi["name"]}-marked-detail.png')
   d=abs(np.array(before.crop((x,y,x+w,y+h))).astype(float)[:,:,0]-np.array(after.crop((x,y,x+w,y+h))).astype(float)[:,:,0]);gt={'markedBeforeMAE10bit':None,'markedAfterMAE10bit':None}
   if span==2:
    subset=data[(data[:,0]==2)&(data[:,1]==4)];rm=np.zeros((GH,GW),bool);rm[y//8:(y+h)//8,x//8:(x+w)//8]=True;selected=rm.reshape(-1)&(subset[:,3]>0)
    if selected.any():gt={'markedBeforeMAE10bit':float(subset[selected,4].mean()),'markedAfterMAE10bit':float(subset[selected,5].mean())}
   visual.append(dict(**gt,case=case,span=span,region=roi['name'],markedPixels=int(roiMark.sum()),maskPixels=w*h,changedPixels=int((d>0).sum()),markedMeanPreviewCodeChange=float(d[roiMark].mean()) if roiMark.any() else None,crop=name))
 # Fixed ROIs, all available adjacent pairs / triplets, NOT tracked defect masks.
 for span in [1,2]:
  rows=data[data[:,0]==span].reshape(-1,GW*GH,6);rec=[];prec=[]
  for i,b in enumerate(rows):
   a=signals(case,span,i);r,g=scores(a)
   if span==2:assert np.array_equal(a[:,8],b[:,4])
   for method,mark in [('E1-top10',r>=float(thresholds['0.1'])),('E1-top5',r>=float(thresholds['0.05'])),('E2-final',b[:,3])]:
    neighborhood.append(dict(case=case,span=span,first=i,crossesKnownCut=case=='anime1082' and ((span==1 and i==6) or (span==2 and i in [5,6])),method=method,**counts(mark*64,bm)))
    # counts above works in block space: convert mask support from blocks to pixels below.
    neighborhood[-1]['maskPixels']=int(bm.sum()*64);neighborhood[-1]['recall']=neighborhood[-1]['intersectionPixels']/neighborhood[-1]['maskPixels']

# Aggregate truth in fixed ROIs over the whole 49-frame fixture, with cut sensitivity.
windowTruth=[]
for case in CASES:
 rois=json.loads((PHASE/case/'regions.json').read_text());bm=np.zeros((GH,GW),bool)
 for roi in rois:
  x,y,w,h=roi['rect'];bm[y//8:(y+h)//8,x//8:(x+w)//8]=True
 bm=bm.reshape(-1);data=blocks(case);b=data[data[:,0]==2].reshape(47,GW*GH,6)
 aa=np.concatenate([signals(case,2,i) for i in range(47)]);risk,gpuRisk=scores(aa)
 for subset,ids in [('all47',list(range(47))),('withoutKnownCut',[i for i in range(47) if case!='anime1082' or i not in [5,6]])]:
  ix=np.concatenate([np.arange(i*GW*GH,(i+1)*GW*GH) for i in ids]);mask=np.tile(bm,len(ids));saved=b[ids].reshape(-1,6);assert np.all((saved[:,3]==0)|(saved[:,3]==1))
  for method,r,mark in [('E1-top10',risk[ix],risk[ix]>=float(thresholds['0.1'])),('E2-final',gpuRisk[ix],saved[:,3]>0)]:
   windowTruth.append(dict(case=case,subset=subset,triplets=len(ids),method=method,**errors(aa[ix],r,mark,mask)))
(OUT/'window-truth.json').write_text(json.dumps(windowTruth,indent=2,allow_nan=False)+'\n')

(OUT/'calibration-checks.json').write_text(json.dumps(checks,indent=2)+'\n')

# Independent small checks on overlap denominators, empty prediction and block grouping.
assert counts(np.array([1,0,1]),np.array([1,1,0]))['recall']==.5
assert counts(np.array([0,0]),np.array([1,0]))['precision'] is None
for name,rows in [('coverage',coverage),('truth',truth),('fixed-roi-per-pair',neighborhood),('visual',visual)]:
 (OUT/f'{name}.json').write_text(json.dumps(rows,indent=2,allow_nan=False)+'\n')
 if rows:
  with (OUT/f'{name}.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)
(OUT/'input-sha256.json').write_text(json.dumps(inputs,indent=2)+'\n')
print(json.dumps(dict(primary=[r for r in coverage if r['span']==1 and r['method'] in ['E1-top10.0','E1-top5.0','E2-final','E2-initial']],truth=truth),indent=2))

# Only recorded total wall times can be recovered. No missing stage is inferred.
runs=[];fields=set();profileLines=0
for state in ['off','on']:
 for i in range(1,6):
  err=E2/f'gui-{state}-{i}.err';log=E2/f'gui-{state}-{i}.log';record(err);record(log);text=err.read_text(errors='replace');output=log.read_text(errors='replace');rows=[]
  for line in text.splitlines():
   if line.startswith('RIFT_PAIR_TIMING,'):
    p=line.split(',');fields.add(len(p));assert len(p)==6;rows.append((int(p[1]),int(p[2]),int(p[3]),int(p[4]),float(p[5])))
  first=rows[0][0];values=np.array([r[4] for r in rows if r[0]>=first+10_000_000_000 and r[1:3]==(736,320)]);assert len(values)>400
  p95=float(np.sort(values)[int(np.ceil(.95*len(values)))-1]);profileLines+=output.count('DENSE GPU PROFILE')
  runs.append(dict(state=state,run=i,pairs=len(values),p95MS=p95,acquisitionMS=None,confidenceMS=None,blendMS=None,realAcquisitionLogLines=output.count('E2_TEMPORAL actual=1'),strongProcessedLogLines=output.count('processed=true bypass=false')))
def dispersion(v):return dict(median=float(np.median(v)),minimum=float(np.min(v)),maximum=float(np.max(v)),IQR=float(np.quantile(v,.75)-np.quantile(v,.25)),stdPopulation=float(np.std(v)))
groups={state:dispersion([r['p95MS'] for r in runs if r['state']==state]) for state in ['off','on']};paired=[next(r['p95MS'] for r in runs if r['state']=='on' and r['run']==i)-next(r['p95MS'] for r in runs if r['state']=='off' and r['run']==i) for i in range(1,6)]
assert profileLines==0 and fields=={6}
(OUT/'cost-audit.json').write_text(json.dumps(dict(runs=runs,groups=groups,deltaOfMediansMS=groups['on']['median']-groups['off']['median'],pairedP95DeltasMS=paired,pairedDeltaDispersion=dispersion(paired),stageTimingRecords=0,denseProfileLines=profileLines,recordedTimingFields=['tag','uptimeNS','workWidth','workHeight','subframeCount','totalWallMS'],conclusion='Stage breakdown not identifiable from existing recordings; no new runs or E2 activation.'),indent=2)+'\n')
(OUT/'input-sha256.json').write_text(json.dumps(inputs,indent=2)+'\n')
