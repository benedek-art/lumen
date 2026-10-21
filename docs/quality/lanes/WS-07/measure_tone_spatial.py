#!/usr/bin/env python3
"""WS-07 measurements: halo, gradient reversal and local-contrast retention of the S7
tone stage (Highlights/Shadows/Whites/Blacks through the guided mask), from renders.

    measure_tone_spatial.py halo  IN.lfi BASE.png TONED.png [--radius R] [--json out]
    measure_tone_spatial.py scale SMALL.png LARGE.png BASE_SMALL.png BASE_LARGE.png
    measure_tone_spatial.py mksynth OUTDIR          (step_*.lfi, noise04.lfi)
    measure_tone_spatial.py step BASE.png TONED.png

step: the synthetic vertical step edges (0.75, 1.5, 3, 5 EV, straddling shadows and
midtones, 1600x400). Along the middle row g(x) = log2(Y_toned/Y_base); far = g 30 px
from either border. peak = max |g - far(side)| at >= 3 px from the edge, width = the
largest distance with a deviation > 0.05 EV, reversals = 1-code downward steps of the
toned row (the input is a monotone step, so any is a counter-gradient).

halo: the input's own log2 luminance (area-downsampled to the render size) splits the
frame into dark and bright by Otsu, with a 1 EV dead band around the split. For every
classified pixel g = log2(Y_toned / Y_base) is the gain the tone stage gave it, as seen
on the display. Far from the other class (d > 4R) g is a function of the pixel's own
level only; that function f is fitted (binned median over the input EV). The halo is
what is left near an edge: h(d) = median over pixels at distance d of g - f(L_in).
  overshoot = max |h(d)| for 3 <= d <= 4R (px), width = the largest d with |h| > 0.05 EV.
Reported separately for the bright side (what Shadows lifts across the edge onto the
sky) and the dark side (what Highlights pulls down onto the treeline).

reversal: sign of the horizontal/vertical difference of encoded luminance, toned vs
base, where the base step is >= 3 codes; a pixel reverses if the toned step is >= 1 code
the other way. Fraction of the qualifying steps.

detail: std of (L - gauss_s(L)) on encoded luminance, toned / base, s = 1.5 and 12 px
(scaled by long edge / 1600). 1.0 = local contrast untouched by the stage.

noise: a flat -1 EV frame under +-0.4 EV per-pixel noise (ISO 6400 shadows before
denoise). gainStd5pxEV = spatial std of the 5x5-averaged tone gain, i.e. how much of the
grain the mask follows; detail as above (the grain is the detail here).

scale: the large renders area-downsampled to the small one's size. The tone stage's
gain at each size is log2(toned / base); the report is |gain_small - gain_large| per
pixel (mean, p99, max), so resampling differences that exist without the tone stage
are not charged to it.
"""
import argparse, json, os, sys
import numpy as np
from PIL import Image
from scipy import ndimage

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "..", "scripts", "proof"))
from decode_raw import read_lfi, REC2020_TO_XYZ, area_downsample  # noqa: E402


def png_lum(path):
    a = np.asarray(Image.open(path).convert("RGB")).astype(np.float64) / 255.0
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    y = lin @ np.array([0.2126, 0.7152, 0.0722])
    enc = a @ np.array([0.2126, 0.7152, 0.0722])
    return y, enc * 255.0


def otsu(v):
    hist, edges = np.histogram(v, 256)
    c = (edges[:-1] + edges[1:]) / 2
    w = np.cumsum(hist); m = np.cumsum(hist * c)
    wt, mt = w[-1], m[-1]
    b = (mt * w - m * wt) ** 2 / np.maximum(w * (wt - w), 1)
    return c[np.argmax(b)]


def halo(a):
    yb, eb = png_lum(a.base); yt, et = png_lum(a.toned)
    h, w = yb.shape
    img = area_downsample(read_lfi(a.input).astype(np.float32), max(h, w))
    lin = img @ REC2020_TO_XYZ[1].astype(np.float32)
    L = np.log2(np.clip(lin, 1e-6, None) / 0.18)
    assert L.shape == yb.shape, (L.shape, yb.shape)
    R = a.radius or max(int(max(h, w) * 0.02), 2)
    t = a.split if a.split is not None else otsu(L[np.isfinite(L)])
    dark = L < t - 0.5; bright = L > t + 0.5
    ok = (yb > 1.5 / 255 / 12.92) & (yt > 1.5 / 255 / 12.92) & (yb < 0.99) & (yt < 0.99)
    g = np.log2(np.clip(yt, 1e-7, None) / np.clip(yb, 1e-7, None))
    out = {"radius": R, "otsuEV": float(t)}
    for name, cls, other in (("bright", bright, dark), ("dark", dark, bright)):
        d = ndimage.distance_transform_edt(~other)
        sel = cls & ok
        far = sel & (d > 4 * R)
        if far.sum() < 100:
            out[name] = None; continue
        bins = np.linspace(L[sel].min(), L[sel].max() + 1e-9, 41)
        idx = np.clip(np.digitize(L, bins) - 1, 0, 39)
        f = np.full(40, np.nan)
        for i in range(40):
            m = far & (idx == i)
            if m.sum() >= 20: f[i] = np.median(g[m])
        fi = np.arange(40); good = ~np.isnan(f)
        f = np.interp(fi, fi[good], f[good])
        resid = g - f[idx]
        valid = sel & (d >= 1) & (d <= 4 * R) & (ok)
        # Only pixels whose own level was seen far from edges (no extrapolation).
        lo, hi = L[far].min(), L[far].max()
        valid &= (L >= lo) & (L <= hi)
        prof = []
        for dd in range(1, 4 * R + 1):
            m = valid & (np.rint(d) == dd)
            prof.append(float(np.median(resid[m])) if m.sum() >= 20 else float("nan"))
        prof = np.array(prof)
        dist = np.arange(1, 4 * R + 1)
        core = (dist >= 3) & ~np.isnan(prof)
        over = float(np.max(np.abs(prof[core]))) if core.any() else float("nan")
        big = dist[(np.abs(np.nan_to_num(prof)) > 0.05)]
        out[name] = {"overshootEV": over,
                     "signedPeakEV": float(prof[core][np.argmax(np.abs(prof[core]))]) if core.any() else None,
                     "widthPx": int(big.max()) if big.size else 0,
                     "widthOverR": (int(big.max()) / R) if big.size else 0.0,
                     "profile": [None if np.isnan(v) else round(float(v), 4) for v in prof]}
    # Gradient reversal on encoded luminance.
    rev = 0; qual = 0
    for ax in (0, 1):
        db = np.diff(eb, axis=ax); dt = np.diff(et, axis=ax)
        q = np.abs(db) >= 3
        qual += int(q.sum()); rev += int((q & (np.sign(dt) == -np.sign(db)) & (np.abs(dt) >= 1)).sum())
    out["reversal"] = {"fraction": rev / max(qual, 1), "count": rev, "steps": qual}
    s0 = max(h, w) / 1600.0
    det = {}
    for s in (1.5, 12.0):
        sb = np.std(eb - ndimage.gaussian_filter(eb, s * s0))
        st = np.std(et - ndimage.gaussian_filter(et, s * s0))
        det["s%g" % s] = float(st / max(sb, 1e-9))
    out["detail"] = det
    out["spread"] = {"base_p95_p5": float(np.percentile(eb, 95) - np.percentile(eb, 5)),
                     "toned_p95_p5": float(np.percentile(et, 95) - np.percentile(et, 5))}
    return out


def scale(a):
    ys, _ = png_lum(a.small); yl, _ = png_lum(a.large)
    bs, _ = png_lum(a.base_small); bl, _ = png_lum(a.base_large)
    def down(x, ref):
        return area_downsample(np.repeat(x[..., None], 3, 2).astype(np.float32), max(ref.shape))[..., 0]
    yl2, bl2 = down(yl, ys), down(bl, ys)
    assert yl2.shape == ys.shape, (yl2.shape, ys.shape)
    lo, hi = 2 / 255 / 12.92, 0.99
    m = ((ys > lo) & (yl2 > lo) & (bs > lo) & (bl2 > lo)
         & (ys < hi) & (yl2 < hi) & (bs < hi) & (bl2 < hi))
    # The tone stage's own effect at each size, as the display shows it: gain in EV of
    # the toned render over the untoned one. Preview and full size must agree on it.
    gs = np.log2(ys[m] / bs[m]); gl = np.log2(yl2[m] / bl2[m])
    e = np.abs(gs - gl)
    return {"gainDiffEV": {"mean": float(e.mean()), "p99": float(np.percentile(e, 99)),
                           "max": float(e.max())},
            "meanGainEV": {"small": float(gs.mean()), "large": float(gl.mean())},
            "pixels": int(m.sum())}


def mksynth(a):
    import struct
    os.makedirs(a.outdir, exist_ok=True)
    def write(name, ev):
        h, w = ev.shape
        img = np.repeat((0.18 * 2.0 ** ev).astype(np.float32)[..., None], 3, 2)
        with open(os.path.join(a.outdir, name + ".lfi"), "wb") as f:
            f.write(b"LFI1" + struct.pack("<III", w, h, 3)); f.write(img.astype("<f4").tobytes())
    w, h = 1600, 400
    for d in (0.75, 1.5, 3.0, 5.0):
        lo = -1.0 - d / 2 * 1.4
        write("step_%s" % d, np.where(np.arange(w)[None, :] < w // 2, lo, lo + d) * np.ones((h, 1)))
    rng = np.random.default_rng(7)
    write("noise04", -1 + (rng.random((h, w)) - 0.5) * 0.8)
    return {"wrote": sorted(os.listdir(a.outdir))}


def step(a):
    yb, _ = png_lum(a.base); yt, et = png_lum(a.toned)
    r = yb.shape[0] // 2
    g = np.log2(yt[r] / yb[r]); e = et[r]; w = len(g); c = w // 2
    left, right = g[30], g[w - 30]
    dist = np.abs(np.arange(w) - c + 0.5)
    dev = g - np.where(np.arange(w) < c, left, right)
    core = dist >= 3
    i = int(np.argmax(np.abs(dev) * core))
    big = dist[np.abs(dev) > 0.05]
    return {"farGainEV": [float(left), float(right)], "peakEV": float(dev[i]),
            "peakAtPx": float(dist[i]), "widthPx": float(big.max()) if big.size else 0.0,
            "reversals": int((np.diff(e) <= -1).sum())}


def noise(a):
    yb, eb = png_lum(a.base); yt, et = png_lum(a.toned)
    g = np.log2(yt / yb)[20:-20, 20:-20]
    gs = ndimage.uniform_filter(np.log2(yt / yb), 5)[20:-20, 20:-20]
    d = np.std(et - ndimage.gaussian_filter(et, 1.5)) / np.std(eb - ndimage.gaussian_filter(eb, 1.5))
    return {"gainStdEV": float(g.std()), "gainStd5pxEV": float(gs.std()), "detail": float(d)}


def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("halo"); p.add_argument("input"); p.add_argument("base"); p.add_argument("toned")
    p.add_argument("--radius", type=int, default=0); p.add_argument("--json")
    p.add_argument("--split", type=float, default=None, help="dark/bright split in EV (default Otsu)")
    q = sp.add_parser("scale"); q.add_argument("small"); q.add_argument("large")
    q.add_argument("base_small"); q.add_argument("base_large"); q.add_argument("--json")
    m = sp.add_parser("mksynth"); m.add_argument("outdir"); m.add_argument("--json")
    for name in ("step", "noise"):
        t = sp.add_parser(name); t.add_argument("base"); t.add_argument("toned"); t.add_argument("--json")
    a = ap.parse_args()
    r = {"halo": halo, "scale": scale, "mksynth": mksynth, "step": step, "noise": noise}[a.cmd](a)
    if a.json:
        json.dump(r, open(a.json, "w"), indent=1)
    brief = {k: ({kk: vv for kk, vv in v.items() if kk != "profile"} if isinstance(v, dict) else v)
             for k, v in r.items()}
    print(json.dumps(brief, indent=1))


if __name__ == "__main__":
    main()
