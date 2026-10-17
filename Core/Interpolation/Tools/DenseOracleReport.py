"""Assemble bounded offline oracle evidence; never accesses the source movie."""
from pathlib import Path
import hashlib,json,gzip,zipfile
from PIL import Image,ImageEnhance,ImageDraw,ImageChops
ROOT=Path(__file__).resolve().parents[3]
OUT=ROOT/'docs/diagnostics/assets/dense-oracle-static-2026-10-17'
SOURCE=ROOT/'docs/diagnostics/assets/trajectory-survival-2026-10-17'

def sheet(paths,labels,rect,path,scale=2):
    x,y,w,h=rect
    canvas=Image.new('RGB',(w*scale*len(paths),h*scale+48),'white');draw=ImageDraw.Draw(canvas)
    for i,(p,label) in enumerate(zip(paths,labels)):
        image=ImageEnhance.Brightness(Image.open(p).convert('RGB')).enhance(1.8).crop((x,y,x+w,y+h)).resize((w*scale,h*scale),Image.Resampling.NEAREST)
        canvas.paste(image,(i*w*scale,24));draw.text((i*w*scale+4,5),label,fill='black')
    draw.text((4,h*scale+30),'Luma 10-bit preview; all columns x1.8 brightness; nearest-neighbor 2x.',fill='black');canvas.save(path)

def main():
    summary=[]
    for case in ['avatar69','avatar300','anime1082']:
        folder=OUT/case;rois=json.loads((SOURCE/case/'regions.json').read_text());p=folder/'pair_4'
        old=ROOT/'docs/diagnostics/assets/oracle-static-2026-10-17'/case/'oracle-on'
        for t in ['0.25','0.5','0.75']:
            assert ImageChops.difference(Image.open(p/f'current_t{t}.png'),Image.open(old/f'current_t{t}.png')).getbbox() is None,'Production baseline changed'
            assert ImageChops.difference(Image.open(p/f'legacy-sparse_t{t}.png'),Image.open(old/f'oracle_t{t}.png')).getbbox() is None,'Sparse A ablation did not reproduce A'
        runs=[]
        for i in range(48):
            f=folder/f'pair_{i}';run=json.loads((f/'run.json').read_text())
            assert run['pair']==i and run['spatialCoverage']==1152*480 and run['enabled']
            assert all(r['disabledIdentical'] for r in run['samples'])
            run['pngSHA256']={v.name:hashlib.sha256(v.read_bytes()).hexdigest() for v in sorted(f.glob('*.png'))}
            runs.append(run)
        (folder/'all-pairs.json').write_text(json.dumps(runs,indent=2)+'\n')
        with zipfile.ZipFile(folder/'reference-grids.zip','w',zipfile.ZIP_DEFLATED) as archive:
            for i in range(48):
                for name in ['reference-0.f32','reference-1.f32','cache.json']:
                    archive.write(folder/f'pair_{i}'/name,f'pair_{i}/{name}')
        for roi in rois:
            for t in ['0.25','0.5','0.75']:
                sheet([p/'original0.png',p/'original1.png',p/f'current_t{t}.png',p/f'dense_t{t}.png'],['Original A','Original B','Motor actual',f'Oraculo denso t={t}'],roi['rect'],folder/f"{roi['name']}-t{t}.png")
            sheet([p/'current_t0.5.png',p/'masked_t0.5.png',p/'dense_t0.5.png'],['Motor actual','Mismo campo; mascara dispersa','Mismo campo; cobertura completa'],roi['rect'],folder/f"{roi['name']}-mask-ablation.png")
        for roi in rois:
            sheet([p/'current_t0.5.png',p/'legacy-sparse_t0.5.png',p/'legacy-filled_t0.5.png',p/'dense_t0.5.png'],['Motor actual','A: oraculo disperso exacto','Mismos vectores A; huecos llenos','Oraculo denso independiente'],roi['rect'],folder/f"{roi['name']}-legacy-ablation.png")
        # All 48 midpoints, with the same fixed ROI, make temporal coverage reviewable.
        for roi in rois:
            x,y,w,h=roi['rect'];cols=6;rows=8
            contact=Image.new('RGB',(cols*w*2,rows*(h+22)),'white');draw=ImageDraw.Draw(contact)
            for i in range(48):
                xx=(i%cols)*w*2;yy=(i//cols)*(h+22)
                draw.text((xx+2,yy+3),f'pair {i}: actual | dense',fill='black')
                for j,name in enumerate(['current_t0.5.png','dense_t0.5.png']):
                    image=ImageEnhance.Brightness(Image.open(folder/f'pair_{i}'/name).convert('RGB')).enhance(1.8).crop((x,y,x+w,y+h))
                    contact.paste(image,(xx+j*w,yy+22))
            contact.save(folder/f"{roi['name']}-all48.png")
        # Keep primary-pair raw panels for direct inspection, plus cut pair for 18:02.
        for i in ([4,6] if case=='anime1082' else [4]):
            pair=folder/f'pair_{i}'
            sheet([pair/'original0.png',pair/'original1.png',pair/'current_t0.5.png',pair/'dense_t0.5.png'],['Original A','Original B','Motor actual','Oraculo denso'],[0,0,1152,480],folder/f'full-pair{i}.png',scale=1)
        summary.append({'case':case,'pairs':len(runs),'sourceFrames':49,'coveragePerDirection':1152*480,'blocksPerDirection':1152*480//64,'radius':256,'disabledComparisons':len(runs)*3,'changedPixelsPair4':[x['changedPixels'] for x in runs[4]['samples']], 'offlineSeconds':sum(r['seconds'] for r in runs)})
    (OUT/'step-c.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(summary,indent=2))
if __name__=='__main__': main()
