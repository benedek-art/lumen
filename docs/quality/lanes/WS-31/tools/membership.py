"""Band membership measured through the engine (no knowledge of the band geometry).

membership_b(x) = dlog2Y_b / dlog2Y_all, where dlog2Y_b = log2 Y(band b lum=+d) - log2 Y(band b lum=-d)
and dlog2Y_all is the same with all 8 bands' lum at +/-d. With a partition of unity the
all-bands move is the uniform move, so the ratio is band b's weight at x (gate cancels).
Region "mass" sums numerator and denominator over the region's chromatic pixels.

usage: membership.py --bin lumen-render --corpus corpus --out DIR [--delta 5]
"""
import argparse, colorsys, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib import *

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True)
ap.add_argument("--corpus", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--delta", type=float, default=5)
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)
d = a.delta

# ---- patch frame: sRGB primaries/secondaries, CC skins, MST 1-10 ----
patches = []
for n, hh in zip(BANDS, [0, 30, 60, 120, 180, 240, 270, 300]):
    rgb = srgb_dec(np.array(colorsys.hsv_to_rgb(hh / 360, 1, 1)))
    patches.append(("sRGB " + n, n, 0.45 * (SRGB_TO_2020 @ rgb)))
cc = json.load(open(os.path.join(a.corpus, "synthetic", "colorchecker.json")))["truth"]["patches"]
for p in cc:
    if p["name"] in ("dark skin", "light skin"):
        patches.append(("CC " + p["name"], "orange", np.array(p["rec2020_linear"])))
sk = json.load(open(os.path.join(a.corpus, "synthetic", "skin_tones.json")))["truth"]["patches"]
for p in sk:
    if p["name"].startswith("MST"):
        patches.append((p["name"], "orange", np.array(p["rec2020_linear"])))
P, G = 48, 16
W = G + len(patches) * (P + G)
img = np.full((P + 2 * G, W, 3), 0.18, np.float32)
for i, (_, _, rgb) in enumerate(patches):
    x = G + i * (P + G)
    img[G:G + P, x:x + P] = rgb
pf = os.path.join(a.out, "patches.lfi")
write_lfi(pf, img)

def runs(lfi, tag, le, dither=False):
    outs = {}
    for s in (+1, -1):
        v = s * d
        outs[("all", s)] = render(a.bin, lfi, os.path.join(a.out, f"{tag}_all_{v:+g}.png"),
                                  [f"{key(b,'lum')}={v:g}" for b in range(8)], le, dither)
        for b in range(8):
            outs[(b, s)] = render(a.bin, lfi, os.path.join(a.out, f"{tag}_b{b}_{v:+g}.png"), [f"{key(b,'lum')}={v:g}"], le, dither)
    outs["base"] = render(a.bin, lfi, os.path.join(a.out, f"{tag}_base.png"), [], le, dither)
    return outs

def dlog(outs, k, sl):
    yp = lin_Y(png_lin(outs[(k, 1)])[sl]); ym = lin_Y(png_lin(outs[(k, -1)])[sl])
    return np.log2(np.maximum(yp, 1e-6)) - np.log2(np.maximum(ym, 1e-6))

res = {"patches": {}, "regions": {}}
o = runs(pf, "patch", 0, dither=True)  # ordered dither + 32x32 mean = sub-code precision
lines = []
for i, (name, want, _) in enumerate(patches):
    x = G + i * (P + G)
    sl = (slice(G + 8, G + P - 8), slice(x + 8, x + P - 8))
    da = dlog(o, "all", sl).mean()
    m = np.array([dlog(o, b, sl).mean() for b in range(8)]) / da if abs(da) > 1e-4 else np.full(8, np.nan)
    res["patches"][name] = dict(all_dEV=float(da), membership=[float(v) for v in m], sum=float(np.nansum(m)))
    top = np.argsort(-np.nan_to_num(m))[:2]
    lines.append(f"{name:22s} all-bands dEV {da:+.3f}  {want} {m[BANDS.index(want)]:.2f}  top {BANDS[top[0]]} {m[top[0]]:.2f} / {BANDS[top[1]]} {m[top[1]]:.2f}  sum {np.nansum(m):.3f}")

# ---- corpus regions (fractions x0,x1,y0,y1 of the frame; the audit's regions.py) ----
REG = {
    "sky 1840": ("1840_nikon-d850", 0.0, 1.0, 0.0, 0.07, "blue"),
    "sky 2545": ("2545_panasonic-dmc-gx85", 0.90, 1.0, 0.0, 0.10, "blue"),
    "sky 983": ("983_canon-eos-5d-mark-iv", 0.0, 0.25, 0.0, 0.06, "blue"),
    "foliage 6929 tree": ("6929_sony-ilce-7m4", 0.0, 1.0, 0.0, 0.45, "green"),
    "foliage 1840 field": ("1840_nikon-d850", 0.0, 1.0, 0.6, 0.95, "green"),
    "foliage 1569 sunlit": ("1569_panasonic-dmc-gx80", 0.55, 1.0, 0.0, 0.45, "green"),
}
for name, (f, x0, x1, y0, y1, want) in REG.items():
    src = os.path.join(a.corpus, "lfi", f + ".lfi")
    if not os.path.exists(src):
        lines.append(f"{name}: MISSING {src}"); continue
    im = read_lfi(src); H, Wd, _ = im.shape
    crop = np.array(im[int(y0 * H):int(y1 * H), int(x0 * Wd):int(x1 * Wd)])
    cf = os.path.join(a.out, "reg_" + name.replace(" ", "_") + ".lfi")
    write_lfi(cf, crop, json.load(open(src[:-4] + ".json")).get("recipe_hint"))
    import shutil; shutil.copy(src[:-4] + ".json", cf[:-4] + ".json")
    o = runs(cf, "reg_" + name.replace(" ", "_"), None)
    base = png_lab(o["base"]); _, C, _ = lch(base)
    sl = (slice(None), slice(None))
    msk = C > 0.02
    da = dlog(o, "all", sl)[msk].sum()
    m = np.array([dlog(o, b, sl)[msk].sum() for b in range(8)]) / da
    res["regions"][name] = dict(membership=[float(v) for v in m], chromatic_pct=float(msk.mean() * 100))
    top = np.argsort(-m)[:2]
    lines.append(f"{name:22s} chromatic {msk.mean()*100:4.1f}%  {want} {m[BANDS.index(want)]:.2f}  yellow {m[2]:.2f}  top {BANDS[top[0]]} {m[top[0]]:.2f} / {BANDS[top[1]]} {m[top[1]]:.2f}  sum {m.sum():.3f}")

# ---- verdicts ----
pr = res["patches"]; rg = res["regions"]
def mem(dct, n, b): return dct[n]["membership"][BANDS.index(b)]
checks = []
checks.append(("S1 sRGB primaries/secondaries >=0.80 own band",
               min(mem(pr, "sRGB " + n, n) for n in BANDS) >= 0.80, min(mem(pr, "sRGB " + n, n) for n in BANDS)))
sk_names = ["CC dark skin", "CC light skin"] + [f"MST {i}" for i in range(5, 9)]
checks.append(("S2 CC skins + MST 5-8 >=0.60 orange", min(mem(pr, n, "orange") for n in sk_names) >= 0.60,
               min(mem(pr, n, "orange") for n in sk_names)))
sk34 = ["MST 3", "MST 4"]
checks.append(("S2b MST 3-4 >=0.40 orange", min(mem(pr, n, "orange") for n in sk34) >= 0.40,
               min(mem(pr, n, "orange") for n in sk34)))
sk_ = [n for n in rg if n.startswith("sky")]
checks.append(("S3 skies >=0.90 blue", min(mem(rg, n, "blue") for n in sk_) >= 0.90, min(mem(rg, n, "blue") for n in sk_)))
fo = [n for n in rg if n.startswith("foliage")]
checks.append(("S4 foliage green >0.50", min(mem(rg, n, "green") for n in fo) > 0.50, min(mem(rg, n, "green") for n in fo)))
checks.append(("S4 foliage green+yellow >=0.90", min(mem(rg, n, "green") + mem(rg, n, "yellow") for n in fo) >= 0.90,
               min(mem(rg, n, "green") + mem(rg, n, "yellow") for n in fo)))
sums = [v["sum"] for v in pr.values() if abs(v["all_dEV"]) > 0.1] + [sum(v["membership"]) for v in rg.values()]
checks.append(("S5 engine partition sum within 1+/-0.05", max(abs(s - 1) for s in sums) <= 0.05, max(abs(s - 1) for s in sums)))
print("\n".join(lines))
for n, ok, v in checks:
    print(f"{verdict(ok)}  {n}: {v:.3f}")
json.dump(res, open(os.path.join(a.out, "membership.json"), "w"), indent=1)
