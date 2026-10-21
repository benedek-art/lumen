"""WS-16 BW-1..BW-7: Black & White mixer (stage via ws16probe; BW-3b/BW-6b via lumen-render).
EV = log2(grey / default-mix grey), the default mix being all bands 0 (= Rec.2020 Y).
Usage: python3 m_bw.py"""
import sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import *

CENTRES = [float(x) for x in subprocess.run([PROBE, "centres"], capture_output=True, text=True, check=True).stdout.split()]
Z = [0] * 8


def band(i, v):
    b = list(Z); b[i] = v; return b


def ev(points, bands):
    y0 = stage(points, bw=Z)["twRGB"][:, 0]
    y = stage(points, bw=bands)["twRGB"][:, 0]
    return np.log2(np.maximum(y, 1e-30) / np.maximum(y0, 1e-30)), y0


def ingamut(points):
    return in_gamut(stage(points))


# BW-1: depth. A band at -100 darkens a saturated in-band colour by 1-2.5 EV, never to black;
# +100 brightens it by 1-2.5 EV.
lo_m, hi_m, lo_p, hi_p = np.inf, -np.inf, np.inf, -np.inf
sym, lin = 0.0, 0.0
for i, c in enumerate(CENTRES):
    for C in (0.10, 0.15):
        p = [(0.6, C, c)]
        if not ingamut(p)[0]:
            continue
        em = ev(p, band(i, -100))[0][0]; ep = ev(p, band(i, 100))[0][0]
        em50 = ev(p, band(i, -50))[0][0]; ep50 = ev(p, band(i, 50))[0][0]
        lo_m, hi_m = min(lo_m, em), max(hi_m, em)
        lo_p, hi_p = min(lo_p, ep), max(hi_p, ep)
        sym = max(sym, abs(ep + em))
        for half, full in ((em50, em), (ep50, ep)):
            lin = max(lin, abs(half / full - 0.5) if np.isfinite(full) and full != 0 else np.inf)
check("BW-1", lo_m >= -2.5 and hi_m <= -1.0 and lo_p >= 1.0 and hi_p <= 2.5,
      f"band -100: {lo_m:+.2f}..{hi_m:+.2f} EV; band +100: {lo_p:+.2f}..{hi_p:+.2f} EV",
      "-100 in [-2.5, -1.0] EV and +100 in [+1.0, +2.5] EV (band centre, L 0.6, C 0.10/0.15)")
check("BW-2", sym <= 0.1 and lin <= 0.1, f"max |EV(+100)+EV(-100)| {sym:.3f}; max |EV(50)/EV(100) - 0.5| {lin:.3f}",
      "<= 0.1 EV and <= 0.1 (response symmetric and linear in EV)")

# BW-3a: floor. Nothing in-gamut goes more than 3 EV down, for any single band or all at -100.
pts = grid()
ok = ingamut(pts)
worst, where = np.inf, None
for bands in [band(i, -100) for i in range(8)] + [[-100] * 8]:
    e, y0 = ev(pts, bands)
    m = ok & (y0 > 1e-4)
    if e[m].min() < worst:
        worst, where = e[m].min(), str(bands)
check("BW-3a", worst >= -3.0, f"min EV {worst:+.2f} ({where})", ">= -3.0 EV over the in-gamut grid")
# BW-3b: GX85 sky, Azure -100: no pixel newly crushed to near black.
pid = "2545_panasonic-dmc-gx85"
g0 = render(pid, ["look.bw.enabled=true"], 1024)[..., 1]
g1 = render(pid, ["look.bw.enabled=true", "look.bw.bands.5=-100"], 1024)[..., 1]
crushed = ((g1 <= 2) & (g0 > 2)).mean()
check("BW-3b", crushed <= 0.001, f"2545 Azure -100: {crushed*100:.2f}% of pixels newly at code <= 2", "<= 0.1%")

# BW-4: soft chroma gate: the band's effect grows with chroma, gradually.
Cs = np.arange(0.0, 0.2001, 0.005)
worst_s, worst_p = 0.0, 0.0
for i, c in enumerate(CENTRES):
    p = [(0.6, C, c) for C in Cs]
    okc = ingamut(p)
    e, _ = ev(p, band(i, -100))
    s = np.abs(np.diff(e)) / 0.5
    s = np.where(okc[1:] & okc[:-1], s, 0)
    worst_s = max(worst_s, s.max())
    i4, i12 = np.argmin(abs(Cs - 0.04)), np.argmin(abs(Cs - 0.12))
    if okc[i12]:
        worst_p = max(worst_p, e[i4] / e[i12] if e[i12] != 0 else np.inf)
check("BW-4", worst_s <= 0.3 and worst_p <= 0.75, f"max |dEV| per 0.01 C {worst_s:.3f}; max EV(C 0.04)/EV(C 0.12) {worst_p:.2f}",
      "<= 0.3 EV per 0.01 C and <= 0.75 (band -100 at its centre, L 0.6)")

# BW-5: smooth across hue, and no notch at band boundaries.
hs = np.arange(0, 360, 0.5)
p = [(0.6, 0.10, h) for h in hs]
okh = ingamut(p)
worst = 0.0
for i in range(8):
    for v in (-100, 100):
        e, _ = ev(p, band(i, v))
        s = np.abs(np.diff(e)) / 0.5
        worst = max(worst, np.where(okh[1:] & okh[:-1], s, 0).max())
e_all, _ = ev(p, [-100] * 8)
spread_all = np.ptp(e_all[okh])
spread_pair = 0.0
for i in range(8):
    j = (i + 1) % 8
    bands = list(Z); bands[i] = -100; bands[j] = -100
    e, _ = ev(p, bands)
    a, b = CENTRES[i], CENTRES[j]
    between = np.array([(hd(a, h) >= 0) and (hd(a, h) <= hd(a, b)) for h in hs]) & okh
    spread_pair = max(spread_pair, np.ptp(e[between]))
check("BW-5", worst <= 0.08 and spread_all <= 0.05 and spread_pair <= 0.1,
      f"max |dEV/dh| {worst:.3f}/deg; all -100 spread {spread_all:.3f} EV; adjacent pair -100 spread {spread_pair:.3f} EV",
      "<= 0.08 EV/deg, <= 0.05 EV, <= 0.1 EV (L 0.6, C 0.10)")

# BW-6a: neutrals are fixed exactly (stage).
neut = [("rgb", v, v, v) for v in (0.001, 0.01, 0.05, 0.18, 0.5, 1.0, 4.0)]
yv = np.array([0.001, 0.01, 0.05, 0.18, 0.5, 1.0, 4.0])
worst = 0.0
for bands in [band(i, v) for i in range(8) for v in (-100, 100)] + [[-100] * 8, [100] * 8, [50, -50, 100, -100, 30, -70, 0, 20]]:
    r = stage(neut, bw=bands)
    worst = max(worst, (np.abs(r["twRGB"] - yv[:, None]) / yv[:, None]).max())
check("BW-6a", worst <= 1e-6, f"max relative grey error on neutrals {worst:.2e}", "<= 1e-6")
# BW-6b: colorchecker neutral patches 19-24 do not move at output for any band at +/-100.
P = patches("colorchecker")
base = render("colorchecker", ["look.bw.enabled=true"])
gb = np.array([patch_lab(base, q["rect"])[1][1] for q in P[18:]])
worst = 0.0
for i in range(8):
    for v in (-100, 100):
        img = render("colorchecker", ["look.bw.enabled=true", f"look.bw.bands.{i}={v}"])
        g = np.array([patch_lab(img, q["rect"])[1][1] for q in P[18:]])
        worst = max(worst, np.abs(g - gb).max())
check("BW-6b", worst <= 0.5, f"max neutral patch move {worst:.2f} codes", "<= 0.5 code")

# BW-7: the default mix (all bands 0) is Rec.2020 luminance.
r = stage(pts, bw=Z)
y = r["rgb"] @ LUMA2020
m = ok & (y > 1e-4)
err = (np.abs(r["twRGB"][m, 0] - y[m]) / y[m]).max()
check("BW-7", err <= 1e-5, f"max relative |grey - Y| {err:.2e}", "<= 1e-5 (Float twin)")
summary()
