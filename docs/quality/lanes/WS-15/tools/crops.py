#!/usr/bin/env python3
"""Side-by-side 100% crops. Usage: crops.py OUT.png X0 Y0 W H img1.png img2.png ... [--gain G]
Coordinates are fractions (0-1) of the frame if <= 1, else pixels. --gain multiplies
encoded values for visibility (label says so)."""
import sys
from PIL import Image, ImageDraw
args = sys.argv[1:]; gain = 1.0
if '--gain' in args:
    i = args.index('--gain'); gain = float(args[i + 1]); del args[i:i + 2]
out, x0, y0, w, h, imgs = args[0], *map(float, args[1:5]), args[5:]
tiles = []
for p in imgs:
    im = Image.open(p).convert('RGB'); W, H = im.size
    px = lambda v, S: int(v * S) if v <= 1 else int(v)
    X, Y = px(x0, W), px(y0, H); c = im.crop((X, Y, X + px(w, W), Y + px(h, H)))
    if gain != 1: c = c.point(lambda v: min(255, int(v * gain)))
    d = ImageDraw.Draw(c); d.rectangle([0, 0, 200, 12], fill=(0, 0, 0))
    d.text((2, 1), p.split('/')[-1] + (f' x{gain}' if gain != 1 else ''), fill=(255, 255, 0)); tiles.append(c)
sheet = Image.new('RGB', (sum(t.width for t in tiles) + 4 * (len(tiles) - 1), max(t.height for t in tiles)), (128, 128, 128))
x = 0
for t in tiles: sheet.paste(t, (x, 0)); x += t.width + 4
sheet.save(out); print(out, sheet.size)
