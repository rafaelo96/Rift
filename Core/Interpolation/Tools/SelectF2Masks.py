from pathlib import Path
from PIL import Image,ImageDraw,ImageEnhance
import numpy as np,json,hashlib
R=Path(__file__).resolve().parents[3];F=R/'docs/diagnostics/assets/structural-masks-f1-2026-10-17';O=R/'docs/diagnostics/assets/edge-field-f2-2026-10-17';O.mkdir(exist_ok=True)
polygons={'anime1082':[[[442,263],[454,268],[471,291],[480,302],[498,320],[506,346],[497,352],[481,333],[462,322],[453,302],[447,283]]]}
rows=[]
for case in ['avatar69','avatar300','anime1082']:
 d=O/case;d.mkdir(exist_ok=True);secondary=Image.open(F/case/'candidate.png').convert('L')
 if case=='anime1082':
  primary=Image.new('L',secondary.size);draw=ImageDraw.Draw(primary)
  for p in polygons[case]:draw.polygon([tuple(x) for x in p],fill=255)
  roi=Image.open(F/case/'roi.png');primary=Image.fromarray(np.uint8((np.array(primary)>0)&(np.array(roi)>0))*255);why='Manual envelope around visible bird; no face features exist in this frame. Not a certified defect label.'
 else:
  choice='candidate.png' if case=='avatar69' else 'core.png';primary=Image.open(F/case/choice);why='Select sensitive mask; do not label shared real motion blur as deformation.' if case=='avatar69' else 'Select strict structural core; it captures the fragmented residual at the old face position, including ghosted background. No unsupported pose exclusion.'
 primary.save(d/'primary-mask.png');secondary.save(d/'secondary-mask.png');mask=np.array(primary)>0
 imgs=[]
 for suffix in ['before','truth']:
  im=ImageEnhance.Brightness(Image.open(R/f'docs/diagnostics/assets/confidence-e2-2026-10-17/{case}/quality/span2-pair4-{suffix}.png').convert('RGB')).enhance(1.8);a=np.array(im);a[mask]=(a[mask]*.55+np.array([0,210,255])*.45).astype('u1');imgs.append(Image.fromarray(a))
 canvas=Image.new('RGB',(2304,512),'white');draw=ImageDraw.Draw(canvas)
 for i,im in enumerate(imgs):canvas.paste(im,(i*1152,28));draw.text((i*1152+4,5),'Motor actual + principal' if i==0 else 'Real I5 + principal',fill='black')
 canvas.save(d/'selected-overlay.png');rows.append(dict(case=case,selection=why,primaryPixels=int(mask.sum()),secondaryPixels=int((np.array(secondary)>0).sum()),polygons=polygons.get(case),status='Selected by assistant under user delegation; not independently human annotated',sha256=hashlib.sha256((d/'primary-mask.png').read_bytes()).hexdigest()))
(O/'mask-decisions.json').write_text(json.dumps(rows,indent=2)+'\n')
print(rows)
