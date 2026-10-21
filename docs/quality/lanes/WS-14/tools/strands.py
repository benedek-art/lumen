"""Texture on ORIENTED fine detail at normal contrast (amendment S9): strands_6000.
usage: python3 strands.py DIR PREFIX [name ...]       e.g. strands.py OUT/strands st6000 t100 t-100
Works at any render size of strands_6000. For each of the six 200-row bands (strokes 0.1/0.2/0.3 EV,
grating 0.1/0.2/0.3 EV), on its middle 160 rows: cross-spectral gain of log2 Y (render vs identity,
Hann window) over the Texture band 375 .. min(1500, 0.95 Nyquist) cpi (cpi of the frame's long edge)."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, logY, STRANDS_EV

d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ["t100", "t-100", "t50", "t-50"]
ref = logY(load(f"{d}/{p}_id.png")); h, w = ref.shape; L = max(h, w); s = w / 6000.0
labels = [f"strokes {a}EV" for a in STRANDS_EV] + [f"grating {a}EV" for a in STRANDS_EV]


def region(a, b):
    return a[int((b * 200 + 20) * s):int((b * 200 + 180) * s)]


specs = []
for b in range(6):
    r = region(ref, b); hh, ww = r.shape
    win = np.outer(np.hanning(hh), np.hanning(ww))
    I = np.fft.rfft2((r - r.mean()) * win)
    cpi = np.hypot(np.fft.rfftfreq(ww)[None, :] * L, np.fft.fftfreq(hh)[:, None] * L)
    m = (cpi >= 375) & (cpi < min(1500, 0.95 * L / 2))
    specs.append((I, win, m))
print(f"  {p}: L={L}   " + " | ".join(labels))
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    o = logY(load(fn)); g = []
    for b, (I, win, m) in enumerate(specs):
        q = region(o, b)
        O = np.fft.rfft2((q - q.mean()) * win)
        g.append((O * np.conj(I)).real[m].sum() / max((np.abs(I) ** 2)[m].sum(), 1e-12))
    print(f"  {n:>6}: " + "  ".join(f"{x:6.3f}" for x in g) + f"   min {min(g):.3f} max {max(g):.3f}")
