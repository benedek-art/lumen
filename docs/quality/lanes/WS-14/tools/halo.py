"""Halos and edge width on the steps_6000 probe (five strips, vertical step at x = W/2 of
0.5/1/2/3/6 EV centred on 0.18, dark left / bright right).

usage: python3 halo.py DIR PREFIX [name ...]       e.g. halo.py OUT/steps s6000 t100 c100 t-100 c-100

For each render and strip, on the column mean (middle half of the strip's rows) of encoded luma:
  over%   max brightening on the bright side, % of the identity step height (codes)
  under%  max darkening on the dark side, % of the step height (reported positive)
  width   farthest distance from the edge where |out - id| > 1 code, px and % of long edge
  rise    10-90 % rise distance (px) of the output vs the identity
  far     mean |out - id| (codes) farther than 5 % L from the edge (flat-field brightness)
Last line per render: WORST over/under across strips, and the strips' max rise growth.
"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, encY, STEPS_EV

d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ["t-100", "t50", "t100", "c-100", "c50", "c100"]
ref = encY(load(f"{d}/{p}_id.png")); h, w = ref.shape; L = max(h, w); e = w // 2
sh = h / len(STEPS_EV)


def profs(img):
    return [img[int((i + .25) * sh):int((i + .75) * sh)].mean(0) for i in range(len(STEPS_EV))]


def rise(r):
    seg = r[e - 200:e + 200]; lo, hi = seg[:40].mean(), seg[-40:].mean()
    t = (seg - lo) / (hi - lo)
    return int(np.argmax(t > 0.9) - np.argmax(t > 0.1))


P0 = profs(ref)
print(f"{p}: L={L}")
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    P = profs(encY(load(fn)))
    wo, wu, wr, ww = 0.0, 0.0, 0, 0.0
    for s, r, q in zip(STEPS_EV, P0, P):
        dl = q - r
        step = r[e + 40:e + 80].mean() - r[e - 80:e - 40].mean()
        over = max(dl[e:].max(), 0) / step * 100
        under = max(-dl[:e].min(), 0) / step * 100
        far = np.where(np.abs(dl) > 1.0)[0]
        wid = int(np.abs(far - e).max()) if len(far) else 0
        ff = int(0.05 * L)
        farm = np.abs(np.r_[dl[:max(e - ff, 1)], dl[e + ff:]]).mean()
        r0, r1 = rise(r), rise(q)
        wo, wu, wr, ww = max(wo, over), max(wu, under), max(wr, r1 - r0), max(ww, 100 * wid / L)
        print(f"  {n:>6} {s:>3}EV step {step:6.1f} codes | over {over:5.1f}% under {under:5.1f}% | "
              f"width {wid:4d} px ({100*wid/L:.2f}% L) | rise {r0}->{r1} px | far {farm:.2f}")
    print(f"  {n:>6} WORST over {wo:.1f}%  under {wu:.1f}%  width {ww:.2f}% L  rise growth {wr:+d} px")
