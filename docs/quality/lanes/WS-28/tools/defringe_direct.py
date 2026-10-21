"""defringe_direct.py BEFORE.png AFTER.png [x0 y0 x1 y1]

Direct Defringe measurement: pixels within 4 px of a >= 1.5-stop luminance edge (9x9
window range of log2 Y, from BEFORE), OKLab chroma > 0.03 in BEFORE, split by BEFORE's
OKLab hue (blue 230-279, purple 279-351, green 148-184); prints mean chroma before/after
per class. Default region: the top-right quadrant of a 7008x4672 frame (A7 IV, 6929).
numpy + Pillow only."""
import sys
import numpy as np
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929], [0.2119034982, 0.6806995451, 0.1073969566], [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099], [0.0259040371, 0.7827717662, -0.8086757660]])
box = tuple(map(int, sys.argv[3:7])) if len(sys.argv) >= 7 else (3500, 0, 7008, 2400)
def window(a, fn, r=4):
    out = a.copy()
    for axis in (0, 1):
        src = out.copy()
        for d in range(1, r + 1):
            out = fn(out, np.roll(src, d, axis)); out = fn(out, np.roll(src, -d, axis))
    return out
def load(p):
    a = np.asarray(Image.open(p).convert('RGB'))[box[1]:box[3], box[0]:box[2]].astype(np.float32) / 255
    l = np.where(a <= 0.04045, a / 12.92, ((a + 0.055) / 1.055) ** 2.4)
    lab = np.cbrt(l @ M1.T) @ M2.T
    return l, np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360
l0, C0, h0 = load(sys.argv[1]); _, C1, _ = load(sys.argv[2])
lY = np.log2(np.maximum(l0 @ [0.2126, 0.7152, 0.0722], 1e-4))
edge = (window(lY, np.maximum) - window(lY, np.minimum)) > 1.5
for name, lo, hi in [('blue', 230, 279), ('purple', 279, 351), ('green', 148, 184)]:
    m = edge & (h0 >= lo) & (h0 < hi) & (C0 > 0.03)
    print(f"{name:7s} {lo}-{hi} deg: {int(m.sum()):7d} edge px  mean OKLab C before {C0[m].mean():.4f} after {C1[m].mean():.4f}  ({100 * (1 - C1[m].mean() / C0[m].mean()):.0f}% removed)")
far = ~window(edge.astype(np.float32), np.maximum, 6).astype(bool)
print(f"away from edges (>10 px): mean |dC| {np.abs(C1 - C0)[far].mean():.5f}, max {np.abs(C1 - C0)[far].max():.5f}")
