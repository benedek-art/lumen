"""Skin probe (skin_6000): what +-Texture and +-Clarity do to pores, mottling, lashes and the lip edge.

usage: python3 skin.py DIR PREFIX [name ...]        e.g. skin.py OUT/skin k6000 t-100 t-50 c-100 t100 c100
Works at any render size of skin_6000 (coordinates scale with the long edge).
  pores    std of the fine band (log2 Y minus a 3x box mean of radius 2*s px, s = L/6000... min 1)
           in the pore-only region, ratio to identity      (Texture's band: 2-8 px features at 24 MP)
  mottle   std of the mid band (box r=8s minus 3x box r=60s) in the pore-only region, ratio to identity
           (40-200 px mottling: Clarity's band)
  lash     mean lash depth (log2 Y, row-averaged profile across the 25 vertical lashes), ratio to
           identity, and the mean half-depth width growth (px)
  lip      10-90 % rise (px) of the 1 EV lip edge, identity -> render, and over/under % of the step
"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, logY, encY, box, lowpass, SKIN

d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ["t-100", "t-50", "t50", "t100", "c-100", "c-50", "c50", "c100"]
id_img = load(f"{d}/{p}_id.png"); h, w = id_img.shape[:2]; s = w / SKIN["W"]
x0, y0, x1, y1 = [int(v * s) for v in SKIN["pore_region"]]


def bands(lg):
    rf = max(int(round(2 * s)), 1)
    fine = lg - lowpass(lg, rf)
    mid = box(lg, max(int(8 * s), 1)) - lowpass(lg, max(int(60 * s), 2))
    return fine[y0:y1, x0:x1].std(), mid[y0:y1, x0:x1].std()


def lash(lg):
    ly0, ly1 = int(SKIN["lash_y"][0] * s), int(SKIN["lash_y"][1] * s)
    prof = lg[ly0 + (ly1 - ly0) // 5: ly1 - (ly1 - ly0) // 5].mean(0)
    deps, wids = [], []
    for i in range(1, SKIN["lash_n"] - 1):
        c = (SKIN["lash_x0"] + i * SKIN["lash_pitch"] + SKIN["lash_w"] / 2) * s
        half = SKIN["lash_pitch"] * s / 2
        bg = 0.5 * (prof[int(round(c - half))] + prof[int(round(c + half))])
        seg = prof[int(round(c - half)) + 1:int(round(c + half))]
        dep = bg - seg.min()
        deps.append(dep); wids.append(int((seg < bg - dep / 2).sum()))
    return float(np.mean(deps)), float(np.mean(wids))


def lip(img):
    e = encY(img)
    xa, xb = int(SKIN["lip_x"][0] * s) + int(100 * s), w - int(100 * s)
    ly = int(SKIN["lip_y"] * s); r = int(60 * s)
    prof = e[ly - r:ly + r, xa:xb].mean(1)
    return prof


def rise(prof):
    hi, lo = prof[:len(prof) // 6].mean(), prof[-len(prof) // 6:].mean()
    t = (hi - prof) / (hi - lo)
    return int(np.argmax(t > 0.9) - np.argmax(t > 0.1)), hi - lo


lg0 = logY(id_img)
f0, m0 = bands(lg0); d0, w0 = lash(lg0); p0 = lip(id_img); r0, st0 = rise(p0)
print(f"  {'id':>6}: fine {f0:.4f}  mid {m0:.4f}  lash depth {d0:.3f} EV width {w0:.1f} px  lip rise {r0} px")
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    im = load(fn); lg = logY(im)
    f, m = bands(lg); dd, ww = lash(lg); pp = lip(im); rr, _ = rise(pp)
    dl = pp - p0; k = len(pp) // 2
    over = max(dl[:k].max(), 0) / st0 * 100; under = max(-dl[k:].min(), 0) / st0 * 100
    print(f"  {n:>6}: pores x{f/f0:.2f}  mottle x{m/m0:.2f}  lash depth x{dd/d0:.2f} width {ww-w0:+.1f} px  "
          f"lip rise {r0}->{rr} px over {over:.1f}% under {under:.1f}%")
