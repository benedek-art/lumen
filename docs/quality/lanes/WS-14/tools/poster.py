"""Histogram-gap probe on ramp_lo (2400x600 log ramp -7..+3.5 EV with 0.03 EV 1/f texture): a
control must not open new gaps (unused 8-bit codes) in the histogram of a smooth, lightly textured
ramp. (Plateaus with hard outlines on soft gradients are measured by blobs.py.)

usage: python3 poster.py DIR PREFIX [name ...]          e.g. poster.py OUT/ramp rl c100 c50 t100

Per render, over the tone range scene EV -5..+2.5 split into 15 windows of 160 px:
  kurt      (information only) kurtosis of the high-passed log2 Y per window
  gaps      empty 8-bit encoded-luma codes between the 0.5th and 99.5th percentiles of each 
            window's encoded luma, summed over windows, render minus identity (new histogram gaps)
"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, logY, encY, box

d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ["c100", "c50", "c-100", "t100", "t-100"]
W = 2400
x0 = int((-5 + 7) / 10.5 * W); x1 = int((2.5 + 7) / 10.5 * W)
wins = [(a, a + 160) for a in range(x0, x1 - 159, 160)]


def kurt(a):
    a = a - a.mean(); v = (a * a).mean()
    return float((a ** 4).mean() / max(v * v, 1e-20))


def stats(img):
    lg = logY(img); hp = (lg - box(lg, 4))[10:-10]
    code = np.rint(np.asarray(img).mean(-1))[10:-10]   # neutral frame: R=G=B
    ks, gaps = [], 0
    for a, b in wins:
        ks.append(kurt(hp[:, a:b]))
        c = code[:, a:b].ravel()
        lo, hi = np.percentile(c, 0.5), np.percentile(c, 99.5)
        used = np.unique(c[(c >= lo) & (c <= hi)])
        gaps += int((hi - lo + 1) - len(used))
    return np.array(ks), gaps


k0, g0 = stats(load(f"{d}/{p}_id.png"))
print(f"  {'id':>6}: kurt mean {k0.mean():.2f} (min {k0.min():.2f})  gaps {g0}")
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    k, g = stats(load(fn))
    print(f"  {n:>6}: kurt mean {k.mean():.2f} (min {k.min():.2f})  worst kurt ratio {np.min(k / k0):.2f}  "
          f"new gaps {g - g0:+d}")
