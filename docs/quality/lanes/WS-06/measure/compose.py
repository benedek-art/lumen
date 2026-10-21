#!/usr/bin/env python3
"""Build the committed WS-06 evidence (each file < 400 KB) from sheets.sh output.

  compose.py BEFORE_DIR [AFTER_DIR] EVIDENCE_DIR

With AFTER_DIR: per photo one PNG with the before row above the after row (tiles
downsized to 320 px wide), plus 100% crops of contrast 0 / +100 before and after.
Without AFTER_DIR: the same with the before row only (baseline record).
"""
import glob, os, sys
from PIL import Image, ImageDraw

args = sys.argv[1:]
before, after, outdir = (args[0], args[1], args[2]) if len(args) == 3 else (args[0], None, args[1])
os.makedirs(outdir, exist_ok=True)
VALS = ["-100", "-50", "0", "+50", "+100"]
# 100% crops at long edge 1024: (x, y, w, h), what to look at
CROPS = {
    "V1_6929": (300, 250, 360, 260),        # foliage shadows against the wall
    "V2_1346": (330, 280, 300, 300),        # dark patches, black card, dark surround
    "V3_983_exp1.5": (560, 120, 400, 300),  # lantern glass, snow, pale chart patches
    "V4_2545": (700, 0, 324, 260),          # sky against the tree line
}


def tiles(d):
    fs = {os.path.basename(f)[:-4].split("_", 2)[2]: f for f in glob.glob(d + "/tile_*.png")}
    return [Image.open(fs[v]).convert("RGB") for v in VALS]


def label(im, text):
    ImageDraw.Draw(im).rectangle((0, 0, 7 * len(text) + 6, 13), fill=(0, 0, 0))
    ImageDraw.Draw(im).text((3, 1), text, fill=(255, 255, 255))
    return im


def save(im, path):
    im.save(path, optimize=True)
    while os.path.getsize(path) > 400_000:  # palette PNG, then smaller, under the cap
        q = im.quantize(256, method=Image.Quantize.MEDIANCUT)
        q.save(path, optimize=True)
        if os.path.getsize(path) > 400_000:
            im = im.resize((int(im.width * 0.85), int(im.height * 0.85)), Image.LANCZOS)
    print(path, im.size, os.path.getsize(path) // 1024, "KB")


for name, crop in CROPS.items():
    rows = [("before", before)] + ([("after", after)] if after else [])
    thumbs = []
    for tag, d in rows:
        ts = tiles(os.path.join(d, name))
        w = 320; h = round(ts[0].height * w / ts[0].width)
        thumbs.append([label(t.resize((w, h), Image.LANCZOS), f"{tag} contrast {v}") for t, v in zip(ts, VALS)])
    W = 5 * 320 + 4 * 4; H = len(thumbs) * (thumbs[0][0].height + 4)
    sheet = Image.new("RGB", (W, H), (128, 128, 128))
    for r, row in enumerate(thumbs):
        for c, t in enumerate(row):
            sheet.paste(t, (c * 324, r * (t.height + 4)))
    save(sheet, os.path.join(outdir, f"{name}_sweep_{'before_after' if after else 'before'}.png"))
    x, y, w, h = crop
    parts = []
    for tag, d in rows:
        ts = tiles(os.path.join(d, name))
        for v in ("0", "+100"):
            parts.append(label(ts[VALS.index(v)].crop((x, y, x + w, y + h)), f"{tag} {v}"))
    S = Image.new("RGB", (len(parts) * (w + 4) - 4, h), (128, 128, 128))
    for i, p in enumerate(parts):
        S.paste(p, (i * (w + 4), 0))
    save(S, os.path.join(outdir, f"{name}_crop100_{'before_after' if after else 'before'}.png"))
