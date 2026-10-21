"""Corner / junction marks versus straight-edge marks (amendment H8).

usage: python3 corners.py DIR PREFIX [name ...]     e.g. corners.py OUT/synth colorchecker c100 c-100

Generic, geometry-free, measured on the IDENTITY render (encoded luma E, codes):
  edge pixels    |grad E| >= 6 codes/px (central differences of E after a 3x3 box)
  corner pixels  edge pixels whose 2-D structure tensor (box radius 2) has lambda2 >= 0.2 * lambda1,
                 i.e. gradients in two directions: convex corners, T/X junctions, line ends
  corner zone    pixels within rc = max(3, 0.5 % L) px of a corner pixel
  straight zone  pixels within rc of an edge pixel and farther than 3*rc from every corner pixel
Reports per render: max |out - id| (codes) in each zone, the 99.5th percentiles, the ratio of the
maxima corner/straight, and the share of corner-zone pixels changed by > 8 codes."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, encY, box


def dilate(m, r):
    """square dilation of a boolean mask by radius r (separable running max via cumsum)"""
    f = m.astype(np.float64)
    return box(f, r) > 1e-9


d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ["c100", "c-100", "t100", "t-100"]
E = encY(load(f"{d}/{p}_id.png")); h, w = E.shape; L = max(h, w)
Es = box(E, 1)
gy, gx = np.gradient(Es)
g = np.hypot(gx, gy)
edge = g >= 6
jxx, jyy, jxy = box(gx * gx, 2), box(gy * gy, 2), box(gx * gy, 2)
tr = jxx + jyy; det = jxx * jyy - jxy * jxy
disc = np.sqrt(np.maximum(tr * tr / 4 - det, 0))
l1, l2 = tr / 2 + disc, tr / 2 - disc
corner = edge & (l2 >= 0.2 * np.maximum(l1, 1e-9))
rc = max(3, int(round(0.005 * L)))
czone = dilate(corner, rc)
szone = dilate(edge, rc) & ~dilate(corner, 3 * rc)
b = 4  # frame border
inner = np.zeros_like(edge); inner[b:-b, b:-b] = True
czone &= inner; szone &= inner
print(f"  {p}: L={L} rc={rc}px  corner px {corner.sum()}  corner-zone {czone.mean()*100:.2f}%  straight-zone {szone.mean()*100:.2f}%")
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    dl = np.abs(encY(load(fn)) - E)
    cm = dl[czone].max() if czone.any() else 0.0
    sm = dl[szone].max() if szone.any() else 0.0
    cp = np.percentile(dl[czone], 99.5) if czone.any() else 0.0
    sp = np.percentile(dl[szone], 99.5) if szone.any() else 0.0
    print(f"  {n:>6}: corner max {cm:5.1f} (p99.5 {cp:4.1f})  straight max {sm:5.1f} (p99.5 {sp:4.1f})  "
          f"ratio {cm/max(sm,1.0):.2f}  corner>8 {100*(dl[czone]>8).mean():.2f}%")
