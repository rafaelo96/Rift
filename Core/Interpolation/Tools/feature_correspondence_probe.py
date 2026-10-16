"""Bounded image-pair diagnostic, not a runtime dependency or interpolator.

Uses installed NumPy/Pillow to test rotation-normalized gradient descriptors and
geometric support before implementing a Swift/Metal correspondence proposal.
"""
import argparse
import json
import time
from pathlib import Path

import numpy as np
from PIL import Image


def blur(image, radius):
    padded = np.pad(image, radius, mode="edge")
    integral = np.pad(padded, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    size = radius * 2 + 1
    return (integral[size:, size:] - integral[:-size, size:]
            - integral[size:, :-size] + integral[:-size, :-size]) / size**2


def sample(image, x, y):
    x = np.clip(x, 0, image.shape[1] - 1)
    y = np.clip(y, 0, image.shape[0] - 1)
    ix, iy = x.astype(int), y.astype(int)
    jx, jy = np.minimum(ix + 1, image.shape[1] - 1), np.minimum(iy + 1, image.shape[0] - 1)
    fx, fy = x - ix, y - iy
    return ((1 - fy) * ((1 - fx) * image[iy, ix] + fx * image[iy, jx])
            + fy * ((1 - fx) * image[jy, ix] + fx * image[jy, jx]))


def features(image, limit=700):
    gy, gx = np.gradient(image)
    xx, xy, yy = blur(gx * gx, 3), blur(gx * gy, 3), blur(gy * gy, 3)
    score = 0.5 * (xx + yy - np.sqrt(np.maximum(0, (xx - yy)**2 + 4 * xy**2)))
    score[:28] = score[-28:] = 0
    score[:, :28] = score[:, -28:] = 0
    if score.max() <= 1e-10:
        return np.empty((0, 2)), np.empty((0, 3, 128))
    minimum = score.max() * 0.01
    order = np.argsort(score.ravel())[::-1]
    occupied = np.zeros_like(score, dtype=bool)
    points = []
    for index in order:
        y, x = divmod(int(index), image.shape[1])
        if score[y, x] < minimum or len(points) == limit:
            break
        if occupied[y, x]:
            continue
        points.append((x, y))
        occupied[max(0, y - 7):y + 8, max(0, x - 7):x + 8] = True
    grid_y, grid_x = np.mgrid[:16, :16]
    u, v = grid_x - 7.5, grid_y - 7.5
    gaussian = np.exp(-(u*u + v*v) / (2 * 7.5**2))
    cells = (grid_y // 4) * 4 + grid_x // 4
    descriptors = []
    for x, y in points:
        variants = []
        for scale in (1.0, 1.5, 2.0):
            dx, dy = sample(gx, x + scale*u, y + scale*v), sample(gy, x + scale*u, y + scale*v)
            angles = np.mod(np.arctan2(dy, dx), 2*np.pi)
            weights = np.hypot(dx, dy) * gaussian
            orientation = np.bincount((angles.ravel()*36/(2*np.pi)).astype(int), weights=weights.ravel(), minlength=36)
            angle = (orientation.argmax() + 0.5) * 2*np.pi/36
            c, s = np.cos(angle), np.sin(angle)
            px, py = x + scale*(c*u - s*v), y + scale*(s*u + c*v)
            dx, dy = sample(gx, px, py), sample(gy, px, py)
            bins = np.mod(np.arctan2(dy, dx) - angle, 2*np.pi) * 8/(2*np.pi)
            low = np.floor(bins).astype(int)
            fraction = bins - low
            weights = np.hypot(dx, dy) * gaussian
            descriptor = np.zeros((16, 8))
            np.add.at(descriptor, (cells.ravel(), low.ravel() % 8), (weights*(1-fraction)).ravel())
            np.add.at(descriptor, (cells.ravel(), (low.ravel()+1) % 8), (weights*fraction).ravel())
            descriptor = descriptor.ravel()
            descriptor /= max(np.linalg.norm(descriptor), 1e-12)
            descriptor = np.minimum(descriptor, 0.2)
            descriptor /= max(np.linalg.norm(descriptor), 1e-12)
            variants.append(descriptor)
        descriptors.append(variants)
    return np.array(points, dtype=float), np.array(descriptors, dtype=np.float32)


def correspond(first, last):
    pa, da = features(first)
    pb, db = features(last)
    if len(pa) < 2 or len(pb) < 2:
        return pa, pb, []
    assert np.isfinite(da).all() and np.isfinite(db).all(), "Nonfinite descriptor"
    # Explicit reduction avoids platform BLAS floating-status warnings on unit vectors.
    similarity = np.einsum("ik,jk->ij", da.reshape(-1, 128), db.reshape(-1, 128), optimize=False)
    similarity = similarity.reshape(len(pa), 3, len(pb), 3).max(axis=(1, 3))
    assert np.isfinite(similarity).all(), "Nonfinite descriptor similarity"
    distances = np.maximum(0, 2 - 2*similarity)
    nearest = distances.argmin(1)
    reverse = distances.argmin(0)
    sorted_cost = np.sort(distances, axis=1)[:, :2]
    valid = ((sorted_cost[:, 0] < 0.64*sorted_cost[:, 1]) & (sorted_cost[:, 0] < 0.8)
             & (reverse[nearest] == np.arange(len(pa))))
    pairs = [{"first": pa[i].tolist(), "last": pb[j].tolist(),
              "squared_ratio": float(sorted_cost[i, 0]/max(sorted_cost[i, 1], 1e-12))}
             for i, j in enumerate(nearest) if valid[i]]
    return pa, pb, pairs


def models(pairs):
    if len(pairs) < 6:
        return []
    first = np.array([p["first"] for p in pairs])
    last = np.array([p["last"] for p in pairs])
    design = np.c_[first, np.ones(len(first))]
    remaining = np.arange(len(first))
    rng = np.random.default_rng(0)
    results = []
    for _ in range(3):
        best = np.array([], dtype=int)
        if len(remaining) < 6:
            break
        for _ in range(600):
            chosen = rng.choice(remaining, 3, replace=False)
            if abs(np.linalg.det(design[chosen])) < 64:
                continue
            matrix = np.linalg.solve(design[chosen], last[chosen])
            determinant = np.linalg.det(matrix[:2])
            if not 0.25 < determinant < 4:
                continue
            error = np.linalg.norm(design[remaining] @ matrix - last[remaining], axis=1)
            inliers = remaining[error < 3]
            if len(inliers) > len(best):
                best = inliers
        if len(best) < 6:
            break
        matrix = np.linalg.lstsq(design[best], last[best], rcond=None)[0]
        results.append({"matrix": matrix.tolist(), "inliers": best.tolist(),
                        "source_bounds": [first[best].min(0).tolist(), first[best].max(0).tolist()],
                        "mean_error": float(np.linalg.norm(design[best] @ matrix - last[best], axis=1).mean())})
        remaining = np.setdiff1d(remaining, best)
    return results


def selfcheck():
    blank = np.zeros((128, 128), dtype=float)
    assert not correspond(blank, blank)[2]
    rng = np.random.default_rng(12)
    first = blur(blur(rng.random((256, 384)), 1), 1)
    angle = 0.25
    rotation = np.array([[np.cos(angle), -np.sin(angle)], [np.sin(angle), np.cos(angle)]])
    center, shift = np.array([191.5, 127.5]), np.array([-48, -12])
    y, x = np.mgrid[:256, :384]
    target = np.stack((x, y), axis=-1)
    source = (target-center-shift) @ rotation + center
    last = sample(first, source[..., 0], source[..., 1])
    _, _, pairs = correspond(first, last)
    assert len(pairs) >= 20, f"Only {len(pairs)} known-motion feature matches"
    errors = [np.linalg.norm((np.array(p["first"])-center) @ rotation.T+center+shift-p["last"]) for p in pairs]
    assert np.median(errors) < 2, f"Known correspondence median error {np.median(errors)}"
    fitted = models(pairs)
    assert fitted, "No supported known-motion model"
    controls = np.array([[96, 64, 1], [192, 128, 1], [256, 192, 1]])
    truth = (controls[:, :2]-center) @ rotation.T+center+shift
    assert np.max(np.linalg.norm(controls @ np.array(fitted[0]["matrix"])-truth, axis=1)) < 2
    print(json.dumps({"selfcheck": "passed", "matches": len(pairs), "median_error": float(np.median(errors)),
                      "model_inliers": len(fitted[0]["inliers"])}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("first", nargs="?")
    parser.add_argument("last", nargs="?")
    parser.add_argument("--out")
    parser.add_argument("--selfcheck", action="store_true")
    args = parser.parse_args()
    if args.selfcheck:
        selfcheck()
    else:
        if not args.first or not args.last or not args.out:
            parser.error("first, last and --out are required")
        first = np.asarray(Image.open(args.first).convert("L"), dtype=float)/255
        last = np.asarray(Image.open(args.last).convert("L"), dtype=float)/255
        if first.shape != last.shape or max(first.shape) > 2048:
            parser.error("requires matching bounded diagnostic images (maximum2048px)")
        started = time.perf_counter()
        pa, pb, pairs = correspond(first, last)
        result = {"features": [len(pa), len(pb)], "matches": pairs, "models": models(pairs),
                  "seconds": time.perf_counter()-started, "scope": "offline bounded-pair diagnostic, not runtime"}
        Path(args.out).write_text(json.dumps(result, indent=2))
        print(json.dumps({"features": result["features"], "matches": len(pairs),
                          "models": [len(m["inliers"]) for m in result["models"]], "seconds": result["seconds"]}))
