"""Exact Python ports of MonotoneCubic.swift and CurveStack.bakeParametric (audit only)."""
import math
import numpy as np


class MonotoneCubic:
    def __init__(self, points):
        pts = sorted([p for p in points if len(p) >= 2], key=lambda p: p[0])
        xs, ys = [], []
        for p in pts:
            if xs and p[0] <= xs[-1]:
                continue
            xs.append(float(p[0])); ys.append(float(p[1]))
        self.xs, self.ys = xs, ys
        n = len(xs)
        if n < 2:
            self.m = [0.0] * n
            return
        d = [(ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) for i in range(n - 1)]
        m = [0.0] * n
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in range(1, n - 1):
            m[i] = 0.0 if d[i - 1] * d[i] <= 0 else (d[i - 1] + d[i]) / 2
        for i in range(n - 1):
            if d[i] == 0:
                m[i] = 0.0; m[i + 1] = 0.0
            else:
                a = m[i] / d[i]; b = m[i + 1] / d[i]
                s = a * a + b * b
                if s > 9:
                    t = 3 / math.sqrt(s)
                    m[i] = t * a * d[i]; m[i + 1] = t * b * d[i]
        self.m = m

    def __call__(self, x):
        x = np.asarray(x, dtype=float)
        xs, ys, m = np.array(self.xs), np.array(self.ys), np.array(self.m)
        n = len(xs)
        if n == 0:
            return x.copy()
        if n == 1:
            return np.full_like(x, ys[0])
        lo = np.clip(np.searchsorted(xs, x, side='right') - 1, 0, n - 2)
        h = xs[lo + 1] - xs[lo]
        t = (x - xs[lo]) / h
        t2, t3 = t * t, t * t * t
        y = ((2 * t3 - 3 * t2 + 1) * ys[lo] + (t3 - 2 * t2 + t) * h * m[lo]
             + (-2 * t3 + 3 * t2) * ys[lo + 1] + (t3 - t2) * h * m[lo + 1])
        y = np.where(x <= xs[0], ys[0], y)
        y = np.where(x >= xs[-1], ys[-1], y)
        return y


def region_centres(splits):
    s = sorted(splits) if len(splits) == 3 else [.25, .5, .75]
    a = min(max(s[0], .02), .96)
    b = min(max(s[1], a + .01), .97)
    c = min(max(s[2], b + .01), .98)
    return [a / 2, (a + b) / 2, (b + c) / 2, (c + 1) / 2]


def crossfade(x, piv):
    n = len(piv)
    if not (x > piv[0]):
        return 0, 1.0
    if x >= piv[-1]:
        return n - 1, 1.0
    i = 0
    while i < n - 1 and not (piv[i] <= x < piv[i + 1]):
        i += 1
    u = (x - piv[i]) / (piv[i + 1] - piv[i])
    return i, 0.5 * (1 + math.cos(math.pi * u))


def soft_knee(u, k=0.8):
    if not (u > 0) or not math.isfinite(u):
        return 0.0
    if u <= k:
        return u
    q = k / (1 - k)
    return 1 - (1 - k) * (k / u) ** q


def slope_limit(delta, floor, probes=1024):
    dx = 1.0 / probes
    st = np.diff(delta)
    neg = st < 0
    if not neg.any():
        return math.inf
    return float(np.min((1 - floor) * dx / -st[neg]))


def bake_parametric(highlights=0, lights=0, darks=0, shadows=0, splits=(.25, .5, .75), size=1024):
    amounts = [min(max(v, -100), 100) / 100 for v in (shadows, darks, lights, highlights)]
    if not any(a != 0 for a in amounts):
        return np.linspace(0, 1, size), 1.0
    c = region_centres(list(splits))
    P = 1024
    bumps = np.zeros((4, P + 1))
    for i in range(P + 1):
        x = i / P
        lo, w = crossfade(x, c)
        env = 4 * x * (1 - x)
        bumps[lo][i] = w * env
        if lo + 1 < 4:
            bumps[lo + 1][i] = (1 - w) * env
    amp = [0.0] * 4
    for r in range(4):
        if amounts[r] != 0:
            sgn = -1 if amounts[r] < 0 else 1
            lim = slope_limit(bumps[r] * sgn, 0.2)
            amp[r] = lim if math.isfinite(lim) else 0
    req = sum(bumps[r] * amounts[r] * amp[r] for r in range(4))
    lim = slope_limit(req, 0)
    scale = min(1, lim * soft_knee(1 / lim, 0.8)) if math.isfinite(lim) else 1
    signed = [amounts[r] * amp[r] for r in range(4)]
    out = np.zeros(size); run = -math.inf
    for i in range(size):
        x = i / (size - 1)
        lo, w = crossfade(x, c)
        d = signed[lo] * w + (signed[lo + 1] * (1 - w) if lo + 1 < 4 else 0)
        env = 4 * x * (1 - x)
        run = max(run, min(max(x + d * env * scale, 0), 1))
        out[i] = run
    return out, scale


def lut1d_eval(samples, x):
    x = np.clip(np.asarray(x, float), 0, 1)
    n = len(samples)
    f = x * (n - 1)
    i = np.clip(np.floor(f).astype(int), 0, n - 2)
    t = f - i
    return samples[i] * (1 - t) + samples[i + 1] * t


def master(x, point=None, param=None):
    y = np.clip(np.asarray(x, float), 0, 1)
    if param is not None:
        y = lut1d_eval(param, y)
    if point is not None:
        y = MonotoneCubic(point)(y)
    return y


# sRGB transfer
def srgb_enc(v):
    v = np.clip(v, 0, None)
    return np.where(v <= 0.0031308, 12.92 * v, 1.055 * np.power(v, 1 / 2.4) - 0.055)


def srgb_dec(e):
    e = np.asarray(e, float)
    return np.where(e <= 0.04045, e / 12.92, np.power((e + 0.055) / 1.055, 2.4))


# ---- colour helpers (audit) ----
S2R = np.array([[0.6274040, 0.3292820, 0.0433136], [0.0690970, 0.9195400, 0.0113612], [0.0163916, 0.0880132, 0.8955950]])
R2S = np.linalg.inv(S2R)
W2020 = np.array([0.2627, 0.6780, 0.0593])


def png_to_rec2020_linear(img8):
    lin = srgb_dec(img8 / 255.0)
    return lin @ S2R.T


def rec2020_linear_to_png(lin):
    s = np.clip(lin @ R2S.T, 0, 1)
    return np.round(255 * srgb_enc(s))


def apply_stack(lin, master_f=None, preserve=True, chan=(None, None, None)):
    """CurveStack.apply at white 1, no luma curve, masterBlack==0 (Python port)."""
    e = srgb_enc(np.clip(lin, 0, 1))
    if master_f is not None:
        if preserve:
            L = np.clip(e @ W2020, 0, 1)
            k = np.where(L > 1e-6, master_f(L) / np.maximum(L, 1e-6), 1)
            e2 = e * k[..., None]
            e = np.where((L > 1e-6)[..., None], e2, master_f(e))
        else:
            e = master_f(e)
    for i, f in enumerate(chan):
        if f is not None:
            e[..., i] = np.where(e[..., i] > 1, f(np.ones_like(e[..., i])), f(e[..., i]))
    return srgb_dec(np.clip(e, 0, 1))


def oklab_from_srgb_linear(c):
    M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929], [0.2119034982, 0.6806995451, 0.1073969566], [0.0883024619, 0.2817188376, 0.6299787005]])
    M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099], [0.0259040371, 0.7827717662, -0.8086757660]])
    lms = np.cbrt(c @ M1.T)
    return lms @ M2.T


def oklch_from_png(img8):
    lab = oklab_from_srgb_linear(srgb_dec(img8 / 255.0))
    L, a, b = lab[..., 0], lab[..., 1], lab[..., 2]
    return L, np.hypot(a, b), np.degrees(np.arctan2(b, a)) % 360
