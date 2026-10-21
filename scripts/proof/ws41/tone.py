#!/usr/bin/env python3
"""Tone monotonicity of the vignette at fixed pixel positions (spec: no tone inversion).

Renders 3:2 flat neutral frames (192x128) at 28 scene-linear levels Y = 0.005 ... 8
(log-spaced) with the given settings, undithered, and checks that the output code at the
corner, the side-edge middle and the diagonal at r = 0.85 never DEcreases as Y rises.
Prints the worst reversal (codes, 8-bit green) and the per-level table with --table.

  tone.py --set look.vignette=-4 --set look.vignetteHighlights=100 [--table]
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib

LEVELS = np.geomspace(0.005, 8.0, 28)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--set', action='append', default=[])
    ap.add_argument('--table', action='store_true')
    a = ap.parse_args()
    W, H = 192, 128
    pos = {'corner': (0, 0), 'side_mid': (H // 2, 0),
           'r0.85': (int(H / 2 - 0.85 * H / 2), int(W / 2 - 0.85 * W / 2))}
    out = {k: [] for k in pos}
    base = []
    for y in LEVELS:
        p = os.path.join(lib.FRAMES, 'tone_%.5f.lfi' % y)
        if not os.path.exists(p):
            os.makedirs(lib.FRAMES, exist_ok=True)
            lib.write_lfi(p, np.full((H, W, 3), y))
        img, _ = lib.render(p, a.set, long_edge=W)
        base.append(int(img[H // 2, W // 2, 1]))
        for k, (r, c) in pos.items():
            out[k].append(int(img[r, c, 1]))
    worst = 0
    for k, v in out.items():
        d = np.diff(v)
        rev = int(max(0, -d.min()))
        worst = max(worst, rev)
        print('%-8s worst reversal %d codes   codes: %s' % (k, rev, ' '.join(map(str, v))))
    print('centre   codes: %s' % ' '.join(map(str, base)))
    if a.table:
        for i, y in enumerate(LEVELS):
            print('Y %.4f  centre %3d  ' % (y, base[i]) + '  '.join('%s %3d' % (k, out[k][i]) for k in out))
    print('WORST_REVERSAL', worst)


if __name__ == '__main__':
    main()
