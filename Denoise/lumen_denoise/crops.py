"""Real-photo comparison grids (no ground truth exists for real noisy shots).

python -m lumen_denoise.crops --files data/lists/local_real_noisy.txt --n 12 \
    --methods bm3d,net:runs/A/best.pt --out reports/real
Per photo: 2 crops (most detailed area, flattest mid-tone area) x columns
[original | each method | residual of the last method (x4, what was removed)].
Optional Lightroom column: put Lightroom's denoised DNG at reports/lightroom/<stem>*.dng
"""
import argparse, glob, json
from pathlib import Path
import numpy as np
import rawpy
from PIL import Image, ImageDraw
from . import raw as rawio, render
from .prepare import to_rggb, from_rggb
from .bench import get
from .train import NoiseTable

CROP = 320  # rendered px


def pick_regions(img):
    """(detail, flat) top-left corners on the rendered original, avoiding clipped/black areas."""
    g = img.mean(2).astype(np.float32)
    b = CROP
    h, w = g.shape[0] // b, g.shape[1] // b
    blocks = g[: h * b, : w * b].reshape(h, b, w, b)
    mean = blocks.mean((1, 3))
    gy = np.abs(np.diff(g, axis=0))[: h * b - 1]
    grad = np.pad(gy, ((0, 1), (0, 0)))[: h * b, : w * b].reshape(h, b, w, b).mean((1, 3))
    ok = (mean > 25) & (mean < 220)
    if not ok.any(): ok[:] = True
    det = np.unravel_index(np.where(ok, grad, -1).argmax(), grad.shape)
    flat = np.unravel_index(np.where(ok & (mean > 50), grad, 1e9).argmin(), grad.shape)
    return [(det[0] * b, det[1] * b), (flat[0] * b, flat[1] * b)]


def run_method(f, r, p, K, rv, region, margin=48):
    """Denoise only the packed area under a rendered region (+margin) to keep it fast."""
    (y, x) = region
    py0, px0 = max(y // 2 - margin, 0), max(x // 2 - margin, 0)
    py1, px1 = min(y // 2 + CROP // 2 + margin, p.shape[1]), min(x // 2 + CROP // 2 + margin, p.shape[2])
    out = p.copy()
    sub = p[:, py0:py1, px0:px1]
    hh, ww = (-sub.shape[1]) % 16, (-sub.shape[2]) % 16
    d = f(np.pad(sub, ((0, 0), (0, hh), (0, ww)), mode="reflect"), K, rv)[:, : sub.shape[1], : sub.shape[2]]
    out[:, py0:py1, px0:px1] = d
    return out


def label(im, text):
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, 8 * len(text) + 8, 18), fill=(0, 0, 0))
    d.text((4, 3), text, fill=(255, 255, 255))
    return im


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--files", default="data/lists/local_real_noisy.txt"); ap.add_argument("--n", type=int, default=12)
    ap.add_argument("--methods", required=True); ap.add_argument("--out", default="reports/real")
    ap.add_argument("--calib", default="data/calib.json")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    table = NoiseTable(a.calib)
    files = [l.strip() for l in open(a.files) if l.strip()]
    files = files[:: max(1, len(files) // a.n)][: a.n]
    methods = [(m, get(m)) for m in a.methods.split(",")]
    index = []
    for f in files:
        r = rawio.load(f)
        p = to_rggb(rawio.pack(r.cfa), r.pattern)
        lo, hi = table.iso_range(r.model)
        K, rv = table.params(r.model, float(np.clip(r.iso, lo, hi)))
        orig = render.render(f)
        regions = pick_regions(orig)
        cols = [("original", orig)]
        lr = glob.glob(f"reports/lightroom/{Path(f).stem.rsplit('_', 1)[0]}*.dng")
        if lr:
            with rawpy.imread(lr[0]) as rr:
                cols.append(("lightroom", rr.postprocess(use_camera_wb=True, output_bps=8, no_auto_bright=True, bright=1.0)))
        for name, fn in methods:
            q = p.copy()
            for reg in regions:
                sub = run_method(fn, r, p, K, rv, reg)
                (y, x) = reg
                ys, xs = slice(max(y // 2 - 48, 0), y // 2 + CROP // 2 + 48), slice(max(x // 2 - 48, 0), x // 2 + CROP // 2 + 48)
                q[:, ys, xs] = sub[:, ys, xs]
            cfa = r.cfa.copy(); h2, w2 = q.shape[1] * 2, q.shape[2] * 2
            cfa[:h2, :w2] = rawio.unpack(from_rggb(q, r.pattern))
            cols.append((name.split("/")[-2] if name.startswith("net:") else name, render.render(f, cfa)))
        stem = Path(f).stem
        for k, (y, x) in enumerate(regions):
            tiles = [label(Image.fromarray(np.ascontiguousarray(im[y:y + CROP, x:x + CROP])), n) for n, im in cols]
            res = np.clip((cols[-1][1][y:y + CROP, x:x + CROP].astype(np.int16) - orig[y:y + CROP, x:x + CROP]) * 4 + 128, 0, 255).astype(np.uint8)
            tiles.append(label(Image.fromarray(res), "removed x4"))
            grid = Image.new("RGB", (CROP * len(tiles), CROP))
            for i, t in enumerate(tiles): grid.paste(t, (i * CROP, 0))
            name = f"{stem}_{'detail' if k == 0 else 'flat'}.png"
            grid.save(out / name)
            index.append({"file": name, "src": stem, "iso": r.iso, "model": r.model, "kind": "detail" if k == 0 else "flat",
                          "cols": [n for n, _ in cols] + ["removed x4"]})
        print(stem, r.model, r.iso, flush=True)
    json.dump(index, open(out / "index.json", "w"), indent=1)


if __name__ == "__main__":
    main()
