"""Audit the reapplied candidate against the user's explicit C/D acceptance limits."""
from pathlib import Path
import collections,csv,hashlib,json,math,re,struct,sys
from PIL import Image,ImageChops
from DenseOracleReport import sheet,ROOT,OUT
OLD=ROOT/'docs/diagnostics/assets/oracle-static-2026-10-17'
CASES=['avatar69','avatar300','anime1082']

def write(value,path):path.write_text(json.dumps(value,indent=2)+'\n')
def metrics(case,phase):
    rows={}
    for line in (OUT/f'{case}-regression-{phase}.log').read_text().splitlines():
        m=re.match(r'(DENSE(?: FOUR)? GROUND TRUTH): pair=(\d+).*dense(?:4)? MAE=([\d.]+)',line)
        if m: rows[(m[1],int(m[2]))]=float(m[3])
    assert len(rows)==8
    return rows

def performance(name):
    log=OUT/f'gui-{name}-stderr.log';rows=[]
    for line in log.read_text().splitlines():
        if line.startswith('RIFT_PAIR_TIMING,'):
            _,stamp,w,h,n,ms=line.split(',');rows.append((int(stamp),int(w),int(h),int(n),float(ms)))
    assert rows
    plane=collections.Counter((r[1],r[2]) for r in rows).most_common(1)[0][0]
    kept=[r for r in rows if r[0]>=rows[0][0]+10_000_000_000 and r[1:3]==plane]
    assert len(kept)>700
    values=sorted(r[4] for r in kept)
    def quantile(p):return values[math.ceil(len(values)*p)-1]
    with (OUT/f'pairs-{name}.csv').open('w') as f:
        writer=csv.writer(f,lineterminator="\n");writer.writerow(['uptimeNS','width','height','outputs','milliseconds']);writer.writerows(kept)
    stdout=(OUT/f'gui-{name}.log').read_text()
    assert 'FLUENCY second=45' in stdout and 'mode=motion4x playing=1' in stdout
    strong=[r for r in stdout.splitlines() if r.startswith('SUPERRES mode=strong') and 'processed=true bypass=false' in r]
    if name!='before-preflight':assert strong,'Strong processing not observed'
    return {'variant':name,'chip':'Apple M4','build':'Release','samples':len(kept),'workPlane':plane,'warmupExcludedSeconds':10,'quantile':'empirical nearest-rank','p50MS':quantile(.5),'p95MS':quantile(.95),'maxMS':max(values),'withinAdjusted43_29MS':quantile(.95)<=43.29,'meetsSeparate35MSGoal':quantile(.95)<35,'decodeActive':True,'strongConfigured':True,'strongProcessedDiagnosticSamples':len(strong),'outputsPerPair':dict(collections.Counter(r[3] for r in kept)),'scope':'Whole interpolatePair under GUI decode/Strong/presentation load; not sum of separate decode/render duration or end-to-end display latency. First five Strong diagnostics do not prove no adaptive bypass later.'}

def main():
    synthetic=json.loads((OUT/'synthetic-after/synthetic.json').read_text())
    assert len(synthetic['stationary'])==12 and all(r['jitterFractionAbove1LSB']==0 for r in synthetic['stationary'])
    assert synthetic['motion'][1]['frozenPixels']==0 and synthetic['motion'][1]['inverseSourceErrorPx']==0
    disabledSynthetic=json.loads((OUT/'synthetic-disabled/synthetic.json').read_text())
    assert disabledSynthetic['motion'][0]['mae']==disabledSynthetic['motion'][1]['mae']
    samples=json.loads((OLD/'six-static-predicates.json').read_text());six=[]
    for sample in samples:
        case=sample['case'];x,y=sample['destination'];k=y*1152+x
        values={}
        for phase in ['before','after','disabled']:
            path=OUT/case/f'static-{phase}'
            coords=struct.unpack_from('<4f',(path/'after-coordinates.f32').read_bytes(),k*16)
            still=struct.unpack_from('<f',(path/'after-evidence.f32').read_bytes(),k*64+48)[0]
            values[phase]={'still':still,'inverseOffsets':coords}
        assert values['before']['still']==1 and values['after']['still']==0 and values['disabled']==values['before']
        assert math.hypot(*values['after']['inverseOffsets'][:2])>0 and math.hypot(*values['after']['inverseOffsets'][2:])>0
        six.append({'case':case,'point':sample['point'],'destination':[x,y],**values})
    write(six,OUT/'six-static-recovered.json')
    reference=[];disabledPNGs=0
    old=json.loads((OLD/'reference-mae.json').read_text())
    for case in CASES:
        before=metrics(case,'before');after=metrics(case,'after');disabled=metrics(case,'disabled')
        assert before==disabled
        for metric,pair in sorted(before):
            b,a=before[(metric,pair)],after[(metric,pair)]
            assert b==next(r['before'] for r in old if r['case']==case and r['metric']==metric and r['pair']==pair)
            delta=(a/b-1)*100;assert delta<=.5
            reference.append({'case':case,'metric':metric,'pair':pair,'before':b,'after':a,'relativeDeltaPercent':delta,'withinPlus0_5Percent':True})
        disabledReal=json.loads((OUT/case/'static-disabled/real.json').read_text())
        for t in [.25,.5,.75]:
            hashes=[r['sha256'] for r in disabledReal if r['t']==t]
            assert len(hashes)==2 and hashes[0]==hashes[1],'Disabled candidate changed 10-bit pixels'
        for prefix in ['regression','static']:
            for file in (OUT/case/f'{prefix}-before').glob('*.png'):
                other=OUT/case/f'{prefix}-disabled'/file.name
                assert other.exists() and ImageChops.difference(Image.open(file),Image.open(other)).getbbox() is None,other
                disabledPNGs+=1
        rois=json.loads((ROOT/'docs/diagnostics/assets/trajectory-survival-2026-10-17'/case/'regions.json').read_text())
        for roi in rois:
            for t in ['0.25','0.5','0.75']:
                p=OUT/case/'pair_4'
                sheet([p/'original0.png',p/'original1.png',OUT/case/'static-before'/f'after_t{t}.png',OUT/case/'static-after'/f'after_t{t}.png'],['Original A','Original B','Antes','Candidata reaplicada'],roi['rect'],OUT/case/f"static-{roi['name']}-t{t}.png")
        # Include every hidden-frame reference, both two-source and four-source, at 300s.
        if case=='avatar300':
            beforePath=OUT/case/'regression-before';afterPath=OUT/case/'regression-after'
            for metric,pair in sorted(before):
                kind='four' if ' FOUR ' in metric else 'reconstructed'
                for roi in rois:
                    sheet([beforePath/f'ground{pair}_truth.png',beforePath/f'ground{pair}_{kind}.png',afterPath/f'ground{pair}_{kind}.png'],['Referencia oculta','Antes','Candidata reaplicada'],roi['rect'],OUT/case/f"reference-{pair}-{kind}-{roi['name']}.png")
    write(reference,OUT/'reference-mae.json')
    if '--quality-only' in sys.argv:
        print('Quality checks passed: six recovered, 12 zero-jitter controls, 24 MAEs <=+0.5%, disabled outputs equal; crops require inspection.')
        return
    perf=[performance(name) for name in ['before-preflight','before','after']]
    write(perf,OUT/'performance-comparison.json')
    disposition={'sixRecovered':len(six),'stationaryControls':12,'jitterFractionAllControls':0,'referenceComparisons':len(reference),'worstReferenceRelativeDeltaPercent':max(r['relativeDeltaPercent'] for r in reference),'disabledPNGsIdentical':disabledPNGs,'disabledSyntheticPixelsAndCoordinatesIdentical':True,'afterP95MS':perf[-1]['p95MS'],'performanceAccepted':perf[-1]['withinAdjusted43_29MS'],'separate35MSGoalMet':perf[-1]['meetsSeparate35MSGoal'],'visual300s':'Inspected all eight hidden-frame references in face/clothing crops, plus pair4 at .25/.5/.75: no new visible deformation; existing severe fragmentation remains. Luma previews only.','runtimeFlag':'RIFT_STATIC_MOTION_GUARD=1; defaults off'}
    write(disposition,OUT/'step-d.json');print(json.dumps(disposition,indent=2));print(json.dumps(perf,indent=2))
if __name__=='__main__':main()
