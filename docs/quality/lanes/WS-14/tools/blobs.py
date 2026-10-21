"""Posterisation / false contours and halos on soft gradients: blobs_6000 (eight Gaussian blobs,
sigma 0.25-2 % of the long edge, +-1 EV, on 0.18). Works at any render size of blobs_6000.

usage: python3 blobs.py DIR PREFIX [name ...]        e.g. blobs.py OUT/blobs b6000 c100 c50 t100 c-100

Per blob, the azimuthal-mean radial profile of log2 Y out to 4 sigma, identity vs render:
  slope    max |d profile / dr| render / identity. A local-contrast gain G raises it to about G;
           a remap that turns the soft transition into a plateau with a hard outline (posterisation,
           the 983 lantern-glass / bokeh defect) raises it far more.
  contrast (profile(0) - profile(4 sigma)) render / identity
  ring     largest reversal of the profile's monotonic direction (a bright or dark ring = halo),
           % of the identity blob amplitude
Last line: worst slope ratio, worst ring, min/max contrast over the eight blobs.
"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, logY, BLOBS

d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ["c100", "c50", "c-100", "t100", "t-100"]
ref = logY(load(f"{d}/{p}_id.png")); h, w = ref.shape; s = w / 6000.0


def profiles(lg):
    out = []
    for k, (sig, amp) in enumerate(BLOBS):
        cx, cy, sg = (375 + 750 * k) * s, 500 * s, sig * s
        R = int(min(4 * sg, 370 * s)) + 1
        y0, y1 = int(cy - R), int(cy + R) + 1; x0, x1 = int(cx - R), int(cx + R) + 1
        yy, xx = np.mgrid[y0:y1, x0:x1]
        r = np.hypot(xx + 0.5 - cx - 0.5, yy + 0.5 - cy - 0.5)
        sub = lg[max(y0, 0):y1, x0:x1]; r = r[max(y0, 0) - y0:, :]
        step = max(0.5, sg / 12)
        nb = int(R / step)
        idx = np.minimum((r / step).astype(int), nb)
        prof = np.bincount(idx.ravel(), sub.ravel(), nb + 1) / np.maximum(np.bincount(idx.ravel(), None, nb + 1), 1)
        out.append((prof[:nb], step, amp))
    return out


P0 = profiles(ref)
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    P = profiles(logY(load(fn)))
    ws, wr, cs = 0.0, 0.0, []
    line = []
    for (a, st, amp), (b, _, _), (sig, _) in zip(P0, P, BLOBS):
        sa = np.abs(np.diff(a)).max(); sb = np.abs(np.diff(b)).max()
        c0 = a[0] - a[-1]; c1 = b[0] - b[-1]
        sgn = np.sign(c0)
        # monotonic direction from centre outwards: values should fall (bright blob) or rise (dark blob)
        q = sgn * b
        rev = max(0.0, max(np.max(q[i:]) - q[i] for i in range(len(q) - 1)) if False else 0.0)
        run_min = np.minimum.accumulate(q)
        rev = float(np.max(q - run_min))
        ring = 100 * rev / abs(c0)
        ws, wr = max(ws, sb / sa), max(wr, ring); cs.append(c1 / c0)
        line.append(f"s{sig}{'+' if amp > 0 else '-'}: slope x{sb/sa:.2f} contrast x{c1/c0:.2f} ring {ring:.1f}%")
    print(f"  {n:>6}: " + " | ".join(line))
    print(f"  {n:>6}: WORST slope x{ws:.2f}  ring {wr:.1f}%  contrast {min(cs):.2f}..{max(cs):.2f}")
