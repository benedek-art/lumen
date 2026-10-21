"""WS-16 visual sheets (VIS-1..VIS-3). Writes PNGs to $WS16_OUT/sheets (default
/tmp/ws16-measure/sheets): each sheet is a row of labelled tiles plus a row of 100% crops.
Usage: python3 visual.py [outdir]"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import *
from PIL import Image, ImageDraw

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(OUT, "sheets")
os.makedirs(out, exist_ok=True)


def label(im, text):
    d = ImageDraw.Draw(im); d.rectangle([0, 0, 7 * len(text) + 8, 15], fill=(0, 0, 0)); d.text((4, 2), text, fill=(255, 255, 255))
    return im


def sheet(name, frame, tiles, crop, long_edge=None, tile_w=480):
    """tiles: [(label, sets)]; crop: (x, y, w, h) in render pixels, shown at 100%."""
    ims = [(lab, Image.fromarray(render(frame, sets, long_edge))) for lab, sets in tiles]
    top = [label(im.resize((tile_w, int(im.height * tile_w / im.width)), Image.LANCZOS), lab) for lab, im in ims]
    x, y, w, h = crop
    bot = [label(im.crop((x, y, x + w, y + h)), lab + " 100%") for lab, im in ims]
    W = max(sum(t.width for t in top), sum(b.width for b in bot))
    H = max(t.height for t in top) + max(b.height for b in bot)
    m = Image.new("RGB", (W, H), (40, 40, 40))
    cx = 0
    for t in top: m.paste(t, (cx, 0)); cx += t.width
    cx = 0
    for b in bot: m.paste(b, (cx, max(t.height for t in top))); cx += b.width
    p = os.path.join(out, name)
    m.save(p, optimize=True)
    print(p)


# VIS-1: hue wheel, skin sector (30-100 deg OKLab sits upper right of the wheel).
j = json.load(open(os.path.join(SYN, "hue_wheel.json")))["truth"]
cx, cy, R = j["centre"][0], j["centre"][1], j["radius_px"]
sheet("vis1_wheel_sat_vib.png", "hue_wheel",
      [("Sat 0", []), ("Sat +100", ["develop.color.saturation=100"]), ("Vib +100", ["develop.color.vibrance=100"]),
       ("Vib -100", ["develop.color.vibrance=-100"])],
      (int(cx), int(cy - R), int(R * 0.9), int(R * 0.9)), tile_w=360)
# VIS-2: GX85 sky with the Azure band.
sheet("vis2_2545_bw_azure.png", "2545_panasonic-dmc-gx85",
      [(f"Azure {v:+d}" if v else "B&W 0", ["look.bw.enabled=true"] + ([f"look.bw.bands.5={v}"] if v else [])) for v in (-100, -50, 0, 50, 100)],
      (724, 0, 300, 220), long_edge=1024, tile_w=300)
# VIS-3: Vibrance vs Saturation on a saturated still life (4694) and a portrait-free street frame (6929).
sheet("vis3_4694_sat_vs_vib.png", "4694_canon-eos-r5",
      [("0", []), ("Sat +100", ["develop.color.saturation=100"]), ("Vib +100", ["develop.color.vibrance=100"]),
       ("Vib -100", ["develop.color.vibrance=-100"])], (300, 250, 360, 300), long_edge=1024, tile_w=360)
sheet("vis3_6929_vib.png", "6929_sony-ilce-7m4",
      [("0", []), ("Vib -100", ["develop.color.vibrance=-100"]), ("Vib -50", ["develop.color.vibrance=-50"]),
       ("Vib +100", ["develop.color.vibrance=100"])], (300, 250, 360, 300), long_edge=1024, tile_w=360)
