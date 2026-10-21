"""WS-16 SKIN-1..SKIN-5: Protect Skin (stage, S9 alone through ws16probe) plus an output check.
Usage: python3 m_skin.py"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import *

DENS = default_of("develop.color.density")
PROT = default_of("develop.color.protectSkin")
sk = skin_patches()
P = [("rgb",) + tuple(rgb) for _, rgb, _ in sk]


def gains(points, prot, **kw):
    b = stage(points, dens=DENS, prot=prot)
    r = stage(points, dens=DENS, prot=prot, **kw)
    return r["twin"][:, 1] / b["twin"][:, 1]


# SKIN-1 / SKIN-2: every skin patch (CC light/dark skin, MST 1-9) is protected from Sat +100.
g0 = gains(P, 0, sat=100)
for sid, prot, lim in (("SKIN-1", PROT, 0.45), ("SKIN-2", 100, 0.15)):
    g = gains(P, prot, sat=100)
    rel = (g - 1) / np.maximum(g0 - 1, 1e-9)
    i = int(np.argmax(rel))
    check(sid, rel.max() <= lim, f"max (g-1)/(g_P0-1) {rel.max():.2f} ({sk[i][0]}, h {sk[i][2][2]:.1f})",
          f"<= {lim} at Sat +100, Protect {prot:g}")

# SKIN-3: non-skin ColorChecker colours that share the skin hues are NOT protected.
names = ["orange", "orange yellow", "yellow", "red", "moderate red", "foliage"]
Q = [("rgb",) + tuple(cc_patch(n)) for n in names]
q0 = gains(Q, 0, sat=100); q = gains(Q, PROT, sat=100)
rel = (q - 1) / np.maximum(q0 - 1, 1e-9)
i = int(np.argmin(rel))
check("SKIN-3", rel.min() >= 0.8, f"min (g-1)/(g_P0-1) {rel.min():.2f} ({names[i]})",
      ">= 0.8 at Sat +100, default Protect (orange, orange yellow, yellow, red, moderate red, foliage)")

# SKIN-4: no seam in hue: gain changes smoothly across the band edges.
hs = np.arange(0, 360, 0.5)
for sid, prot, lim in (("SKIN-4a", PROT, 0.04), ("SKIN-4b", 100, 0.06)):
    worst, where = 0.0, None
    for key in ("sat", "vib"):
        for L in (0.5, 0.7):
            for C in (0.03, 0.06, 0.10):
                p = [(L, C, h) for h in hs]
                b = stage(p, dens=DENS, prot=prot); okh = in_gamut(b)
                g = stage(p, dens=DENS, prot=prot, **{key: 100})["twin"][:, 1] / b["twin"][:, 1]
                s = (np.abs(np.diff(g)) / 0.5)
                s = np.where(okh[1:] & okh[:-1], s, 0)
                if s.max() > worst:
                    worst, where = s.max(), f"{key} +100 L {L} C {C} h {hs[np.argmax(s)]:g}"
    check(sid, worst <= lim, f"max |dgain/dh| {worst:.3f}/deg ({where})", f"<= {lim}/deg at Protect {prot:g}")

# SKIN-5: no seam in chroma inside the skin hues, and chroma order is kept.
Cs = np.arange(0.01, 0.2001, 0.0025)
worst, where, inv = 0.0, None, 0.0
for prot in (PROT, 100):
    for key in ("sat", "vib"):
        for L in (0.6, 0.75):
            for h in (40.0, 55.0, 70.0, 85.0):
                p = [(L, c, h) for c in Cs]
                b = stage(p, dens=DENS, prot=prot); okc = in_gamut(b)
                r = stage(p, dens=DENS, prot=prot, **{key: 100})
                g = r["twin"][:, 1] / b["twin"][:, 1]
                s = np.abs(np.diff(g)) / 0.25          # per 0.01 of chroma
                m = okc[1:] & okc[:-1] & (Cs[:-1] >= 0.03)
                if m.any() and s[m].max() > worst:
                    worst, where = s[m].max(), f"{key} +100 P{prot:g} L {L} h {h:g} C {Cs[1:][m][np.argmax(s[m])]:.4f}"
                d = np.diff(r["twin"][:, 1])[okc[1:] & okc[:-1]]
                inv = min(inv, d.min()) if len(d) else inv
check("SKIN-5", worst <= 0.3 and inv >= -1e-6, f"max |dgain| per 0.01 C {worst:.3f} ({where}); worst chroma-order step {inv:.2e}",
      "<= 0.3 per 0.01 C (C >= 0.03) and no chroma-order inversion")

# SKIN-6 (output): skin_tones and CC skin at Sat +100, default Protect, through the pipeline.
ref = render("skin_tones"); img = render("skin_tones", ["develop.color.saturation=100"])
gmax, gw = 0.0, None
for p in patches("skin_tones"):
    if not p["name"].startswith("MST") or p["name"] == "MST 10":
        continue
    l0, _ = patch_lab(ref, p["rect"]); l1, _ = patch_lab(img, p["rect"])
    g = np.hypot(*l1[1:]) / np.hypot(*l0[1:])
    if g > gmax: gmax, gw = g, p["name"]
check("SKIN-6", gmax <= 1.45, f"max output chroma gain {gmax:.2f} ({gw})", "<= 1.45 (skin_tones MST 1-9, Sat +100, default Protect)")
summary()
