"""Report E2 interventions and real-frame errors without hiding failing cases."""
from pathlib import Path
import json,zipfile,csv
import numpy as np
from DenseOracleReport import sheet,ROOT
OUT=ROOT/'docs/diagnostics/assets/confidence-e2-2026-10-17'
CASES=['avatar69','avatar300','anime1082','spider180','spider900','spider3600']
def summarize():
 summary=[]
 for case in CASES:
  folder=OUT/case/'quality';m=json.loads((folder/'metrics.json').read_text());a=np.fromfile(folder/'block-errors.f32',dtype='<f4').reshape(-1,6)
  assert m['trustedPixelIdentity'] and len(m['records'])==95
  for span in [1,2]:
   records=[r for r in m['records'] if r['span']==span];coverage=np.array([r['markedPixelFraction'] for r in records]);part=a[a[:,0]==span]
   row={'case':case,'span':span,'pairs':len(records),'degradedFractionMedian':float(np.median(coverage)),'degradedFractionP95':float(np.quantile(coverage,.95,method='higher')),'degradedFractionMax':float(max(coverage)),'changedFractionMedian':float(np.median([r['actualChangedFraction'] for r in records]))}
   if span==2:
    for name,mask in [('degraded',part[:,2]>0),('trusted',part[:,2]==0),('all',np.ones(len(part),bool))]:
     before=part[mask,4].astype(float);after=part[mask,5].astype(float)
     if name=='trusted':assert np.array_equal(before,after)
     if len(before)==0:
      row[name]={'blocks':0,'beforeMAE':None,'afterMAE':None,'relativeDeltaPercent':None,'improvedBlocks':0,'worsenedBlocks':0};continue
     row[name]={'blocks':int(mask.sum()),'beforeMAE':float(np.mean(before)),'afterMAE':float(np.mean(after)),'relativeDeltaPercent':float((after.mean()/before.mean()-1)*100) if before.mean()>0 else 0,'improvedBlocks':int((after<before).sum()),'worsenedBlocks':int((after>before).sum())}
   if span==2:
    row['pixelGroups']={}
    for group,prefix in [('degraded','degraded'),('trusted','trusted')]:
     count=sum(r[prefix+'Pixels'] for r in records)
     row['pixelGroups'][group]={'pixels':count,'beforeMAE':sum(max(0,r[prefix+'BeforeMAE'])*r[prefix+'Pixels'] for r in records)/count if count else None,'afterMAE':sum(max(0,r[prefix+'AfterMAE'])*r[prefix+'Pixels'] for r in records)/count if count else None}
    held=part[part[:,1]>=27];mask=held[:,2]>0
    row['E1HeldoutStarts27to46']={'blocks':len(held),'degradedBlocks':int(mask.sum()),'beforeMAE':float(held[:,4].astype(float).mean()),'afterMAE':float(held[:,5].astype(float).mean()),'degradedBeforeMAE':float(held[mask,4].astype(float).mean()) if mask.any() else None,'degradedAfterMAE':float(held[mask,5].astype(float).mean()) if mask.any() else None}
   summary.append(row)
  roiFile=ROOT/'docs/diagnostics/assets/trajectory-survival-2026-10-17'/case/'regions.json'
  rois=json.loads(roiFile.read_text()) if roiFile.exists() else [{'name':'central-motion','rect':[384,96,384,288]}]
  for roi in rois:
   for span in [1,2]:
    prefix=folder/f'span{span}-pair4'
    sheet([Path(str(prefix)+'-A.png'),Path(str(prefix)+'-B.png'),Path(str(prefix)+'-before.png'),Path(str(prefix)+'-after.png')],['Original A','Original B','Motor actual','E2; umbrales revisados'],roi['rect'],OUT/case/f"{roi['name']}-span{span}-comparison.png")
  with zipfile.ZipFile(folder/'block-errors.zip','w',zipfile.ZIP_DEFLATED) as z:z.write(folder/'block-errors.f32','block-errors.f32')
 (OUT/'quality-summary.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':summarize()
