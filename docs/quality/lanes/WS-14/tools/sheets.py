"""Build the three visual-judgement sheets of SPEC.md from render_all.sh output.
usage: python3 sheets.py OUT [DEST]      (DEST default OUT/sheets)
  V1_skin.png        skin_6000 at 6000 px, 2x crop of pores left of / between the lashes:
                     identity, Texture -50, Texture -100, Clarity -100, Texture +100, Clarity +100
  V2_lantern.png     983 native strip, full size, 1:1 crop of the lantern glass and background bokeh:
                     identity, Clarity +50, Clarity +100, Clarity -100, Texture +100, Texture -100
  V3_preview.png     2545 native strip: the 1600 px preview render vs the full-size render
                     area-downsampled to 1600, for Texture -100, Texture +100, Clarity +100 (2x crop)
"""
import sys, os
import numpy as np
from PIL import Image, ImageDraw
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, lin

OUT = sys.argv[1]; DEST = sys.argv[2] if len(sys.argv) > 2 else os.path.join(OUT, "sheets")
os.makedirs(DEST, exist_ok=True)


def sheet(path, items, box, scale, cols=3):
    x, y, w, h = box; W, H = w * scale, h * scale
    rows = (len(items) + cols - 1) // cols
    sh = Image.new("RGB", (cols * (W + 6), rows * (H + 22)), (40, 40, 40)); dr = ImageDraw.Draw(sh)
    for i, (lab, im) in enumerate(items):
        if isinstance(im, str):
            im = Image.open(im).convert("RGB")
        im = im.crop((x, y, x + w, y + h)).resize((W, H), Image.NEAREST)
        cx, cy = (i % cols) * (W + 6), (i // cols) * (H + 22)
        sh.paste(im, (cx, cy + 20)); dr.text((cx + 4, cy + 4), lab, fill=(255, 255, 0))
    sh.save(path); print(path)


def down(path, size):
    l = lin(load(path)).astype(np.float32)
    l = np.stack([np.asarray(Image.fromarray(l[..., c]).resize(size, Image.BOX)) for c in range(3)], -1)
    v = np.where(l <= 0.0031308, 12.92 * l, 1.055 * np.power(np.maximum(l, 0), 1 / 2.4) - 0.055)
    return Image.fromarray(np.clip(np.rint(v * 255), 0, 255).astype(np.uint8))


k = f"{OUT}/skin/k6000"
sheet(f"{DEST}/V1_skin.png", [("0", f"{k}_id.png"), ("tex -50", f"{k}_t-50.png"), ("tex -100", f"{k}_t-100.png"),
      ("clar -100", f"{k}_c-100.png"), ("tex +100", f"{k}_t100.png"), ("clar +100", f"{k}_c100.png")],
      (3950, 250, 300, 220), 2)
n = f"{OUT}/native/983_full"
sheet(f"{DEST}/V2_lantern.png", [("0", f"{n}_id.png"), ("clar +50", f"{n}_c50.png") if os.path.exists(f"{n}_c50.png") else ("clar +25", f"{n}_c25.png"),
      ("clar +100", f"{n}_c100.png"), ("clar -100", f"{n}_c-100.png"), ("tex +100", f"{n}_t100.png"), ("tex -100", f"{n}_t-100.png")],
      (4700, 250, 700, 700), 1)
s, f = f"{OUT}/native/2545_1600", f"{OUT}/native/2545_full"
size = Image.open(f"{s}_id.png").size
items = []
for v, lab in (("t-100", "tex -100"), ("t100", "tex +100"), ("c100", "clar +100")):
    items += [(f"{lab} preview 1600", f"{s}_{v}.png"), (f"{lab} export->1600", down(f"{f}_{v}.png", size))]
sheet(f"{DEST}/V3_preview.png", [("0 preview", f"{s}_id.png"), ("0 export->1600", down(f"{f}_id.png", size))] + items,
      (500, 0, 360, 300), 2, cols=2)
