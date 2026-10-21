#!/usr/bin/env python3
"""Emulate the CPU airlight estimate (Decomposition.airlight: dark channel, radius
min(w,h)/100 >= 3, mean colour of the top 0.1% dark-channel pixels) on the LFI input at a
given long edge, and say WHERE the selected pixels are. Approximation: uses the input
scene-linear camera-reference RGB (as-shot neutral = R=G=B), not the exact S8 input
(no WB/exposure/tone before it at default recipe, so close).

THIS EMULATES THE PRE-FIX RULE ONLY. It is the baseline for SPEC lines A1-A3. After the
rule changes, the authoritative numbers come from the Swift test
`WS15DehazeAirlightCorpusTests` (SPEC U10), which prints the same fields.

Usage: airlight_probe.py FRAME.lfi [long_edge ...] [--png OUT.png]
       airlight_probe.py --json ID [ID ...]      (spec mode: 512 and 2048 per frame;
           prints per frame: A, chromaticity, fraction of selection in each
           regions.json airlight_forbidden box, selection centroid, and the 512-vs-2048
           chromaticity distance / luminance ratio)"""
import sys, os, json, numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../../../../scripts/proof'))
from decode_raw import read_lfi, area_downsample
from numpy.lib.stride_tricks import sliding_window_view as _sw


def minimum_filter(a, size, mode='nearest'):
    r = size // 2
    a = np.pad(a, r, mode='edge')
    a = _sw(a, size, axis=0).min(-1)
    return _sw(a, size, axis=1).min(-1)


def down(img, le):
    return area_downsample(img, le).astype(np.float64)


def estimate(im):
    h, w = im.shape[:2]; r = max(min(w, h) // 100, 3)
    dc = minimum_filter(im.min(-1), size=2 * r + 1, mode='nearest')
    thr = np.quantile(dc, 1 - 0.001); sel = dc >= thr
    return im[sel].mean(0), sel, r


def spec(ids):
    R = json.load(open(os.path.join(HERE, 'regions.json')))
    out = {}
    for fid in ids:
        img = read_lfi(os.path.join(HERE, '../../../../..', R[fid]['lfi'])).astype(np.float64)
        rec = {}
        for le in (512, 2048):
            im = down(img, le); h, w = im.shape[:2]
            A, sel, r = estimate(im)
            ys, xs = np.nonzero(sel)
            fr = {}
            for name, b in R[fid].get('airlight_forbidden', {}).items():
                inside = (xs >= b[0] * w) & (xs < b[2] * w) & (ys >= b[1] * h) & (ys < b[3] * h)
                fr[name] = round(float(inside.mean()), 3)
            rec[f'L{le}'] = {'A': [round(float(v), 4) for v in A],
                             'chroma': [round(float(v), 4) for v in A / A.sum()],
                             'luma': round(float(A @ [0.2627, 0.6780, 0.0593]), 4),
                             'centroid_xy': [round(float(xs.mean() / w), 3), round(float(ys.mean() / h), 3)],
                             'forbidden_fraction': fr, 'n': int(sel.sum())}
        a, b = rec['L512'], rec['L2048']
        rec['chroma_dist_512_2048'] = round(float(np.hypot(*(np.array(a['chroma'][:2]) - b['chroma'][:2]))), 4)
        rec['luma_ratio_512_over_2048'] = round(a['luma'] / b['luma'], 3)
        out[fid] = rec
    return out


if __name__ == '__main__':
    args = [a for a in sys.argv[1:]]; png = None
    if args and args[0] == '--json':
        json.dump(spec(args[1:]), sys.stdout); print(); sys.exit(0)
    if '--png' in args: i = args.index('--png'); png = args[i + 1]; del args[i:i + 2]
    img = read_lfi(args[0]).astype(np.float64)
    for le in map(int, args[1:] or ['512', '1024', '2048']):
        im = down(img, le); h, w = im.shape[:2]
        A, sel, r = estimate(im); ys, xs = np.nonzero(sel)
        print(f"L{le} ({w}x{h}) r={r}: A=({A[0]:.3f},{A[1]:.3f},{A[2]:.3f}) b/r={A[2]/A[0]:.3f} n={sel.sum()} "
              f"at x {xs.min()/w:.2f}-{xs.max()/w:.2f}, y {ys.min()/h:.2f}-{ys.max()/h:.2f} (fractions)  img max-lum p99.9 {np.quantile(im.mean(-1),0.999):.3f}")
        if png and le == int((args[1:] or ['1024'])[-1]):
            from PIL import Image
            v = np.clip(im / np.quantile(im, 0.99), 0, 1) ** (1 / 2.2) * 255; v[sel] = [255, 0, 255]
            Image.fromarray(v.astype(np.uint8)).save(png)
