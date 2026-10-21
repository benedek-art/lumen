"""Greys, low chroma, Sat +100 roll-off and identity.

combos: all 24 sliders +100, all -100, alternating +/-100 (the audit's greys.py), plus each
single slider at +/-100 (48 renders per frame) for grey_ramp and flat_grey.

usage: neutrals.py --bin lumen-render --corpus corpus --out DIR
"""
import argparse, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib import *

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True); ap.add_argument("--corpus", required=True)
ap.add_argument("--out", required=True)
a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
S = os.path.join(a.corpus, "synthetic")
COMPS = ("hue", "sat", "lum")
combos = {"all+100": [f"{key(b,c)}=100" for b in range(8) for c in COMPS],
          "all-100": [f"{key(b,c)}=-100" for b in range(8) for c in COMPS],
          "alt": [f"{key(b,c)}={100 if (b + i) % 2 else -100}" for b in range(8) for i, c in enumerate(COMPS)]}
single = {f"b{b}{c}{v:+d}": [f"{key(b,c)}={v}"] for b in range(8) for c in COMPS for v in (100, -100)}
def le(f): return 1200 if f == "hue_wheel" else 0
res = {}
ccp = json.load(open(os.path.join(S, "colorchecker.json")))["truth"]["patches"]
for f in ("grey_ramp", "flat_grey", "colorchecker", "hue_wheel"):
    src = os.path.join(S, f + ".lfi")
    bp = render(a.bin, src, os.path.join(a.out, f"{f}_base.png"), [], le(f))
    bc = png_codes(bp); bl = png_lin(bp); blab = to_lab(bl, "srgb"); _, Cb, _ = lch(blab)
    todo = dict(combos)
    if f in ("grey_ramp", "flat_grey"):
        todo.update(single)
    r = {}
    for k, s in todo.items():
        p = render(a.bin, src, os.path.join(a.out, f"{f}_{k}.png"), s, le(f))
        c = png_codes(p); l = png_lin(p); lab = to_lab(l, "srgb")
        dok = np.linalg.norm(lab - blab, axis=-1)
        neu = Cb < 0.01; low = (Cb >= 0.01) & (Cb < 0.02)
        if f == "colorchecker":   # the six grey patches' interiors, not patch borders
            neu = np.zeros_like(neu)
            for pp in ccp:
                if pp["name"].split()[0] in ("white", "neutral", "black"):
                    x, y, w, h = pp["rect"]; neu[y + 20:y + h - 20, x + 20:x + w - 20] = True
        r[k] = dict(maxcode=int(np.abs(c - bc).max()),
                    maxcode_neutral=int(np.abs(c - bc)[neu].max()) if neu.any() else 0,
                    de00_neutral=float(np.percentile(de2000(bl[neu], l[neu]), 99.9)) if neu.any() else 0.0,
                    dok_low=float(dok[low].max()) if low.any() else 0.0,
                    crushed_pct=float((c == 0).any(-1).mean() * 100),
                    finite=bool(np.isfinite(l).all()))
    res[f] = r
    print(f, {k: (v["maxcode_neutral"], round(v["de00_neutral"], 3), round(v["dok_low"], 4), round(v["crushed_pct"], 2)) for k, v in r.items() if k in combos})

# Sat +100 on ColorChecker chromatic patches: keep a real boost
cc = json.load(open(os.path.join(S, "colorchecker.json")))["truth"]["patches"]
b = png_lin(os.path.join(a.out, "colorchecker_base.png")); o = png_lin(os.path.join(a.out, "colorchecker_all+100.png"))
p100 = render(a.bin, os.path.join(S, "colorchecker.lfi"), os.path.join(a.out, "colorchecker_allsat+100.png"),
              [f"{key(bb,'sat')}=100" for bb in range(8)], 0)
o = png_lin(p100); oc = png_codes(p100)
gains = []
for p in cc:
    x, y, w, h = p["rect"]; s = (slice(y + 20, y + h - 20), slice(x + 20, x + w - 20))
    _, C0, _ = lch(to_lab(b[s].reshape(-1, 3).mean(0), "srgb")); _, C1, _ = lch(to_lab(o[s].reshape(-1, 3).mean(0), "srgb"))
    if C0 > 0.05: gains.append(C1 / C0)
crushed = float((oc == 0).any(-1).mean() * 100)
gp = [g for g in gains]
print(f"CC all Sat+100: crushed {crushed:.2f}%  chroma gain median {np.median(gp):.2f} min {np.min(gp):.2f}")

grey = [res[f][k] for f in ("grey_ramp", "flat_grey") for k in res[f]]
cn = [res["colorchecker"][k] for k in combos]
checks = [
    ("N1 grey_ramp/flat_grey: every single slider and combo at +/-100 moves neutrals <= 1 code", max(g["maxcode_neutral"] for g in grey) <= 1, max(g["maxcode_neutral"] for g in grey)),
    ("N2 ... and p99.9 dE2000 < 0.5", max(g["de00_neutral"] for g in grey) < 0.5, max(g["de00_neutral"] for g in grey)),
    ("N3 ColorChecker six grey patches: p99.9 dE2000 <= 1.5 under the 3 combos (no regression)", max(g["de00_neutral"] for g in cn) <= 1.5, max(g["de00_neutral"] for g in cn)),
    ("N4 hue_wheel 0.01<=C<0.02 max dOK <= 0.03 under the 3 combos", max(res["hue_wheel"][k]["dok_low"] for k in combos) <= 0.03, max(res["hue_wheel"][k]["dok_low"] for k in combos)),
    ("X1 every render finite", all(v["finite"] for f in res for v in res[f].values()), 0),
    ("X2 CC all Sat +100 pixels with a code-0 channel <= 5%", crushed <= 5.0, crushed),
    ("X3 CC all Sat +100 median chroma gain (patches C>0.05) >= 1.4", float(np.median(gp)) >= 1.4, float(np.median(gp))),
]
# identity
ident = []
for f, src in (("hue_wheel", os.path.join(S, "hue_wheel.lfi")), ("colorchecker", os.path.join(S, "colorchecker.lfi")),
               ("2545", os.path.join(a.corpus, "lfi", "2545_panasonic-dmc-gx85.lfi"))):
    l = 1200 if f != "colorchecker" else 0
    p0 = render(a.bin, src, os.path.join(a.out, f"id_{f}_default.png"), [], l)
    p1 = render(a.bin, src, os.path.join(a.out, f"id_{f}_zeros.png"), [f"{key(b,c)}=0" for b in range(8) for c in COMPS], l)
    ident.append(int(np.abs(png_codes(p0) - png_codes(p1)).max()))
checks.append(("X4 explicit zeros vs default: bit-identical (hue_wheel, colorchecker, 2545)", max(ident) == 0, max(ident)))
for n, ok, v in checks:
    print(f"{verdict(ok)}  {n}: {v}")
json.dump(res, open(os.path.join(a.out, "neutrals.json"), "w"), indent=0)
