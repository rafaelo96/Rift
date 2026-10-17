"""Held-out, block-level confidence audit; scores only, never changes engine synthesis."""
from pathlib import Path
import csv,gzip,hashlib,json,math,zipfile
import numpy as np
from PIL import Image,ImageDraw,ImageEnhance
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'docs/diagnostics/assets/confidence-e1-2026-10-17'
CASES=['avatar69','avatar300','anime1082']
FEATURES=['fb_px','sad_texture','fold_fraction','inverse_px','temporal_px','AB_luma','existing_risk','combined']
COLS=[0,1,2,3,4,5,7]

def ranks(a):
    _,inv,counts=np.unique(a,return_inverse=True,return_counts=True)
    mid=np.cumsum(counts)-.5*(counts-1)
    return mid[inv]
def corr(a,b):
    if len(a)<2 or np.std(a)==0 or np.std(b)==0:return None
    return float(np.corrcoef(a,b)[0,1])
def auc(a,y):
    n=int(y.sum());m=len(y)-n
    if n==0 or m==0:return None
    return float((ranks(a)[y].sum()-n*(n+1)/2)/(n*m))
def empirical(train,x):
    t=np.sort(train[np.isfinite(train)]);out=np.full(x.shape,np.nan)
    mask=np.isfinite(x)
    out[mask]=(np.searchsorted(t,x[mask],side='left')+np.searchsorted(t,x[mask],side='right'))/(2*len(t))
    return out

def write(value,path):path.write_text(json.dumps(value,indent=2,allow_nan=False)+'\n')
def csvwrite(rows,path):
    with path.open('w') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator='\n');w.writeheader();w.writerows(rows)
def rocsvg(curves,path,title):
    colors=['#0072B2','#E69F00','#009E73','#CC79A7','#56B4E9','#D55E00','#777777','#000000']
    svg=['<svg xmlns="http://www.w3.org/2000/svg" width="760" height="580" viewBox="0 0 760 580"><rect width="760" height="580" fill="white"/>',f'<text x="45" y="25" font-family="sans-serif" font-size="17">{title}; error &gt;16/1023</text>']
    for t in [0,.2,.4,.6,.8,1]:
        x=65+t*440;y=490-t*440
        svg += [f'<path d="M{x} 50V490 M65 {y}H505" stroke="#ddd"/>',f'<text x="{x-8}" y="510" font-size="12">{t:.1f}</text>',f'<text x="35" y="{y+4}" font-size="12">{t:.1f}</text>']
    for name,color in zip(FEATURES,colors):
        points=[r for r in curves if r['signal']==name];coords=' '.join(f"{65+440*r['FPR']},{490-440*r['TPR']}" for r in points if r['FPR'] is not None and r['TPR'] is not None)
        svg += [f'<polyline points="{coords}" fill="none" stroke="{color}" stroke-width="2"/>',f'<text x="530" y="{65+25*FEATURES.index(name)}" font-family="sans-serif" fill="{color}" font-size="13">{name}</text>']
    svg += ['<text x="210" y="550" font-family="sans-serif">False-positive fraction</text><text x="6" y="35" font-family="sans-serif">TPR</text></svg>'];path.write_text('\n'.join(svg))

def main():
    # Unit checks cover tied ranks, perfect/reversed discrimination and constant signals.
    assert np.allclose(ranks(np.array([1,1,2])),[1.5,1.5,3])
    assert auc(np.array([0.,1.,2.,3.]),np.array([False,False,True,True]))==1
    assert auc(np.array([3.,2.,1.,0.]),np.array([False,False,True,True]))==0
    assert corr(np.ones(4),np.arange(4)) is None
    arrays=[];metadata=[];offset=0
    for case in CASES:
        folder=OUT/case;m=json.loads((folder/'manifest.json').read_text());assert len(m['records'])==95
        for r in m['records']:
            a=np.fromfile(folder/(r['name']+'.f32'),dtype='<f4').reshape(-1,10)
            assert len(a)==8640 and np.isfinite(a[:,[0,1,2,3,5,6,7,9]]).all()
            assert r['signalCalls']==1 and not r['contextUsesHiddenFrame']
            arrays.append(a);metadata.append(dict(r,case=case,begin=offset,end=offset+len(a)));offset+=len(a)
        with zipfile.ZipFile(folder/'signals.zip','w',zipfile.ZIP_DEFLATED) as z:
            for f in sorted(folder.glob('*.f32')):z.write(f,f.name)
    data=np.concatenate(arrays);train=np.zeros(len(data),bool);test=train.copy();truth=train.copy();groups=np.empty(len(data),dtype='u1')
    for r in metadata:
        sl=slice(r['begin'],r['end']);groups[sl]=CASES.index(r['case']);truth[sl]=r['span']==2
        if r['span']==2:
            train[sl]=r['first']<=17;test[sl]=r['first']>=27
    assert int(truth.sum())==141*8640 and train.sum()==54*8640 and test.sum()==60*8640
    features=data[:,COLS].astype('f8');normal=np.column_stack([empirical(features[train,j],features[:,j]) for j in range(6)])
    combined=np.nanmean(normal,axis=1);scores=np.column_stack([features,combined]);errors=data[:,8]
    thresholds={name:[float(np.quantile(scores[train,k][np.isfinite(scores[train,k])],q)) for q in np.linspace(1,0,101)] for k,name in enumerate(FEATURES)}
    statistics=[];curves=[];coverage=[]
    for group in ['animation',*CASES]:
        select=test & (np.ones(len(data),bool) if group=='animation' else groups==CASES.index(group));y=errors[select]>16
        for k,name in enumerate(FEATURES):
            x=scores[select,k];valid=np.isfinite(x);e=errors[select][valid]
            statistics.append({'group':group,'signal':name,'blocks':int(select.sum()),'availableFraction':float(valid.mean()),'Pearson':corr(x[valid],e),'Spearman':corr(ranks(x[valid]),ranks(e)),'AUROC_MAE_gt8':auc(x[valid],e>8),'AUROC_MAE_gt16':auc(x[valid],e>16),'AUROC_MAE_gt32':auc(x[valid],e>32),'positiveFraction_gt16':float(y.mean())})
            for t in [math.inf,*thresholds[name],-math.inf]:
                marked=valid & (x>=t);tp=int((marked&y).sum());fp=int((marked&~y).sum());positives=int(y.sum());negatives=len(y)-positives
                curves.append({'group':group,'signal':name,'threshold':str(t),'TPR':tp/positives if positives else None,'FPR':fp/negatives if negatives else None,'precision':tp/int(marked.sum()) if marked.any() else None,'markedPixelFraction':float(marked.mean())})
        rocsvg([r for r in curves if r['group']==group],OUT/f'roc-{group}.svg',f'Held-out {group}')
    comboThresholds={str(p):float(np.quantile(combined[train],1-p)) for p in [.01,.02,.05,.10,.20,.30,.50]}
    perPair=[]
    for r in metadata:
        sl=slice(r['begin'],r['end']);x=combined[sl]
        for p,t in comboThresholds.items():
            marked=x>=t
            perPair.append({'case':r['case'],'span':r['span'],'first':r['first'],'last':r['last'],'calibrationTargetFraction':p,'threshold':t,'markedPixelFraction':float(marked.mean()),'actualDegradedPixelFraction':0})
    for case in CASES:
        for span in [1,2]:
            for p,t in comboThresholds.items():
                rows=[r for r in perPair if r['case']==case and r['span']==span and r['calibrationTargetFraction']==p]
                coverage.append({'case':case,'span':span,'targetCalibrationFraction':float(p),'threshold':t,'markedPixelFraction':float(np.mean([r['markedPixelFraction'] for r in rows])),'maxPairMarkedFraction':max(r['markedPixelFraction'] for r in rows),'actualDegradedFraction':0})
    # The primary crop lies in calibration; explicitly label it rather than claiming held-out evidence.
    for case in CASES:
        record=next(r for r in metadata if r['case']==case and r['span']==2 and r['first']==4)
        folder=OUT/case;prefix='span2-pair4';source=ImageEnhance.Brightness(Image.open(folder/f'{prefix}-prediction.png').convert('RGB')).enhance(1.8)
        draw=ImageDraw.Draw(source);marked=combined[record['begin']:record['end']]>=comboThresholds['0.1']
        for k in np.flatnonzero(marked):
            x=int(k%144)*8;y=int(k//144)*8;draw.rectangle((x,y,x+7,y+7),outline='red')
        source.save(folder/'diagnostic-mask-10pct-calibration.png')
        rois=json.loads((ROOT/'docs/diagnostics/assets/trajectory-survival-2026-10-17'/case/'regions.json').read_text())
        for roi in rois:
            x,y,w,h=roi['rect'];canvas=Image.new('RGB',(w*2*5,h*2+50),'white');d=ImageDraw.Draw(canvas)
            images=[Image.open(folder/f'{prefix}-{n}.png').convert('RGB') for n in ['A','B','prediction','truth']]+[source]
            for j,(image,label) in enumerate(zip(images,['A','B','Motor sin cambios','Central real','Marcaria; calibracion'])):
                if j<4:image=ImageEnhance.Brightness(image).enhance(1.8)
                tile=image.crop((x,y,x+w,y+h)).resize((w*2,h*2),Image.Resampling.NEAREST);canvas.paste(tile,(j*w*2,24));d.text((j*w*2+3,5),label,fill='black')
            d.text((3,h*2+32),'Solo diagnostico: ningun pixel degradado. Rojo=umbral calibrado al 10%; no implica verdad de error.',fill='black');canvas.save(folder/(roi['name']+'-comparison.png'))
    write(statistics,OUT/'statistics.json');csvwrite(curves,OUT/'curves.csv');csvwrite(perPair,OUT/'per-pair-coverage.csv');write(coverage,OUT/'coverage.json')
    write({'triplets':141,'adjacentPairs':144,'tripletBlocks':141*8640,'trainPairs':54,'testPairs':60,'embargoedPairs':27,'trainFirstIndex':'0..17','testFirstIndex':'27..46','contentGroups':{'animation':141,'liveAction':0},'combination':'Equal mean of six train empirical mid-CDF ranks, omitting unavailable temporal evidence; thresholds trained without test labels. Existing risk is a separate comparator. No learned network/model.','positiveBlockDefinition':'Real central reconstruction MAE >16 ten-bit codes; alternatives >8 and >32 reported','thresholds':comboThresholds,'signalDefinitions':'See report; canonical midpoint block-center diagnostics, texture from transported 8x8 source patch.','identityOutputs':573,'degradedPixels':0},OUT/'summary.json')
    print(json.dumps([r for r in statistics if r['group']=='animation'],indent=2))
if __name__=='__main__':main()
