#!/usr/bin/env python3
"""Synthetic colorchecker (corpus/synthetic/colorchecker, 6x4 grid): per patch OKLab hue
shift, chroma ratio, and centre-vs-rim luminance split (halo/blotch inside a flat patch).
Usage: patch_check.py BASE.png OUT.png"""
import sys, os, math, numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dehaze_metrics import load, srgb_to_linear, oklab
b = srgb_to_linear(load(sys.argv[1])); o = srgb_to_linear(load(sys.argv[2])); H, W = b.shape[:2]
worst_h = worst_split = 0; rows = []
for j in range(4):
    for i in range(6):
        cx, cy = (0.095 + 0.164 * i) * W, (0.168 + 0.243 * j) * H
        hw, hh = 0.062 * W, 0.092 * H
        def reg(img, f0, f1):
            ys, xs = np.mgrid[0:H, 0:W]
            dx, dy = np.abs(xs - cx) / hw, np.abs(ys - cy) / hh; m = np.maximum(dx, dy)
            return img[(m >= f0) & (m < f1)]
        c0, c1 = oklab(reg(b, 0, 0.4)).mean(0), oklab(reg(o, 0, 0.4)).mean(0)
        r1 = oklab(reg(o, 0.75, 0.95)).mean(0); r0 = oklab(reg(b, 0.75, 0.95)).mean(0)
        C0, C1 = math.hypot(c0[1], c0[2]), math.hypot(c1[1], c1[2])
        dh = ((math.degrees(math.atan2(c1[2], c1[1]) - math.atan2(c0[2], c0[1]))) + 180) % 360 - 180 if C0 > 0.02 else float('nan')
        split = (r1[0] - c1[0]) - (r0[0] - c0[0])  # rim minus centre, OKLab L, relative to base
        rows.append((j * 6 + i + 1, c0[0], c1[0], C0, C1, dh, split))
        if not math.isnan(dh): worst_h = max(worst_h, abs(dh))
        worst_split = max(worst_split, abs(split))
print('patch  L0     L1    C0     C1    dHue   rim-centre dL')
for r in rows: print('%4d  %.3f  %.3f  %.3f  %.3f  %+6.1f  %+.3f' % r)
print('worst |dHue| (C>0.02): %.1f deg; worst rim-centre split: %.3f OKLab L' % (worst_h, worst_split))
