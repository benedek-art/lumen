"""Frequency response of Texture / Clarity on the isotropic 1/f probe (pink_6000 renders).

usage: python3 spectrum.py DIR PREFIX [name ...]      e.g.  spectrum.py OUT/pink p6000
       (reads DIR/PREFIX_id.png and DIR/PREFIX_<name>.png; default names t/c at -100..100)

Gain per bin = cross-spectral gain of log2 Y(render) onto log2 Y(identity) (Hann window),
24 log-spaced radial bins from 4 cycles per image long edge (cpi) to Nyquist (L/2 cpi).
cpi is resolution-independent: period in px = L / cpi; "px@6000" = 6000 / cpi.

Per render it prints the whole curve and these derived numbers (used by SPEC.md):
  peak_cpi      centre of the bin with the largest |g-1|            (band placement)
  peak          |g-1| at that bin                                    (strength)
  fine_ratio    max |g-1| over bins with centre >= 2000 cpi / peak   (finest scales, Nyquist side)
  fine1500      max |g-1| over bins with centre >= 1500 cpi / peak
  coarse_ratio  max |g-1| over bins with centre <= 120 cpi / peak    (large scales)
  centroid_cpi  |g-1|-weighted geometric mean frequency of the effect
  g750 / g60    gain interpolated at 750 cpi (Texture band centre) / 60 cpi (Clarity band centre)
  gmin / gmax   min / max gain over all bins (sign-flip check)
"""
import sys, os, json
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, logY

d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or [f"{k}{v}" for k in "tc" for v in (-100, -50, -25, 25, 50, 100)]
ref = logY(load(f"{d}/{p}_id.png")); h, w = ref.shape; L = max(h, w)
win = np.outer(np.hanning(h), np.hanning(w))
I = np.fft.rfft2((ref - ref.mean()) * win)
cpi = np.hypot(np.fft.rfftfreq(w)[None, :] , np.fft.fftfreq(h)[:, None]) * L
edges = np.geomspace(4, L / 2, 25)
cen = np.sqrt(edges[:-1] * edges[1:])
pw = np.abs(I) ** 2
masks = [(cpi >= edges[i]) & (cpi < edges[i + 1]) for i in range(len(cen))]


def interp(g, f):
    lf = np.log(cen)
    if f < cen[0] or f > cen[-1]:
        return float("nan")
    return float(np.interp(np.log(f), lf, g))


res = {}
print(f"{p}: L={L}")
print("   cpi     " + " ".join(f"{c:6.0f}" for c in cen))
print("   px@6000 " + " ".join(f"{6000/c:6.1f}" for c in cen))
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    o = logY(load(fn))
    O = np.fft.rfft2((o - o.mean()) * win)
    cr = (O * np.conj(I)).real
    g = np.array([cr[m].sum() / max(pw[m].sum(), 1e-12) for m in masks])
    e = np.abs(g - 1)
    k = int(np.argmax(e)); pk = float(e[k])
    fine = e[cen >= 2000]; fine15 = e[cen >= 1500]; coarse = e[cen <= 120]
    r = dict(gains=g.tolist(), peak_cpi=float(cen[k]), peak=pk,
             fine_ratio=float(fine.max() / pk) if len(fine) and pk > 0 else None,
             fine1500=float(fine15.max() / pk) if len(fine15) and pk > 0 else None,
             coarse_ratio=float(coarse.max() / pk) if pk > 0 else None,
             centroid_cpi=float(np.exp((e * np.log(cen)).sum() / max(e.sum(), 1e-12))),
             g750=interp(g, 750), g60=interp(g, 60), gmin=float(g.min()), gmax=float(g.max()))
    res[n] = r
    print(f"   {n:>6}  " + " ".join(f"{x:6.3f}" for x in g))
    fr = "n/a" if r["fine_ratio"] is None else f"{r['fine_ratio']:.2f}"
    f15 = "n/a" if r["fine1500"] is None else f"{r['fine1500']:.2f}"
    print(f"           peak|g-1|={pk:.3f} @ {r['peak_cpi']:.0f} cpi ({6000/r['peak_cpi']:.1f} px@6000)  "
          f"fine_ratio(>=2000)={fr} fine1500={f15} coarse_ratio(<=120)={r['coarse_ratio']:.2f}  "
          f"centroid={r['centroid_cpi']:.0f} cpi  g750={r['g750']:.3f} g60={r['g60']:.3f}  "
          f"gmin={r['gmin']:.3f} gmax={r['gmax']:.3f}")
# monotonicity of the band-centre gain across the slider
for k, f, key in (("t", 750, "g750"), ("c", 60, "g60")):
    vals = sorted(int(n[1:]) for n in res if n[0] == k)
    if len(vals) >= 2:
        seq = [(v, res[f"{k}{v}"][key]) for v in vals]
        seq_all = sorted(seq + [(0, 1.0)])
        mono = all(b[1] > a[1] for a, b in zip(seq_all, seq_all[1:]))
        print(f"   {k} gain@{f}cpi over slider: " + " ".join(f"{v:+d}:{g:.3f}" for v, g in seq_all)
              + f"  strictly_increasing={mono}")
json.dump(dict(cpi=cen.tolist(), L=L, results=res), open(f"{d}/{p}_spectrum.json", "w"), indent=1)
