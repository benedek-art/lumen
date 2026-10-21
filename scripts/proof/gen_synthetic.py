#!/usr/bin/env python3
"""gen_synthetic.py -- synthetic test frames in Lumen's decode convention.

Every frame is written as .lfi (see decode_raw.py: b"LFI1", uint32 w/h/c=3, float32 LE
RGB) in the SAME convention as a decoded RAW: scene-linear Rec.2020 (D65 white), white
balance already at the "as-shot" neutral, so a neutral surface is R=G=B. Mid grey is
0.18. Each .lfi gets a sidecar .json with the as-shot pair (D65 in the DNG convention:
6503.7 K / +9.77, what RenderPlan(asShotKelvin:asShotTint:) should be given so that a
recipe with nil temp/tint is identity) and the ground truth needed to measure the
frame (patch rectangles and reference values).

Frames:
  colorchecker.lfi  24-patch ColorChecker, BabelColor "ColorChecker 2005" Lab D50
                    averages -> XYZ D50 -> Bradford -> XYZ D65 -> linear Rec.2020.
  grey_ramp.lfi     log ramp -10..+4 EV around 0.18: continuous (top) and 1-EV steps
                    (bottom, 15 steps).
  hue_wheel.lfi     OKLab hue/chroma wheel at the lightness of 0.18 grey; hue = angle,
                    chroma = radius as a fraction of the Rec.2020 gamut boundary for
                    that hue (rim = most saturated colour Rec.2020 holds at that L).
  zone_plate.lfi    circular chirp cos(pi r^2 / 2R) around 0.18, +-80 %; local
                    frequency = 0.5 r/R cycles/px, i.e. Nyquist at the inscribed circle.
  hard_edge.lfi     halo target: left half a +4.5 EV disk (4.0) on a -5 EV field (0.005),
                    right half a -5 EV square rotated 5 deg on a 4.0 field (slanted edges),
                    a 0.18 grey band across the bottom with bright and dark 1/2/4 px lines.
  skin_tones.lfi    Monk Skin Tone scale (10 swatches, the published sRGB values decoded
                    to linear) + ColorChecker dark/light skin, on 0.18 grey.
  flat_grey.lfi     uniform 0.18 (grain/noise measurement; any variance is added).

Usage: gen_synthetic.py OUTDIR
"""

import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from decode_raw import (write_lfi, REC2020_TO_XYZ, XYZ_TO_REC2020, SRGB_TO_XYZ,  # noqa
                        dng_temperature_tint)

GEN_VERSION = "lumen-proof-synthetic/1"
D65_XY = (0.3127, 0.3290)
AS_SHOT = dict(zip(("kelvin", "tint"), (round(v, 4) for v in dng_temperature_tint(*D65_XY))))

# BabelColor ColorChecker 2005 average, Lab under D50 (2 deg). Same data colour-science
# ships as 'ColorChecker 2005' (it stores the xyY of these values).
CC2005 = [
    ("dark skin", 37.986, 13.555, 14.059), ("light skin", 65.711, 18.130, 17.810),
    ("blue sky", 49.927, -4.880, -21.925), ("foliage", 43.139, -13.095, 21.905),
    ("blue flower", 55.112, 8.844, -25.399), ("bluish green", 70.719, -33.397, -0.199),
    ("orange", 62.661, 36.067, 57.096), ("purplish blue", 40.020, 10.410, -45.964),
    ("moderate red", 51.124, 48.239, 16.248), ("purple", 30.325, 22.976, -21.587),
    ("yellow green", 72.532, -23.709, 57.255), ("orange yellow", 71.941, 19.363, 67.857),
    ("blue", 28.778, 14.179, -50.297), ("green", 55.261, -38.342, 31.370),
    ("red", 42.101, 53.378, 28.190), ("yellow", 81.733, 4.039, 79.819),
    ("magenta", 51.935, 49.986, -14.574), ("cyan", 51.038, -28.631, -28.638),
    ("white 9.5", 96.539, -0.425, 1.186), ("neutral 8", 81.257, -0.638, -0.335),
    ("neutral 6.5", 66.766, -0.734, -0.504), ("neutral 5", 50.867, -0.153, -0.270),
    ("neutral 3.5", 35.656, -0.421, -1.231), ("black 2", 20.461, -0.079, -0.973),
]

# Monk Skin Tone Scale (Google, Ellis Monk), published sRGB swatches.
MST = ["#f6ede4", "#f3e7db", "#f7ead0", "#eadaba", "#d7bd96",
       "#a07e56", "#825c43", "#604134", "#3a312a", "#292420"]

D50_XYZ = np.array([0.96422, 1.0, 0.82521])
BRADFORD = np.array([[0.8951, 0.2664, -0.1614],
                     [-0.7502, 1.7135, 0.0367],
                     [0.0389, -0.0685, 1.0296]])


def xyz_white(xy):
    x, y = xy
    return np.array([x / y, 1.0, (1 - x - y) / y])


def bradford(src, dst):
    s, d = BRADFORD @ src, BRADFORD @ dst
    return np.linalg.inv(BRADFORD) @ np.diag(d / s) @ BRADFORD


def lab_d50_to_rec2020(L, a, b):
    fy = (L + 16) / 116
    fx, fz = fy + a / 500, fy - b / 200

    def finv(t):
        return t ** 3 if t ** 3 > 216 / 24389 else (116 * t - 16) / (24389 / 27)
    xyz50 = np.array([finv(fx), finv(fy), finv(fz)]) * D50_XYZ
    xyz65 = bradford(D50_XYZ, xyz_white(D65_XY)) @ xyz50
    return xyz65, XYZ_TO_REC2020 @ xyz65


def srgb_decode(hexstr):
    v = np.array([int(hexstr[i:i + 2], 16) for i in (1, 3, 5)]) / 255.0
    lin = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
    return XYZ_TO_REC2020 @ SRGB_TO_XYZ @ lin


# OKLab (Ottosson), XYZ D65 based.
_M1 = np.array([[0.8189330101, 0.3618667424, -0.1288597137],
                [0.0329845436, 0.9293118715, 0.0361456387],
                [0.0482003018, 0.2643662691, 0.6338517070]])
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])


def oklab_to_rec2020(lab):
    lms_ = lab @ np.linalg.inv(_M2).T
    xyz = (lms_ ** 3) @ np.linalg.inv(_M1).T
    return xyz @ XYZ_TO_REC2020.T


def frame(w, h, value):
    img = np.empty((h, w, 3), np.float32)
    img[:] = value
    return img


def colorchecker():
    p, g = 200, 24
    w, h = 6 * p + 7 * g, 4 * p + 5 * g
    img = frame(w, h, 0.03)
    patches = []
    for i, (name, L, a, b) in enumerate(CC2005):
        r, c = divmod(i, 6)
        x0, y0 = g + c * (p + g), g + r * (p + g)
        xyz, rgb = lab_d50_to_rec2020(L, a, b)
        img[y0:y0 + p, x0:x0 + p] = rgb
        patches.append(dict(index=i + 1, name=name, lab_d50=[L, a, b],
                            xyz_d65=[round(v, 6) for v in xyz],
                            rec2020_linear=[round(float(v), 6) for v in rgb],
                            rect=[x0, y0, p, p]))
    return img, dict(patches=patches, background=0.03,
                     reference="BabelColor ColorChecker 2005 average, Lab D50",
                     adaptation="Bradford D50->D65")


def grey_ramp():
    ev_px, lo, hi, band = 200, -10, 4, 200
    w = (hi - lo) * ev_px
    img = frame(w, 2 * band, 0.18)
    ev = lo + (np.arange(w) + 0.5) / ev_px
    img[:band] = (0.18 * 2.0 ** ev)[None, :, None]
    steps = []
    n = hi - lo + 1
    edges = np.linspace(0, w, n + 1).round().astype(int)
    for k in range(n):
        e = lo + k
        img[band:, edges[k]:edges[k + 1]] = 0.18 * 2.0 ** e
        steps.append(dict(ev=e, value=0.18 * 2.0 ** e,
                          rect=[int(edges[k]), band, int(edges[k + 1] - edges[k]), band]))
    return img, dict(continuous=dict(rows=[0, band], ev_of_x=f"{lo} + (x + 0.5) / {ev_px}",
                                     value="0.18 * 2^ev"), steps=steps)


def hue_wheel():
    n = 1200
    L = np.cbrt(0.18)  # OKLab L of a 0.18 neutral
    yy, xx = np.mgrid[0:n, 0:n] + 0.5
    dx, dy = (xx - n / 2) / (n / 2 * 0.96), (n / 2 - yy) / (n / 2 * 0.96)
    rad, hue = np.hypot(dx, dy), np.arctan2(dy, dx)
    # Rec.2020 gamut boundary per hue, by bisection on chroma.
    hues = np.linspace(-np.pi, np.pi, 3601)
    lo, hi = np.zeros_like(hues), np.full_like(hues, 0.5)
    for _ in range(40):
        mid = (lo + hi) / 2
        lab = np.stack([np.full_like(mid, L), mid * np.cos(hues), mid * np.sin(hues)], -1)
        inside = (oklab_to_rec2020(lab) >= 0).all(-1)
        lo, hi = np.where(inside, mid, lo), np.where(inside, hi, mid)
    cmax = np.interp(hue, hues, lo)
    C = np.clip(rad, 0, 1) * cmax
    lab = np.stack([np.full_like(C, L), C * np.cos(hue), C * np.sin(hue)], -1)
    img = oklab_to_rec2020(lab).astype(np.float32)
    img[rad > 1] = 0.18
    img = np.maximum(img, 0)  # boundary rounding only (> -1e-9)
    return img, dict(space="OKLab", L=float(L), centre=[n / 2, n / 2], radius_px=n / 2 * 0.96,
                     hue="angle atan2(up, right) = OKLab hue", chroma="radius * Cmax(hue)",
                     cmax_range=[float(lo.min()), float(lo.max())], background=0.18)


def zone_plate():
    n = 2048
    R = n / 2
    yy, xx = np.mgrid[0:n, 0:n] + 0.5 - R
    r2 = xx * xx + yy * yy
    img = 0.18 * (1 + 0.8 * np.cos(np.pi * r2 / (2 * R)))
    img = np.repeat(img[..., None].astype(np.float32), 3, -1)
    return img, dict(mean=0.18, amplitude=0.8 * 0.18, phase="pi r^2 / (2R)", R=R,
                     local_frequency="0.5 * r / R cycles/px (Nyquist at r = R; the corners "
                                     "beyond the inscribed circle alias by construction)")


def hard_edge():
    w, h, ss = 1600, 1200, 4
    dark, bright = 0.005, 4.0
    yy, xx = (np.mgrid[0:h * ss, 0:w * ss] + 0.5) / ss
    img = np.full((h * ss, w * ss), dark, np.float32)
    img[np.hypot(xx - 400, yy - 450) < 220] = bright
    right = xx >= 800
    img[right] = bright
    t = np.radians(5)
    u = (xx - 1200) * np.cos(t) + (yy - 450) * np.sin(t)
    v = -(xx - 1200) * np.sin(t) + (yy - 450) * np.cos(t)
    img[right & (np.abs(u) < 220) & (np.abs(v) < 220)] = dark
    img = img.reshape(h, ss, w, ss).mean((1, 3))
    band = slice(950, 1200)
    img[band] = 0.18
    lines = []
    x = 100
    for val in (bright, dark):
        for width in (1, 2, 4):
            img[band, x:x + width] = val
            lines.append(dict(x=x, width=width, value=val))
            x += 120
    img = np.repeat(img[..., None], 3, -1).astype(np.float32)
    return img, dict(dark=dark, bright=bright, disk=dict(centre=[400, 450], radius=220),
                     square=dict(centre=[1200, 450], half=220, rotation_deg=5),
                     grey_band=dict(rows=[950, 1200], value=0.18), lines=lines,
                     antialias="4x4 box supersampling")


def skin_tones():
    p, g = 220, 30
    sw = [("MST %d" % (i + 1), srgb_decode(hx), hx) for i, hx in enumerate(MST)]
    for name, L, a, b in CC2005[:2]:
        sw.append(("ColorChecker " + name, lab_d50_to_rec2020(L, a, b)[1], None))
    cols = 6
    w, h = cols * p + (cols + 1) * g, 2 * p + 3 * g
    img = frame(w, h, 0.18)
    out = []
    for i, (name, rgb, hx) in enumerate(sw):
        r, c = divmod(i, cols)
        x0, y0 = g + c * (p + g), g + r * (p + g)
        img[y0:y0 + p, x0:x0 + p] = rgb
        out.append(dict(name=name, srgb_hex=hx, rec2020_linear=[round(float(v), 6) for v in rgb],
                        rect=[x0, y0, p, p]))
    return img, dict(patches=out, background=0.18,
                     note="MST swatches are display sRGB values decoded to linear and "
                          "treated as scene reflectance; a convention, not a measurement")


def flat_grey():
    return frame(1024, 1024, 0.18), dict(value=0.18)


FRAMES = [("colorchecker", colorchecker), ("grey_ramp", grey_ramp),
          ("hue_wheel", hue_wheel), ("zone_plate", zone_plate),
          ("hard_edge", hard_edge), ("skin_tones", skin_tones), ("flat_grey", flat_grey)]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1:
        raise SystemExit(__doc__)
    out = argv[0]
    os.makedirs(out, exist_ok=True)
    for name, fn in FRAMES:
        img, truth = fn()
        assert np.isfinite(img).all() and img.min() >= 0
        write_lfi(os.path.join(out, name + ".lfi"), img)
        meta = dict(format="LFI1", generator=GEN_VERSION, name=name,
                    width=int(img.shape[1]), height=int(img.shape[0]), channels=3,
                    working_space="linear Rec.2020 (D65), scene-referred",
                    white_balance="neutral = R=G=B (as-shot neutral is D65)",
                    as_shot=dict(AS_SHOT, x=D65_XY[0], y=D65_XY[1],
                                 convention="DNG SDK (Robertson, kTintScale -3000)"),
                    recipe_hint=dict(asShotKelvin=AS_SHOT["kelvin"],
                                     asShotTint=AS_SHOT["tint"], captureISO=None),
                    truth=truth)
        with open(os.path.join(out, name + ".json"), "w") as f:
            json.dump(meta, f, indent=1)
            f.write("\n")
        print("%-14s %5dx%-5d min %.4g max %.4g" % (name, img.shape[1], img.shape[0],
                                                     img.min(), img.max()))


if __name__ == "__main__":
    sys.exit(main())
