"""Star-preservation test: synthetic stars of known brightness on held-out scenes.
Reports the median fraction of each star's flux (7x7 aperture, above the star-free scene) kept
after denoising, bucketed by peak SNR. 1.0 = perfectly kept, 0 = erased.
python -m lumen_denoise.starbench --methods bm3d,net:runs/A/best.pt [--iso 6400]
(Torch/train.add_stars path kept for continuity with old numbers; the release gate uses eval/stars.py.)
"""
import argparse, json, random
from pathlib import Path
import numpy as np

BUCKETS = [(2.5, 5), (5, 10), (10, 25), (25, 60)]


def bench(f, files, meta, table, iso=6400):
    """-> {bucket: [kept fractions]} for method f over the npy files (384 centre crop, seed = file index)."""
    import torch
    from .train import add_noise, add_stars
    kept = {b: [] for b in BUCKETS}
    for i, fp in enumerate(files):
        g = np.load(fp, mmap_mode="r"); _, h, w = g.shape
        clean = torch.from_numpy(np.array(g[:, h // 2 - 192:h // 2 + 192, w // 2 - 192:w // 2 + 192], np.float32))
        cam = meta[fp.stem]; K, r = table.params(cam, min(iso, table.iso_range(cam)[1]))
        random.seed(i); torch.manual_seed(i)
        starry, pos = add_stars(clean.clone(), K, r, n_max=40, ret=True)
        x = add_noise(starry, K, r).clamp(max=1).numpy()
        y = f(x, K, r)
        for iy, ix, k in pos:
            sl = (slice(None), slice(iy - 3, iy + 4), slice(ix - 3, ix + 4))
            true = float((starry[sl] - clean[sl]).sum())
            got = float((torch.from_numpy(y)[sl] - clean[sl]).sum())
            for b in BUCKETS:
                if b[0] <= k < b[1]: kept[b].append(got / max(true, 1e-9))
    return kept


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--val", default="data/gt_val"); ap.add_argument("--meta", default="data/gt_meta.json")
    ap.add_argument("--calib", default="data/calib.json"); ap.add_argument("--methods", required=True)
    ap.add_argument("--iso", type=int, default=6400); ap.add_argument("--n", type=int, default=16)
    a = ap.parse_args(argv)
    from .train import NoiseTable
    from .bench import get
    meta, table = json.load(open(a.meta)), NoiseTable(a.calib)
    files = sorted(Path(a.val).glob("*.npy"))[: a.n]
    for name in a.methods.split(","):
        kept = bench(get(name), files, meta, table, a.iso)
        print(name, "ISO", a.iso, "flux kept by star peak SNR:",
              {f"{b[0]}-{b[1]}x": round(float(np.median(v)), 2) for b, v in kept.items() if v}, flush=True)


if __name__ == "__main__":
    main()
