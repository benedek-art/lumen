#!/usr/bin/env python3
"""Contact sheet: rows = corpus photos, columns = no look + each look JSON in json/.
Usage: python3 contact.py [out.png]  (renders via render.sh, tiles 256 px, labelled)"""
import glob, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from PIL import Image, ImageDraw
L = os.path.dirname(os.path.abspath(__file__))
PHOTOS = ["6929_sony-ilce-7m4", "2545_panasonic-dmc-gx85", "1569_panasonic-dmc-gx80",
          "4694_canon-eos-r5", "1332_canon-eos-77d", "1192_fujifilm-x-t10"]
LOOKS = [("None", "-")] + [(os.path.basename(p)[3:-5].replace("-", " ").title(), p)
                           for p in sorted(glob.glob(f"{L}/json/*.json"))]
TILE, LABEL = 256, 18
os.makedirs(f"{L}/r", exist_ok=True)
def job(pl):
    (p, (name, path)) = pl
    out = f"{L}/r/{p}__{name.replace(' ', '_')}.png"
    subprocess.run([f"{L}/render.sh", p, path, out, "512"], check=True)
    return out
jobs = [(p, l) for p in PHOTOS for l in LOOKS]
with ThreadPoolExecutor(8) as ex:
    outs = list(ex.map(job, jobs))
H = int(TILE * 2 / 3)
sheet = Image.new("RGB", (TILE * len(LOOKS), LABEL + H * len(PHOTOS)), (24, 24, 24))
d = ImageDraw.Draw(sheet)
for j, (name, _) in enumerate(LOOKS):
    d.text((j * TILE + 6, 3), name, fill=(230, 230, 230))
for k, out in enumerate(outs):
    i, j = divmod(k, len(LOOKS))
    im = Image.open(out).convert("RGB"); im.thumbnail((TILE, H))
    sheet.paste(im, (j * TILE + (TILE - im.width) // 2, LABEL + i * H + (H - im.height) // 2))
dst = sys.argv[1] if len(sys.argv) > 1 else f"{L}/contact.png"
sheet.save(dst, optimize=True)                     # full sheet, for review
print(dst, sheet.size, os.path.getsize(dst))
# Evidence copies under the lane's 400 KB cap: photographic PNG does not compress, so the
# sheet is split into strips of two photos each, 1800 px wide, 256 colours, no dither.
for k in range(0, len(PHOTOS), 2):
    strip = sheet.crop((0, 0, sheet.width, LABEL)), sheet.crop((0, LABEL + k * H, sheet.width, LABEL + (k + 2) * H))
    part = Image.new("RGB", (sheet.width, LABEL + 2 * H)); part.paste(strip[0], (0, 0)); part.paste(strip[1], (0, LABEL))
    part = part.resize((1800, round(part.height * 1800 / part.width)), Image.LANCZOS)
    q = part  # full colour: a palette posterises the sheet (WS-29 verifier, defect 7)
    out = dst[:-4] + f"_part{k // 2 + 1}.png"
    q.save(out, optimize=True)
    print(out, part.size, os.path.getsize(out))
