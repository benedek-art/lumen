"""Fit per-camera, per-ISO noise params from real photos -> data/calib.json.

python -m lumen_denoise.calibrate <list.txt> [data/calib.json]
Also reports lag-1 spatial correlation of the noise residual in flat areas (should be ~0 for
untouched raw; clearly > 0 means in-camera raw NR and the model needs a correlated term).
"""
import json, sys
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
import numpy as np
from . import raw, noise


def flat_corr(packed):
    g = packed[1]
    d = g - (np.roll(g, 1, 0) + np.roll(g, -1, 0) + np.roll(g, 1, 1) + np.roll(g, -1, 1)) / 4
    d = d[4:-4, 4:-4]
    # restrict to flattest 20% of 16x16 blocks
    b = 16
    h, w = d.shape[0] // b * b, d.shape[1] // b * b
    blocks = d[:h, :w].reshape(h // b, b, w // b, b).transpose(0, 2, 1, 3).reshape(-1, b, b)
    v = blocks.var((1, 2))
    blocks, v = blocks[v > 0], v[v > 0]  # drop clipped/black blocks
    sel = blocks[v <= np.percentile(v, 20)]
    a = sel[:, :, :-1].ravel(); c = sel[:, :, 1:].ravel()
    return float(np.corrcoef(a, c)[0, 1])


def one(path):
    try:
        r = raw.load(path)
        p = raw.pack(r.cfa)
        K, rv = noise.estimate(p)
        return r.model, r.iso, K, rv, flat_corr(p), path
    except Exception as e:
        return None, 0, 0, 0, 0, f"{path}: {e}"


if __name__ == "__main__":
    files = [l.strip() for l in open(sys.argv[1]) if l.strip()]
    out = sys.argv[2] if len(sys.argv) > 2 else "data/calib.json"
    per = defaultdict(list)
    with ProcessPoolExecutor(6) as ex:
        for m, iso, K, rv, corr, p in ex.map(one, files):
            if m is None:
                print("skip", p); continue
            per[(m, iso)].append((K, rv, corr))
            print(f"{m} ISO{iso:.0f} K={K:.3e} read_sd={rv**.5:.5f} corr={corr:+.3f}", flush=True)
    table = defaultdict(list)
    print("\nmodel ISO n  K(median)  read_sd  corr")
    for (m, iso), v in sorted(per.items()):
        v = np.array(v)
        K, rv, corr = np.median(v, 0)
        table[m].append([iso, K, rv])
        print(f"{m} {iso:.0f} {len(v)} {K:.3e} {rv**.5:.5f} {corr:+.3f}")
    # physical fit per camera on ISO >= 400 (above Sony's dual-gain switch):
    #   K = a * ISO ;  read_var = b * ISO^2 + c   (pre- and post-amplifier read noise)
    # robust: median ratio for a, weighted LS on per-file values for b, c
    fitted = {}
    for m in {k[0] for k in per}:
        pts = [(iso, K, rv) for (mm, iso), v in per.items() if mm == m and iso >= 400 for K, rv, _ in v]
        iso, K, rv = map(np.array, zip(*pts))
        a = float(np.median(K / iso))
        # read noise: per-ISO medians of usable estimates (bright scenes pin the intercept at the
        # 1e-10 floor -> drop those), fit in log space over a small grid of (b, c)
        med = {}
        for i in set(iso):
            v = rv[(iso == i) & (rv > 1e-9)]
            if len(v) >= 2: med[i] = np.median(v)
        mi, mv = np.array(list(med)), np.array(list(med.values()))
        best = None
        for b in np.logspace(-18, -12, 241):
            for c in np.logspace(-10, -5, 101):
                e = np.sum((np.log(b * mi ** 2 + c) - np.log(mv)) ** 2)
                if best is None or e < best[0]: best = (e, b, c)
        _, b, c = best
        isos = sorted({k[1] for k in per if k[0] == m} | {100.0, 51200.0 if m == "ILCE-7M4" else 25600.0})
        fitted[m] = [[i, a * i, b * i * i + c] for i in isos]
        print(f"\n{m}: K = {a:.3e}*ISO  read_sd = sqrt({b:.3e}*ISO^2 + {c:.3e})")
        print("ISO  K_meas  K_fit  read_meas  read_fit")
        for i, Kf, rf in fitted[m]:
            mv = per.get((m, i))
            km, rm = (np.median([x[0] for x in mv]), np.median([x[1] for x in mv]) ** .5) if mv else (np.nan, np.nan)
            print(f"{i:.0f} {km:.2e} {Kf:.2e} {rm:.5f} {rf ** .5:.5f}")
    json.dump(fitted, open(out, "w"), indent=1)
    print("wrote", out)
