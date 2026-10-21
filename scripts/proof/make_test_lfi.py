#!/usr/bin/env python3
"""Write a synthetic scene-linear test frame as `.lfi` for `lumen-render`.

    python3 scripts/proof/make_test_lfi.py out.lfi [--width 960 --height 540]

Layout (top to bottom):
  * 30%  smooth log ramp, -10 ... +4 EV about mid-grey 0.18 (left to right)
  * 15%  fifteen one-stop grey steps, -10 ... +4 EV
  * 55%  a 6x4 ColorChecker-like chart (sRGB 8-bit references, decoded to linear,
         converted to Rec.2020, exposed so the 18% patch lands on 0.18), patches
         separated by a dark 0.02 frame

Colour convention (what ReferenceRenderer expects, see Sources/LumenRender/main.swift):
scene-linear, Rec.2020 primaries, D65, camera-reference white balance (neutral R=G=B).

LFI1: b"LFI1", uint32 LE width, height, channels(=3), then float32 LE RGB interleaved,
row-major, top row first. `lumen-render synth` writes the same frame without numpy.
"""
import argparse
import struct

import numpy as np

# Linear sRGB -> linear Rec.2020 (D65 both), ITU-R BT.2087.
SRGB_TO_2020 = np.array([
    [0.6274039, 0.3292830, 0.0433131],
    [0.0690973, 0.9195404, 0.0113623],
    [0.0163914, 0.0880133, 0.8955953],
])

CHECKER = [
    (115, 82, 68), (194, 150, 130), (98, 122, 157), (87, 108, 67),
    (133, 128, 177), (103, 189, 170), (214, 126, 44), (80, 91, 166),
    (193, 90, 99), (94, 60, 108), (157, 188, 64), (224, 163, 46),
    (56, 61, 150), (70, 148, 73), (175, 54, 60), (231, 199, 31),
    (187, 86, 149), (8, 133, 161), (243, 243, 242), (200, 200, 200),
    (160, 160, 160), (122, 122, 121), (85, 85, 85), (52, 52, 52),
]


def srgb_decode(v):
    v = np.asarray(v, dtype=np.float64)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def make(width, height):
    img = np.zeros((height, width, 3), dtype=np.float64)
    u = (np.arange(width) + 0.5) / width
    ramp_end = int(height * 0.30)
    step_end = int(height * 0.45)
    img[:ramp_end] = (0.18 * 2.0 ** (-10 + 14 * u))[None, :, None]
    steps = np.minimum((u * 15).astype(int), 14)
    img[ramp_end:step_end] = (0.18 * 2.0 ** (steps - 10.0))[None, :, None]

    grey_ref = srgb_decode(122 / 255)
    rows = height - step_end
    for y in range(step_end, height):
        v = (y - step_end) / rows
        row = min(int(v * 4), 3)
        fy = v * 4 - row
        for col in range(6):
            x0, x1 = int(col * width / 6), int((col + 1) * width / 6)
            p = np.array(CHECKER[row * 6 + col]) / 255
            lin = SRGB_TO_2020 @ srgb_decode(p) * (0.18 / grey_ref)
            fx = (np.arange(x0, x1) + 0.5) / width * 6 - col
            inside = (fx >= 0.06) & (fx <= 0.94) & (0.06 <= fy <= 0.94)
            img[y, x0:x1] = np.where(inside[:, None], lin[None, :], 0.02)
    return img.astype("<f4")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--width", type=int, default=960)
    ap.add_argument("--height", type=int, default=540)
    a = ap.parse_args()
    img = make(a.width, a.height)
    with open(a.out, "wb") as f:
        f.write(b"LFI1" + struct.pack("<III", a.width, a.height, 3))
        f.write(img.tobytes())
    print(f"wrote {a.width}x{a.height} LFI1 -> {a.out}")


if __name__ == "__main__":
    main()
