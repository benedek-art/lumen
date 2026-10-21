"""WS-16 ID-1 (full pipeline: every default is byte-exact identity) and ID-2 (stage reports
identity with zero passes at the defaults). Usage: python3 m_identity.py"""
import sys, os, subprocess
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ws16lib import *

DENS = default_of("develop.color.density")
PROT = default_of("develop.color.protectSkin")
cases = [["develop.color.vibrance=0"], ["develop.color.saturation=0"], [f"develop.color.density={DENS:g}"],
         [f"develop.color.protectSkin={PROT:g}"], ["develop.color.density=0", "develop.color.protectSkin=0"],
         ["develop.color.density=100", "develop.color.protectSkin=100"],
         ["look.bw.enabled=false", "look.bw.bands.5=-100", "look.bw.bands.0=100"]]
worst, where = 0, None
for fr, le in (("colorchecker", None), ("hue_wheel", None), ("skin_tones", None), ("2545_panasonic-dmc-gx85", 1024)):
    ref = render(fr, [], le).astype(int)
    for s in cases:
        d = int(np.abs(render(fr, s, le).astype(int) - ref).max())
        if d > worst or where is None:
            worst, where = d, f"{fr} {' '.join(s)}" if d > 0 else "-"
check("ID-1", worst == 0, f"max |dcode| {worst} ({where})", "0 codes (colorchecker, hue_wheel, skin_tones, 2545)")
r = subprocess.run([PROBE, "stage", "0", "0", f"{DENS:g}", f"{PROT:g}"], input="0.6 0.1 40\n", capture_output=True, text=True)
check("ID-2", "engine=true stage=true passes=0" in r.stderr, r.stderr.strip(), "engine=true stage=true passes=0")
# ID-3: no step where a control leaves its default. The move from 0 to +/-1 must be about half the
# move from 0 to +/-2 (a step makes them equal): max|I(1)-I(0)| <= 0.75 max|I(2)-I(0)| + 1 code.
worst, where = 0.0, None
def step(fr, base_sets, key, sign):
    ref = render(fr, base_sets).astype(int)
    d1 = np.abs(render(fr, base_sets + [f"{key}={sign}"]).astype(int) - ref).max()
    d2 = np.abs(render(fr, base_sets + [f"{key}={2 * sign}"]).astype(int) - ref).max()
    return (d1 - 1) / max(d2, 1), d1, d2
for fr in ("colorchecker", "hue_wheel"):
    for key in ("develop.color.saturation", "develop.color.vibrance"):
        for sg in (1, -1):
            x, d1, d2 = step(fr, [], key, sg)
            if x > worst: worst, where = x, f"{fr} {key}={sg}: {d1} vs {d2} codes"
for i in range(8):
    for sg in (1, -1):
        x, d1, d2 = step("colorchecker", ["look.bw.enabled=true"], f"look.bw.bands.{i}", sg)
        if x > worst: worst, where = x, f"band {i} {sg:+d}: {d1} vs {d2} codes"
check("ID-3", worst <= 0.75, f"max (d1-1)/d2 {worst:.2f} ({where})", "<= 0.75 (Sat/Vib +/-1 on colorchecker+hue_wheel, each B&W band +/-1)")
summary()
