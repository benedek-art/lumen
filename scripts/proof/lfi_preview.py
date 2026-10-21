#!/usr/bin/env python3
"""lfi_preview.py -- a quick look at an .lfi frame, for human eyes only.

NOT a Lumen render and not a display transform anyone should measure: scene-linear
Rec.2020 is scaled so its mean log-luminance sits at 0.18 (or by --ev), converted to
linear sRGB, hard-clipped to [0,1] and sRGB-encoded to an 8-bit PNG. Good enough to
see orientation, gross colour casts and exposure. Needs Pillow.

Usage: lfi_preview.py IN.lfi OUT.png [--ev auto|EV] [--max 1200]
"""

import argparse
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_raw import read_lfi, REC2020_TO_XYZ, SRGB_TO_XYZ, area_downsample  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--ev", default="auto")
    ap.add_argument("--max", type=int, default=1200)
    a = ap.parse_args(argv)
    img = area_downsample(read_lfi(a.input).astype(np.float32), a.max)
    y = img @ REC2020_TO_XYZ[1].astype(np.float32)
    if a.ev == "auto":
        g = 0.18 / np.exp(np.mean(np.log(np.clip(y, 1e-5, None))))
    else:
        g = 2.0 ** float(a.ev)
    m = (np.linalg.inv(SRGB_TO_XYZ) @ REC2020_TO_XYZ).astype(np.float32)
    s = np.clip((img * np.float32(g)) @ m.T, 0, 1)
    enc = np.where(s <= 0.0031308, 12.92 * s, 1.055 * np.power(s, 1 / 2.4) - 0.055)
    Image.fromarray((enc * 255 + 0.5).astype(np.uint8)).save(a.output)
    print("%s -> %s  gain %.3f (%+.2f EV)" % (a.input, a.output, g, np.log2(g)))


if __name__ == "__main__":
    sys.exit(main())
