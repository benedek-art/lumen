"""Deterministic benchmark crop selection on a clean packed RGGB frame.

python -m lumen_denoise.eval.regions [--synthetic]   # prints the regions picked on each frame
Kinds: dark (deep shadow, above black), flat (mid-tone, lowest gradient energy), detail (highest
high-frequency energy), mid (median tone, seeded pick), centre (train.validate's ps=512 crop).
All stats come from summed-area tables over a stride grid, so a 24 MP frame takes well under 1 s.
"""
import argparse
import numpy as np
from . import common

KINDS = ("dark", "flat", "detail", "mid", "centre")
DARK = (0.003, 0.03)    # mean linear luminance of a "dark" crop: deep shadow but above the black floor
FLAT_TONE = (0.05, 0.6) # flat crops must be mid-tone (not shadows, which are flat for a different reason)
CLIP = 0.9              # any channel above this counts as (near-)clipped highlight
CLIP_FRAC = 1e-3        # crops with more clipped pixels than this are skipped (denoisers cannot fail there)
DARK_SPILL = 0.06       # a dark crop may hold at most 2 % pixels above this (no bright edge leaking in)


def _sat(a):
    """Summed-area table with a zero row/col so box sums are 4 lookups."""
    return np.pad(a.astype(np.float64).cumsum(0).cumsum(1), ((1, 0), (1, 0)))


def _box(s, ys, xs, b):
    Y, X = np.meshgrid(ys, xs, indexing="ij")
    return (s[Y + b, X + b] - s[Y, X + b] - s[Y + b, X] + s[Y, X]) / (b * b)


def _grid(n, b, stride):
    g = list(range(0, n - b + 1, stride))
    if g[-1] != n - b: g.append(n - b)
    return np.array(g)


def region_stats(clean, crop=common.CROP, stride=None):
    """Per-candidate stats on a stride grid: dict of 2-D arrays + ys, xs, size."""
    _, h, w = clean.shape
    b = min(crop, h, w)
    stride = stride or max(b // 4, 1)
    L = np.clip(clean.mean(0), 0, None)
    t = common.tone(L)
    gy = np.zeros_like(t); gx = np.zeros_like(t)
    gy[:-1] = np.diff(t, axis=0); gx[:, :-1] = np.diff(t, axis=1)
    lap = np.zeros_like(t)  # 4-neighbour Laplacian in tone space: HF energy
    lap[1:-1, 1:-1] = 4 * t[1:-1, 1:-1] - t[:-2, 1:-1] - t[2:, 1:-1] - t[1:-1, :-2] - t[1:-1, 2:]
    ys, xs = _grid(h, b, stride), _grid(w, b, stride)
    return dict(ys=ys, xs=xs, size=b,
                mean=_box(_sat(L), ys, xs, b),
                grad=_box(_sat(gx * gx + gy * gy), ys, xs, b),
                hf=_box(_sat(lap * lap), ys, xs, b),
                clip=_box(_sat((clean.max(0) > CLIP)), ys, xs, b),
                spill=_box(_sat(L > DARK_SPILL), ys, xs, b))


def _overlaps(y, x, b, taken):
    return any(abs(y - r["y"]) < max(b, r["size"]) and abs(x - r["x"]) < max(b, r["size"]) for r in taken)


def _pick(score, valid, st, kind, n, taken):
    """Best n candidates by ascending score among valid, avoiding overlap with taken if possible."""
    if not valid.any(): return []
    idx = np.argwhere(valid)
    order = np.lexsort((idx[:, 1], idx[:, 0], score[valid]))  # score, then raster order: deterministic
    b, out = st["size"], []
    for strict in (True, False):
        for k in order:
            if len(out) >= n: break
            y, x = int(st["ys"][idx[k, 0]]), int(st["xs"][idx[k, 1]])
            if any(r["y"] == y and r["x"] == x for r in out): continue
            if strict and _overlaps(y, x, b, taken + out): continue
            out.append(dict(kind=kind, y=y, x=x, size=b))
    return out


def pick_regions(clean, crop=common.CROP, n_per_kind=1, seed=common.SEED):
    """list of {kind, y, x, size}; same input -> same regions. A kind with no valid candidate
    (e.g. a frame with no shadows) is simply absent; centre is always present."""
    clean = np.asarray(clean, np.float32)
    _, h, w = clean.shape
    st = region_stats(clean, crop)
    m, ok = st["mean"], st["clip"] <= CLIP_FRAC
    if not ok.any(): ok = np.ones_like(ok, bool)
    taken = []
    taken += _pick(-st["hf"], ok & (m > DARK[1]), st, "detail", n_per_kind, taken) or \
        _pick(-st["hf"], ok, st, "detail", n_per_kind, taken)
    dv = ok & (m >= DARK[0]) & (m <= DARK[1]) & (st["spill"] <= 0.02)
    taken += _pick(st["spill"] + m, dv, st, "dark", n_per_kind, taken)  # most uniformly dark first
    fv = ok & (m >= FLAT_TONE[0]) & (m <= FLAT_TONE[1])
    taken += _pick(st["grad"], fv, st, "flat", n_per_kind, taken) or \
        _pick(st["grad"], ok & (m > DARK[1]), st, "flat", n_per_kind, taken)
    # mid: candidates in the 40-60th percentile of candidate tone, a seeded random pick among them
    q = m[ok]
    mv = ok & (m >= np.percentile(q, 40)) & (m <= np.percentile(q, 60))
    rnd = np.random.default_rng(seed).random(m.shape)
    taken += _pick(rnd, mv, st, "mid", n_per_kind, taken)
    c = min(common.CENTRE, h, w)
    taken.append(dict(kind="centre", y=(h - c) // 2, x=(w - c) // 2, size=c))
    return taken


def cut(img, reg):
    y, x, s = reg["y"], reg["x"], reg["size"]
    return np.ascontiguousarray(img[:, y:y + s, x:x + s], np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--val", default="data/gt_val"); ap.add_argument("--meta", default="data/gt_meta.json")
    ap.add_argument("--synthetic", action="store_true"); ap.add_argument("--n", type=int, default=0)
    ap.add_argument("--per-kind", type=int, default=1)
    a = ap.parse_args()
    for f in common.clean_frames(a.val, a.meta, a.n, True if a.synthetic else None):
        for r in pick_regions(f.clean, n_per_kind=a.per_kind):
            print(f.name, f.camera, r)


if __name__ == "__main__":
    main()
