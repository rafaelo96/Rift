"""Offline bounded-pair test of local geometric support, not a runtime estimator.

Uses existing diagnostic gradient descriptors, retaining four candidates per source
rather than committing to a nearest descriptor. Local length/orientation consistency
votes for candidates before a one-to-one selection. No semantic ROI is used to match.
"""
import argparse
import json
import time
from itertools import combinations
from pathlib import Path

import numpy as np
from PIL import Image
from feature_correspondence_probe import features


def select_graph(first, last, source_indices, target_indices, costs, radius=96):
    """Return mutually exclusive candidates supported by at least three neighbors."""
    if not len(costs):
        return [], np.zeros(0)
    a, b = first[source_indices], last[target_indices]
    source_edge = a[:, None] - a[None, :]
    target_edge = b[:, None] - b[None, :]
    source_length = np.linalg.norm(source_edge, axis=2)
    target_length = np.linalg.norm(target_edge, axis=2)
    different = ((source_indices[:, None] != source_indices[None, :])
                 & (target_indices[:, None] != target_indices[None, :]))
    local = different & (source_length >= 12) & (source_length <= radius)
    ratio = target_length / np.maximum(source_length, 1)
    cosine = np.einsum('ijk,ijk->ij', source_edge, target_edge) / np.maximum(source_length * target_length, 1)
    angle = np.arccos(np.clip(cosine, -1, 1))
    allowed = local & (ratio > 0.45) & (ratio < 2.2) & (angle < np.pi / 3)
    affinity = np.where(allowed, np.exp(-(np.log(np.maximum(ratio, 1e-8)) / .5)**2 - (angle / .65)**2), 0)
    unary = np.exp(-costs / .25)
    # shortcut: finite local stretch and rotation, not a general 3-D pose model.
    confidence = unary.copy()
    unique = np.unique(source_indices)
    for _ in range(24):
        support = np.einsum('ij,j->i', affinity, confidence, optimize=False)
        confidence = unary * (support + .05)
        for index in unique:
            mask = source_indices == index
            confidence[mask] /= max(float(confidence[mask].sum()), 1e-12)
    support = np.einsum('ij,j->i', affinity, confidence, optimize=False)
    order = np.argsort(-(confidence * support))
    used_source, used_target, selected = set(), set(), []
    for index in order:
        si, ti = int(source_indices[index]), int(target_indices[index])
        if si in used_source or ti in used_target or support[index] < 3:
            continue
        selected.append(int(index))
        used_source.add(si)
        used_target.add(ti)
    return selected, support


def orientation_conflicts(first, last, radius=96):
    """Local correspondence triples must not reverse the visible surface."""
    bad = []
    tested = 0
    for indices in combinations(range(len(first)), 3):
        a, b = first[list(indices)], last[list(indices)]
        edges = np.linalg.norm(a[:, None] - a[None, :], axis=2)
        if edges.max() > radius:
            continue
        u, v = a[1]-a[0], a[2]-a[0]
        source_area = u[0]*v[1] - u[1]*v[0]
        if abs(source_area) < 64:
            continue
        u, v = b[1]-b[0], b[2]-b[0]
        target_area = u[0]*v[1] - u[1]*v[0]
        tested += 1
        if source_area * target_area <= 0:
            bad.append(indices)
    return tested, bad


def prune_inversions(first, last, selected, source, target, support):
    selected = list(selected)
    rejected = []
    initial_tested, initial_bad = orientation_conflicts(first[source[selected]], last[target[selected]])
    while len(selected) >= 3:
        _, bad = orientation_conflicts(first[source[selected]], last[target[selected]])
        if not bad:
            break
        incidence = np.bincount(np.array(bad).ravel(), minlength=len(selected))
        removal = int(np.argmax(incidence / np.maximum(support[selected], .01)))
        rejected.append(selected.pop(removal))
    final_tested, final_bad = orientation_conflicts(first[source[selected]], last[target[selected]])
    return selected, {'before': {'tested': initial_tested, 'inverted': len(initial_bad)},
                      'after': {'tested': final_tested, 'inverted': len(final_bad)}, 'rejected': len(rejected)}


def image_candidates(first, last):
    pa, da = features(first)
    pb, db = features(last)
    if min(len(pa), len(pb)) < 4:
        return pa, pb, np.zeros(0, dtype=int), np.zeros(0, dtype=int), np.zeros(0)
    similarity = np.einsum('ik,jk->ij', da.reshape(-1, 128), db.reshape(-1, 128), optimize=False)
    similarity = similarity.reshape(len(pa), 3, len(pb), 3).max(axis=(1, 3))
    costs = np.maximum(0, 2 - 2 * similarity)
    candidates = np.argsort(costs, axis=1)[:, :4]
    source = np.repeat(np.arange(len(pa)), 4)
    target = candidates.ravel()
    selected_cost = costs[source, target]
    valid = selected_cost < 1.2
    return pa, pb, source[valid], target[valid], selected_cost[valid]


def selfcheck():
    y, x = np.mgrid[:6, :6]
    first = np.c_[x.ravel()*20, y.ravel()*20].astype(float)
    # Analytic smooth nonrigid deformation; no single affine map is exact.
    last = first + np.c_[8*np.sin(first[:, 1]/35), 5*np.sin(first[:, 0]/30)] + [35, 20]
    source = np.repeat(np.arange(len(first)), 2)
    rng = np.random.default_rng(24)
    wrong = rng.permutation(len(first))
    target = np.stack([np.arange(len(first)), wrong], axis=1).ravel()
    # Wrong proposals have the better descriptor score, so geometry must change selection.
    costs = np.tile([.18, .14], len(first))
    selected, support = select_graph(first, last, source, target, costs, radius=52)
    errors = np.linalg.norm(last[target[selected]] - last[source[selected]], axis=1)
    assert len(selected) >= 30 and errors.max() < 1e-9, (len(selected), errors.max())
    clean, topology = prune_inversions(first, last, selected, source, target, support)
    assert len(clean) == 36 and topology['before']['inverted'] == 0
    crossed = np.array([[0., 0.], [20., 0.], [0., 20.]])
    assert len(orientation_conflicts(crossed, crossed[[0, 2, 1]])[1]) == 1
    assert not select_graph(first, last, source[:2], target[:2], costs[:2])[0]
    assert not select_graph(first, last, source[:0], target[:0], costs[:0])[0]
    print(json.dumps({'selfcheck': 'passed', 'selected': len(selected), 'known_nonrigid_error': float(errors.max()),
                      'independent_descriptor_wrong': int(np.count_nonzero(wrong != np.arange(len(first))))}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('first', nargs='?')
    parser.add_argument('last', nargs='?')
    parser.add_argument('--out')
    parser.add_argument('--selfcheck', action='store_true')
    args = parser.parse_args()
    if args.selfcheck:
        selfcheck()
        return
    if not args.first or not args.last or not args.out:
        parser.error('first, last and --out required')
    first = np.asarray(Image.open(args.first).convert('L'), dtype=float)/255
    last = np.asarray(Image.open(args.last).convert('L'), dtype=float)/255
    if first.shape != last.shape or min(first.shape) < 64 or max(first.shape) > 2048:
        parser.error('matching 64..2048px bounded diagnostic frames required')
    started = time.perf_counter()
    pa, pb, si, ti, cost = image_candidates(first, last)
    selected, support = select_graph(pa, pb, si, ti, cost)
    selected, topology = prune_inversions(pa, pb, selected, si, ti, support)
    rb, ra, rsi, rti, rcost = image_candidates(last, first)
    reverse, rsupport = select_graph(rb, ra, rsi, rti, rcost)
    reverse, reverse_topology = prune_inversions(rb, ra, reverse, rsi, rti, rsupport)
    reverse_pairs = {(int(rti[i]), int(rsi[i])) for i in reverse}
    mutual = [i for i in selected if (int(si[i]), int(ti[i])) in reverse_pairs]
    result = {'topology': topology, 'reverse_topology': reverse_topology, 'mutual_matches': len(mutual), 'scope': 'offline bounded diagnostic, no runtime or quality claim',
              'features': [len(pa), len(pb)], 'candidates': len(cost),
              'matches': [{'first': pa[si[i]].tolist(), 'last': pb[ti[i]].tolist(),
                           'reverse_consistent': i in mutual, 'cost': float(cost[i]), 'geometric_support': float(support[i])} for i in selected],
              'seconds': time.perf_counter()-started}
    Path(args.out).write_text(json.dumps(result, indent=2))
    print(json.dumps({k: len(v) if k == 'matches' else v for k, v in result.items()}))


if __name__ == '__main__':
    main()
