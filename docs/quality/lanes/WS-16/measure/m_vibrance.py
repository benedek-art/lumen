"""WS-16 VIB-1..VIB-8: Vibrance. Stage lines run S9 alone through ws16probe; photo lines
render through lumen-render at --long-edge 1024.
Usage: python3 m_vibrance.py"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import *

DENS = default_of("develop.color.density")
PROT = default_of("develop.color.protectSkin")
NONSKIN = (0.0, 150.0, 200.0, 250.0, 300.0)

# VIB-1: low-chroma priority. Gain falls (never rises) with chroma; low chroma gets much more.
Cs = np.arange(0.02, 0.3001, 0.005)
worst_rise, worst_pri, where = 0.0, np.inf, None
for v in (50, 100):
    for L in (0.45, 0.6, 0.75):
        for h in NONSKIN:
            p = [(L, c, h) for c in Cs]
            b = stage(p, dens=DENS, prot=0); r = stage(p, vib=v, dens=DENS, prot=0)
            g = r["twin"][:, 1] / b["twin"][:, 1]
            okc = in_gamut(b)
            gi = g[okc]
            if len(gi) > 1:
                worst_rise = max(worst_rise, np.diff(gi).max())
            i3, i20 = np.argmin(abs(Cs - 0.03)), np.argmin(abs(Cs - 0.20))
            if okc[i3] and okc[i20]:
                pri = (g[i3] - 1) / max(g[i20] - 1, 1e-9)
                if pri < worst_pri:
                    worst_pri, where = pri, f"Vib +{v} L {L} h {h:g}"
check("VIB-1", worst_rise <= 1e-3 and worst_pri >= 2.5,
      f"max gain rise with chroma {worst_rise:.4f}; min (g(0.03)-1)/(g(0.20)-1) {worst_pri:.2f} ({where})",
      "rise <= 0.001 and ratio >= 2.5")

# VIB-2: gentler than Saturation. Saturated colours: Vib +100 adds at most half of what Sat +100 adds;
# nowhere does Vib +100 add more than Sat +100.
pts = grid()
hue = np.array([p[2] for p in pts])
nonskin = (np.abs(hd(hue, 62.0)) > 45)
b = stage(pts, dens=0, prot=0); ok = in_gamut(b); C0 = b["twin"][:, 1]
gv = stage(pts, vib=100, dens=0, prot=0)["twin"][:, 1] / C0
gs = stage(pts, sat=100, dens=0, prot=0)["twin"][:, 1] / C0
m = ok & (C0 >= 0.12) & nonskin
rel = (gv[m] - 1) / np.maximum(gs[m] - 1, 1e-9)
m2 = ok & (C0 > 0.02)
over = (gv[m2] - gs[m2]).max()
check("VIB-2", rel.max() <= 0.5 and over <= 0.01,
      f"max (gVib-1)/(gSat-1) at C>=0.12 {rel.max():.2f} (median {np.median(rel):.2f}); max gVib-gSat {over:+.3f}",
      "<= 0.5 and <= +0.01 (stage, Protect 0, Density 0)")

# VIB-3 / VIB-4 / VIB-6: real photos.
worst3, worst4, w3, w4 = -np.inf, -np.inf, None, None
lo6, hi6, w6 = np.inf, -np.inf, None
for pid in PHOTOS:
    a0 = render(pid, [], 1024)
    av = render(pid, ["develop.color.vibrance=100"], 1024)
    asat = render(pid, ["develop.color.saturation=100"], 1024)
    am = render(pid, ["develop.color.vibrance=-100"], 1024)
    _, c0, _ = lch(oklab(a0.reshape(-1, 3)))
    mm = c0 > 0.02
    def med(a):
        _, c, _ = lch(oklab(a.reshape(-1, 3)))
        return np.median(c[mm] / c0[mm])
    rv, rs, rm = med(av), med(asat), med(am)
    x = (rv - 1) / max(rs - 1, 1e-9)
    if x > worst3: worst3, w3 = x, f"{pid[:4]} Vib {rv:.2f} vs Sat {rs:.2f}"
    cv = clipped_fraction(av) - clipped_fraction(a0)
    cs = clipped_fraction(asat) - clipped_fraction(a0)
    y = cv / max(cs, 0.005)
    if y > worst4: worst4, w4 = y, f"{pid[:4]} Vib {cv*100:.1f}% vs Sat {cs*100:.1f}%"
    if rm < lo6: lo6, w6 = rm, pid[:4]
    hi6 = max(hi6, rm)
check("VIB-3", worst3 <= 0.85, f"max (medVib-1)/(medSat-1) {worst3:.2f} ({w3})", "<= 0.85 on each of 6 photos")
check("VIB-4", worst4 <= 0.8, f"max newly-clipped Vib/Sat {worst4:.2f} ({w4})", "<= 0.8 (denominator floored at 0.5%)")
check("VIB-6", lo6 >= 0.3 and hi6 <= 0.8, f"Vib -100 median chroma ratio {lo6:.2f}..{hi6:.2f} (lowest {w6})", "within [0.30, 0.80] on each photo")

# VIB-5: skin is protected at the default Protect Skin: skin patch gain increment <= 0.35 x
# that of a matched (L, C) non-skin colour (hues 150 and 250, the smaller increment).
sk = skin_patches()
worst, where = 0.0, None
for name, rgb, (L, C, h) in sk:
    p = [("rgb",) + tuple(rgb), (L, C, 150.0), (L, C, 250.0)]
    b = stage(p, dens=DENS, prot=PROT); r = stage(p, vib=100, dens=DENS, prot=PROT)
    g = r["twin"][:, 1] / b["twin"][:, 1]
    x = (g[0] - 1) / max(min(g[1], g[2]) - 1, 1e-9)
    if x > worst: worst, where = x, f"{name} gain {g[0]:.2f} vs ref {min(g[1], g[2]):.2f}"
check("VIB-5a", worst <= 0.35, f"max skin/ref increment {worst:.2f} ({where})", "<= 0.35 (stage, Vib +100, default Protect)")
ref = render("skin_tones"); img = render("skin_tones", ["develop.color.vibrance=100"])
gmax, gw = 0.0, None
for p in patches("skin_tones"):
    if not p["name"].startswith("MST") or p["name"] == "MST 10":
        continue
    l0, _ = patch_lab(ref, p["rect"]); l1, _ = patch_lab(img, p["rect"])
    g = np.hypot(*l1[1:]) / np.hypot(*l0[1:])
    if g > gmax: gmax, gw = g, p["name"]
check("VIB-5b", gmax <= 1.35, f"max output chroma gain {gmax:.2f} ({gw})", "<= 1.35 (skin_tones MST 1-9, Vib +100, default Protect)")

# VIB-7: Vibrance -100 has no hue wedge (colour-splash): gain uniform across hue.
hs = np.arange(0, 360, 0.5)
worst_s, worst_r = 0.0, 0.0
for C in (0.06, 0.10):
    p = [(0.6, C, h) for h in hs]
    b = stage(p, dens=DENS, prot=PROT); r = stage(p, vib=-100, dens=DENS, prot=PROT)
    okh = in_gamut(b)
    g = r["twin"][:, 1] / b["twin"][:, 1]
    gg = g[okh]
    worst_s = max(worst_s, (np.abs(np.diff(g)) / 0.5)[okh[1:] & okh[:-1]].max())
    worst_r = max(worst_r, gg.max() - gg.min())
check("VIB-7", worst_s <= 0.01 and worst_r <= 0.15, f"max |dgain/dh| {worst_s:.4f}/deg; gain range over hue {worst_r:.3f}",
      "<= 0.01/deg and <= 0.15 (L 0.6, C 0.06/0.10, default Protect)")

# VIB-8: shadow chroma noise (2348, ISO 3200): high-passed a/b std in L<0.35, Vib +100 vs 0.
def uniform_filter(x, k):
    pd = k // 2; xp = np.pad(x, pd, mode="edge"); c = xp.cumsum(0).cumsum(1)
    c = np.pad(c, ((1, 0), (1, 0)))
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)
def hp(lab):
    return np.stack([lab[..., i] - uniform_filter(lab[..., i], 7) for i in (1, 2)], -1)
l0 = oklab(render("2348_panasonic-dc-g9", [], 1024)); msk = l0[..., 0] < 0.35
l1 = oklab(render("2348_panasonic-dc-g9", ["develop.color.vibrance=100"], 1024))
amp = hp(l1)[msk].std() / hp(l0)[msk].std()
check("VIB-8", amp <= 1.6, f"shadow chroma-noise amplification {amp:.2f}", "<= 1.6 (2348, Vib +100)")
summary()
