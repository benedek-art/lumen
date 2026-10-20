"""Sensor noise model: var(x) = K * x + sigma_r^2  (x = normalized signal, black=0, white=1).

estimate(): fits (K, sigma_r^2) per image from flat blocks, per packed channel pooled.
synthesize(): adds calibrated noise to a clean packed image.
"""
import numpy as np


def _block_stats(ch: np.ndarray, b: int = 8):
    h, w = ch.shape[0] // b * b, ch.shape[1] // b * b
    c = ch[:h, :w]
    # noise-only signal: diagonal second difference cancels smooth gradients;
    # (a - b - c + d)/2 has variance = noise var for independent noise
    d = (c[:-1, :-1] - c[:-1, 1:] - c[1:, :-1] + c[1:, 1:]) / 2.0
    hd, wd = (h - 1) // b * b, (w - 1) // b * b
    d = d[:hd, :wd].reshape(hd // b, b, wd // b, b)
    m = c[:hd, :wd].reshape(hd // b, b, wd // b, b).mean(axis=(1, 3))
    v = d.var(axis=(1, 3))
    return m.ravel(), v.ravel()


def estimate(packed: np.ndarray, nbins: int = 24, pct: float = 25.0):
    """Return (K, read_var). packed: (4, h, w) normalized."""
    ms, vs = [], []
    for ch in packed:
        m, v = _block_stats(ch)
        ms.append(m); vs.append(v)
    m, v = np.concatenate(ms), np.concatenate(vs)
    ok = (m > 0.002) & (m < 0.6)  # avoid clipping at both ends
    m, v = m[ok], v[ok]
    edges = np.quantile(m, np.linspace(0, 1, nbins + 1))
    xs, ys = [], []
    for lo, hi in zip(edges[:-1], edges[1:]):
        sel = (m >= lo) & (m < hi)
        if sel.sum() < 50:
            continue
        # flattest blocks in this brightness bin = texture-free; pct-th percentile,
        # rescaled so a pure-noise population maps back to its mean (chi2, 63 dof ~ 0.917 at 25%)
        xs.append(np.median(m[sel]))
        ys.append(np.percentile(v[sel], pct) / _chi2_pct_ratio(pct))
    xs, ys = np.array(xs), np.array(ys)
    # weighted LS: variance estimates scale with their own value, so weight by 1/y
    # (otherwise bright bins dominate and the read-noise intercept is garbage)
    wts = 1 / np.maximum(ys, 1e-12)
    A = np.stack([xs, np.ones_like(xs)], 1) * wts[:, None]
    (K, r), *_ = np.linalg.lstsq(A, ys * wts, rcond=None)
    return float(max(K, 1e-8)), float(max(r, 1e-10))


def _chi2_pct_ratio(pct, dof=49):
    # 8x8 block of diff values -> 7x7=49 used after crop; ratio of percentile to mean
    from scipy.stats import chi2
    return chi2.ppf(pct / 100, dof) / dof


def synthesize(clean: np.ndarray, K: float, read_var: float, rng=np.random):
    """Poisson-Gaussian noise on normalized packed clean image."""
    x = np.clip(clean, 0, None)
    shot = rng.poisson(x / K) * K
    return (shot + rng.normal(0, np.sqrt(read_var), x.shape)).astype(np.float32)


if __name__ == "__main__":
    # self-check: estimator recovers known params on a synthetic textured scene
    rng = np.random.default_rng(0)
    yy, xx = np.mgrid[0:1024, 0:1024] / 1024
    scene = 0.05 + 0.4 * xx * yy + 0.05 * (np.sin(xx * 80) > 0.9)
    clean = np.stack([scene] * 4).astype(np.float32)
    for K, r in [(1e-4, 1e-6), (2e-3, 4e-5)]:
        Ke, re = estimate(synthesize(clean, K, r, rng))
        print(f"K {K:.2e}->{Ke:.2e}  read {r:.2e}->{re:.2e}")
        assert abs(Ke / K - 1) < 0.15, (K, Ke)
    print("noise self-check OK")
