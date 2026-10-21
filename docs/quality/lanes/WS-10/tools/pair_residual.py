#!/usr/bin/env python3
"""Exposure residual of the 6929/6933 pair, before and after Match Total Exposures.

6929 is full frame, 6933 the same scene in APS-C crop mode (1.5x) and re-aimed, so 6933
is located inside 6929 by normalized cross-correlation of log luminance (6933 resized to
1/1.5 of 6929's width, exhaustive offset search) and the matched regions are compared,
both scene-linear from the decode.
The match is ExposureMatch's arithmetic on the manifest EXIF (shutter, aperture, ISO).
Prints the median and log-mean luminance difference in stops. Pass the slider value
`lumen-render match` wrote for 6933 to also report the measured match's residual.
"""
import json, math, os, sys
import numpy as np
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../../../../../scripts/proof"))
from decode_raw import read_lfi  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../../../.."))
W = np.array([0.2627, 0.6780, 0.0593])  # Rec.2020 luminance


def captured(e):
    num, den = e["shutter"].split("/") if "/" in e["shutter"] else (e["shutter"], 1)
    t = float(num) / float(den)
    return math.log2(t * e["iso"] / 100 / (e["aperture"] ** 2))


def stats(img):
    y = img @ W
    y = y[(y > 1e-4) & (y < 0.98)]  # drop black floor and sensor clip
    return math.log2(np.median(y)), float(np.mean(np.log2(y)))


def box(img, f):
    h, w = img.shape[0] // f * f, img.shape[1] // f * f
    return img[:h, :w].reshape(h // f, f, w // f, f, -1).mean(axis=(1, 3))


def register(ref, oth, scale=1.5):
    """6933's footprint in 6929: (crop of ref, oth resampled to that crop, ncc)."""
    f = 8
    r = np.log2(np.maximum(box(ref, f) @ W, 1e-4))
    oh, ow = int(r.shape[0] / scale), int(r.shape[1] / scale)
    small = box(oth, int(round(oth.shape[1] / ow)))
    o = np.log2(np.maximum(small @ W, 1e-4))[:oh, :ow]
    oh, ow = o.shape
    o = (o - o.mean()) / o.std()
    best = (-2, 0, 0)
    for y in range(0, r.shape[0] - oh + 1):
        for x in range(0, r.shape[1] - ow + 1):
            win = r[y:y + oh, x:x + ow]
            ncc = float(((win - win.mean()) / (win.std() + 1e-9) * o).mean())
            if ncc > best[0]:
                best = (ncc, y, x)
    ncc, y, x = best
    crop = box(ref, f)[y:y + oh, x:x + ow]
    return crop, small[:oh, :ow], ncc


def main():
    measured = float(sys.argv[1]) if len(sys.argv) > 1 else None  # matched slider, measured
    m = json.load(open(os.path.join(ROOT, "scripts/proof/corpus.manifest.json")))
    ex = {f["id"]: f for f in m["files"] if f["id"] in ("6929", "6933")}
    ref = read_lfi(os.path.join(ROOT, "corpus/lfi/6929_sony-ilce-7m4.lfi"))
    oth = read_lfi(os.path.join(ROOT, "corpus/lfi/6933_sony-ilce-7m4.lfi"))
    crop, oth, score = register(ref, oth)
    (rm, rl), (om, ol) = stats(crop), stats(oth)
    brighter = captured(ex["6933"]) - captured(ex["6929"])
    slider = round(-brighter, 2)  # ExposureMatch.plan with the reference at 0
    out = {
        "registrationNCC": round(score, 3),
        "stopsBrighterByExif": round(brighter, 3),
        "matchedExposure6933": slider,
        "residualBeforeMedianEV": round(om - rm, 3),
        "residualBeforeLogMeanEV": round(ol - rl, 3),
        "residualAfterMedianEV": round(om + slider - rm, 3),
        "residualAfterLogMeanEV": round(ol + slider - rl, 3),
    }
    if measured is not None:
        out["matchedExposure6933Measured"] = measured
        out["residualAfterMeasuredMedianEV"] = round(om + measured - rm, 3)
        out["residualAfterMeasuredLogMeanEV"] = round(ol + measured - rl, 3)
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
