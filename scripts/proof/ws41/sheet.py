#!/usr/bin/env python3
"""Labelled contact sheet for the WS-41 visual claims (dithered, export path).

  sheet.py --frame 6929 --rows look.vignetteRoundness=-100,0,100 \
           --cols look.vignetteMidpoint=0,25,50,75,100 --set look.vignette=-2 \
           [--crop x0,y0,x1,y1] [--long-edge 1024] [--tile 300] --out sheet.png

Each cell renders at --long-edge, optionally crops the fractional box (a 100 % corner
crop when --long-edge is the source size), and is scaled to --tile px wide. Rows/cols may
also be `style` lists: --rows look.vignetteStyle=highlightPriority,colorPriority,paintOverlay
"""
import argparse, os, sys
import numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib


def axis(spec):
    if not spec:
        return [None]
    k, v = spec.split('=', 1)
    return ['%s=%s' % (k, x) for x in v.split(',')]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frame', required=True)
    ap.add_argument('--rows'); ap.add_argument('--cols')
    ap.add_argument('--set', action='append', default=[])
    ap.add_argument('--crop')
    ap.add_argument('--long-edge', type=int, default=1024)
    ap.add_argument('--tile', type=int, default=300)
    ap.add_argument('--out', required=True)
    a = ap.parse_args()
    lfi = lib.frame(a.frame)
    rows, cols = axis(a.rows), axis(a.cols)
    cells = []
    for r in rows:
        line = []
        for c in cols:
            sets = a.set + [s for s in (r, c) if s]
            img, _ = lib.render(lfi, sets, long_edge=a.long_edge, dither=True)
            if a.crop:
                H, W, _ = img.shape
                x0, y0, x1, y1 = map(float, a.crop.split(','))
                img = img[int(y0 * H):int(y1 * H), int(x0 * W):int(x1 * W)]
            im = Image.fromarray(img)
            im = im.resize((a.tile, max(1, round(im.height * a.tile / im.width))), Image.LANCZOS)
            lab = ' '.join((s.split('.')[-1].replace('vignette', '') or 'amount')
                           .replace('=', ' ') if not s.split('=')[0].endswith('vignette')
                           else 'amount ' + s.split('=')[1] for s in (r, c) if s)
            d = ImageDraw.Draw(im)
            d.rectangle([0, 0, int(d.textlength(lab)) + 6, 13], fill=(0, 0, 0))
            d.text((3, 1), lab, fill=(255, 255, 255))
            line.append(im)
        cells.append(line)
    th = max(im.height for line in cells for im in line)
    pad = 4
    sheet = Image.new('RGB', (len(cols) * (a.tile + pad) + pad, len(rows) * (th + pad) + pad + 16), (40, 40, 40))
    ImageDraw.Draw(sheet).text((pad, 2), '%s  %s' % (a.frame, ' '.join(a.set)), fill=(230, 230, 230))
    for i, line in enumerate(cells):
        for j, im in enumerate(line):
            sheet.paste(im, (pad + j * (a.tile + pad), 16 + pad + i * (th + pad)))
    sheet.save(a.out, optimize=True)
    print('%s  %dx%d  %d KB' % (a.out, sheet.width, sheet.height, os.path.getsize(a.out) // 1024))


if __name__ == '__main__':
    main()
