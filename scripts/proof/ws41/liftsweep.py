#!/usr/bin/env python3
"""SPEC Amendment A2 line 31: Color Priority's lift on bright saturated colour, in float.

For saturated patches (red, green, blue, skin; scene OKLab C >= 0.10) scaled to scene
luminance Y 0.5, 1, 2, 4 and placed in the four corners of a flat 0.18 frame, sweeps
CP Amount 0 -> +2 in steps of 0.125 through the float probe (huefloat.py's) and reports
per patch:
  rev     worst decrease of display OKLab L between adjacent Amounts (<= 0.002)
  hstep   largest hue change between adjacent Amounts, deg (<= 1.5)
  excess  max over Amounts of |dh_CP| - |dh_HP'|, HP' = HP at the Amount whose corner L
          is nearest (HP swept 0..+3 in 0.0625), deg (<= 1.0)

  liftsweep.py [--style colorPriority]
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib
import huefloat as hf

COLOURS = {'red': (0.40, 0.06, 0.04), 'green': (0.08, 0.25, 0.06),
           'blue': (0.10, 0.20, 0.45), 'skin': (0.45, 0.20, 0.10)}
BOX = {'red': (0, 0, .05, .05), 'green': (.95, 0, 1, .05),
       'blue': (0, .95, .05, 1), 'skin': (.95, .95, 1, 1)}
LUMA = np.array([0.2627, 0.6780, 0.0593])


def frame(y):
    p = os.path.join(hf.T, 'lift_%g.lfi' % y)
    if not os.path.exists(p):
        W, H = 768, 512
        a = np.full((H, W, 3), 0.18, np.float32)
        for name, c in COLOURS.items():
            c = np.array(c) * y / (np.array(c) @ LUMA)
            x0, y0, x1, y1 = BOX[name]
            a[int(y0 * H):int(y1 * H), int(x0 * W):int(x1 * W)] = c
        lib.write_lfi(p, a)
    return p


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--style', default='colorPriority')
    a = ap.parse_args()
    hf.build()
    fails = 0
    cp_amounts = np.arange(0, 2.0001, 0.125)
    hp_amounts = np.arange(0, 3.0001, 0.0625)
    for y in (0.5, 1, 2, 4):
        p = frame(y)
        base = hf.probe(p, {'vignette': 0})
        cps = [hf.probe(p, {'vignette': float(v), 'vignetteStyle': a.style}) for v in cp_amounts]
        hps = [hf.probe(p, {'vignette': float(v)}) for v in hp_amounts]
        for name, box in BOX.items():
            c = [hf.compare(base, im, box, 'display') for im in cps]
            h = [hf.compare(base, im, box, 'display') for im in hps]
            L = np.array([x['L'] for x in c]); dh = np.array([x['dh'] for x in c])
            hL = np.array([x['L'] for x in h]); hdh = np.array([x['dh'] for x in h])
            rev = float(max(0, -np.diff(L).min()))
            hstep = float(np.abs(np.diff(dh)).max())
            excess = max(abs(dh[i]) - abs(hdh[np.argmin(np.abs(hL - L[i]))]) for i in range(len(L)))
            ok = rev <= 0.002 and hstep <= 1.5 and excess <= 1.0
            fails += not ok
            print('Y %-3g %-5s L %.3f->%.3f rev %.4f  hstep %.2f  dh(+2) %+6.2f  excess %+.2f  %s' % (
                y, name, L[0], L[-1], rev, hstep, dh[-1], excess, 'ok' if ok else 'FAIL'))
    print('FAILS', fails)


if __name__ == '__main__':
    main()
