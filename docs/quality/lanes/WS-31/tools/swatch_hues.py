"""OKLCh hue of the 8 band swatches sampled from a UI snapshot PNG (treated as sRGB).

usage: swatch_hues.py --png panel-grade-colour-band.png --points "x,y;x,y;..." (8 points,
       wire order red..magenta, pixel coords in the PNG) --centres c0,...,c7 [--tol 5]
Each sample is the mean of a 7x7 block. Prints hue, chroma and offset from the centre.
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib import *
ap = argparse.ArgumentParser()
ap.add_argument("--png", required=True); ap.add_argument("--points", required=True)
ap.add_argument("--centres", required=True); ap.add_argument("--tol", type=float, default=5)
a = ap.parse_args()
lin = png_lin(a.png); cent = [float(v) for v in a.centres.split(",")]
pts = [tuple(int(v) for v in p.split(",")) for p in a.points.split(";")]
assert len(pts) == 8 and len(cent) == 8
worst = 0
for b, (x, y) in enumerate(pts):
    m = lin[y - 3:y + 4, x - 3:x + 4].reshape(-1, 3).mean(0)
    L, C, h = lch(to_lab(m, "srgb")); off = float(hd(cent[b], h)); worst = max(worst, abs(off))
    print(f"{BANDS[b]:8s} L {float(L):.3f} C {float(C):.3f} h {float(h):6.1f}  centre {cent[b]:6.1f}  off {off:+.1f}")
print(f"{verdict(worst <= a.tol)}  U swatch hue within {a.tol} deg of band centre: worst {worst:.1f}")
