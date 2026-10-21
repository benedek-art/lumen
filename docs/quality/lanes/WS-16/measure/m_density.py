"""WS-16 DEN-1..DEN-4: Density (stage via ws16probe, photo 2242 via lumen-render).
Usage: python3 m_density.py"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import *

DENS = default_of("develop.color.density")
PROT = default_of("develop.color.protectSkin")
pts = grid()
base = stage(pts, dens=DENS, prot=PROT)
ok = in_gamut(base); C0 = base["twin"][:, 1]
m = ok & (C0 > 0.02)
Y0 = base["rgb"] @ LUMA2020


def ev(r):
    return np.log2(np.maximum(r["twRGB"] @ LUMA2020, 1e-12) / Y0)


# DEN-1: at the DEFAULT Density a Saturation push does not darken the picture.
e_def = np.median(ev(stage(pts, sat=100, dens=DENS, prot=PROT))[m])
check("DEN-1a", e_def >= -0.06, f"stage median dY at Sat +100, default Density ({DENS:g}): {e_def:+.3f} EV",
      ">= -0.06 EV (in-gamut grid, C > 0.02)")
Y = lambda a: (srgb_to_linear(a.reshape(-1, 3)) @ np.array([0.2126, 0.7152, 0.0722])).mean()
worst, where = 0.0, None
for pid in ("2242_panasonic-dc-gx850", "4694_canon-eos-r5", "6929_sony-ilce-7m4"):
    d = np.log2(Y(render(pid, ["develop.color.saturation=100"], 1024)) / Y(render(pid, [], 1024)))
    if abs(d) > abs(worst):
        worst, where = d, pid[:4]
check("DEN-1b", abs(worst) <= 0.08, f"worst mean-luminance shift Sat +100 (default Density) vs Sat 0: {worst:+.3f} EV ({where})",
      "|shift| <= 0.08 EV on 2242, 4694, 6929")
pid = "2242_panasonic-dc-gx850"
a_0 = render(pid, ["develop.color.saturation=100", "develop.color.density=0"], 1024)
a_100 = render(pid, ["develop.color.saturation=100", "develop.color.density=100"], 1024)

# DEN-2: a positive Saturation never LOWERS chroma, at any Density.
worst, where = np.inf, None
for s in (25, 50, 100):
    for dd in (0, 25, 50, 75, 100):
        r = stage(pts, sat=s, dens=dd, prot=PROT)
        ratio = r["twin"][:, 1] / C0
        i = np.where(m)[0][np.argmin(ratio[m])]
        if ratio[i] < worst:
            worst, where = ratio[i], f"Sat +{s} Density {dd} at L {pts[i][0]} C {pts[i][1]} h {pts[i][2]:g}"
check("DEN-2", worst >= 1 - 1e-4, f"min C ratio {worst:.4f} ({where})", ">= 0.9999")

# DEN-3: Density does something visible: Sat +100, Density 100 vs Density 0 on 2242.
dE = np.linalg.norm(oklab(a_100.reshape(-1, 3)) - oklab(a_0.reshape(-1, 3)), axis=1).mean() * 100
check("DEN-3", dE >= 2.0, f"mean OKLab dE x100 (Density 100 vs 0, Sat +100, 2242) {dE:.2f}", ">= 2.0")

# DEN-4: Density's effect is monotone: more Density never brightens (median dY falls with Density).
meds = [np.median(ev(stage(pts, sat=100, dens=dd, prot=PROT))[m]) for dd in (0, 25, 50, 75, 100)]
mono = all(b <= a + 1e-4 for a, b in zip(meds, meds[1:]))
check("DEN-4", mono and meds[-1] <= meds[0] - 0.1, "median dY at Sat +100 for Density 0/25/50/75/100: " + " ".join(f"{x:+.3f}" for x in meds),
      "non-increasing, and Density 100 at least 0.1 EV below Density 0")
summary()
