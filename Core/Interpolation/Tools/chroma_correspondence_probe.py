"""Offline bounded-pair chroma ablation; not a production dependency or runtime claim."""
import argparse
import json
import time
from pathlib import Path

import numpy as np
from PIL import Image
from feature_correspondence_probe import sample


def smooth(image):
    weights = np.array([1, 4, 6, 4, 1])/16
    result = image
    for axis in (0, 1):
        pad = [(0, 0)]*result.ndim
        pad[axis] = (2, 2)
        padded = np.pad(result, pad, mode="edge")
        result = sum(weight*np.take(padded, np.arange(result.shape[axis])+i, axis=axis)
                     for i, weight in enumerate(weights))
    return result


def coarse_image(folder, index):
    luma = np.asarray(Image.open(folder/f"trace_input{index}.png"), dtype=np.float32)/255
    y, x = np.mgrid[:luma.shape[0], :luma.shape[1]]
    chroma = [np.asarray(Image.open(folder/f"trace_input{index}_uv{c}.png"), dtype=np.float32)/255 for c in range(2)]
    channels = [luma] + [sample(c, (x+0.5)*c.shape[1]/luma.shape[1]-0.5,
                               (y+0.5)*c.shape[0]/luma.shape[0]-0.5) for c in chroma]
    image = smooth(np.stack(channels, axis=-1))
    for _ in range(3):
        image = smooth(image)
        image = (image[::2, ::2] + image[1::2, ::2] + image[::2, 1::2] + image[1::2, 1::2])/4
    return image.astype(np.float32)


def descriptor(image, points):
    y, x = np.mgrid[-4:4, -4:4]
    return np.stack([sample(image[..., c], points[:, 0, None]+x.ravel(), points[:, 1, None]+y.ravel())
                     for c in range(3)], axis=-1).astype(np.float32)


def candidates(first, last, color):
    height, width = first.shape[:2]
    yy, xx = np.mgrid[4:height-4:2, 4:width-4:2]
    targets = np.c_[xx.ravel(), yy.ravel()]
    target = descriptor(last, targets)
    output = np.zeros(((height+3)//4+1, (width+3)//4+1, 2), dtype=np.float32)
    channels = 3 if color else 1
    for y in range(output.shape[0]):
        for x in range(output.shape[1]):
            center = np.array([x*4, y*4])
            if np.any(center < 4) or center[0] >= width-4 or center[1] >= height-4:
                continue
            source = descriptor(first, center[None])[0]
            delta = target[..., :channels] - source[None, ..., :channels]
            costs = np.einsum("ijk,ijk->i", delta, delta, optimize=False)
            output[y, x] = targets[costs.argmin()] - center
    return output


def aggregation_report(folder, trace):
    """Offline coarse ablation; PNG quantization prevents exact Metal parity."""
    first, last = coarse_image(folder, 0), coarse_image(folder, 1)
    height, width = first.shape[:2]
    shape = ((height+3)//4+1, (width+3)//4+1, 4)
    field = np.fromfile(trace, dtype="<f4")
    if field.size != np.prod(shape) or not np.isfinite(field).all():
        raise ValueError("invalid coarse patch field")
    field = field.reshape(shape)
    rows = []
    # Diagnostic landmarks on the stored 1152×480 pair, not motion ground truth.
    for px, py in [(950, 385), (928, 256), (955, 268)]:
        if px >= width*8 or py >= height*8:
            continue
        point = np.array([px//8, py//8])
        base = point//4
        yy, xx = np.mgrid[-1:2, -1:2]
        q = point[:, None]+np.stack([xx.ravel(), yy.ravel()])
        source = np.stack([sample(first[..., c], *q) for c in range(3)], axis=-1)
        scores = []
        for y in range(2):
            for x in range(2):
                vector = field[base[1]+y, base[0]+x]
                target = np.stack([sample(last[..., c], q[0]+vector[0], q[1]+vector[1]) for c in range(3)], axis=-1)
                residual = abs(source-target).mean(0)
                penalty = np.sqrt(max(0, vector[3]))
                scores.append({"vector_native": (vector[:2]*8).tolist(),
                               "luma_score": float(residual[0]+penalty),
                               "color_score": float(residual.sum()+penalty),
                               "residual_yuv": residual.tolist()})
        rows.append({"source": [px, py], "candidates": scores,
                     "luma_winner": min(range(4), key=lambda i: scores[i]["luma_score"]),
                     "color_winner": min(range(4), key=lambda i: scores[i]["color_score"])})
    return rows


def selfcheck():
    first = np.zeros((48, 64, 3), dtype=np.float32)
    first[:] = [0.1, 0.5, 0.5]
    y, x = np.mgrid[:8, :8]
    texture = 0.2 + ((x*37+y*61) % 100)/200
    for cx, uv in [(24, (0.35, 0.65)), (40, (0.65, 0.35))]:
        first[20:28, cx-4:cx+4, 0] = texture
        first[20:28, cx-4:cx+4, 1:] = uv
    last = np.zeros_like(first)
    last[:] = [0.1, 0.5, 0.5]
    last[20:28, 28:36] = first[20:28, 20:28]
    last[20:28, 36:44] = first[20:28, 36:44]
    source = descriptor(first, np.array([[24, 24]]))[0]
    targets = descriptor(last, np.array([[32, 24], [40, 24]]))
    luma = ((targets[..., 0]-source[..., 0])**2).sum(1)
    color = ((targets-source)**2).sum((1, 2))
    assert np.all(luma == 0), luma
    assert color[0] == 0 and color[1] > 0.1, color
    result = candidates(first, last, True)
    assert np.array_equal(result[6, 6], [8, 0]), result[6, 6]
    print(json.dumps({"selfcheck": "passed", "luma_costs": luma.tolist(), "color_costs": color.tolist()}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", nargs="?", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--selfcheck", action="store_true")
    parser.add_argument("--aggregate-trace", type=Path, help="optional propagated l3 patch float4 field")
    args = parser.parse_args()
    if args.selfcheck:
        selfcheck()
    else:
        if not args.folder or not args.out:
            parser.error("folder and --out are required")
        with Image.open(args.folder/"trace_input0.png") as image:
            width, height = image.size
        if min(width, height) < 96 or width > 2048 or height > 2048 or width % 8 or height % 8:
            parser.error("requires bounded pair: dimensions 96–2048, divisible by 8")
        for index in (0, 1):
            for suffix, expected in [("", (width, height)), ("_uv0", (width//2, height//2)), ("_uv1", (width//2, height//2))]:
                with Image.open(args.folder/f"trace_input{index}{suffix}.png") as image:
                    if image.size != expected or image.mode != "L":
                        parser.error(f"invalid dimensions or format: trace_input{index}{suffix}.png")
        started = time.perf_counter()
        first, last = coarse_image(args.folder, 0), coarse_image(args.folder, 1)
        args.out.mkdir(parents=True, exist_ok=True)
        summary = {}
        for mode in ("luma", "color"):
            for direction, (a, b) in enumerate([(first, last), (last, first)]):
                proposed = candidates(a, b, mode == "color")
                # Map each original8×8 block center to its nearest coarse patch.
                yy, xx = np.mgrid[:height//8, :width//8]
                px = np.minimum((xx+2)//4, proposed.shape[1]-1)
                py = np.minimum((yy+2)//4, proposed.shape[0]-1)
                seeds = np.rint(proposed[py, px]*16).astype("<i4")
                seeds.tofile(args.out/f"{mode}_{direction}.i32")
                proposed.tofile(args.out/f"{mode}_{direction}.f32")
                summary[f"{mode}_{direction}"] = {"patch_shape": list(proposed.shape), "block_shape": list(seeds.shape),
                                                   "point29_8_native": (proposed[8, 29]*8).tolist() if proposed.shape[1] > 29 else None}
        if args.aggregate_trace:
            summary["aggregation_ablation"] = aggregation_report(args.folder, args.aggregate_trace)
        summary["seconds"] = time.perf_counter()-started
        summary["scope"] = "offline ablation; not realtime; no claim of correct correspondence"
        (args.out/"summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary))
