#!/usr/bin/env python3
"""8-bit banding of the vignette ramp on flat_grey (1024x1024, 0.18), full resolution.

Undithered render: along the centre row (centre -> right edge) and the diagonal
(centre -> bottom-right corner), green channel:
  distinct   number of distinct codes      maxstep  largest |adjacent step| (codes)
  reversal   largest step against the ramp's direction (codes; must be 0)
  flat       longest run of one code inside the ramp (px; from first moved pixel to edge)
Dithered render (the export path): 17-row band mean around the centre row, 8-px moving
average; reports the largest step and largest reversal of that local mean (codes).

  banding.py --set look.vignette=-4 [--set ...] [--frame flat_grey]
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib


def ramp_stats(p):
    p = np.asarray(p, float)
    moved = np.nonzero(p != p[0])[0]
    if moved.size == 0:
        return dict(distinct=1, maxstep=0, reversal=0, flat=0)
    q = p[max(moved[0] - 1, 0):]
    d = np.diff(q)
    sgn = np.sign(q[-1] - q[0]) or 1
    best = cur = 1
    for k in d:
        cur = cur + 1 if k == 0 else 1
        best = max(best, cur)
    return dict(distinct=len(set(q)), maxstep=int(np.abs(d).max()),
                reversal=int(max(0, (-sgn * d).max())), flat=best)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--set', action='append', default=[])
    ap.add_argument('--frame', default='flat_grey')
    a = ap.parse_args()
    lfi = lib.frame(a.frame)
    img, _ = lib.render(lfi, a.set, long_edge=1024)
    g = img[..., 1].astype(float)
    H, W = g.shape
    n = min(H, W) // 2
    row = g[H // 2, W // 2:]
    diag = np.array([g[H // 2 + int(i * (H / 2) / n), W // 2 + int(i * (W / 2) / n)] for i in range(n)])
    worst = 0
    for name, p in (('row', row), ('diag', diag)):
        s = ramp_stats(p)
        worst = max(worst, s['maxstep'])
        print('%-5s distinct %3d  maxstep %d  reversal %d  flat %3d px' % (
            name, s['distinct'], s['maxstep'], s['reversal'], s['flat']))
    dimg, _ = lib.render(lfi, a.set, long_edge=1024, dither=True)
    band = dimg[H // 2 - 8:H // 2 + 9, W // 2:, 1].astype(float).mean(0)
    m = np.convolve(band, np.ones(8) / 8, mode='valid')
    d = np.diff(m)
    sgn = np.sign(m[-1] - m[0]) or 1
    print('dith  local-mean maxstep %.2f  reversal %.2f' % (np.abs(d).max(), max(0, (-sgn * d).max())))
    print('MAXSTEP', worst)


if __name__ == '__main__':
    main()
