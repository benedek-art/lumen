#!/usr/bin/env python3
"""Corner colour and contrast: OKLab of named boxes, setting vs the same recipe at Amount 0.

  corner.py --frame skytest --set look.vignette=-4 [--set look.vignetteHighlights=100 ...]
            [--box name=x0,y0,x1,y1 (fractions)] [--long-edge 768]

Per box: base L C h -> L C h, L/L0, C/C0, cl = (C/L)/(C0/L0), dh (deg, hue of mean a,b),
sdL = std(L)/std(L0) (local contrast kept), clip0 / clip255 (% of box pixels with any
channel at 0 / 255). Undithered. Default boxes per frame below; `c5` = the four 5 % corners.
Also prints the frame's shadowsPct / highlightsPct (lumen-render metrics, `any`).
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib

C5 = {'TL': (0, 0, .05, .05), 'TR': (.95, 0, 1, .05), 'BL': (0, .95, .05, 1), 'BR': (.95, .95, 1, 1)}
BOXES = {
    'skytest': {'sky_TR': (.94, .01, .99, .06), 'white_TL': (.02, .03, .07, .10),
                'specular': (.017, .15, .044, .19), 'snow_BL': (.01, .94, .06, .99),
                'snow_BR': (.94, .94, .99, .99), 'grey_mid': (.48, .45, .52, .55)},
    'colour4': {'red_TL': (0, 0, .016, .023), 'blue_TR': (.984, 0, 1, .023),
                'green_BL': (0, .977, .016, 1), 'skin_BR': (.984, .977, 1, 1)},
    'skin_tones': {'light_TL': (.02, .057, .052, .15), 'tan_TR': (.948, .057, .98, .15),
                   'dark_BL': (.02, .85, .052, .94), 'mid_BR': (.948, .85, .98, .94)},
    'checker': {'TL': (0, 0, .08, .12), 'BR': (.92, .88, 1, 1), 'centre': (.46, .44, .54, .56)},
    'flat32': {'corner_TL': (0, 0, .01, .015), 'side_mid': (0, .49, .01, .51)},
    'flat_grey': {'corner_TL': (0, 0, .01, .01)},
}


def stats(img, box):
    H, W, _ = img.shape
    x0, y0, x1, y1 = box
    p = img[int(y0 * H):max(int(y1 * H), int(y0 * H) + 1), int(x0 * W):max(int(x1 * W), int(x0 * W) + 1)]
    L, A, B = lib.oklab(p)
    return dict(L=L.mean(), C=np.hypot(A, B).mean(), h=np.degrees(np.arctan2(B.mean(), A.mean())),
                sd=L.std(), c0=100 * np.mean((p == 0).any(-1)), c255=100 * np.mean((p == 255).any(-1)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frame', required=True)
    ap.add_argument('--set', action='append', default=[])
    ap.add_argument('--box', action='append', default=[])
    ap.add_argument('--long-edge', type=int, default=768)
    a = ap.parse_args()
    lfi = lib.frame(a.frame)
    boxes = dict(BOXES.get(a.frame, C5))
    for b in a.box:
        n, v = b.split('=')
        boxes[n] = tuple(map(float, v.split(',')))
    base_sets = [s for s in a.set if not s.startswith('look.vignette=')] + ['look.vignette=0']
    b0, m0 = lib.render(lfi, base_sets, long_edge=a.long_edge, metrics=True)
    b1, m1 = lib.render(lfi, a.set, long_edge=a.long_edge, metrics=True)
    print('frame %s  sets %s' % (a.frame, ' '.join(a.set)))
    for n, box in boxes.items():
        s0, s1 = stats(b0, box), stats(b1, box)
        cl = (s1['C'] / max(s1['L'], 1e-6)) / max(s0['C'] / max(s0['L'], 1e-6), 1e-9)
        dh = (s1['h'] - s0['h'] + 180) % 360 - 180 if s0['C'] > 0.01 else float('nan')
        sd = '%.2f' % (s1['sd'] / s0['sd']) if s0['sd'] > 0.005 else ' n/a'
        print('  %-10s L %.3f->%.3f (x%.2f)  C %.4f->%.4f (x%.2f)  cl %.2f  dh %+5.1f  sdL x%s  '
              'clip0 %.2f->%.2f%% clip255 %.2f->%.2f%%' % (
                  n, s0['L'], s1['L'], s1['L'] / max(s0['L'], 1e-6), s0['C'], s1['C'],
                  s1['C'] / max(s0['C'], 1e-9), cl, dh, sd, s0['c0'], s1['c0'], s0['c255'], s1['c255']))
    for tag, m in (('base', m0), ('set', m1)):
        c = m['metrics']['clipping']
        print('  frame %-4s shadowsPct %.3f  highlightsPct %.3f' % (
            tag, c['shadowsPct']['any'], c['highlightsPct']['any']))


if __name__ == '__main__':
    main()
