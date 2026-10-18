"""Compare all saved triplets; fixed face ROI, no parameter fitting or motor changes."""
from pathlib import Path
import argparse,json,sys
import numpy as np
from PIL import Image,ImageEnhance,ImageDraw
from StructuralMaskCandidates import structure
p=argparse.ArgumentParser();p.add_argument('folder',type=Path);args=p.parse_args();folder=args.folder
rows=json.loads((folder/'metrics.json').read_text())['records'];truthrows=[]
mask=np.zeros((480,1152),bool);mask[30:440,360:760]=True
for row in rows:
 if row['span']!=2:continue
 i=row['first'];images=[np.asarray(Image.open(folder/f'span2-pair{i}-{tag}.png'),dtype=float)/255 for tag in ['truth','off','on']]
 record=dict(first=i,centralPTS=sum(row['PTS'])/2)
 for tag,im in zip(['off','on'],images[1:]):
  ssim,gradient=structure(im,images[0])
  for name,region in [('face',mask),('outside',~mask)]:
   record[tag+'_'+name]=dict(MAE8=float((abs(im-images[0])*255)[region].mean()),gradient=float(gradient[region].mean()*255),SSIM=float(ssim[region].mean()))
 truthrows.append(record)
summary={tag+'_'+name:{metric:float(np.mean([r[tag+'_'+name][metric] for r in truthrows])) for metric in ['MAE8','gradient','SSIM']} for tag in ['off','on'] for name in ['face','outside']}
summary['faceMAEWorseTriplets']=sum(r['on_face']['MAE8']>r['off_face']['MAE8'] for r in truthrows)
summary['triplets']=len(truthrows)
(folder.parent/'structural-summary.json').write_text(json.dumps(dict(ROI=[360,30,400,410],summary=summary,records=truthrows),indent=2))
for span,i in [(2,23),(1,23),(2,max(truthrows,key=lambda r:r['off_face']['gradient'])['first'])]:
 tags=['truth','off','on'] if span==2 else ['A','B','off','on'];out=Image.new('RGB',(400*len(tags),440),'#202020');draw=ImageDraw.Draw(out)
 for n,tag in enumerate(tags):
  name=f'source-{i if tag=="A" else i+1}.png' if tag in ['A','B'] else f'span{span}-pair{i}-{tag}.png'
  im=Image.open(folder/name).crop((360,30,760,440));im=ImageEnhance.Brightness(ImageEnhance.Contrast(im).enhance(2)).enhance(1.4)
  out.paste(im,(n*400,30));draw.text((n*400+10,8),{'truth':'Original central real','A':'Original A','B':'Original B','off':'Frame+ actual','on':'Frame+ F2'}[tag],fill='white')
 out.save(folder.parent/f'comparison-span{span}-pair{i}.png')
print(json.dumps(summary,indent=2))
