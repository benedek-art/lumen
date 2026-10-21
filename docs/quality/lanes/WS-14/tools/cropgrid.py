"""Assemble the same crop from several renders into one labelled sheet.
usage: python3 cropgrid.py OUT.png x y w h [scale] -- label=path label=path ...
Crop box in the render's own pixels; scale (default 1) enlarges with NEAREST; 3 columns."""
import sys
from PIL import Image, ImageDraw
out = sys.argv[1]; x, y, w, h = map(int, sys.argv[2:6])
rest = sys.argv[6:]
scale = 1
if rest[0] != "--":
    scale = int(rest[0]); rest = rest[1:]
items = [a.split("=", 1) for a in rest[1:]]
cols = min(len(items), 3); rows = (len(items) + cols - 1) // cols
W, H = w * scale, h * scale
sheet = Image.new("RGB", (cols * (W + 6), rows * (H + 22)), (40, 40, 40))
dr = ImageDraw.Draw(sheet)
for i, (lab, p) in enumerate(items):
    im = Image.open(p).convert("RGB").crop((x, y, x + w, y + h)).resize((W, H), Image.NEAREST)
    cx, cy = (i % cols) * (W + 6), (i // cols) * (H + 22)
    sheet.paste(im, (cx, cy + 20)); dr.text((cx + 4, cy + 4), lab, fill=(255, 255, 0))
sheet.save(out)
print(out)
