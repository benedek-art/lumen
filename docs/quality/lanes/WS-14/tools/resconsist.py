"""Resolution consistency: preview render vs full-size render area-downsampled to the preview size.

usage: python3 resconsist.py BIG_ID BIG_OUT SMALL_ID SMALL_OUT
  BIG_* are renders at the larger long edge (identity and value), SMALL_* at the smaller one.
The big pair is box-downsampled in LINEAR light to the small size (what the renderer's own area
downsample does to the input), then the EFFECT e = log2 Y(value) - log2 Y(identity) is compared:
  ratio  RMS(e_small) / RMS(e_bigdown)       (1.00 = same strength)
  corr   Pearson correlation of e_small and e_bigdown (same pattern)
8 px border trimmed; pixels where either identity's encoded luma is < 8 or > 250 codes are excluded
(log2 of crushed / clipped pixels is quantisation noise, not the control's effect).
Also printed (amendment R5): Nq, the expected RMS of the 8-bit quantisation noise in the SMALL effect
map (both small renders quantised to whole codes: per pixel var = 2 * (1/12) * (dlog2Y/dcode)^2,
dlog2Y/dcode from the sRGB curve at the identity's code), and corr_max = S^2 / (S^2 + Nq^2) with
S^2 = RMS_small^2 - Nq^2, the best correlation a perfect implementation could reach on that frame."""
import sys, os
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, lin, logY


def down(path, size):
    l = lin(load(path)).astype(np.float32)
    ch = [np.asarray(Image.fromarray(l[..., c]).resize(size, Image.BOX)) for c in range(3)]
    l = np.stack(ch, -1).astype(np.float64)
    v = np.where(l <= 0.0031308, 12.92 * l, 1.055 * np.power(np.maximum(l, 0), 1 / 2.4) - 0.055)
    return np.clip(v * 255, 0, 255)


bi, bo, si, so = sys.argv[1:5]
s_id, s_out = load(si), load(so)
size = (s_id.shape[1], s_id.shape[0])
b_id, b_out = down(bi, size), down(bo, size)
es = logY(s_out) - logY(s_id); eb = logY(b_out) - logY(b_id)
c = 8
from wslib import encY
m = (encY(s_id) >= 8) & (encY(s_id) <= 250) & (encY(b_id) >= 8) & (encY(b_id) <= 250)
m = m[c:-c, c:-c]
es, eb = es[c:-c, c:-c][m], eb[c:-c, c:-c][m]
rs, rb = es.std(), eb.std()
corr = float(np.corrcoef(es.ravel(), eb.ravel())[0, 1])
code = np.clip(encY(s_id)[c:-c, c:-c][m], 1, 255)
v = code / 255.0
yl = np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)
dy = np.where(v <= 0.04045, 1 / 12.92, 2.4 / 1.055 * ((v + 0.055) / 1.055) ** 1.4) / 255.0
nq = float(np.sqrt(np.mean(2.0 / 12.0 * (dy / (yl * np.log(2))) ** 2)))
S2 = max(rs * rs - nq * nq, 0.0)
cmax = S2 / (S2 + nq * nq) if S2 + nq * nq > 0 else 0.0
print(f"  {os.path.basename(so)}: effectRMS small {rs:.4f} EV  bigDown {rb:.4f} EV  "
      f"ratio {rs/max(rb,1e-9):.2f}  corr {corr:.3f}  (masked {100*(1-m.mean()):.1f}% px)  "
      f"Nq {nq:.4f} EV  corr_max {cmax:.2f}  {'BELOW-FLOOR (corr exempt)' if rs < max(0.03, 2 * nq) else ''}")
