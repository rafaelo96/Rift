"""Summarize observed dense candidates against an integer photometric reference.
No semantic ground truth is inferred. Run after MV_TRAJECTORY_REPLAY.
"""
import argparse
from collections import Counter, defaultdict
import json
import gzip
import math
from pathlib import Path


def close(vector, reference, tolerance=1.5):
    return math.hypot(vector[0] - reference[0], vector[1] - reference[1]) <= tolerance


def summarize(folder):
    run = json.loads((folder / 'run.json').read_text())
    refs = json.loads((folder / 'oracle.json').read_text())
    stage_path=folder/'stages.json'
    stages=json.loads(stage_path.read_bytes() if stage_path.exists() else gzip.decompress((folder/'stages.json.gz').read_bytes()))
    rows = []
    for ref in refs:
        if ref['level'] != 0:
            continue
        i = ref['point']
        vector = [ref['dx'], ref['dy']]
        entries = []
        propagation = 0
        for stage in stages:
            if stage['level'] != 0 and not stage['stage'].startswith('synthesis/'):
                continue
            name = stage['stage'].split('/')[-1]
            if name == 'densePatchPropagate' and not stage['candidates']:
                propagation += 1
            sample = next((s for s in stage['samples'] if s['point'] == i), None)
            if sample is None:
                continue
            vectors = sample['vectors']
            if name in ('coordinates', 'inverseCoordinates'):
                vectors = [[-2*vectors[0][0], -2*vectors[0][1]],
                           [2*vectors[0][2], 2*vectors[0][3]]]
            entries.append(dict(stage=name, direction=stage['stage'].split('/')[0], candidates=stage['candidates'],
                                present=any(close(v, vector) for v in vectors),
                                vectors=vectors, passIndex=propagation))
        evaluated = any(e['present'] for e in entries if e['candidates'])
        winners = [e for e in entries if not e['candidates'] and e['direction']=='d0']
        assessed = next(e for e in winners if e['stage'] == 'denseTVAssess')
        coords = next(e for e in entries if e['stage'] == 'coordinates')
        inverse = next(e for e in entries if e['stage'] == 'inverseCoordinates')
        reverse = next(e for e in entries if e['stage'] == 'denseTVAssess' and e['direction']=='d1')
        reverse_present = any(close([-v[0],-v[1]],vector) for v in reverse['vectors'])
        alpha = next(e for e in entries if e['stage'] == 'blend')['vectors'][0][0]
        decisions = next(e for e in entries if e['stage']=='decisions')['vectors'][0]

        active = [coords['vectors'][j] for j, weight in enumerate((1-alpha, alpha)) if weight > 0.05]
        synthesized = bool(active) and all(close(v, vector) for v in active)
        synthesis_reason = ('retained' if synthesized else
                            'static-protection' if decisions[0]>0 else
                            'low-support-fallback' if decisions[1]<=1e-4 and decisions[2]==0 else
                            'ownership' if decisions[2]>0 else 'transport-or-blend')
        losses = []
        seen = False
        for e in entries:
            if e['stage'] in ('coordinates', 'inverseCoordinates', 'blend', 'decisions') or e['direction']=='d1':
                continue
            if e['candidates']:
                seen |= e['present']
            elif seen and not e['present']:
                label = e['stage']
                if label == 'densePatchPropagate':
                    label += str(e['passIndex'])
                losses.append(label)
                seen = False
            elif e['present']:
                seen = True
        if not evaluated:
            category = 'never_evaluated_L0'
        elif not assessed['present']:
            category = 'lost_before_synthesis'
        elif not synthesized:
            category = 'lost_at_synthesis'
        else:
            category = 'retained_through_synthesis'
        rows.append(dict(point=i, region=run['regions'][i], eligible=ref['eligible'],
                         reference=vector, gap=ref['gap'], cost=ref['cost'],
                         boundary=ref['boundary'], category=category,
                         losses=losses, assessedPresent=assessed['present'],
                         synthesisPresent=synthesized, synthesisDecision=synthesis_reason, initialInversePresent=all(close(v,vector) for v in inverse['vectors']), reversePresent=reverse_present, hiddenCounterpart=assessed['vectors'][0][3]<-1, blendAlpha=alpha))
    groups = defaultdict(list)
    for row in rows:
        groups[row['region']].append(row)
    summary = []
    for region, samples in groups.items():
        eligible = [s for s in samples if s['eligible']]
        counts = Counter(s['category'] for s in eligible)
        losses = Counter(loss for s in eligible for loss in s['losses'])
        summary.append(dict(region=region, sampled=len(samples), eligible=len(eligible),
                            excluded=len(samples)-len(eligible), counts=dict(counts),
                            observedLossEvents=dict(losses)))
    level_summary = []
    for level in range(4):
        level_refs = [r for r in refs if r['level'] == level and r['eligible']]
        generated = selected = 0
        events = Counter()
        for ref in level_refs:
            vector = [ref['dx'], ref['dy']]
            seen = False
            ever = False
            last = False
            for stage in stages:
                if stage['level'] != level or not stage['stage'].startswith('d0/l'):
                    continue
                sample = next(s for s in stage['samples'] if s['point']==ref['point'])
                present = any(close(v,vector) for v in sample['vectors'])
                if stage['candidates']:
                    ever |= present
                    seen |= present
                else:
                    if seen and not present:
                        events[stage['stage'].split('/')[-1]] += 1
                    seen = present
                    last = present
            generated += ever
            selected += last
        level_summary.append(dict(level=level, eligible=len(level_refs), evaluated=generated,
                                  retainedAfterAggregation=selected, lossEvents=dict(events)))
    result = dict(levelSummary=level_summary, scope='L0 forward diagnostic, integer photometric oracle, not semantic truth',
                  sourcePTS=run['PTS'], tolerancePixels=1.5, gapThreshold=0.1,
                  summary=summary, blocks=rows)
    (folder / 'survival.json').write_text(json.dumps(result, indent=2)+'\n')
    return summary


def selfcheck():
    assert close([8, 0], [8, 0])
    assert close([9, 1], [8, 0])
    assert not close([0, 0], [8, 0])
    assert not close([10, 0], [8, 0])
    # Known four-way partition, including a proposal rejected by search and bad inverse transport.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        folder = Path(tmp)
        (folder/'run.json').write_text(json.dumps({'regions':['fixture']*4,'PTS':[0,1]}))
        refs = [dict(point=i,level=0,dx=8,dy=0,gap=1,cost=0,boundary=False,eligible=True) for i in range(4)]
        (folder/'oracle.json').write_text(json.dumps(refs))
        stages = []
        def stage(name, vectors, candidates=False):
            stages.append(dict(stage=name,level=0,candidates=candidates,
                               samples=[dict(point=i,vectors=[v]) for i,v in enumerate(vectors)]))
        stage('d0/l0/densePatchSearch',[[0,0,0,1],[8,0,0,1],[8,0,0,1],[8,0,0,1]],True)
        stage('d0/l0/densePatchSearch',[[0,0,0,1],[0,0,0,1],[8,0,0,1],[8,0,0,1]])
        stage('d0/assessment/denseTVAssess',[[0,0,1,0],[0,0,1,0],[8,0,1,0],[8,0,1,0]])
        stage('d1/assessment/denseTVAssess',[[-8,0,1,0]]*4)
        for label in ['inverseCoordinates','coordinates']:
            stage('synthesis/t0.5/'+label,[[0,0,0,0],[0,0,0,0],[0,0,0,0],[-4,0,4,0]])
        stage('synthesis/t0.5/blend',[[0.5,0,0,0]]*4)
        stage('synthesis/t0.5/decisions',[[0,1,0,0.5]]*4)
        (folder/'stages.json').write_text(json.dumps(stages))
        summary = summarize(folder)[0]
        assert summary['counts'] == dict(never_evaluated_L0=1,lost_before_synthesis=1,lost_at_synthesis=1,retained_through_synthesis=1)
        assert summary['observedLossEvents']=={'densePatchSearch':1}



if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folders', nargs='*', type=Path)
    parser.add_argument('--selfcheck', action='store_true')
    args = parser.parse_args()
    if args.selfcheck:
        selfcheck()
        print('SURVIVAL REPORT CHECK passed: tolerance, four-way partition and exact search loss')
    for folder in args.folders:
        print(folder)
        print(json.dumps(summarize(folder), indent=2))
