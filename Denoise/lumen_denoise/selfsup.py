"""Self-supervised fine-tuning on REAL noisy raws (no clean target), mixed with the supervised loss.

Why: the synthetic Poisson-Gaussian pairs miss whatever the real sensor does that the model doesn't
(residual structure, tails, per-unit quirks). Real high-ISO frames carry that noise for free; a
self-supervised term lets the net see it without ground truth.

Two modes (both unbiased for zero-mean noise, both need an L2 loss in LINEAR space):
  r2r  Recorrupted-to-Recorrupted (Pang et al. CVPR 2021). With z ~ N(0, Sigma) and the noise
       Sigma = K*x + r we already know from calibration:
           input  y^ = y + a*z,   target  y~ = y - z/a
       noise(y^) = n + a z and noise(y~) = n - z/a have cov Sigma - Sigma = 0, so for Gaussian n they
       are independent and E|f(y^) - y~|^2 = E|f(y^) - x|^2 + const: the supervised MSE at noise
       level (1+a^2)*Sigma. Full resolution (matches inference); the std map simply says
       "ISO x (1+a^2)" (K, r both scale by 1+a^2), so the conditioned net is used consistently.
       Limitation: noise components NOT in z (row banding, FPN) are shared by input and target, so
       R2R teaches the net to KEEP them. Use n2n (or the supervised banding noise) for those.
  n2n  Neighbor2Neighbor (Huang et al. CVPR 2021). Two half-res sub-images g1(y), g2(y) take one
       packed pixel each from every 2x2 cell of the packed image; loss
           |f(g1 y) - g2 y|^2 + gamma |f(g1 y) - g2 y - (g1 f(y) - g2 f(y))|^2   (f(y) no grad)
       The regulariser corrects the half-pixel signal mismatch between neighbours. pairs="vert"
       (default) picks vertically adjacent packed px: they hold DIFFERENT raw rows (packed row i =
       raw rows 2i, 2i+1), so row noise is independent between input and target and gets removed.
       "diag" also decorrelates raw columns (column FPN); "any" (paper's sampler) includes horizontal
       pairs, which share raw rows - row noise then survives. Cost: trains at half resolution.
  Blind-spot (Noise2Void/Noise2Self) is not offered: it assumes noise independent between a pixel
  and its neighbours, which row noise / any spatially correlated component violates, and it throws
  away the centre pixel (weak at high ISO where every photon counts).

Why L2 + linear: these losses are unbiased only because E[target | input] = clean. With L1 the
optimum is the conditional MEDIAN of the noisy target, which for Poisson (skewed, low counts) is
not the mean; in tone space E[(x+n)^(1/2.2)] != x^(1/2.2) (Jensen), so the net would learn a
brightness-biased output (darker shadows). Linear L2 has no such bias.

Scale: the raw MSE is ~ noise variance (1e-6..1e-3 across ISO). selfsup_loss normalises per sample:
  norm="std" (default): divide by the sample's mean noise std. Then the gradient has the SAME ISO
               scaling and roughly the same size as the supervised tone-L1 + 4x linear-L1 (both ~ sigma;
               measured on a nf16 residual UNet, ISO 1600-51200: grad-norm ratio ss/sup 0.3-0.9 for
               r2r, 0.5-1.0 for n2n), and the loss value is of the same order (~0.02-0.3). So
               total = sup + w * ss with w in 0.1-1 means "w times as much pull as the supervised term".
  norm="var":  divide by mean noise variance -> loss O(1) (~(1+1/a^2) + excess) and every ISO weighs
               the same in loss VALUE, but gradients are 10-100x the supervised ones and largest at
               LOW ISO; with clip_grad_norm(1.0) it would swamp the supervised term. Use w ~ 0.01.
parts["excess"] = normalised loss minus the irreducible target-noise term ~= MSE(pred, clean)/var:
an unbiased-ish estimate of residual error in noise units on REAL photos (no GT needed) - log it.
"""
import json, random
from pathlib import Path
import numpy as np
import torch
import torch.nn.functional as F

MODES = ("r2r", "n2n")


def std_map(noisy, K, r):
    """Duplicate of train.std_map (importing train here would be circular). Keep in sync."""
    sig = F.avg_pool2d(noisy.mean(1, keepdim=True).clamp(min=0), 3, 1, 1)
    return torch.sqrt(K * sig + r)


def pixel_var(y, K, r, k=5):
    """Per-channel noise variance K*x_c + r from the local mean of the noisy image (x_c differs per
    CFA channel - R/B are much darker than G pre-WB - so the channel-mean std map would mis-scale z).
    The mean is NOT clamped at 0 (that overstates the variance in blacks, ~+9% at x=0, ISO 51200,
    breaking Sigma_z = Sigma_n); K*m + r is unbiased, only floored at r/4 to stay positive."""
    m = F.avg_pool2d(F.pad(y, (k // 2,) * 4, mode="replicate"), k, 1)
    return torch.maximum(K * m + r, 0.25 * r * torch.ones_like(m))


def _cells(x):
    """(B,C,H,W) -> (B,C,H/2,W/2,4): the 2x2 packed cell, positions 0=TL 1=TR 2=BL 3=BR."""
    B, C, H, W = x.shape
    x = x[:, :, : H // 2 * 2, : W // 2 * 2]
    return x.reshape(B, C, H // 2, 2, W // 2, 2).permute(0, 1, 2, 4, 3, 5).reshape(B, C, H // 2, W // 2, 4)


def n2n_pairs(B, h, w, pairs="vert", gen=None, device="cpu"):
    """Random neighbour pair per cell -> (i1, i2) long (B,h,w) in 0..3. vert: same column, other row
    (different raw rows); diag: other row AND column; any: the paper's 4-neighbour sampler."""
    rnd = lambda n: torch.randint(0, n, (B, h, w), generator=gen)
    o = rnd(2)  # which one is the input
    if pairs == "vert":
        c = rnd(2); a, b = c, c + 2
    elif pairs == "diag":
        d = rnd(2); a, b = d, 3 - d  # (0,3) or (1,2)
    elif pairs == "any":
        t = torch.tensor([[0, 1], [2, 3], [0, 2], [1, 3]])[rnd(4)]
        a, b = t[..., 0], t[..., 1]
    else:
        raise ValueError(pairs)
    i1, i2 = torch.where(o == 0, a, b), torch.where(o == 0, b, a)
    return i1.to(device), i2.to(device)


def subsample(x, idx):
    """Pick cell position idx (B,h,w) from every 2x2 cell -> (B,C,h,w) (a valid RGGB packed image)."""
    c = _cells(x)
    return torch.gather(c, 4, idx[:, None, :, :, None].expand(*c.shape[:4], 1)).squeeze(4)


def recorrupt(y, K, r, alpha=0.5, gen=None):
    """R2R pair (y + a z, y - z/a) with z ~ N(0, K x_c + r); returns (input, target, var)."""
    v = pixel_var(y, K, r).detach()
    z = (torch.randn(y.shape, generator=gen).to(y) if gen is not None else torch.randn_like(y)) * v.sqrt()
    return y + alpha * z, y - z / alpha, v


def _mmean(e, m):
    return (e * m).sum((1, 2, 3)) / m.sum((1, 2, 3)).clamp(min=1)


def selfsup_loss(net, noisy, K, r, mode="r2r", gamma=1.0, alpha=0.5, pairs="vert", std_fn=std_map,
                 norm="std", clip=0.98, gen=None):
    """noisy (B,4,H,W) real raw, K/r (B,1,1,1) calibrated params. net(x, std_map) -> clean estimate.
    Returns (loss scalar, parts dict of floats-as-tensors). Clipped pixels (and their 5x5 neighbours = pixel_var window)
    are masked: noise is not zero-mean at the white point. gen: optional CPU torch.Generator."""
    y = noisy
    keep = (F.max_pool2d(y.amax(1, keepdim=True), 5, 1, 2) < clip).to(y.dtype)
    if mode == "r2r":
        yh, yt, v = recorrupt(y, K, r, alpha, gen)
        s = 1 + alpha ** 2
        pred = net(yh, std_fn(yh, K * s, r * s))
        m = keep.expand_as(y)
        mse = _mmean((pred - yt) ** 2, m)
        vb = _mmean(v, m)
        floor = 1 + 1 / alpha ** 2
        reg = torch.zeros_like(mse)
    elif mode == "n2n":
        B, _, H, W = y.shape
        i1, i2 = n2n_pairs(B, H // 2, W // 2, pairs, gen, y.device)
        g1, g2 = subsample(y, i1), subsample(y, i2)
        with torch.no_grad():
            fy = net(y, std_fn(y, K, r))
        pred = net(g1, std_fn(g1, K, r))
        m = (subsample(keep, i1) * subsample(keep, i2)).expand_as(g1)
        d = pred - g2
        mse = _mmean(d ** 2, m)
        reg = _mmean((d - (subsample(fy, i1) - subsample(fy, i2))) ** 2, m)
        vb = _mmean(subsample(pixel_var(y, K, r), i2), m)
        floor = 1.0
    else:
        raise ValueError(f"mode {mode!r} not in {MODES}")
    den = vb.clamp(min=1e-12)
    den = den if norm == "var" else den.sqrt()
    per = (mse + gamma * reg) / den
    loss = per.mean()
    parts = {"ss": loss.detach(), "ss_mse": mse.mean().detach(), "ss_reg": reg.mean().detach(),
             "ss_excess": (mse / vb.clamp(min=1e-12) - floor).mean().detach()}
    return loss, parts


def gamma_ramp(it, start, ramp, gamma):
    """N2N paper ramps gamma up from 0 for stability; linear over `ramp` steps after `start`."""
    return gamma * min(max((it - start) / max(ramp, 1), 0.0), 1.0)


# ---------------------------------------------------------------- real-photo crops (prepare_real.py)

def unpack_t(p):
    """(4,h,w) RGGB packed -> (2h,2w) CFA (numpy)."""
    _, h, w = p.shape
    out = np.empty((2 * h, 2 * w), p.dtype)
    out[0::2, 0::2], out[0::2, 1::2], out[1::2, 0::2], out[1::2, 1::2] = p
    return out


def pack_t(c):
    return np.stack([c[0::2, 0::2], c[0::2, 1::2], c[1::2, 0::2], c[1::2, 1::2]])


def augment(c, ps, fh, fv, tr):
    """Exact Bayer-aware dihedral augmentation. c: (4, >=ps+1, >=ps+1) packed RGGB (ps x ps if no
    flips). A raw flip turns RGGB into GRBG/GBRG; dropping one raw row/column restores RGGB, hence
    the one extra packed px. Raw transpose keeps R,B and swaps G1/G2 - still RGGB."""
    raw_ = unpack_t(c)
    raw_ = raw_[:, ::-1][:, 1:1 + 2 * ps] if fh else raw_[:, : 2 * ps]
    raw_ = raw_[::-1][1:1 + 2 * ps] if fv else raw_[: 2 * ps]
    if tr:
        raw_ = raw_.T
    return pack_t(raw_)


def table_params(table, model, iso):
    """(K, r) at iso, extrapolated with the physical model beyond the calibrated range (K ~ ISO,
    r = b*ISO^2 + c from the two edge-most table ISOs). Clamping would under-report noise on e.g.
    ISO 102400 crops by ~2x; R2R then needs Sigma_z = Sigma_n or the target shares input noise."""
    lo, hi = table.iso_range(model)
    if lo <= iso <= hi:
        return table.params(model, iso)
    e = hi if iso > hi else lo
    e2 = max(e / 2, lo) if iso > hi else min(e * 2, hi)
    (K1, r1), (K2, r2) = table.params(model, e), table.params(model, e2)
    b = (r1 - r2) / (e * e - e2 * e2) if e2 != e else 0.0
    b = max(b, 0.0); c = max(r1 - b * e * e, 0.0)
    return K1 * iso / e, max(b * iso * iso + c, 1e-12)


class RealData:
    """Random patches of real noisy crops written by prepare_real.py, with their calibrated (K, r).
    Files are opened per sample (no long-lived mmaps: 20k crops would exhaust macOS's fd limit)."""

    def __init__(self, dir, meta_path, device="cpu", iso_min=0, flips=True, rng=None):
        meta = json.load(open(meta_path))
        self.dev, self.flips, self.rng = device, flips, rng or random
        self.items = []
        for f in sorted(Path(dir).glob("*.npy")):
            m = meta.get(f.stem) or meta.get(f.stem.rsplit("_c", 1)[0])
            if m and float(m["iso"]) >= iso_min:
                self.items.append((f, m["model"], float(m["iso"])))
        if not self.items:
            raise ValueError(f"no crops with meta in {dir}")

    def __len__(self):
        return len(self.items)

    def batch(self, n, ps, table):
        xs, ks, rs = [], [], []
        R = self.rng
        for _ in range(n):
            f, model, iso = self.items[R.randrange(len(self.items))]
            a = np.load(f, mmap_mode="r")
            _, h, w = a.shape
            q = ps + 1 if self.flips and min(h, w) > ps else ps
            y0, x0 = R.randrange(h - q + 1), R.randrange(w - q + 1)
            c = np.array(a[:, y0:y0 + q, x0:x0 + q], np.float32)
            if q > ps:
                c = augment(c, ps, R.random() < 0.5, R.random() < 0.5, R.random() < 0.5)
            elif R.random() < 0.5:
                c = c.transpose(0, 2, 1)[[0, 2, 1, 3]]
            del a
            K, r = table_params(table, model, iso)
            xs.append(torch.from_numpy(np.ascontiguousarray(c))); ks.append(K); rs.append(r)
        x = torch.stack(xs).to(self.dev)
        K = torch.tensor(ks, dtype=torch.float32, device=self.dev).view(-1, 1, 1, 1)
        r = torch.tensor(rs, dtype=torch.float32, device=self.dev).view(-1, 1, 1, 1)
        return x, K, r


@torch.no_grad()
def real_excess(net, data, table, n=32, ps=256, mode="r2r", seed=0, **kw):
    """No-GT metric on held-out REAL crops: mean ss_excess (~ MSE to clean / noise var at the
    recorrupted level; lower = better). Seeded so runs are comparable. Synthetic val can't see
    real-noise gains; this can (relative comparisons only)."""
    st = random.getstate(); random.seed(seed)
    rng0, data.rng = data.rng, random.Random(seed)
    g = torch.Generator().manual_seed(seed)
    was = getattr(net, "training", None)
    if was is not None: net.eval()
    try:
        x, K, r = data.batch(n, ps, table)
        ex = [selfsup_loss(net, x[i:i + 4], K[i:i + 4], r[i:i + 4], mode=mode, gen=g, **kw)[1]["ss_excess"] for i in range(0, n, 4)]
    finally:
        data.rng = rng0; random.setstate(st)
        if was is not None: net.train(was)
    return float(torch.stack(ex).mean())
