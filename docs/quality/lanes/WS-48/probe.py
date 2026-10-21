#!/usr/bin/env python3
"""WS-47/48 range-mask probe.

Rasterizes Luminance Range and Colour Range components over corpus frames through the
real `MaskRaster.combine` (Tests/LumenCoreTests/RangeMaskProbeTests.swift), writes the
alpha as a greyscale PNG and measures it against the hand-defined regions in regions.py.

    python3 docs/quality/lanes/WS-48/probe.py OUTDIR [--only name,name] [--no-build]
                                                     [--measure-only]

Metrics (alpha at the corpus' 2400 px long edge):
  precision  TP / (TP + FP) over the labelled pixels, alpha > 0.5
  recall     TP / |pos|
  speckle    8-connected islands of alpha > 0.5 plus holes of alpha <= 0.5, each smaller
             than 25 px, per megapixel
  hf         1000 x mean |alpha - Gaussian(alpha, sigma 2 px)|: grain in the matte
  hardflat   pixels per MP where |grad alpha| > 0.35/px while the picture itself is flat
             there (OKLab gradient of the sigma-1.5 blurred frame < 0.004/px): a cliff the
             selection made that the photograph does not have
"""
import argparse, json, os, struct, subprocess, sys
import numpy as np
from PIL import Image
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "../../../.."))
sys.path.insert(0, os.path.join(ROOT, "scripts/proof"))
sys.path.insert(0, HERE)
import decode_raw  # noqa: E402
from regions import R  # noqa: E402

LFI = {
    "8559": "8559_nikon-z-fc", "3437": "3437_canon-eos-rebel-t7i",
    "983": "983_canon-eos-5d-mark-iv", "2062": "2062_canon-eos-kiss-x9",
    "2348": "2348_panasonic-dc-g9",
}


def nev(ev):
    return (ev + 10) / 14


def sample(img, x, y, r=2):
    """The eyedropper: a 5 x 5 mean, as `sampleMaskStageInput` takes it."""
    h, w, _ = img.shape
    cx, cy = int(x * w), int(y * h)
    return [float(v) for v in img[cy - r:cy + r + 1, cx - r:cx + r + 1].reshape(-1, 3).mean(0)]


def cases(imgs):
    c = []
    for refine in (25, 50, 75):
        c.append(("cr_8559_r%d" % refine, "8559", "8559",
                  {"kind": "colorRange", "samples": [sample(imgs["8559"], .44, .80)],
                   "rangeAmount": refine}))
    c.append(("cr_3437_r50", "3437", "3437",
              {"kind": "colorRange", "samples": [sample(imgs["3437"], .10, .95)], "rangeAmount": 50}))
    c.append(("cr_3437_2s_r50", "3437", "3437",
              {"kind": "colorRange", "samples": [sample(imgs["3437"], .10, .95),
                                                 sample(imgs["3437"], .55, .55)], "rangeAmount": 50}))
    c.append(("cr_2062_r50", "2062", "2062",
              {"kind": "colorRange", "samples": [sample(imgs["2062"], .70, .44)], "rangeAmount": 50}))
    c.append(("cr_2348red_r50", "2348", "2348red",
              {"kind": "colorRange", "samples": [sample(imgs["2348"], .425, .495)], "rangeAmount": 50}))
    for smooth in (0, 50, 100):
        c.append(("lr_983_s%d" % smooth, "983", "983",
                  {"kind": "lumaRange", "lo": nev(-3.6), "hi": 1.0, "smooth": smooth}))
    c.append(("lr_2348_s50", "2348", "2348",
              {"kind": "lumaRange", "lo": 0.0, "hi": nev(-4.6), "smooth": 50}))
    c.append(("lr_2348_s0", "2348", "2348",
              {"kind": "lumaRange", "lo": 0.0, "hi": nev(-4.6), "smooth": 0}))
    return c


def oklab(rgb):
    # linear Rec.2020 -> XYZ -> LMS (OKLab M1) -> cube root -> Lab; good enough for a
    # "is the picture flat here" test.
    m = np.array([[0.636958, 0.144617, 0.168881], [0.262700, 0.677998, 0.059302],
                  [0.0, 0.028073, 1.060985]])
    m1 = np.array([[0.8189330101, 0.3618667424, -0.1288597137],
                   [0.0329845436, 0.9293118715, 0.0361456387],
                   [0.0482003018, 0.2643662691, 0.6338517070]])
    m2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                   [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]])
    lms = np.cbrt(np.clip(rgb @ (m1 @ m).T, 0, None))
    return lms @ m2.T


def measure(alpha, img, reg):
    h, w = alpha.shape
    sel = alpha > 0.5

    def mask(rects):
        m = np.zeros_like(sel)
        for x0, y0, x1, y1 in rects:
            m[int(y0 * h):int(y1 * h), int(x0 * w):int(x1 * w)] = True
        return m
    pos, neg = mask(reg["pos"]), mask(reg["neg"])
    tp = (sel & pos).sum(); fp = (sel & neg).sum()
    precision = tp / max(tp + fp, 1); recall = tp / max(pos.sum(), 1)
    eight = np.ones((3, 3))
    small = 0
    for m in (sel, ~sel):
        lab, n = ndimage.label(m, structure=eight)
        if n:
            sizes = np.bincount(lab.ravel())[1:]
            small += int((sizes < 25).sum())
    mp = h * w / 1e6
    hf = 1000 * np.abs(alpha - ndimage.gaussian_filter(alpha, 2)).mean()
    gy, gx = np.gradient(alpha)
    ga = np.hypot(gx, gy)
    lab = oklab(ndimage.gaussian_filter(img, (1.5, 1.5, 0)))
    gi = np.zeros((h, w))
    for k in range(3):
        a, b = np.gradient(lab[..., k]); gi += a * a + b * b
    gi = np.sqrt(gi)
    hardflat = int(((ga > 0.35) & (gi < 0.004)).sum())
    return {"precision": round(float(precision), 4), "recall": round(float(recall), 4),
            "speckle_per_mp": round(small / mp, 1), "hf": round(float(hf), 2),
            "hardflat_per_mp": round(hardflat / mp, 1),
            "mean_alpha": round(float(alpha.mean()), 4)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--only", default="")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--measure-only", action="store_true",
                    help="re-measure the .f32 files already in OUTDIR (e.g. a baseline)")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    imgs = {k: decode_raw.read_lfi(os.path.join(ROOT, "corpus/lfi/%s.lfi" % v)) for k, v in LFI.items()}
    want = set(filter(None, a.only.split(",")))
    todo = [c for c in cases(imgs) if not want or c[0] in want]
    jobs = []
    for name, img, _, comp in todo:
        comp = dict({"op": "add", "amount": 100, "invert": False}, **comp)
        jobs.append({"input": os.path.join(ROOT, "corpus/lfi/%s.lfi" % LFI[img]),
                     "out": os.path.join(a.out, name + ".f32"), "component": comp})
    jp = os.path.join(a.out, "jobs.json")
    json.dump(jobs, open(jp, "w"), indent=1)
    cmd = ["swift", "test", "-c", "release", "-Xswiftc", "-enable-testing",
           "--filter", "RangeMaskProbeTests"]
    if a.no_build:
        cmd.insert(2, "--skip-build")
    env = dict(os.environ, LUMEN_MASK_PROBE=jp)
    if not a.measure_only:
        r = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
        for line in r.stdout.splitlines():
            if line.startswith("probe "):
                print(line)
        if r.returncode:
            print(r.stdout[-3000:], r.stderr[-3000:]); sys.exit(1)
    results = {}
    for name, img, reg, comp in todo:
        raw = open(os.path.join(a.out, name + ".f32"), "rb").read()
        w, h = struct.unpack("<II", raw[:8])
        alpha = np.frombuffer(raw[8:], dtype="<f4").reshape(h, w).astype(np.float64)
        Image.fromarray(np.round(np.clip(alpha, 0, 1) * 255).astype(np.uint8)).save(
            os.path.join(a.out, name + ".png"))
        results[name] = measure(alpha, imgs[img].astype(np.float64), R[reg])
        print(name, results[name])
    json.dump(results, open(os.path.join(a.out, "metrics.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
