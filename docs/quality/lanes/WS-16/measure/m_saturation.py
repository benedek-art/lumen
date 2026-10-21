"""WS-16 HUE-1 and SAT-1..SAT-6: Saturation (and the hue/gamut lines shared with Vibrance).
Stage lines run S9 alone through ws16probe; SAT-3b renders through lumen-render.
Usage: python3 m_saturation.py"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import *

DENS = default_of("develop.color.density")
PROT = default_of("develop.color.protectSkin")
pts = grid()
base = stage(pts, dens=DENS, prot=PROT)
ok = in_gamut(base)
L0, C0, h0 = base["twin"].T
Lp = np.array([p[0] for p in pts])

# HUE-1: Saturation and Vibrance hold OKLab hue at the stage output.
worst, where = 0.0, None
for key in ("sat", "vib"):
    for v in (-100, -50, -25, 25, 50, 100):
        for d in sorted({0.0, DENS, 100.0}):
            for pr in (0, PROT, 100):
                r = stage(pts, dens=d, prot=pr, **{key: v})
                L1, C1, h1 = r["twin"].T
                m = ok & (C0 > 0.02) & (C1 > 0.005)
                if not m.any():
                    continue
                dh = np.abs(hd(h0, h1))[m].max()
                if dh > worst:
                    worst, where = dh, f"{key} {v:+d} density {d:g} protect {pr:g}"
check("HUE-1", worst <= 0.1, f"max |dh| {worst:.4f} deg ({where})", "<= 0.1 deg")

# SAT-1: pulls are a uniform chroma scale.
worst = 0.0
for s in (-25, -50, -75):
    r = stage(pts, sat=s, dens=DENS, prot=PROT)
    ratio = r["twin"][:, 1] / C0
    m = ok & (C0 > 0.02)
    worst = max(worst, np.abs(ratio[m] - (1 + s / 100)).max())
check("SAT-1", worst <= 0.005, f"max |C ratio - (1+s)| {worst:.4f} over Sat -25/-50/-75", "<= 0.005")

# SAT-2: pushes are a uniform chroma scale wherever the push stays well inside Rec.2020.
hs = np.arange(0, 360, 5.0)
Ls = (0.3, 0.45, 0.6, 0.75, 0.9)
Lh = [(L, h) for L in Ls for h in hs]
bd = dict(zip(Lh, boundary_chroma(Lh)))
bound = np.array([bd[(p[0], p[2])] for p in pts])
worst, where = 1.0, None
for s in (25, 50, 100):
    r = stage(pts, sat=s, dens=DENS, prot=0)
    rel = r["twin"][:, 1] / C0 / (1 + s / 100)
    m = ok & (C0 > 0.02) & ((1 + s / 100) * C0 <= 0.6 * bound) & (Lp <= 0.75)
    i = np.where(m)[0][np.argmin(rel[m])]
    if rel[i] < worst:
        worst, where = rel[i], f"Sat +{s} at L {pts[i][0]} C {pts[i][1]} h {pts[i][2]:g}"
check("SAT-2", worst >= 0.95, f"min C ratio/(1+s) {worst:.3f} ({where})",
      ">= 0.95 for samples with (1+s)C <= 0.6 x Rec.2020 boundary, L 0.3-0.75, Protect 0, default Density")

# SAT-3: -100 is clean monochrome, whatever Protect Skin and Vibrance say.
mx = 0.0
for pr in (0, PROT, 100):
    for vib in (0, 100, -100):
        r = stage(pts, sat=-100, vib=vib, dens=DENS, prot=pr)
        mx = max(mx, r["twin"][ok, 1].max())
check("SAT-3a", mx <= 1e-5, f"stage max output C {mx:.2e}", "<= 1e-5 (in-gamut grid, Protect 0/70/100, Vib -100/0/+100)")
worst = 0
for fr in ("colorchecker", "hue_wheel", "skin_tones"):
    img = render(fr, ["develop.color.saturation=-100", "develop.color.protectSkin=100"]).astype(int)
    worst = max(worst, np.abs(img[..., 0] - img[..., 1]).max(), np.abs(img[..., 1] - img[..., 2]).max())
check("SAT-3b", worst <= 1, f"max |R-G|,|G-B| {worst} codes", "<= 1 code (colorchecker, hue_wheel, skin_tones; Sat -100, Protect 100)")

# SAT-4: positive pushes keep in-gamut (Rec.2020) colours inside Rec.2020.
bad_total, worst, where = 0, 0.0, None
for st in (dict(sat=25), dict(sat=50), dict(sat=100), dict(vib=50), dict(vib=100), dict(vib=100, sat=100)):
    for d in sorted({0.0, DENS, 100.0}):
        r = stage(pts, dens=d, prot=0, **st)
        mn = r["twRGB"].min(1)
        bad = ok & (mn < -1e-4)
        bad_total += int(bad.sum())
        if bad.any() and mn[bad].min() < worst:
            worst, where = mn[bad].min(), f"{st} density {d:g}"
check("SAT-4", bad_total == 0, f"{bad_total} in-gamut samples pushed outside Rec.2020 (worst channel {worst:.4f}, {where})",
      "0 samples with a channel < -1e-4")

# SAT-5: no plateau (gamut blotch): output chroma keeps rising with input chroma.
Cf = np.linspace(0.002, 0.40, 200)
lines = [(L, h) for L in Ls for h in hs]
fp = [(L, c, h) for (L, h) in lines for c in Cf]
fb = stage(fp)
fok = in_gamut(fb).reshape(len(lines), -1)
okk = fok[:, 1:] & fok[:, :-1]
worst, where = np.inf, None
for st in (dict(sat=100, prot=0), dict(sat=100, prot=PROT), dict(sat=100, prot=0, dens=0), dict(sat=100, prot=0, dens=100),
           dict(vib=100, prot=0), dict(vib=100, prot=PROT), dict(vib=100, sat=100, prot=0)):
    kw = dict(dens=DENS); kw.update(st)
    r = stage(fp, **kw)
    Co = r["twin"][:, 1].reshape(len(lines), -1)
    slope = np.where(okk, np.diff(Co, axis=1) / np.diff(Cf), np.inf)
    i = np.unravel_index(np.argmin(slope), slope.shape)
    if slope[i] < worst:
        worst, where = slope[i], f"{st} at L {lines[i[0]][0]} h {lines[i[0]][1]:g} C {Cf[i[1]]:.3f}"
check("SAT-5", worst >= 0.3, f"min dCout/dCin {worst:.3f} ({where})", ">= 0.3 over in-gamut inputs")

# SAT-6: full-pipeline guard on new sRGB clipping at Sat +100 (the sRGB clip itself is NEEDS N1).
# Thresholds = the measured baseline (before WS-16) + 1 percentage point.
for sid, fr, thr in (("SAT-6a", "hue_wheel", 0.264), ("SAT-6b", "2242_panasonic-dc-gx850", 0.166),
                     ("SAT-6c", "4694_canon-eos-r5", 0.143)):
    le = None if fr == "hue_wheel" else 1024
    a0 = render(fr, [], le); a1 = render(fr, ["develop.color.saturation=100"], le)
    extra = clipped_fraction(a1) - clipped_fraction(a0)
    check(sid, extra <= thr, f"{fr}: newly clipped {extra*100:.1f}% of pixels", f"<= {thr*100:.1f}% (no worse than baseline + 1 pp)")
summary()
