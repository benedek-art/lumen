"""Real high-ISO RAW access for the no-reference checks (the photos live only on the user's Mac).

python -m lumen_denoise.eval.realdata <list.txt|dir> [--n 4]   # prints model/ISO/K/r and picked crops
Everything degrades to "not available" (never raises) when rawpy or the files are missing.
"""
import argparse
from pathlib import Path
import numpy as np
from scipy.ndimage import gaussian_filter
from . import common

RAW_EXT = {".arw", ".rw2", ".dng", ".nef", ".cr2", ".cr3", ".raf", ".orf"}


def list_files(src, n=0):
    """RAW paths from a .txt list (one per line, # comments ok) or a directory; [] if missing."""
    if not src:
        return []
    p = Path(src)
    try:
        if p.is_dir():
            fs = sorted(str(f) for f in p.iterdir() if f.suffix.lower() in RAW_EXT)
        elif p.is_file():
            fs = [l.strip() for l in open(p) if l.strip() and not l.lstrip().startswith("#")]
            fs = [f for f in fs if Path(f).is_file()]
        else:
            return []
    except OSError:
        return []
    return fs[: n or None]


def available(files=None):
    """(ok, reason): rawpy importable, files present. raw.load reads ISO/model in-process (exiftool is only its
    fallback), so a missing exiftool is no reason to skip; an unreadable file surfaces per file instead."""
    try:
        import rawpy  # noqa: F401
    except Exception as e:  # ImportError or a broken libraw
        return False, f"rawpy not importable ({type(e).__name__})"
    if files is not None and not files:
        return False, "no real high-ISO RAW files given"
    return True, "ok"


def load_packed(path, table=None):
    """-> (packed RGGB (4,h,w) float32, K, r, {model, iso, source}). Same param logic as infer.Engine:
    calibrated table for known cameras (ISO clamped to the calibrated range), else noise.estimate."""
    from .. import raw, noise
    from ..prepare import to_rggb
    rw = raw.load(path)
    p = np.ascontiguousarray(to_rggb(raw.pack(rw.cfa), rw.pattern), np.float32)
    if table is not None and rw.model in table.cameras():
        lo, hi = table.iso_range(rw.model)
        K, r = table.params(rw.model, float(np.clip(rw.iso, lo, hi)))
        src = "calib"
    else:
        K, r = noise.estimate(p)
        src = "estimate"
    return p, float(K), float(r), dict(model=rw.model, iso=float(rw.iso), source=src)


def pick_test_crops(packed, n=4, size=common.CROP, seed=common.SEED):
    """n crops [(kind, (4,s,s) array)] on a NOISY real frame, preferring flat, dark, detail, mid.
    Regions are chosen on a lightly smoothed copy so noise does not masquerade as detail."""
    _, h, w = packed.shape
    size = min(size, h, w)
    guide = np.stack([gaussian_filter(c, 1.5) for c in packed])
    regs = []
    try:
        from .regions import pick_regions
        regs = [g for g in pick_regions(guide, crop=size, seed=seed) if g["kind"] != "centre"]
    except Exception:
        regs = []
    order = {"flat": 0, "dark": 1, "detail": 2, "mid": 3}
    regs.sort(key=lambda g: order.get(g["kind"], 9))
    seen = set()  # small frames: pick_regions may return the same window for two kinds
    regs = [g for g in regs if (g["y"], g["x"]) not in seen and not seen.add((g["y"], g["x"]))]
    rng = np.random.default_rng(seed)
    while len(regs) < n:  # top up with seeded random crops (also the fallback if regions is missing)
        regs.append(dict(kind="rand", y=int(rng.integers(0, h - size + 1)), x=int(rng.integers(0, w - size + 1)), size=size))
    out = []
    for g in regs[:n]:
        y, x, s = g["y"], g["x"], g["size"]
        out.append((g["kind"], np.ascontiguousarray(packed[:, y:y + s, x:x + s], np.float32)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src"); ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--calib", default=str(common.DEFAULT_CALIB))
    a = ap.parse_args()
    files = list_files(a.src, a.n)
    ok, why = available(files)
    if not ok:
        print("realdata unavailable:", why); return
    table = common.NoiseTable(a.calib)
    for f in files:
        p, K, r, meta = load_packed(f, table)
        kinds = [k for k, _ in pick_test_crops(p)]
        print(Path(f).name, meta, f"K={K:.3e} r={r:.3e}", p.shape, kinds)


if __name__ == "__main__":
    main()
