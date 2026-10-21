"""Blue-band luminance on real skies (983, 1840, 2545): strength in EV, crushing, noise,
monotone response, symmetry, and the 1840 treeline fringe.

Sky patches and the noise formula are the audit's (skym.py): high-pass = L - box3(L) of
display OKLab L; "rel" noise = (std_hp / median L)_edit / (std_hp / median L)_base.
Fringe (1840): per column, the treeline row y_e is the first row below y=60 whose base L
falls under the midpoint of sky L (rows 5..60) and tree L (rows 400..500). For the band
y_e-8..y_e+8, bump = p95(Y)/median(Y of rows y_e-24..y_e-12); fringe = mean over columns
of max(0, bump_edit - bump_base). It is how much brighter the edge stands out than the
sky just above it, beyond what the untouched render already shows.

usage: sky.py --bin lumen-render --corpus corpus --out DIR [--band 5]
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib import *

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True); ap.add_argument("--corpus", required=True)
ap.add_argument("--out", required=True); ap.add_argument("--band", type=int, default=5)
a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
F = {"983": ("983_canon-eos-5d-mark-iv", (0.0, 0.25, 0.0, 0.06)),
     "1840": ("1840_nikon-d850", (0.0, 1.0, 0.0, 0.07)),
     "2545": ("2545_panasonic-dmc-gx85", (0.90, 1.0, 0.0, 0.10))}
VALS = list(range(-100, 101, 20))
def rp(k, v):
    src = os.path.join(a.corpus, "lfi", F[k][0] + ".lfi")
    return render(a.bin, src, os.path.join(a.out, f"sky_{k}_lum{v:+d}.png"), [f"{key(a.band,'lum')}={v}"] if v else [], 1600)

def noise(L, sl):
    hp = L - box(L, 3); return hp[sl].std() / np.median(L[sl])

out = {}
for k, (f, (x0, x1, y0, y1)) in F.items():
    p0 = rp(k, 0); lin0 = png_lin(p0); Y0 = lin_Y(lin0); H, W = Y0.shape
    sl = (slice(int(y0 * H) + 2, int(y1 * H)), slice(int(x0 * W) + 2, int(x1 * W) - 2))
    L0 = to_lab(lin0, "srgb")[..., 0]; c0 = png_codes(p0)[sl]
    ev, rel, crush = {}, {}, {}
    for v in VALS:
        p = rp(k, v); lin = png_lin(p); Y = lin_Y(lin)
        ev[v] = float(np.log2(np.median(Y[sl]) / np.median(Y0[sl])))
        rel[v] = float(noise(to_lab(lin, "srgb")[..., 0], sl) / noise(L0, sl))
        c = png_codes(p)[sl]
        crush[v] = float((((c == 0).any(-1)) & ~((c0 == 0).any(-1))).mean() * 100)
    out[k] = (ev, rel, crush)
    print(f"{k}: EV " + " ".join(f"{v:+d}:{ev[v]:+.2f}" for v in VALS))
    print(f"      noise rel x  -100:{rel[-100]:.2f} +100:{rel[100]:.2f}   newly crushed % -100:{crush[-100]:.2f}")

# fringe on 1840
p0 = rp("1840", 0); pm = rp("1840", -100)
Lb = to_lab(png_lin(p0), "srgb")[..., 0]; Yb = lin_Y(png_lin(p0)); Ym = lin_Y(png_lin(pm))
thr = (np.median(Lb[5:60]) + np.median(Lb[400:500])) / 2
fr = []
for x in range(Lb.shape[1]):
    below = np.where(Lb[60:, x] < thr)[0]
    if not below.size: continue
    ye = 60 + below[0]
    if ye < 90 or ye > 380: continue
    def bump(Y):
        return np.percentile(Y[ye - 8:ye + 9, x], 95) / np.median(Y[ye - 24:ye - 11, x])
    fr.append(max(0.0, bump(Ym) - bump(Yb)))
fringe = float(np.mean(fr))
print(f"1840 fringe (Blue lum -100) {fringe:.4f} over {len(fr)} columns")

checks = []
for k, (ev, rel, crush) in out.items():
    checks.append((f"L1 {k} -100 darkens 1.0..1.6 EV", 1.0 <= -ev[-100] <= 1.6, ev[-100]))
    checks.append((f"L2 {k} +100 brightens 0.7..1.2 EV", 0.7 <= ev[100] <= 1.2, ev[100]))
    checks.append((f"L3 {k} newly crushed < 0.5% at -100", crush[-100] < 0.5, crush[-100]))
    checks.append((f"L4 {k} rel noise <= 1.3x at -100 and +100", max(rel[-100], rel[100]) <= 1.3, max(rel[-100], rel[100])))
    e = [ev[v] for v in VALS]
    checks.append((f"L6 {k} EV strictly increasing in slider (step 20)", all(np.diff(e) > 0), float(np.min(np.diff(e)))))
    s = ev[100] / -ev[-100]
    checks.append((f"L7 {k} |EV+100|/|EV-100| in 0.7..1.3", 0.7 <= s <= 1.3, s))
for n, ok, v in checks:
    print(f"{verdict(ok)}  {n}: {v:.3f}")
print(f"(L5) fringe = {fringe:.4f}; spec threshold = baseline/3")
