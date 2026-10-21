#!/usr/bin/env python3
"""Inspect the halo-profile geometry: for every profile in regions.json, write an image
with (top) the 100 % strip of the base render along the profile, laid horizontally,
marked with the detected edge (red), each side's near window (yellow, px 2 .. 40 % of the
side) and far-plateau window (cyan, 60 .. 100 % of the side); (bottom) plots of
log2 base Y (white, 1 EV per 20 px), log2(out/base) for each OUT value (orange +, green -,
1 EV per 40 px, zero line grey). Used to check that near and plateau lie on one surface.

Usage: halo_inspect.py WORKDIR OUTDIR [--values 100,-100] [--frames 4213,...]"""
import argparse, json, os, sys
import numpy as np
from PIL import Image, ImageDraw
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import dehaze_metrics as dm


def edge_index(pb, p):
    n = len(pb); lg = np.log2(np.maximum(pb, 1e-5))
    guess = int((p['edge'] - p['from']) / (p['to'] - p['from']) * n)
    lo, hi = max(guess - n // 8, 1), min(guess + n // 8, n - 1)
    return lo + int(np.argmax(np.abs(np.diff(lg[lo - 1:hi + 1]))[:hi - lo]))


def strip(img8, p, half=60):
    h, w = img8.shape[:2]
    if p['axis'] == 'v':
        x = int(p['at'] * w); a, z = int(p['from'] * h), int(p['to'] * h)
        s = img8[a:z, max(x - half, 0):x + half + 1]
        return np.ascontiguousarray(np.transpose(s, (1, 0, 2)))  # along profile -> x
    y = int(p['at'] * h); a, z = int(p['from'] * w), int(p['to'] * w)
    return img8[max(y - half, 0):y + half + 1, a:z]


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('work'); ap.add_argument('out')
    ap.add_argument('--values', default='100,-100'); ap.add_argument('--frames', default='4213,983,2545,1840,3437')
    a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
    R = json.load(open(os.path.join(HERE, 'regions.json')))
    for f in a.frames.split(','):
        bpath = os.path.join(a.work, 'full', f'{f}_L2400_d0.png')
        b8 = np.asarray(Image.open(bpath).convert('RGB')); b = dm.srgb_to_linear(b8 / 255.0)
        outs = {int(v): dm.srgb_to_linear(dm.load(os.path.join(a.work, 'full', f'{f}_L2400_d{v}.png'))) for v in a.values.split(',')}
        for name, p in R[f].get('profiles', {}).items():
            pb, _ = dm.profile(b, p); n = len(pb); e = edge_index(pb, p)
            st = strip(b8, p); sh = st.shape[0]
            PH = 260; img = Image.new('RGB', (n, sh + PH), (0, 0, 0)); img.paste(Image.fromarray(st), (0, 0))
            d = ImageDraw.Draw(img); mid = sh // 2
            d.line([(e, 0), (e, sh)], fill=(255, 0, 0))
            for side, sign in (('start', -1), ('end', 1)):
                L = e if side == 'start' else n - e - 1
                def px(k): return e + sign * k
                for (k0, k1), col in (((2, max(int(L * 0.4), 4)), (255, 255, 0)), ((int(L * 0.6), L), (0, 255, 255))):
                    d.line([(px(k0), mid + (6 if col[0] else -6)), (px(k1), mid + (6 if col[0] else -6))], fill=col, width=3)
            lg = np.log2(np.maximum(pb, 1e-5)); y0 = sh + 10
            pts = [(i, y0 + int((lg.max() - lg[i]) * 20)) for i in range(n)]; d.line(pts, fill=(255, 255, 255))
            zero = sh + 170; d.line([(0, zero), (n, zero)], fill=(90, 90, 90))
            for v, o in outs.items():
                po, _ = dm.profile(o, p); r = np.log2(np.maximum(po, 1e-6) / np.maximum(pb, 1e-6))
                col = (255, 150, 0) if v > 0 else (0, 220, 0)
                d.line([(i, zero - int(np.clip(r[i], -2, 2) * 40)) for i in range(n)], fill=col)
            d.text((2, sh + PH - 12), f'{f} {name}  edge@{e}  white=log2 base Y (20px/EV); orange/green=log2 out/base (40px/EV)', fill=(255, 255, 0))
            img.save(os.path.join(a.out, f'{f}_{name}.png'))
            print(os.path.join(a.out, f'{f}_{name}.png'), n, e)


if __name__ == '__main__':
    main()
