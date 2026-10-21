"""Per-pixel monotone response of all 24 sliders, -100..100 step 10, on the hue ramp that
hue_ramp.py writes (pass its ramp.lfi). Axis: hue for hue sliders (unwrapped), C for sat,
L for lum; display OKLab; dithered 8x8 block means. A pixel is non-monotone if any step
goes against its overall direction by more than 0.003 (L, C) or, for hue, 1.5 deg on the
C 0.03 rows and 0.75 deg elsewhere (the dithered-mean noise floor). Pixels whose
total move is < 0.01 (L, C) or 1 deg are ignored; clipped blocks are masked.

usage: monotone.py --bin lumen-render --ramp DIR/ramp.lfi --out DIR
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib import *
ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True); ap.add_argument("--ramp", required=True); ap.add_argument("--out", required=True)
a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
BH = 8; VALS = list(range(-100, 101, 10))
def blocks(p):
    c = png_codes(p); lin = srgb_dec(c / 255.0); n = c.shape[0] // BH
    lab = to_lab(np.stack([lin[r * BH:(r + 1) * BH].mean(0) for r in range(n)]), "srgb")
    clip = np.stack([((c[r * BH:(r + 1) * BH] == 0) | (c[r * BH:(r + 1) * BH] == 255)).any(-1).any(0) for r in range(n)])
    return lab, clip
tot_bad = 0
for b in range(8):
    for comp, ax in (("hue", 2), ("sat", 1), ("lum", 0)):
        q, cl = [], None
        for v in VALS:
            lab, clip = blocks(render(a.bin, a.ramp, os.path.join(a.out, f"m_b{b}_{comp}{v:+d}.png"), [f"{key(b,comp)}={v}"] if v else [], 0, dither=True))
            q.append(np.stack(lch(lab), 0)[ax]); cl = clip if cl is None else cl | clip
        q = np.array(q)
        if ax == 2:
            q = q[0] + hd(q[0], q)
        tot = q[-1] - q[0]; d = np.diff(q, axis=0)
        act = (np.abs(tot) > (1.0 if ax == 2 else 0.01)) & ~cl
        tolh = np.where(np.arange(q.shape[1]) % 4 == 0, 1.5, 0.75)[:, None]   # row order: C 0.03 first in each L
        tol = tolh if ax == 2 else 0.003
        bad = ((d * np.sign(tot)) < -tol).any(0) & act
        tot_bad += int(bad.sum())
        print(f"{BANDS[b]:8s} {comp}: active {int(act.sum()):5d}  non-monotone {int(bad.sum())}")
print(f"{verdict(tot_bad == 0)}  X6 non-monotone pixels over 24 sliders: {tot_bad}")
