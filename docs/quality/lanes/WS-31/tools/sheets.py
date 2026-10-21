"""Renders the sheets the visual claims (V1-V3) are judged from.

usage: sheets.py --bin lumen-render --corpus corpus --out DIR
writes DIR/{hw_b3_hue,hw_b1_sat,hw_b5_lum,1569_b3_hue,sky_1840_b5lum,skin_b1_lum}.png and
DIR/sky1840_edge_0_vs_m100_zoom3x.png (left identity, right Blue lum -100, 3x nearest).
"""
import argparse, os, subprocess, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib import *
ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True); ap.add_argument("--corpus", required=True); ap.add_argument("--out", required=True)
a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
S = os.path.join(a.corpus, "synthetic"); L = os.path.join(a.corpus, "lfi")
jobs = [("hw_b3_hue", os.path.join(S, "hue_wheel.lfi"), 3, "hue", 400),
        ("hw_b1_sat", os.path.join(S, "hue_wheel.lfi"), 1, "sat", 400),
        ("hw_b5_lum", os.path.join(S, "hue_wheel.lfi"), 5, "lum", 400),
        ("1569_b3_hue", os.path.join(L, "1569_panasonic-dmc-gx80.lfi"), 3, "hue", 480),
        ("sky_1840_b5lum", os.path.join(L, "1840_nikon-d850.lfi"), 5, "lum", 480),
        ("skin_b1_lum", os.path.join(S, "skin_tones.lfi"), 1, "lum", 600)]
for name, src, b, c, le in jobs:
    subprocess.run([a.bin, "sweep", "--input", src] + sidecar(src) + ["--no-dither", "--key", key(b, c),
                    "--values", "-100,-50,0,50,100", "--long-edge", str(le), "--columns", "5",
                    "--out", os.path.join(a.out, name + ".png"), "--metrics", os.path.join(a.out, name + ".json")],
                   check=True, capture_output=True)
src = os.path.join(L, "1840_nikon-d850.lfi")
p0 = render(a.bin, src, os.path.join(a.out, "_1840_0.png"), [], 1600, cache=False)
pm = render(a.bin, src, os.path.join(a.out, "_1840_m100.png"), [f"{key(5,'lum')}=-100"], 1600, cache=False)
box_ = (740, 150, 900, 230)
crops = [Image.open(p).convert("RGB").crop(box_).resize((480, 240), Image.NEAREST) for p in (p0, pm)]
sheet = Image.new("RGB", (968, 240), (40, 40, 40)); sheet.paste(crops[0], (0, 0)); sheet.paste(crops[1], (488, 0))
sheet.save(os.path.join(a.out, "sky1840_edge_0_vs_m100_zoom3x.png"))
print("ok")
