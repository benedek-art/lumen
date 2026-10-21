#!/usr/bin/env python3
"""Evidence sheets for REPORT.md -> docs/quality/lanes/WS-19/evidence/. Needs prepare.sh."""
import os, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw
from measure import nr, shipped, real, sim, REAL, OUT, TMP, ROOT, HERE
import lfi

EVD = os.path.join(HERE, '..', 'evidence')
RENDER = os.path.join(ROOT, '.build/release/lumen-render')
os.makedirs(EVD, exist_ok=True)

def png(arr, ev):
    i, o = os.path.join(TMP, 'r.lfi'), os.path.join(TMP, 'r.png')
    lfi.write(i, arr)
    subprocess.run([RENDER, 'render', '--input', i, '--set', 'develop.denoise.mode=off',
                    '--set', 'develop.tone.exposure=%g' % ev, '--no-dither',
                    '--long-edge', '100000', '--out', o], stdout=subprocess.DEVNULL, check=True)
    return Image.open(o).convert('RGB')

def sheet(name, panels, box, zoom):
    x, y, w, h = box; tiles = []
    for label, im in panels:
        t = im.crop((x, y, x + w, y + h)).resize((w * zoom, h * zoom), Image.NEAREST)
        d = ImageDraw.Draw(t); d.rectangle((0, 0, 7 * len(label) + 8, 15), fill=(0, 0, 0))
        d.text((4, 2), label, fill=(255, 255, 0)); tiles.append(t)
    out = Image.new('RGB', (sum(t.width for t in tiles) + 4 * (len(tiles) - 1), tiles[0].height), (40, 40, 40))
    cx = 0
    for t in tiles: out.paste(t, (cx, 0)); cx += t.width + 4
    p = os.path.join(EVD, name); out.save(p, optimize=True)
    print(p, os.path.getsize(p) // 1024, 'KB')

def real_sheet(k, box, zoom, name):
    f, _, _, iso, ev = REAL[k]; d = real(k)
    sheet(name, [('input ISO %d' % iso, png(d['x'], ev)),
                 ('shipped default', png(shipped(d['x'], iso), ev)),
                 ('new default', png(nr(d['x'], iso), ev))], box, zoom)

real_sheet('2348', (170, 260, 190, 190), 2, '2348-jacket.png')
real_sheet('2062', (200, 140, 190, 190), 2, '2062-poppy.png')
real_sheet('1192', (170, 170, 190, 190), 2, '1192-glass.png')
real_sheet('2242', (220, 220, 190, 190), 2, '2242-puzzle.png')
real_sheet('4144', (220, 170, 190, 190), 2, '4144-leaf.png')

# ground truth: noisy | shipped ISO-3200 default | new ISO-3200 default | clean
for s, box, name in [('a7iv', (250, 250, 160, 160), 'sim-a7iv-luma.png'),
                     ('r5', (740, 600, 160, 160), 'sim-r5-colour-edge.png')]:
    d = sim(s)
    sheet(name, [('noisy (sim ISO 3200)', png(d['n'], d['ev'])),
                 ('shipped default', png(shipped(d['n'], 3200), d['ev'])),
                 ('new default', png(nr(d['n'], 3200), d['ev'])),
                 ('clean twin', png(d['c'], d['ev']))], box, 2)

# hot pixels: the three hot-pixel decodes share feature positions, so one row per kind,
# same window: a hot pixel, a star (PSF sigma >= 0.7 px) and a specular disc at each spot.
from hot_shipped import hotpass_shipped
a, b = lfi.seed(3200)
rows = []
for k, label in (('hot', 'hot pixels'), ('star07', 'stars'), ('spec', 'speculars')):
    img = lfi.read(OUT + '/sim/hot_%s.lfi' % k).astype(np.float64)
    rows.append([(label + ': input', png(img, 2.5)),
                 ('shipped Hot Pixels 50', png(hotpass_shipped(img, 50, a, b), 2.5)),
                 ('new Hot Pixels 50', png(nr(img, 3200, luma=0, chroma=0, hot=50), 2.5))])
x, y, w, h, z = 612, 1093, 100, 80, 3
tiles = []
for row in rows:
    for label, im in row:
        t = im.crop((x, y, x + w, y + h)).resize((w * z, h * z), Image.NEAREST)
        d = ImageDraw.Draw(t); d.rectangle((0, 0, 7 * len(label) + 8, 15), fill=(0, 0, 0))
        d.text((4, 2), label, fill=(255, 255, 0)); tiles.append(t)
out = Image.new('RGB', (3 * w * z + 8, 3 * h * z + 8), (40, 40, 40))
for n, t in enumerate(tiles):
    out.paste(t, ((n % 3) * (w * z + 4), (n // 3) * (h * z + 4)))
p = os.path.join(EVD, 'hot-pixels.png'); out.save(p, optimize=True)
print(p, os.path.getsize(p) // 1024, 'KB')
