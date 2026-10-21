"""SPEC 4 (tint direction). A uniform 0.18 grey at as-shot A, Temp = A's Kelvin, Tint = t. The rendered
display OKLab hue/chroma is compared with the Adobe-convention prediction: the pixel
wbmodel.adobe_matrix(A, (A.K, t)) @ grey, rendered with no WB set (same downstream pipeline).
Tints past the new magenta guard are skipped for the comparison (the guard is SPEC 8's business).
  python3 docs/quality/lanes/WS-03/tools/tint_axis.py"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from wbmodel import adobe_matrix, hue_deg
from lr import lfi_const, render, png_mean_linear, oklab_srgb

CASES = [((6503.7072, 9.77), [-150, -75, -25, 25, 75, 150]), ((5500, 10), [-150, -75, -25, 25, 75, 150]),
         ((3200, 0), [-150, -75, -25, 25, 50]), ((2850, 0), [-150, -75, -25, 25])]
if __name__ == '__main__':
    g = lfi_const([0.18] * 3, name='g.lfi'); worst_h = 0; worst_c = 0
    print(f"{'as-shot':>14s} {'tint':>5s} {'Lumen hue':>9s} {'Adobe hue':>9s} {'dHue':>6s} {'C ratio':>7s}")
    for a, ts in CASES:
        for t in ts:
            lab = oklab_srgb(png_mean_linear(render(g, a, a[0], t)))
            ref = lfi_const(adobe_matrix(a, (a[0], t)) @ np.full(3, 0.18), name='ref.lfi')
            rl = oklab_srgb(png_mean_linear(render(ref, a)))
            dh = (hue_deg(lab) - hue_deg(rl) + 180) % 360 - 180; cr = np.hypot(*lab[1:]) / np.hypot(*rl[1:])
            worst_h = max(worst_h, abs(dh)); worst_c = max(worst_c, abs(cr - 1))
            print(f'{a[0]:8.0f}/{a[1]:+5.1f} {t:+5d} {hue_deg(lab):9.1f} {hue_deg(rl):9.1f} {dh:+6.1f} {cr:7.3f}')
    ok = worst_h <= 3 and worst_c <= 0.10
    print(f'max |dHue| {worst_h:.1f} deg, max |C ratio - 1| {worst_c:.3f} ->', 'PASS' if ok else 'FAIL', '(threshold 3 deg, 0.10)')
