"""Orange sat/lum on skin_tones (MST 1-10 + ColorChecker skins): monotone, hue drift,
floor on darkening, and that every MST patch responds.

Patch value = mean display-linear RGB over the patch rect inset by 20 px, rendered WITH the
ordered dither (sub-code means). Hue drift is evaluated where base and edit chroma are both
>= 0.008 (below that a patch has no meaningful hue).

usage: skin.py --bin lumen-render --corpus corpus --out DIR [--band 1]
"""
import argparse, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib import *

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True); ap.add_argument("--corpus", required=True)
ap.add_argument("--out", required=True); ap.add_argument("--band", type=int, default=1)
a = ap.parse_args(); os.makedirs(a.out, exist_ok=True)
src = os.path.join(a.corpus, "synthetic", "skin_tones.lfi")
pts = json.load(open(src[:-4] + ".json"))["truth"]["patches"]
VALS = list(range(-100, 101, 20))

def meas(png):
    lin = png_lin(png); r = []
    for p in pts:
        x, y, w, h = p["rect"]
        m = lin[y + 20:y + h - 20, x + 20:x + w - 20].reshape(-1, 3).mean(0)
        L, C, hh = lch(to_lab(m, "srgb")); r.append((float(lin_Y(m)), float(L), float(C), float(hh)))
    return np.array(r)

data = {}
for comp in ("sat", "lum"):
    data[comp] = {v: meas(render(a.bin, src, os.path.join(a.out, f"skin_{comp}{v:+d}.png"),
                               [f"{key(a.band,comp)}={v}"] if v else [], 0, dither=True)) for v in VALS}
base = data["lum"][0]
names = [p["name"] for p in pts]; mst = [i for i, n in enumerate(names) if n.startswith("MST")]
print("patch          Y0      L0    C0    h0  | lum-100 Y/Y0  dL-100  dL+100 | sat-100 C  sat+100 C | max hue drift (lum, sat)")
drift = {}
for i, n in enumerate(names):
    dr = []
    for comp in ("sat", "lum"):
        for v in VALS:
            o = data[comp][v][i]
            if min(o[2], base[i][2]) >= 0.008:
                dr.append((comp, abs(float(hd(base[i][3], o[3])))))
    drift[n] = {c: max([d for cc, d in dr if cc == c], default=0.0) for c in ("lum", "sat")}
    l, s = data["lum"], data["sat"]
    print(f"{n[:13]:13s} {base[i][0]:.4f} {base[i][1]:.3f} {base[i][2]:.3f} {base[i][3]:5.1f} | {l[-100][i][0]/base[i][0]:6.3f} {l[-100][i][1]-base[i][1]:+.3f} {l[100][i][1]-base[i][1]:+.3f} | {s[-100][i][2]:.3f}  {s[100][i][2]:.3f} | {drift[n]['lum']:.1f} {drift[n]['sat']:.1f}")

def mono(comp, ax, i):
    q = np.array([data[comp][v][i][ax] for v in VALS])
    tot = q[-1] - q[0]
    return bool(np.all(np.diff(q) * np.sign(tot) >= -1e-4)) if abs(tot) > 1e-3 else True

checks = []
checks.append(("K1 Orange lum monotone (L) on all patches", all(mono("lum", 1, i) for i in range(len(names))), 0))
checks.append(("K1 Orange sat monotone (C) on all patches", all(mono("sat", 2, i) for i in range(len(names))), 0))
md = max(max(drift[names[i]].values()) for i in mst)
checks.append(("K2 hue drift <= 3 deg on every MST patch (sat and lum, all values)", md <= 3.0, md))
fl = min(data["lum"][-100][i][0] / base[i][0] for i in mst)
checks.append(("K3 Orange lum -100 keeps Y >= 0.4 Y0 on every MST patch", fl >= 0.4, fl))
resp = min(min(abs(data["lum"][-100][i][1] - base[i][1]), abs(data["lum"][100][i][1] - base[i][1])) for i in mst)
checks.append(("K4 every MST patch moves |dL| >= 0.015 at Orange lum -100 and +100", resp >= 0.015, resp))
ev = [abs(np.log2(data["lum"][-100][i][0] / base[i][0])) for i in mst[2:8]]
checks.append(("K5 MST 3-8 Orange lum -100 EV spread max/min <= 3", max(ev) / max(min(ev), 1e-6) <= 3, max(ev) / max(min(ev), 1e-6)))
for n, ok, v in checks:
    print(f"{verdict(ok)}  {n}: {v:.3f}")
