# The shipped (9068ded) hot-pixel pass, ported: 3x3 strict extremum and |v - median8| > k*sigma,
# k = 2 + 10(1-h/100)^2, centre pixel replaced by the median of its 8 neighbours.
import numpy as np
def hotpass_shipped(img, h, a, b):
    k = 2 + 10 * (1 - h / 100) ** 2
    H, W, _ = img.shape; p = np.pad(img, ((1, 1), (1, 1), (0, 0)), mode='edge')
    n = np.sort(np.stack([p[1 + dy:1 + dy + H, 1 + dx:1 + dx + W] for dy in (-1, 0, 1)
                          for dx in (-1, 0, 1) if dy or dx], -1), -1)
    med = (n[..., 3] + n[..., 4]) / 2
    sig = np.sqrt(np.maximum(a * np.maximum(med, 0) + b, 1e-12))
    rep = ((img > n[..., 7]) | (img < n[..., 0])) & (np.abs(img - med) > k * sig)
    return np.where(rep, med, img)
