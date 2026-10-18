"""F1 only: CPU structural diagnostics on saved E2-OFF triplet PNGs; never runs the engine."""
from pathlib import Path
import json,hashlib,csv
import numpy as np
from PIL import Image,ImageDraw,ImageEnhance
ROOT=Path(__file__).resolve().parents[3];ASSETS=ROOT/'docs/diagnostics/assets';SOURCE=ASSETS/'confidence-e2-2026-10-17';ROIS=ASSETS/'trajectory-survival-2026-10-17';OUT=ASSETS/'structural-masks-f1-2026-10-17'
CASES=['avatar69','avatar300','anime1082'];PARAMS={'pairFirst':4,'span':2,'prediction':'E2-off before PNG','inputBits':8,'ssimWindow':11,'ssimGaussianSigma':1.5,'K1':.01,'K2':.03,'gradient':'3x3 Sobel /8, reflect padding, vector difference magnitude','sensitiveSSIMLoss':.01,'sensitiveGradientCodesPerPixel':.5,'coreSSIMLoss':.1,'coreGradientCodesPerPixel':2,'minimumSensitiveComponentPixels':8,'connectivity':4,'morphologicalExpansion':False,'status':'CANDIDATE; NOT VALIDATED; NOT USED FOR F2'}

def separable(a,k):
 p=len(k)//2;v=np.pad(a,((p,p),(0,0)),mode='reflect');b=sum(k[i]*v[i:i+a.shape[0]] for i in range(len(k)));v=np.pad(b,((0,0),(p,p)),mode='reflect');return sum(k[i]*v[:,i:i+a.shape[1]] for i in range(len(k)))
def gradient(a):
 p=np.pad(a,1,mode='reflect');h,w=a.shape
 def z(y,x):return p[y:y+h,x:x+w]
 return ((z(0,2)+2*z(1,2)+z(2,2)-z(0,0)-2*z(1,0)-z(2,0))/8,(z(2,0)+2*z(2,1)+z(2,2)-z(0,0)-2*z(0,1)-z(0,2))/8)
def structure(a,b):
 k=np.exp(-np.arange(-5,6,dtype=float)**2/(2*1.5**2));k/=k.sum();u=separable(a,k);v=separable(b,k);aa=np.maximum(separable(a*a,k)-u*u,0);bb=np.maximum(separable(b*b,k)-v*v,0);ab=separable(a*b,k)-u*v
 s=((2*u*v+.01**2)*(2*ab+.03**2))/((u*u+v*v+.01**2)*(aa+bb+.03**2));s=np.clip(s,-1,1);ax,ay=gradient(a);bx,by=gradient(b);return s,np.hypot(ax-bx,ay-by)
def remove_small(mask,minimum):
 remaining=set(map(tuple,np.argwhere(mask)));result=np.zeros_like(mask);sizes=[]
 while remaining:
  todo=[remaining.pop()];component=[]
  while todo:
   y,x=todo.pop();component.append((y,x))
   for q in [(y-1,x),(y+1,x),(y,x-1),(y,x+1)]:
    if q in remaining:remaining.remove(q);todo.append(q)
  if len(component)>=minimum:
   for y,x in component:result[y,x]=True
   sizes.append(len(component))
 return result,sorted(sizes,reverse=True)
def metrics(a,b,ssim,g,mask):
 n=int(mask.sum())
 return {'pixels':n,'MAE8bitCodes':float(np.mean(abs(a-b)[mask])*255) if n else None,'gradientVectorError8bitCodesPerPixel':float(g[mask].mean()*255) if n else None,'localSSIMMean':float(ssim[mask].mean()) if n else None,'localSSIMLossMean':float((1-ssim[mask]).mean()) if n else None}
def overlay(image,mask,core):
 x=np.asarray(ImageEnhance.Brightness(image.convert('RGB')).enhance(1.8)).copy();x[mask]=(x[mask]*.55+np.array([255,165,0])*.45).astype('u1');x[core]=(x[core]*.45+np.array([255,0,60])*.55).astype('u1');return Image.fromarray(x)

def main():
    OUT.mkdir(exist_ok=True)
    # Exact identity and a translated edge check shape sensitivity independently of mask selection.
    a=np.zeros((40,40));a[:,20:]=.7;s,g=structure(a,a);assert np.max(abs(s-1))<1e-10 and g.max()==0
    b=np.roll(a,2,axis=1);s,g=structure(a,b);assert (1-s[:,16:24]).mean()>.05 and g[:,16:24].mean()>0
    assert remove_small(np.array([[1,0,0],[0,0,1],[0,0,1]],bool),2)[0].sum()==2
    rows=[];inputs={};summary=[]
    for case in CASES:
     folder=OUT/case;folder.mkdir(exist_ok=True);prefix=SOURCE/case/'quality/span2-pair4';pp=Path(str(prefix)+'-before.png');tp=Path(str(prefix)+'-truth.png');rp=ROIS/case/'regions.json'
     for p in [pp,tp,rp]:inputs[str(p.relative_to(ROOT))]=hashlib.sha256(p.read_bytes()).hexdigest()
     pred=Image.open(pp).convert('L');truth=Image.open(tp).convert('L');a=np.asarray(pred).astype(float)/255;b=np.asarray(truth).astype(float)/255;assert a.shape==b.shape==(480,1152)
     rois=json.loads(rp.read_text());union=np.zeros_like(a,dtype=bool)
     for roi in rois:
      x,y,w,h=roi['rect'];union[y:y+h,x:x+w]=True
     ssim,g=structure(a,b);loss=1-ssim;raw=union&(loss>=.01)&(g*255>=.5);candidate,sizes=remove_small(raw,8);core=candidate&(loss>=.1)&(g*255>=2);assert not (candidate&~union).any() and not (core&~candidate).any()
     for name,mask in [('roi',union),('candidate-raw',raw),('candidate',candidate),('core',core)]:Image.fromarray(mask.astype('u1')*255).save(folder/(name+'.png'))
     np.savez_compressed(folder/'maps.npz',localSSIM=ssim.astype('f4'),gradientErrorCodes=(g*255).astype('f4'))
     overlay(pred,candidate,core).save(folder/'prediction-overlay.png');overlay(truth,candidate,core).save(folder/'truth-overlay.png')
     # Grayscale maps use fixed ranges shared by all cases, not per-image contrast normalization.
     Image.fromarray(np.uint8(np.clip(loss/.3,0,1)*255)).save(folder/'ssim-loss-map.png');Image.fromarray(np.uint8(np.clip(g*255/8,0,1)*255)).save(folder/'gradient-error-map.png')
     for roi in rois:
      x,y,w,h=roi['rect'];rm=np.zeros_like(union);rm[y:y+h,x:x+w]=True;rect=(x,y,x+w,y+h);scale=3
      sheet=Image.new('RGB',(w*scale*4,h*scale+54),'white');d=ImageDraw.Draw(sheet)
      panels=[(ImageEnhance.Brightness(pred.convert('RGB')).enhance(1.8),'Motor actual (E2 OFF)'),(ImageEnhance.Brightness(truth.convert('RGB')).enhance(1.8),'Central real I5'),(overlay(pred,candidate,core),'Candidata sobre motor'),(overlay(truth,candidate,core),'Candidata sobre real')]
      for i,(im,label) in enumerate(panels):sheet.paste(im.crop(rect).resize((w*scale,h*scale),Image.Resampling.NEAREST),(i*w*scale,26));d.text((i*w*scale+3,5),label,fill='black')
      d.text((4,h*scale+32),'NARANJA: sensible; ROJO: nucleo exigente. CANDIDATAS SIN VALIDAR. Luma x1.8; metricas sin realce.',fill='black');sheet.save(folder/(roi['name']+'-review.png'))
      for name,mask in [('ROI',rm),('candidate',rm&candidate),('core',rm&core)]:rows.append(dict(case=case,region=roi['name'],mask=name,**metrics(a,b,ssim,g,mask)))
     reviews=[Image.open(folder/(roi['name']+'-review.png')) for roi in rois]
     sheet=Image.new('RGB',(max(im.width for im in reviews),sum(im.height+24 for im in reviews)+36),'white');d=ImageDraw.Draw(sheet);d.text((4,5),f'{case}: F1 CANDIDATAS, pendientes de validacion. No son etiquetas de verdad.',fill='black');yy=36
     for roi,im in zip(rois,reviews):d.text((4,yy),roi['name']+' '+str(roi['rect']),fill='black');sheet.paste(im,(0,yy+24));yy+=im.height+24
     sheet.save(folder/'case-review.png')
     for name,mask in [('ROI',union),('candidate',candidate),('core',core)]:rows.append(dict(case=case,region='union',mask=name,**metrics(a,b,ssim,g,mask)))
     summary.append({'case':case,'roiPixels':int(union.sum()),'rawCandidatePixels':int(raw.sum()),'candidatePixels':int(candidate.sum()),'corePixels':int(core.sum()),'candidateFractionOfROI':float(candidate.sum()/union.sum()),'retainedComponents':len(sizes),'componentSizes':sizes,'validated':False})
    (OUT/'parameters.json').write_text(json.dumps(PARAMS,indent=2)+'\n');(OUT/'summary.json').write_text(json.dumps(summary,indent=2)+'\n');(OUT/'baseline.json').write_text(json.dumps(rows,indent=2,allow_nan=False)+'\n');(OUT/'input-sha256.json').write_text(json.dumps(inputs,indent=2)+'\n')
    with (OUT/'baseline.csv').open('w') as f:w=csv.DictWriter(f,fieldnames=list(rows[0]),lineterminator='\n');w.writeheader();w.writerows(rows)
    print(json.dumps({'summary':summary,'baseline':[r for r in rows if r['region']=='union']},indent=2))

if __name__=="__main__":main()
