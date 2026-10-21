"""Noise amplification on noise_6000 (flat 0.18 with 4 % per-pixel Gaussian luminance noise).

usage: python3 noise.py DIR PREFIX [name ...]          e.g. noise.py OUT/noise n6000 t100 t-100 c100
prints per render: std of encoded luma (codes) over the frame (2 % border trimmed) and its ratio to
the identity's, and the same for the pixel-level component (minus a 3x3 box mean)."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, encY, box

d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ["t100", "t-100", "c100", "c-100"]


def st(fn):
    e = encY(load(fn)); h, w = e.shape; b = int(0.02 * max(h, w))
    e = e[b:h - b, b:w - b] if h > 2 * b else e[:, b:w - b]
    return e.std(), (e - box(e, 1)).std()


s0, f0 = st(f"{d}/{p}_id.png")
print(f"  {'id':>6}: std {s0:.3f} codes  pixel-level {f0:.3f}")
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if os.path.exists(fn):
        s, f = st(fn)
        print(f"  {n:>6}: std {s:.3f} (x{s/s0:.2f})  pixel-level {f:.3f} (x{f/f0:.2f})")
