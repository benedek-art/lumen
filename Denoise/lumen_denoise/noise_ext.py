"""Richer synthetic raw noise on top of the calibrated Poisson-Gaussian model (all opt-in).

    noisy = K_c * Poisson(x / K_c) + read + row + col + fpn + hot,  then quantized to the DN grid

Components (each a NoiseOpts flag; all off == train.add_noise, bit-identical for the same RNG state):
  gain     per-channel K jitter (CFA channels have slightly different conversion gain); the SIGNAL
           is untouched so the target stays consistent - only the shot-noise level differs per channel.
  heavy    Tukey-lambda read noise instead of Gaussian (ELD, Wei et al. CVPR 2020: read noise is
           long-tailed from RTS / flicker / dark spikes), rescaled so its variance is still r.
  row/col  banding: one N(0, s) offset per RAW row / column. Packed row i = raw rows 2i (ch 0,1)
           and 2i+1 (ch 2,3); packed col j = raw cols 2j (ch 0,2) and 2j+1 (ch 1,3).
  fpn      dark shading / fixed pattern: per-channel black-level error (ELD "color bias"), smooth
           low-frequency offset (bilinear 4x4 grid), per-column fixed offset (PMN dark shading).
           Fixed per camera in reality; drawn per sample here so the net learns to ignore it.
  hot      sparse hot pixels (single raw px, log-uniform amplitude; rate small, mostly long exposures).
  quant    rounding to the ADC grid AFTER noise: step = 1/(white-black) normalized.
  dualgain Sony A7 IV switches to high conversion gain at ISO 320; the fitted table (ISO >= 400) is
           HCG-only, so below the switch the pre-gain read noise (in e-) is raised by lcg_ratio.

Read variance r is the TOTAL read variance from calibrate.py, whose diagonal second difference
cancels row/column offsets, so row/col/fpn terms are ADDED on top of r (not carved out of it).
Magnitudes default to literature-scale guesses (fractions of read sd) until calibrate_rows.py
measures them; see ExtParams.
"""
import json, math
from dataclasses import dataclass, fields
import numpy as np
import torch
import torch.nn.functional as F

_FLAGS = ("row", "col", "gain", "fpn", "hot", "quant", "dualgain", "heavy")


@dataclass
class NoiseOpts:
    row: bool = False
    col: bool = False
    gain: bool = False
    fpn: bool = False
    hot: bool = False
    quant: bool = False
    dualgain: bool = False
    heavy: bool = False

    @classmethod
    def parse(cls, spec: str = ""):
        """"" -> all off, "all" -> all on, else comma list of flag names."""
        spec = (spec or "").strip().lower()
        if spec in ("", "none", "off"):
            return cls()
        if spec == "all":
            return cls(**{f: True for f in _FLAGS})
        names = [s.strip() for s in spec.split(",") if s.strip()]
        bad = [n for n in names if n not in _FLAGS]
        if bad:
            raise ValueError(f"unknown noise opts {bad}; choose from {','.join(_FLAGS)} or 'all'")
        return cls(**{n: True for n in names})

    def any(self):
        return any(getattr(self, f.name) for f in fields(self))

    def __str__(self):
        on = [f.name for f in fields(self) if getattr(self, f.name)]
        return ",".join(on) if on else "off"


# Per-camera defaults. *_frac = std as a fraction of the sample's read sd sqrt(r); a measured
# curve (absolute std in normalized units vs "iso", from calibrate_rows.py) overrides it.
# Guesses: ELD reports row noise as the dominant structured term on Sony bodies with sd a small
# fraction of read sd; column noise is "generally negligible" (ELD 3.1). Panasonic m43 bands more.
_BASE = dict(row_frac=0.08, col_frac=0.03, chan_gain_sd=0.01, black_frac=0.05, shade_frac=0.03,
             fpn_col_frac=0.02, shade_grid=4, hot_rate=1e-5, hot_lo=8.0, hot_max=0.1,
             tl_lambda=0.0, white=16383, black=512, dg_switch=None, lcg_ratio=2.5, dg_b=None, dg_c=None)
CAM_DEFAULTS = {
    "ILCE-7M4": dict(_BASE, dg_switch=320.0),
    "DMC-GX85": dict(_BASE, row_frac=0.15, col_frac=0.05, white=4095, black=143),
}
_CURVES = {"row_sd": "row_frac", "col_sd": "col_frac", "black_offset_sd": "black_frac", "hot_rate": None}


def _loglog(iso_grid, vals, iso):
    v = np.maximum(np.asarray(vals, np.float64), 1e-30)
    return float(np.exp(np.interp(math.log(iso), np.log(np.asarray(iso_grid, np.float64)), np.log(v))))


def fit_bc(rows, iso_min=400):
    """Least-squares r = b*ISO^2 + c over table rows [[iso, K, r], ...] with iso >= iso_min
    (the same physical model calibrate.py fits): b = pre-gain, c = post-gain (ADC) read noise."""
    a = np.array([x for x in sorted(rows) if x[0] >= iso_min], np.float64)
    if len(a) < 2:
        return None, None
    (b, c), *_ = np.linalg.lstsq(np.stack([a[:, 0] ** 2, np.ones(len(a))], 1), a[:, 2], rcond=None)
    return float(max(b, 0.0)), float(max(c, 0.0))


def dualgain_r(r, iso, b, c, switch=320.0, lcg_ratio=2.5):
    """Read variance with the conversion-gain switch. The table r = b*ISO^2 + c was fit on HCG
    ISOs; K (normalized/e-) is proportional to ISO in both modes, so the pre-gain term b*ISO^2 =
    (K*e_read)^2 just needs e_read scaled by lcg_ratio below the switch; c (ADC) is unchanged.
    r may carry training jitter: it is rescaled by the model ratio so the jitter survives."""
    if switch is None or b is None or iso >= switch:
        return r
    hcg = b * iso * iso + c
    return r * (b * (lcg_ratio * iso) ** 2 + c) / max(hcg, 1e-30)


class ExtParams:
    """Per-camera magnitudes for the extra terms, ISO-interpolated log-log like train.NoiseTable.

    JSON (calibrate_rows.py): {"ILCE-7M4": {"iso": [...], "row_sd": [...], "col_sd": [...],
    "chan_gain_sd": float, "black_offset_sd": [...], "hot_rate": [...]}, ...}; row_sd / col_sd /
    black_offset_sd are absolute std in normalized units (black=0, white=1). Any missing key ->
    default; any scalar default key (e.g. tl_lambda, white, black, lcg_ratio) may be overridden.
    jitter: per-sample log-uniform factor in [1/j, j] on row/col/fpn std (calibration is
    uncertain and varies with temperature); 1 = exact."""

    def __init__(self, cams=None, jitter=1.5, table=None):
        self.jitter = float(jitter)
        self.c = {m: dict(d) for m, d in CAM_DEFAULTS.items()}
        for m, d in (cams or {}).items():
            d = dict(d)
            for key in _CURVES:  # calibrate_rows writes 0.0 = "below detection / no frames", not "none":
                cv = d.get(key)    # drop those points (log-log would collapse the whole interval to 0)
                if isinstance(cv, (list, tuple)):
                    keep = [(i, v) for i, v in zip(d["iso"], cv) if v and v > 0]
                    if keep:
                        d[key + "_iso"], d[key] = [i for i, _ in keep], [v for _, v in keep]
                    else:
                        d.pop(key)  # nothing measured -> *_frac / scalar default
            self.c.setdefault(m, dict(_BASE)).update(d)
        if table is not None:  # pre/post-gain read split for dualgain from the calib table
            for m, rows in (table.items() if isinstance(table, dict) else ()):
                cm = self.c.setdefault(m, dict(_BASE))
                if cm.get("dg_b") is None:
                    cm["dg_b"], cm["dg_c"] = fit_bc(rows)

    @classmethod
    def load(cls, path=None, calib=None, jitter=1.5):
        """path: calibrate_rows.py JSON (optional); calib: calib.json path or loaded dict."""
        cams = json.load(open(path)) if path else None
        if isinstance(calib, str):
            calib = json.load(open(calib))
        return cls(cams, jitter, calib)

    def cam(self, model):
        return self.c.get(model) or self.c.setdefault(model, dict(_BASE))

    def get(self, model, key, iso, read_sd=None):
        """Absolute magnitude for a curve key (row_sd, col_sd, black_offset_sd, hot_rate)."""
        d = self.cam(model)
        if key in d and isinstance(d[key], (list, tuple)):
            return _loglog(d.get(key + "_iso", d["iso"]), d[key], iso)
        if key in d and d[key] is not None:
            return float(d[key])
        frac = _CURVES.get(key)
        return d[frac] * read_sd if frac else float(d[key])

    def jitter_ex2(self):
        """E[f^2] for f = exp(U(-L, L)), L = log(jitter): sinh(2L)/(2L)."""
        L = math.log(max(self.jitter, 1.0))
        return 1.0 if L < 1e-12 else math.sinh(2 * L) / (2 * L)


def _per_sample(K, r, iso, models, opts, params):
    """Python-side per-sample magnitudes (B is small) -> dict of (B,) float lists."""
    B = K.shape[0]
    iso = [float(v) for v in (iso.flatten().tolist() if torch.is_tensor(iso) else
                              (iso if isinstance(iso, (list, tuple)) else [iso] * B))]
    models = [models] * B if isinstance(models, str) else list(models)
    rs = r.detach().float().cpu().flatten().tolist() if torch.is_tensor(r) else [float(r)] * B
    if len(rs) == 1: rs = rs * B
    out = {k: [] for k in ("r", "row", "col", "bias", "shade", "fcol", "hot", "hot_lo", "hot_hi",
                           "q", "lam", "gsd", "grid")}
    for m, i, rv in zip(models, iso, rs):
        d = params.cam(m)
        if opts.dualgain:
            rv = dualgain_r(rv, i, d.get("dg_b"), d.get("dg_c"), d.get("dg_switch"), d["lcg_ratio"])
        sd = math.sqrt(max(rv, 0.0))
        out["r"].append(rv)
        out["row"].append(params.get(m, "row_sd", i, sd))
        out["col"].append(params.get(m, "col_sd", i, sd))
        out["bias"].append(params.get(m, "black_offset_sd", i, sd))
        out["shade"].append(d.get("shade_sd") if d.get("shade_sd") is not None else d["shade_frac"] * sd)
        out["fcol"].append(d.get("fpn_col_sd") if d.get("fpn_col_sd") is not None else d["fpn_col_frac"] * sd)
        out["hot"].append(params.get(m, "hot_rate", i))
        hi = float(d["hot_max"]); out["hot_hi"].append(hi); out["hot_lo"].append(min(max(d["hot_lo"] * sd, hi * 1e-3), hi / 2))
        out["q"].append(d.get("quant_step") or 1.0 / (d["white"] - d["black"]))
        out["lam"].append(max(float(d["tl_lambda"]), -0.3))  # variance infinite at lambda <= -0.5
        out["gsd"].append(float(d["chan_gain_sd"]))
        out["grid"].append(int(d["shade_grid"]))
    return out


def _col(v, ref):
    return torch.tensor(v, device=ref.device, dtype=ref.dtype).view(-1, 1, 1, 1)


def _randn(shape, ref, g):
    return torch.randn(shape, generator=g, device=ref.device, dtype=ref.dtype)


def _rand(shape, ref, g):
    return torch.rand(shape, generator=g, device=ref.device, dtype=ref.dtype)


def _jit(B, ref, params, g):
    L = math.log(max(params.jitter, 1.0))
    return 1.0 if L == 0 else torch.exp((_rand((B, 1, 1, 1), ref, g) * 2 - 1) * L)


def chan_gain(B, sd, ref, generator=None):
    """Per-channel gain factors (B,4,1,1), mean exactly 1 in expectation (symmetric, clamped)."""
    return (1 + _randn((B, 4, 1, 1), ref, generator) * sd).clamp(0.5, 1.5)


def _tl_std(lam):
    """Std of standard Tukey-lambda(lam); logistic (pi/sqrt 3) at lam -> 0."""
    if abs(lam) < 1e-4:
        return math.pi / math.sqrt(3)
    lg = math.lgamma(lam + 1)
    return math.sqrt(2 / lam ** 2 * (1 / (1 + 2 * lam) - math.exp(2 * lg - math.lgamma(2 * lam + 2))))


def tukey_lambda(shape, lam, ref, generator=None):
    """Unit-variance Tukey-lambda samples via the quantile function Q(u)=(u^l-(1-u)^l)/l
    (lam=0.14 ~ Gaussian, lam<0.14 heavier tails; ELD fits lam per camera with a PPCC plot)."""
    u = _rand(shape, ref, generator).clamp(1e-6, 1 - 1e-6)
    z = torch.log(u / (1 - u)) if abs(lam) < 1e-4 else (u ** lam - (1 - u) ** lam) / lam
    return z / _tl_std(lam)


def _shade_w2(n, g):
    """Sum of squared bilinear (align_corners) weights along one axis -> per-position var factor."""
    t = torch.arange(n, dtype=torch.float32) * ((g - 1) / max(n - 1, 1))
    f = t - t.floor()
    return f ** 2 + (1 - f) ** 2


def add_noise_ext(clean, K, r, iso, models, opts=None, params=None, generator=None):
    """clean (B,4,H,W) normalized packed RGGB, K/r (B,1,1,1). Returns noisy, NOT clipped at white
    (caller clips like train.Data.batch). With opts all off this IS train.add_noise."""
    opts = opts or NoiseOpts()
    g = generator
    if not opts.any():
        x = clean.clamp(min=0) / K
        shot = (torch.poisson(x) if g is None else torch.poisson(x, generator=g)) * K
        rr = torch.as_tensor(r, device=clean.device, dtype=clean.dtype)
        n = torch.randn_like(clean) if g is None else _randn(clean.shape, clean, g)
        return shot + n * rr.sqrt()
    params = params or ExtParams()
    B, C, H, W = clean.shape
    p = _per_sample(K, r, iso, models, opts, params)
    Kc = K * chan_gain(B, _col(p["gsd"], clean), clean, g) if opts.gain else K
    x = clean.clamp(min=0) / Kc
    out = (torch.poisson(x) if g is None else torch.poisson(x, generator=g)) * Kc
    rr = _col(p["r"], clean)
    if opts.heavy:
        lams = sorted(set(p["lam"]))
        if len(lams) == 1:
            z = tukey_lambda(clean.shape, lams[0], clean, g)
        else:
            z = torch.stack([tukey_lambda(clean.shape[1:], l, clean, g) for l in p["lam"]])
        out = out + z * rr.sqrt()
    else:
        out = out + _randn(clean.shape, clean, g) * rr.sqrt()
    if opts.row:
        o = _randn((B, 2, H, 1), clean, g) * (_col(p["row"], clean) * _jit(B, clean, params, g))
        out = out + o[:, [0, 0, 1, 1]]
    if opts.col:
        o = _randn((B, 2, 1, W), clean, g) * (_col(p["col"], clean) * _jit(B, clean, params, g))
        out = out + o[:, [0, 1, 0, 1]]
    if opts.fpn:
        j = _jit(B, clean, params, g)
        out = out + _randn((B, 4, 1, 1), clean, g) * (_col(p["bias"], clean) * j)
        gs = max(p["grid"])
        sh = _randn((B, 4, gs, gs), clean, g) * (_col(p["shade"], clean) * j)
        out = out + F.interpolate(sh, size=(H, W), mode="bilinear", align_corners=True)
        o = _randn((B, 2, 1, W), clean, g) * (_col(p["fcol"], clean) * j)
        out = out + o[:, [0, 1, 0, 1]]
    if opts.hot:
        lo, hi = _col(p["hot_lo"], clean), _col(p["hot_hi"], clean)
        mask = _rand(clean.shape, clean, g) < _col(p["hot"], clean)
        amp = torch.exp(lo.log() + _rand(clean.shape, clean, g) * (hi.log() - lo.log()))
        out = out + mask * amp
    if opts.quant:
        q = _col(p["q"], clean)
        out = torch.round(out / q) * q
    return out


def ext_variance(clean, K, r, iso, models, opts=None, params=None):
    """Theoretical per-pixel variance (B,4,H,W) of add_noise_ext over all random draws
    (jitter included via E[f^2]; quantization as q^2/12, valid when noise sd >> q)."""
    opts = opts or NoiseOpts()
    v = K * clean.clamp(min=0)  # gain jitter has mean 1 -> E[K_c] x = K x
    if not opts.any():
        return v + torch.as_tensor(r, device=clean.device, dtype=clean.dtype)
    params = params or ExtParams()
    B, C, H, W = clean.shape
    p = _per_sample(K, r, iso, models, opts, params)
    col = lambda k: _col(p[k], clean)
    v = v + col("r")
    j2 = params.jitter_ex2()
    if opts.row: v = v + col("row") ** 2 * j2
    if opts.col: v = v + col("col") ** 2 * j2
    if opts.fpn:
        gs = max(p["grid"])
        w = (_shade_w2(H, gs)[:, None] * _shade_w2(W, gs)[None]).to(clean)
        v = v + (col("bias") ** 2 + col("fcol") ** 2 + col("shade") ** 2 * w) * j2
    if opts.hot:
        lo, hi, rate = col("hot_lo"), col("hot_hi"), col("hot")
        ln = (hi / lo).log()
        ea, ea2 = (hi - lo) / ln, (hi ** 2 - lo ** 2) / (2 * ln)
        v = v + rate * ea2 - (rate * ea) ** 2
    if opts.quant: v = v + col("q") ** 2 / 12
    return v.expand(B, C, H, W)
