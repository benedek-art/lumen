#!/usr/bin/env python3
"""WS-17 capture-sharpening (S4) measurement, lane T3. python3 + numpy + Pillow only.

USAGE
  python3 docs/quality/lanes/WS-18/measure_capture.py [--amount 100] [--radius R]
      [--scratch DIR] [--bin PATH] [--real] [--crops DIR] [--out result.json]

Every render goes through `lumen-render render --no-dither --iso N` at native size, ON
(capture defaults, or --amount/--radius) against OFF (`develop.detail.capture.auto=false`,
same everything else). S4 only runs with --iso, which is how lumen-render marks a RAW.
Metrics are on the sRGB-decoded (display-linear) PNG unless marked "encoded".

  edge     5-degree slanted step 0.05 -> 0.40 linear, 8x supersampled, Gaussian σ 1.0
           (blurred) and σ 0 (sharp), 512²: slanted-edge MTF50 (ESF 4x binned along the
           normal, LSF, Hann, |FFT|) and ENCODED overshoot/undershoot in % of the step.
  zone     corpus/synthetic/zone_plate.lfi (2048²) blurred σ 1.0: MTF50 =
           first f = 0.5 r/R where annulus modulation < 50 % of its low-f value.
  noise    flat 0.18 + N(0, σ) with σ the ISO 6400 seed-profile σ at 0.18 ("matched")
           and 1.6x it ("noisier"), rendered at --iso 6400: std ratio on/off.
  --real   1024² native crops (default /tmp/claude-0/ws18/crops: 6929_ivy, 6929_canopy at
           ISO 250; 2348_shelf, 2348_jacket at ISO 3200): mean gradient magnitude ratio
           on/off over the top-10 % gradient pixels of OFF (an acutance proxy), and the
           std ratio of a flat patch (2348_shelf rows 700-1000, cols 300-900 = the wall).
"""
import argparse, json, os, struct, subprocess
import numpy as np
from PIL import Image

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
DEF_BIN = os.path.join(REPO, ".build/x86_64-unknown-linux-gnu/release/lumen-render")

SHOT = [(100, 1e-5), (400, 4e-5), (1600, 1.6e-4), (6400, 6.4e-4), (25600, 2.56e-3)]
READ = [(100, 1e-8), (400, 6e-8), (1600, 4e-7), (6400, 3e-6), (25600, 2.4e-5)]


def profile_sigma(iso, y):
    lx = np.log2([i for i, _ in SHOT])
    a = 2 ** np.interp(np.log2(iso), lx, np.log2([v for _, v in SHOT]))
    b = 2 ** np.interp(np.log2(iso), lx, np.log2([v for _, v in READ]))
    return float(np.sqrt(a * y + b))


def read_lfi(p):
    with open(p, "rb") as f:
        mg, w, h, c = struct.unpack("<4sIII", f.read(16))
        return np.frombuffer(f.read(), np.float32).reshape(h, w, 3).copy()


def write_lfi(p, a):
    a = np.ascontiguousarray(a, np.float32)
    with open(p, "wb") as f:
        f.write(b"LFI1" + struct.pack("<3I", a.shape[1], a.shape[0], 3) + a.tobytes())


def gblur(p, s):
    if s <= 0:
        return p
    r = int(np.ceil(4 * s))
    k = np.exp(-np.arange(-r, r + 1) ** 2 / (2 * s * s))
    k /= k.sum()
    q = np.pad(p, r, mode="edge")
    q = np.apply_along_axis(lambda v: np.convolve(v, k, "valid"), 1, q)
    return np.apply_along_axis(lambda v: np.convolve(v, k, "valid"), 0, q)


def slanted(n=512, lo=0.05, hi=0.4, blur=1.0, ang=5, ss=8):
    yy, xx = (np.mgrid[0:n * ss, 0:n * ss] + 0.5) / ss
    t = np.radians(ang)
    u = (xx - n / 2) * np.cos(t) + (yy - n / 2) * np.sin(t)
    img = np.where(u > 0, hi, lo).reshape(n, ss, n, ss).mean((1, 3))
    return np.repeat(gblur(img, blur)[..., None], 3, -1)


def lum_png(p):
    a = np.asarray(Image.open(p), np.float64) / 255.0
    lin = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    return lin @ np.array([0.2126, 0.7152, 0.0722]), a @ np.array([0.2126, 0.7152, 0.0722])


def esf(y, ang=5, ss=4):
    n = y.shape[0]
    yy, xx = np.mgrid[0:n, 0:n] + 0.5
    t = np.radians(ang)
    u = (xx - n / 2) * np.cos(t) + (yy - n / 2) * np.sin(t)
    m = (np.abs(u) < 20) & (yy > n * 0.2) & (yy < n * 0.8)
    b = np.round(u[m] * ss).astype(int)
    i = b - b.min()
    return np.bincount(i, y[m]) / np.maximum(np.bincount(i), 1)


def mtf50(y, ss=4):
    e = esf(y, ss=ss)
    l = np.diff(e) * np.hanning(len(e) - 1)
    m = np.abs(np.fft.rfft(l))
    m /= m[0]
    f = np.fft.rfftfreq(len(l), 1 / ss)
    i = int(np.argmax(m < 0.5))
    return float(f[i - 1] + (m[i - 1] - 0.5) / (m[i - 1] - m[i]) * (f[i] - f[i - 1]))


def overshoot(enc):
    e = esf(enc)
    lo, hi = e[:12].mean(), e[-12:].mean()
    return (round(100 * (e.max() - hi) / (hi - lo), 2), round(100 * (lo - e.min()) / (hi - lo), 2))


def zp_mtf50(y):
    n = y.shape[0]
    R = n / 2
    yy, xx = np.mgrid[0:n, 0:n] + 0.5 - R
    f = 0.5 * np.hypot(xx, yy) / R
    fr = np.arange(0.02, 0.48, 0.01)
    mod = []
    for q in fr:
        v = y[np.abs(f - q) < 0.01]
        a, b = np.percentile(v, 99), np.percentile(v, 1)
        mod.append((a - b) / (a + b))
    mod = np.array(mod) / mod[0]
    i = int(np.argmax(mod < 0.5))
    return float(fr[i]) if i > 0 else float("nan")


def render(binp, src, out, iso, sets):
    args = [binp, "render", "--input", src, "--long-edge", "8192", "--no-dither",
            "--iso", str(iso), "--out", out]
    for s in sets:
        args += ["--set", s]
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--amount", type=float)
    ap.add_argument("--radius", type=float)
    ap.add_argument("--scratch", default="/tmp/claude-0/ws18/capture")
    ap.add_argument("--bin", default=DEF_BIN)
    ap.add_argument("--real", action="store_true")
    ap.add_argument("--crops", default="/tmp/claude-0/ws18/crops")
    ap.add_argument("--out")
    o = ap.parse_args()
    os.makedirs(o.scratch, exist_ok=True)
    on = []
    if o.amount is not None:
        on.append(f"develop.detail.capture.amount={o.amount}")
    if o.radius is not None:
        on.append(f"develop.detail.capture.radius={o.radius}")
    off = ["develop.detail.capture.auto=false"]
    S = lambda n: os.path.join(o.scratch, n)

    frames = {}
    if not os.path.exists(S("edge_b1.lfi")):
        write_lfi(S("edge_b1.lfi"), slanted(blur=1.0))
        write_lfi(S("edge_b0.lfi"), slanted(blur=0.0))
        zp = read_lfi(os.path.join(REPO, "corpus/synthetic/zone_plate.lfi"))[..., 0]
        write_lfi(S("zone_b1.lfi"), np.repeat(gblur(zp.astype(np.float64), 1.0)[..., None], 3, -1))
        rng = np.random.default_rng(18)
        sd = profile_sigma(6400, 0.18)
        for name, k in (("noise_matched", 1.0), ("noise_noisier", 1.6)):
            write_lfi(S(name + ".lfi"), 0.18 + rng.normal(0, sd * k, (512, 512, 1)) * np.ones(3))
    res = {"settings": on or ["defaults"]}
    for name, iso in (("edge_b1", 100), ("edge_b0", 100), ("zone_b1", 100),
                      ("noise_matched", 6400), ("noise_noisier", 6400)):
        render(o.bin, S(name + ".lfi"), S(name + "_on.png"), iso, on)
        render(o.bin, S(name + ".lfi"), S(name + "_off.png"), iso, off)
        frames[name] = (lum_png(S(name + "_on.png")), lum_png(S(name + "_off.png")))

    for name in ("edge_b1", "edge_b0"):
        (lin_on, enc_on), (lin_off, _) = frames[name]
        a, b = mtf50(lin_off), mtf50(lin_on)
        res[name] = {"mtf50_off": round(a, 4), "mtf50_on": round(b, 4), "gain": round(b / a, 3),
                     "overshoot_pct_bright_dark": overshoot(enc_on)}
    (lin_on, _), (lin_off, _) = frames["zone_b1"]
    a, b = zp_mtf50(lin_off), zp_mtf50(lin_on)
    res["zone_b1"] = {"mtf50_off": a, "mtf50_on": b, "gain": round(b / a, 3)}
    for name in ("noise_matched", "noise_noisier"):
        (_, enc_on), (_, enc_off) = frames[name]
        c = (slice(51, -51), slice(51, -51))
        res[name] = {"std_ratio": round(float(enc_on[c].std() / enc_off[c].std()), 4)}

    if o.real:
        for name, iso in (("6929_ivy", 250), ("6929_canopy", 250), ("2348_shelf", 3200),
                          ("2348_jacket", 3200)):
            src = os.path.join(o.crops, name + ".lfi")
            render(o.bin, src, S(name + "_on.png"), iso, on)
            render(o.bin, src, S(name + "_off.png"), iso, off)
            (lin_on, enc_on), (lin_off, enc_off) = lum_png(S(name + "_on.png")), lum_png(S(name + "_off.png"))
            g = lambda p: np.hypot(*np.gradient(p))
            go, gn = g(enc_off), g(enc_on)
            top = go > np.percentile(go, 90)
            r = {"acutance_ratio_top10pct": round(float(gn[top].mean() / go[top].mean()), 3)}
            if name == "2348_shelf":
                w = (slice(700, 1000), slice(300, 900))
                r["flat_wall_std_ratio"] = round(float(enc_on[w].std() / enc_off[w].std()), 4)
            res[name] = r
    txt = json.dumps(res, indent=1)
    print(txt)
    if o.out:
        open(o.out, "w").write(txt)


if __name__ == "__main__":
    main()
