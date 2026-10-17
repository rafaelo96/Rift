"""Bounded offline connected-region correspondence; no runtime dependencies."""
import argparse
import json
from pathlib import Path
import numpy as np
from PIL import Image


def components(mask):
    """Four-connected run labeling, avoiding a queue entry for every pixel."""
    parent = [0]
    rows = []
    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    previous = []
    for row in mask:
        edges = np.diff(np.r_[False, row, False].astype(np.int8))
        runs = []
        previous_index = 0
        for lo, hi in zip(np.flatnonzero(edges == 1), np.flatnonzero(edges == -1)):
            label = len(parent)
            parent.append(label)
            while previous_index < len(previous) and previous[previous_index][1] <= lo:
                previous_index += 1
            j = previous_index
            while j < len(previous) and previous[j][0] < hi:
                parent[root(previous[j][2])] = root(label)
                j += 1
            runs.append((int(lo), int(hi), label))
        rows.append(runs)
        previous = runs
    labels = np.zeros(mask.shape, dtype=np.int32)
    for y, runs in enumerate(rows):
        for lo, hi, label in runs:
            labels[y, lo:hi] = root(label)
    _, inverse = np.unique(labels, return_inverse=True)
    # Zero stays background because its original ID is smallest.
    return inverse.reshape(mask.shape)


def load(folder, index):
    planes = []
    with Image.open(folder/f'trace_input{index}.png') as image:
        if image.mode != 'L' or min(image.size) < 32 or max(image.size) > 2048:
            raise ValueError('Bounded grayscale source required')
        w, h = image.size
        size = (w//2, h//2)
        planes.append(np.asarray(image.resize(size, Image.Resampling.BILINEAR), dtype=np.float32)/255)
    for c in range(2):
        with Image.open(folder/f'trace_input{index}_uv{c}.png') as image:
            if image.mode != 'L' or image.size != size:
                raise ValueError('Half-size chroma required')
            planes.append(np.asarray(image, dtype=np.float32)/255)
    return np.stack(planes, axis=-1)


def regions(image, threshold):
    edge = np.zeros(image.shape[:2], dtype=bool)
    for axis in (0, 1):
        delta = np.abs(np.diff(image, axis=axis))
        strong = np.maximum(delta[..., 0], 2*np.max(delta[..., 1:], axis=-1)) > threshold
        if axis == 0:
            edge[1:] |= strong
            edge[:-1] |= strong
        else:
            edge[:, 1:] |= strong
            edge[:, :-1] |= strong
    labels = components(~edge)
    result = []
    for label, count in enumerate(np.bincount(labels.ravel())):
        if label == 0 or count < 64 or count > image.shape[0]*image.shape[1]*0.5:
            continue
        y, x = np.where(labels == label)
        points = np.c_[x, y].astype(np.float32)
        center = points.mean(0)
        centered = points-center
        covariance = np.einsum("ni,nj->ij",centered,centered,optimize=False)/len(points)
        eigenvalues, eigenvectors = np.linalg.eigh(covariance)
        if eigenvalues[0] < 1:
            continue
        result.append({'id': label, 'area': int(count), 'center': center,
                       'color': image[y, x].mean(0), 'eigenvalues': eigenvalues,
                       'eigenvectors': eigenvectors, 'points': points})
    return labels, result


def match(a, b, target_labels):
    matches = []
    for source in a:
        choices = []
        for target in b:
            ratio = target['area']/source['area']
            color = np.linalg.norm(source['color']-target['color'])
            if ratio < 0.2 or ratio > 5 or color > 0.05:
                continue
            for sign in (1, -1):
                transform = (target['eigenvectors'] @ np.diag(np.sqrt(target['eigenvalues']/source['eigenvalues'])) @ source['eigenvectors'].T)*sign
                if np.linalg.det(transform) <= 0:
                    # Eigenvector basis handedness is arbitrary; choose a proper map.
                    transform = target['eigenvectors'] @ np.diag(np.sqrt(target['eigenvalues']/source['eigenvalues'])*[sign, -sign]) @ source['eigenvectors'].T
                points = source['points'][::max(1,len(source['points'])//1500)]
                projected = np.rint((points-source['center']) @ transform.T+target['center']).astype(int)
                inside = (projected[:, 0] >= 0) & (projected[:, 0] < target_labels.shape[1]) & (projected[:, 1] >= 0) & (projected[:, 1] < target_labels.shape[0])
                coverage = np.zeros(len(projected), dtype=bool)
                q = projected[inside]
                coverage[inside] = target_labels[q[:, 1], q[:, 0]] == target['id']
                overlap = float(coverage.mean())
                score = overlap-4*float(color)-0.1*abs(np.log(ratio))
                choices.append({'source': source['id'], 'target': target['id'], 'score': score,
                                'coverage': overlap, 'color_distance': float(color),
                                'source_center': (source['center']*2).tolist(),
                                'target_center': (target['center']*2).tolist(),
                                'linear': transform.tolist(), 'translation': ((target['center']-transform @ source['center'])*2).tolist()})
        choices.sort(key=lambda c: c['score'], reverse=True)
        if choices:
            choices[0]['margin'] = choices[0]['score']-(choices[1]['score'] if len(choices)>1 else 0)
            matches.append(choices[0])
    return matches


def export_fields(first, last, threshold, forward_path, backward_path, output):
    la, a = regions(first, threshold)
    lb, b = regions(last, threshold)
    proposals = match(a, b, lb)
    reverse = match(b, a, la)
    reciprocal = {(m['target'], m['source']) for m in reverse}
    h, w = first.shape[:2]
    height, width = h*2, w*2
    yy, xx = np.mgrid[:height, :width]
    points = np.stack([xx, yy], axis=-1).astype(np.float32)
    labels = [np.repeat(np.repeat(label, 2, axis=0), 2, axis=1) for label in [la, lb]]
    fields = []
    for path in [forward_path, backward_path]:
        field = np.fromfile(path, dtype='<f4')
        if field.size != height*width*4 or not np.isfinite(field).all():
            raise ValueError('Invalid diagnostic field')
        fields.append(field.reshape(height, width, 4).copy())
    masks = [np.zeros((height, width), dtype=bool) for _ in range(2)]
    accepted = []
    for m in proposals:
        if (m['source'], m['target']) not in reciprocal:
            continue
        transform = np.asarray(m['linear'], dtype=np.float32)
        translation = np.asarray(m['translation'], dtype=np.float32)
        inverse = np.linalg.inv(transform)
        for direction, (label, matrix, shift) in enumerate([
                (m['source'], transform, translation),
                (m['target'], inverse, -inverse @ translation)]):
            mask = labels[direction] == label
            q = points[mask]
            projected = np.einsum('ij,nj->ni', matrix, q, optimize=False)+shift
            fields[direction][mask, :2] = projected-q
            masks[direction] |= mask
        accepted.append(m)
    output.mkdir(parents=True, exist_ok=True)
    for direction in range(2):
        fields[direction].astype('<f4').tofile(output/f'field{direction}.f32')
        Image.fromarray(masks[direction].astype(np.uint8)*255).save(output/f'mask{direction}.png')
    return {'threshold': threshold, 'overwritten_pixels': [int(m.sum()) for m in masks], 'matches': accepted,
            'scope': 'diagnostic direct field replacement, not runtime or correct flow claim'}


def selfcheck():
    mask = np.array([[1,0,1,1],[1,0,0,1],[0,1,1,1],[1,0,0,0]],dtype=bool)
    labels = components(mask)
    assert labels[0,0] == labels[1,0] != labels[0,2]
    assert labels[0,2] == labels[2,1] != labels[3,0]
    assert np.all(labels[~mask] == 0)
    assert components(np.zeros((2,3),dtype=bool)).max() == 0
    print('RegionSurface components selfcheck passed')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder',nargs='?',type=Path)
    parser.add_argument('--out',type=Path)
    parser.add_argument('--selfcheck',action='store_true')
    parser.add_argument('--forward',type=Path)
    parser.add_argument('--backward',type=Path)
    parser.add_argument('--field-output',type=Path)
    args = parser.parse_args()
    if args.selfcheck:
        selfcheck()
    else:
        if not args.folder or not args.out:
            parser.error('folder and --out required')
        first, last = load(args.folder,0), load(args.folder,1)
        if first.shape != last.shape:
            parser.error('source dimensions must match')
        report = []
        for threshold in (1/255,2/255,4/255):
            la,a = regions(first,threshold)
            lb,b = regions(last,threshold)
            forward, backward = match(a,b,lb), match(b,a,la)
            inverse = {(m['target'],m['source']) for m in backward}
            reciprocal = [m for m in forward if (m['source'],m['target']) in inverse]
            report.append({'threshold':threshold,'regions':[len(a),len(b)],'reciprocal':reciprocal})
            print('threshold',threshold,'regions',len(a),len(b),'reciprocal',len(reciprocal))
        if args.field_output:
            if not args.forward or not args.backward:
                parser.error('--forward and --backward required with --field-output')
            fields = export_fields(first,last,2/255,args.forward,args.backward,args.field_output)
            (args.field_output/'experiment.json').write_text(json.dumps(fields,indent=2))
        args.out.write_text(json.dumps(report,indent=2))
