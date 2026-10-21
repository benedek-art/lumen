"""Local-contrast gain versus tone on ramp_tex / ramp_tex0 (2400x800 log ramp -8..+4 EV along x with
0.10 EV 1/f texture).

usage: python3 ramp_gain.py DIR PREFIX [--vs PREFIX2] [name ...]   e.g. ramp_gain.py OUT/ramp r c100 c-100 t100 t-100
       --vs PREFIX2: also compute the same curve on DIR/PREFIX2_* (ramp_tex0 renders, one black pixel)
                     and print vs_maxdiff = max |gain difference| over [-6, +3.5] EV

gain = regression of high-passed log2 Y(out) onto high-passed log2 Y(identity) (high-pass: minus a
25 px box mean) in 100-px column windows (each window = 0.5 EV of scene tone). Prints the curve and:
  mid_min / mid_max  min / max gain over windows with scene EV in [-3, +2] (the midtones)
  mid_ratio          max/min of the midtone gains (positive values) or min/max (negative), >= 1
  all_min / all_max  over windows with scene EV in [-6, +3.5]
  max_jump           max |gain difference| between adjacent windows in [-6, +3.5] (comb / node check)
"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, logY, encY, box

d, p = sys.argv[1], sys.argv[2]
args = sys.argv[3:]
p2 = None
if args[:1] == ["--vs"]:
    p2, args = args[1], args[2:]
ref = logY(load(f"{d}/{p}_id.png")); h, w = ref.shape
hp = lambda a: (a - box(a, 12))[20:-20]
R = hp(ref)
xs = list(range(0, w, 100))
ev = np.array([-8 + 12 * (x + 50) / w for x in xs])
print("  scene EV " + " ".join(f"{v:5.1f}" for v in ev))
idc = encY(load(f"{d}/{p}_id.png"))[h // 2]
print("  id code  " + " ".join(f"{idc[x+50]:5.0f}" for x in xs))
mid = (ev >= -3) & (ev <= 2); allr = (ev >= -6) & (ev <= 3.5)
def curve(prefix, n):
    Rr = hp(logY(load(f"{d}/{prefix}_id.png")))
    O = hp(logY(load(f"{d}/{prefix}_{n}.png")))
    g = []
    for x in xs:
        r, o = Rr[:, x:x + 100].ravel(), O[:, x:x + 100].ravel()
        g.append((o * r).sum() / max((r * r).sum(), 1e-12))
    return np.array(g)


for n in args:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    g = curve(p, n)
    gm, ga = g[mid], g[allr]
    ratio = gm.max() / max(gm.min(), 1e-6)
    jump = np.abs(np.diff(ga)).max()
    print(f"  {n:>7}  " + " ".join(f"{v:5.2f}" for v in g))
    print(f"  {n:>7}  mid_min {gm.min():.3f} mid_max {gm.max():.3f} mid_ratio {ratio:.2f} | "
          f"all_min {ga.min():.3f} all_max {ga.max():.3f} | max_jump {jump:.3f}")
    if p2 and os.path.exists(f"{d}/{p2}_{n}.png"):
        g2 = curve(p2, n)
        print(f"  {n:>7}  {p2}: " + " ".join(f"{v:5.2f}" for v in g2))
        print(f"  {n:>7}  vs_maxdiff {np.abs(g2 - g)[allr].max():.3f}")
