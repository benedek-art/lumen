"""Real-star check on a night shot: per detected star, how much peak height and 3x3 flux the
denoiser keeps vs the original. Stars are located on a smoothed copy so noise spikes don't bias it.
python -m lumen_denoise.realstars FILE.ARW --methods bm3d,net:runs/A/best.pt [--box y0,x0,size]"""
import argparse
import numpy as np
from scipy.ndimage import gaussian_filter, maximum_filter, median_filter
from . import raw as rawio
from .prepare import to_rggb
from .bench import get
from .train import NoiseTable

ap = argparse.ArgumentParser(); ap.add_argument("file"); ap.add_argument("--methods", required=True)
ap.add_argument("--box", default=""); ap.add_argument("--calib", default="data/calib.json")
a = ap.parse_args()
r = rawio.load(a.file); p = to_rggb(rawio.pack(r.cfa), r.pattern)
t = NoiseTable(a.calib); K, rv = t.params(r.model, r.iso)
if a.box:
    y0, x0, s = map(int, a.box.split(",")); p = p[:, y0:y0 + s, x0:x0 + s]
else:  # darkest-variance 768px region = sky
    s = 768; g = p.mean(0); best = None
    for y0 in range(0, p.shape[1] - s, s // 2):
        for x0 in range(0, p.shape[2] - s, s // 2):
            v = np.std(gaussian_filter(g[y0:y0 + s, x0:x0 + s], 8))
            if best is None or v < best[0]: best = (v, y0, x0)
    _, y0, x0 = best; p = p[:, y0:y0 + s, x0:x0 + s]
lum = p.mean(0); sm = gaussian_filter(lum, 1.0); bgm = median_filter(sm, 25)
sd = np.sqrt(K * np.clip(bgm, 0, None) + rv) / 2  # std of the 4-channel mean
pk = (sm == maximum_filter(sm, 7)) & (sm - bgm > 4 * sd / 1.5)
ys, xs = np.nonzero(pk); keep = (ys > 3) & (xs > 3) & (ys < s - 4) & (xs < s - 4); ys, xs = ys[keep], xs[keep]
print(f"{r.model} ISO{r.iso:.0f} box {y0},{x0} size {s}: {len(ys)} stars")
def meas(img):
    l = img.mean(0); bg = median_filter(l, 25)
    peak = np.array([l[y, x] - bg[y, x] for y, x in zip(ys, xs)])
    flux = np.array([(l[y - 1:y + 2, x - 1:x + 2] - bg[y, x]).sum() for y, x in zip(ys, xs)])
    return peak, flux
p0, f0 = meas(p)
for name in a.methods.split(","):
    f = get(name); hh, ww = (-s) % 16, (-s) % 16
    y = f(np.pad(p, ((0, 0), (0, hh), (0, ww)), mode="reflect"), K, rv)[:, :s, :s]
    p1, f1 = meas(y)
    faint = f0 < np.median(f0)
    print(f"  {name}: flux kept {np.median(f1 / f0):.2f} (faint half {np.median(f1[faint] / f0[faint]):.2f}), "
          f"peak kept {np.median(p1 / p0):.2f}, stars lost (<30% flux) {np.mean(f1 / f0 < 0.3) * 100:.0f}%")
