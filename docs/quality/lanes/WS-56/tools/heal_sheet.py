#!/usr/bin/env python3
"""Evidence sheet for WS-56/57: each case's crop rendered through lumen-render (the app's
picture, default recipe at the frame's as-shot WB), shown at 100% and at 3x nearest.

usage: heal_sheet.py <evidence-dir> <out.png> [case-substring ...] [--cols truth,damaged,heal,clone]
"""
import json, os, subprocess, sys
from PIL import Image, ImageDraw

LUMEN = os.path.dirname(os.path.abspath(__file__)) + "/../../../../.."
BIN = os.environ.get("LUMEN_RENDER", LUMEN + "/.build/x86_64-unknown-linux-gnu/release/lumen-render")

def as_shot(case):
    frame = {"983": "983_canon-eos-5d-mark-iv", "1840": "1840_nikon-d850",
             "6929": "6929_sony-ilce-7m4", "6933": "6933_sony-ilce-7m4",
             "1192": "1192_fujifilm-x-t10"}.get(case.split("-")[0])
    if not frame:
        return []
    side = json.load(open(f"{LUMEN}/corpus/lfi/{frame}.json")).get("recipe_hint", {})
    return ["--as-shot-kelvin", str(side.get("asShotKelvin", 5500)),
            "--as-shot-tint", str(side.get("asShotTint", 0))]

def render(lfi, case):
    png = lfi[:-4] + ".png"
    if not os.path.exists(png) or os.path.getmtime(png) < os.path.getmtime(lfi):
        subprocess.run([BIN, "render", "--input", lfi, "--long-edge", "0", "--no-dither",
                        "--out", png] + as_shot(case), check=True, capture_output=True)
    return Image.open(png).convert("RGB")

def main():
    args = sys.argv[1:]
    cols = ["truth", "damaged", "heal", "clone"]
    if "--cols" in args:
        i = args.index("--cols"); cols = args[i + 1].split(","); del args[i:i + 2]
    zoom = 3
    if "--zoom" in args:
        i = args.index("--zoom"); zoom = int(args[i + 1]); del args[i:i + 2]
    d, out, wanted = args[0], args[1], args[2:]
    rows = json.load(open(f"{d}/metrics.json"))
    cases = []
    for r in rows:
        if r["case"] not in cases and (not wanted or any(r["case"].startswith(w) for w in wanted)):
            cases.append(r["case"])
    by = {(r["case"], r["mode"]): r for r in rows}
    tiles = []
    for c in cases:
        row = []
        for col in cols:
            p = f"{d}/{c}-{col}.lfi"
            if not os.path.exists(p):
                continue
            im = render(p, c)
            r = by.get((c, "heal")) or next((x for x in rows if x["case"] == c), None)
            # a centred window of 6 radii, zoomed, beside nothing else: 100% judged on the zoom
            side = im.width
            rad = r["radius"] if r else side / 8
            half = int(min(side / 2, 2.2 * rad))
            cx = int(r["cx"] - r["cropX"]) if r else side // 2
            cy = int(r["cy"] - r["cropY"]) if r else side // 2
            win = im.crop((cx - half, cy - half, cx + half, cy + half))
            win = win.resize((win.width * zoom, win.height * zoom), Image.NEAREST)
            label = col
            m = by.get((c, col)) or by.get((c, col.replace("_before", "")))
            if m:
                label += f"  dE {m['colourError']:.2f} bl {m['blotch']:.1f} tx {m['textureRatio']:.2f}"
            row.append((win, label))
        tiles.append((c, row))
    tw = max(t.width for _, row in tiles for t, _ in row)
    th = max(t.height for _, row in tiles for t, _ in row)
    W = len(cols) * (tw + 6) + 6
    H = len(tiles) * (th + 34) + 6
    sheet = Image.new("RGB", (W, H), (40, 40, 40))
    dr = ImageDraw.Draw(sheet)
    for j, (c, row) in enumerate(tiles):
        y = 6 + j * (th + 34)
        dr.text((6, y), c, fill=(230, 230, 230))
        for i, (t, label) in enumerate(row):
            x = 6 + i * (tw + 6)
            sheet.paste(t, (x, y + 14))
            dr.text((x, y + 16 + t.height), label, fill=(200, 200, 200))
    sheet.save(out, optimize=True)
    print(out, sheet.size)

main()
