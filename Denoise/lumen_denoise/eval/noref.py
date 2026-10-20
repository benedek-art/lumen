"""No-reference checks for real high-ISO frames (no ground truth): is what the denoiser removed
just noise, and did it leave colour blotches or banding behind?

python -m lumen_denoise.eval.noref --model wiener --baseline blur:1.0 [--real list.txt|dir] [--quick]
Idea: on real photos the residual (noisy - out) must look like the sensor's noise: white, with the
variance the calibrated model predicts, independent across the 4 Bayer planes. Structure in the
residual = detail removed; residual variance << predicted = noise left in; >> predicted = detail removed.
All metric functions are pure numpy/scipy on packed (4,h,w) arrays.
"""
import argparse, math
import numpy as np
from scipy.ndimage import gaussian_filter, gaussian_filter1d, gaussian_gradient_magnitude, uniform_filter
from . import common
from .common import Check

SEC_REAL = "real-noise"
SEC_PROXY = "real-noise (synthetic proxy)"
LAGS = ((1, 0), (0, 1), (1, 1), (2, 0), (0, 2))
CHROMA_EPS = 2e-3        # log-chroma floor (linear): keeps deep shadows (~noise floor) from exploding
CLIP = 0.9               # pixels at/above this (out or noisy) are ignored: clipped noise is not Poisson-Gaussian

# --- release thresholds (model on real high-ISO crops, median over crops) ---
AUTOCORR_MAX = 0.10      # |lag-1 autocorr| of normalized residual, worst crop kind; white ~0 +-0.01 on 256^2, removed texture 0.13-0.6
FLATNESS_MIN = 0.70      # radial spectral flatness, worst kind; white 0.99, removed texture (1/f^2) or low-freq noise left in (local filters) 0.03-0.55
XCHAN_MAX = 0.15         # mean |corr| between Bayer-plane residuals; sensor noise is independent per photosite, luminance detail is not
WHITE_REL = 0.15         # ...or no worse than the baseline's worst kind by 15 %: at ISO 25600 even a 0.5 px oracle blur misses the absolute bar on fine texture (lag1 0.12, xchan 0.17)
WHITE_HARD = dict(lag1=0.30, flatness=0.30, xchan=0.50)  # never pass beyond these, whatever the baseline: blur:1.0 = 0.39/0.17/0.66, NLM = 0.05/0.80/0.21
VAR_BAND = (0.60, 1.40)  # residual var / predicted var; wide because real-file calib can be ~20 % off and real noise has FPN on top
VAR_KIND_MAX = 2.0       # per-kind median var ratio ceiling: removed signal >= the noise itself on some crop kind (blur:1.0 detail 2.7, blur:2.0 5.7, 0.5 px blur 1.2)
LEFTOVER_MAX = 0.50      # noise std left in the output / input std on flat+dark crops; must remove >= half the noise (identity = 1)
BLOTCH_MARGIN = 0.15     # model chroma-blotch score may exceed the baseline's by at most 15 % (+ BLOTCH_ABS)
BLOTCH_ABS = 0.02        # absolute slack in normalized units so two near-zero scores do not fail on noise
BAND_AMPLIFY = 1.20      # flat+dark crops, per axis: output row (col) banding <= 1.2x input's; input always holds white noise (~1) so the ratio is well posed
BAND_CEIL = 3.0          # flat+dark crops: an axis stronger than in the input must stay <= 3x a white-noise row mean (sigma_in/sqrt(w)), i.e. barely visible
N_FILES_QUICK, N_FILES = 2, 12   # real files used (quick / full)
N_CROPS = 4              # flat, dark, detail, mid


# ---------------------------------------------------------------- metrics ----
def _valid(noisy, out):
    return (np.asarray(out) < CLIP) & (np.asarray(noisy) < CLIP)


def _corr(a, b, m):
    a, b = a[m], b[m]
    if a.size < 16:
        return float("nan")
    a = a - a.mean(); b = b - b.mean()
    d = math.sqrt(float((a * a).sum() * (b * b).sum()))
    return float((a * b).sum() / d) if d > 0 else float("nan")


def normalized_residual(residual, K, r, img, valid=None):
    """residual / predicted noise std (from img, normally the denoised output); invalid px -> 0."""
    z = np.asarray(residual, np.float64) / common.noise_std(img, K, r)
    v = np.ones(z.shape, bool) if valid is None else np.asarray(valid, bool)
    return np.where(v, z, 0.0), v


def autocorr(z, valid, lags=LAGS):
    """Pearson autocorrelation per lag, averaged over the 4 planes -> {lag: corr}."""
    out = {}
    for dy, dx in lags:
        cs = []
        for c in range(z.shape[0]):
            a, b = z[c, : z.shape[1] - dy, : z.shape[2] - dx], z[c, dy:, dx:]
            m = valid[c, : z.shape[1] - dy, : z.shape[2] - dx] & valid[c, dy:, dx:]
            cs.append(_corr(a, b, m))
        out[(dy, dx)] = float(np.nanmean(cs)) if np.isfinite(cs).any() else float("nan")
    return out


def spectral_flatness(z, nbins=None):
    """Wiener entropy (geometric / arithmetic mean) of the radially averaged 2-D power spectrum,
    DC excluded, Hann-windowed, planes averaged. 1 = white. [Johnston 1988; Gray & Markel 1974]"""
    _, h, w = z.shape
    win = np.outer(np.hanning(h), np.hanning(w))
    P = np.zeros((h, w))
    for c in z:
        P += np.abs(np.fft.fft2((c - c.mean()) * win)) ** 2
    fy, fx = np.meshgrid(np.fft.fftfreq(h), np.fft.fftfreq(w), indexing="ij")
    rad = np.hypot(fy, fx)
    nbins = nbins or max(min(h, w) // 8, 4)
    edges = np.linspace(0, 0.5, nbins + 1)
    idx = np.digitize(rad, edges) - 1
    ok = (rad > 0) & (idx >= 0) & (idx < nbins)
    s = np.bincount(idx[ok], P[ok], nbins); n = np.bincount(idx[ok], minlength=nbins)
    prof = s[n > 0] / n[n > 0]
    if prof.size == 0 or prof.mean() <= 0:
        return float("nan")
    prof = np.maximum(prof, prof.mean() * 1e-12)
    return float(np.exp(np.log(prof).mean()) / prof.mean())


def cross_channel_corr(z, valid):
    """Mean |Pearson corr| over the 6 pairs of Bayer-plane residuals (independent noise -> ~0)."""
    cs = []
    for i in range(4):
        for j in range(i + 1, 4):
            cs.append(abs(_corr(z[i], z[j], valid[i] & valid[j])))
    return float(np.nanmean(cs)) if np.isfinite(cs).any() else float("nan")


def whiteness(residual, K, r, img, valid=None):
    """Residual whiteness: autocorr at LAGS, |lag-1| (mean of (1,0),(0,1)), max |autocorr|,
    spectral flatness, cross-plane corr. A zero residual (identity) gives NaNs."""
    z, v = normalized_residual(residual, K, r, img, valid)
    if not np.any(z[v]):
        nan = float("nan")
        return dict(ac={l: nan for l in LAGS}, lag1=nan, ac_max=nan, flatness=nan, xchan=nan)
    ac = autocorr(z, v)
    return dict(ac=ac, lag1=(abs(ac[(1, 0)]) + abs(ac[(0, 1)])) / 2, ac_max=max(abs(a) for a in ac.values()),
                flatness=spectral_flatness(z), xchan=cross_channel_corr(z, v))


def variance_ratio(noisy, out, K, r, mask=None, nbins=6):
    """var(noisy - out) / predicted var (K*out + r), overall and per brightness bin (quantiles of out).
    ~1: removed exactly the noise; << 1: noise left in; >> 1: structure removed too."""
    noisy, out = np.asarray(noisy, np.float64), np.asarray(out, np.float64)
    res = noisy - out
    pv = (common.noise_std(out, K, r).astype(np.float64) ** 2) * np.ones_like(out)
    m = _valid(noisy, out) if mask is None else (np.asarray(mask, bool) & _valid(noisy, out))
    if not m.any():
        return dict(overall=float("nan"), bins=[])
    res = res - res[m].mean()
    overall = float((res[m] ** 2).sum() / pv[m].sum())
    lum = np.broadcast_to(out.mean(0, keepdims=True), out.shape)[m]
    rr, pp = res[m] ** 2, pv[m]
    edges = np.unique(np.quantile(lum, np.linspace(0, 1, nbins + 1)))
    bins = []
    for lo, hi in zip(edges[:-1], edges[1:]):
        s = (lum >= lo) & (lum <= hi)
        if s.sum() >= 64:
            bins.append((float(lo), float(hi), float(rr[s].sum() / pp[s].sum())))
    return dict(overall=overall, bins=bins)


def _haar_hh(c):
    h, w = c.shape[0] // 2 * 2, c.shape[1] // 2 * 2
    c = c[:h, :w]
    return (c[0::2, 0::2] - c[0::2, 1::2] - c[1::2, 0::2] + c[1::2, 1::2]) / 2.0


def mad_sigma(c):
    """Donoho-Johnstone noise std: median(|HH|)/0.6745 on the finest Haar diagonal band. [Donoho 1995]"""
    return float(np.median(np.abs(_haar_hh(np.asarray(c, np.float64)))) / 0.6745)


def leftover_noise(out, K, r, ref=None):
    """Noise std still in `out` relative to the input's predicted std (1 = untouched, 0 = clean).
    Haar-HH coefficients are divided by the plane's own predicted std at their location, then MAD (robust to edges)."""
    out = np.asarray(out, np.float64)
    sd = plane_noise_std(out if ref is None else ref, K, r)
    ratios = []
    for c, s in zip(out, sd):
        hh = _haar_hh(c) / _haar_hh_pos(s)
        ratios.append(np.median(np.abs(hh)) / 0.6745)
    return float(np.median(ratios))


def plane_noise_std(img, K, r, size=5):
    """Predicted noise std per Bayer plane (4,h,w): var_c = K*x_c + r. common.noise_std uses the 4-plane mean,
    which is right for plane-summed quantities but mis-scales single planes (R/B sit 2-3x below G in a raw)."""
    x = np.clip(uniform_filter(np.asarray(img, np.float64), (0, size, size)), 0, None)
    return np.sqrt(K * x + r)


def _haar_hh_pos(sd):
    h, w = sd.shape[0] // 2 * 2, sd.shape[1] // 2 * 2
    return sd[:h, :w].reshape(h // 2, 2, w // 2, 2).mean((1, 3))


def _dog_l2(s1, s2):
    """L2 norm of a 2-D difference of unit-mass Gaussians (white-noise gain)."""
    return math.sqrt(max(1 / (4 * math.pi * s1 ** 2) + 1 / (4 * math.pi * s2 ** 2) - 1 / (math.pi * (s1 ** 2 + s2 ** 2)), 1e-12))


def _chroma(img):
    """log-ratio chroma log(R/G), log(B/G) (+eps): a tinted gradient or exposure change has constant chroma."""
    t = np.log(np.clip(np.asarray(img, np.float64), 0, None) + CHROMA_EPS)
    g = (t[1] + t[2]) / 2
    return t, np.stack([t[0] - g, t[3] - g]), (t[0] + t[1] + t[2] + t[3]) / 4


def chroma_blotch_score(out, scale=(4, 16), K=None, r=None, mask=None):
    """Low-frequency colour noise: RMS of the DoG(scale) band of log-ratio chroma (R/G, B/G) on the
    flattest half of the crop (luma gradient). With K,r: divided by what white input noise would give in
    that band (noisy input ~1, a clean result ~0, blotchy NR stays high); without: RMS x 1000.
    Constant hue -> constant log chroma, and DoG has no response to linear ramps: smooth skies are not flagged."""
    s1, s2 = scale
    t, ch, luma = _chroma(out)
    band = np.stack([gaussian_filter(c, s1) - gaussian_filter(c, s2) for c in ch])
    gm = gaussian_gradient_magnitude(gaussian_filter(luma, s1), 1.0)
    flat = gm <= np.percentile(gm, 50) if mask is None else np.asarray(mask, bool)
    b = int(min(2 * s2, min(luma.shape) // 4))  # drop the border where reflect padding bends gradients
    flat = flat.copy()
    if b:
        flat[:b] = flat[-b:] = False; flat[:, :b] = flat[:, -b:] = False
    if not flat.any():
        return float("nan")
    rms = float(np.sqrt((band[:, flat] ** 2).mean()))
    if K is None:
        return rms * 1000
    x = np.clip(np.asarray(out, np.float64), 0, None)
    xs = np.maximum(gaussian_filter(x, (0, 2, 2)), 0)
    sl = np.sqrt(K * xs + r)        # linear std PER PLANE: var_c = K*x_c + r (R/B sit well below G in a raw)
    dt = 1 / (xs + CHROMA_EPS)      # d log(x+eps)/dx per plane (delta method)
    st = sl * dt
    v = np.stack([st[0] ** 2 + (st[1] ** 2 + st[2] ** 2) / 4, st[3] ** 2 + (st[1] ** 2 + st[2] ** 2) / 4])
    exp = math.sqrt(float(v[:, flat].mean())) * _dog_l2(s1, s2)
    return rms / exp if exp > 0 else float("nan")


def banding_score(img, sigma=None, smooth=8.0):
    """Row/column pattern noise. Per plane: std of row (col) means minus a Gaussian-smoothed trend,
    in units of a white-noise row mean (sigma/sqrt(width)); white noise -> ~1, visible stripes -> >> 1.
    sigma: per-pixel noise std (scalar or per-plane); default: robust MAD estimate from img itself.
    Pass the INPUT noise std when scoring an output so input and output share one scale."""
    img = np.asarray(img, np.float64)
    C, h, w = img.shape
    if sigma is None:
        sig = np.array([mad_sigma(c) for c in img])
    else:
        sig = np.broadcast_to(np.asarray(sigma, np.float64), (C,))
    sig = np.maximum(sig, 1e-12)
    # detrending also removes a little white-noise variance: 1 - 2 g(0) + ||g||^2
    keep = math.sqrt(1 - 2 / (math.sqrt(2 * math.pi) * smooth) + 1 / (2 * math.sqrt(math.pi) * smooth))
    rows, cols = [], []
    for c, s in zip(img, sig):
        rm, cm = c.mean(1), c.mean(0)
        rows.append(np.std(rm - gaussian_filter1d(rm, smooth, mode="nearest")) / (s / math.sqrt(w)) / keep)
        cols.append(np.std(cm - gaussian_filter1d(cm, smooth, mode="nearest")) / (s / math.sqrt(h)) / keep)
    rows, cols = float(np.mean(rows)), float(np.mean(cols))
    return dict(rows=rows, cols=cols, score=max(rows, cols))


def crop_metrics(noisy, out, K, r):
    """Every no-ref metric for one crop -> flat dict of floats."""
    noisy, out = np.asarray(noisy, np.float32), np.asarray(out, np.float32)
    v = _valid(noisy, out)
    wh = whiteness(noisy - out, K, r, out, v)
    sig_in = np.sqrt(K * np.clip(noisy.reshape(4, -1).mean(1), 0, None) + r)
    bo, bi = banding_score(out, sig_in), banding_score(noisy, sig_in)
    # per axis: column content (fences, the synthetic shadow stripes) must not mask model-made ROW banding
    amp = max(bo[a] / bi[a] if bi[a] > 0 else (math.inf if bo[a] > 0 else 0.0) for a in ("rows", "cols"))
    new = max([bo[a] for a in ("rows", "cols") if bo[a] > bi[a]], default=0.0)
    return dict(lag1=wh["lag1"], ac_max=wh["ac_max"], flatness=wh["flatness"], xchan=wh["xchan"],
                var_ratio=variance_ratio(noisy, out, K, r)["overall"], leftover=leftover_noise(out, K, r, ref=noisy),
                blotch=chroma_blotch_score(out, K=K, r=r), blotch_in=chroma_blotch_score(noisy, K=K, r=r),
                band=bo["score"], band_in=bi["score"], band_amp=amp, band_new=new)


# ------------------------------------------------------------------ gate ----
def _med(rows, key, kinds=None):
    v = [m[key] for k, m in rows if (kinds is None or k in kinds) and np.isfinite(m[key])]
    return float(np.median(v)) if v else float("nan")


def _f(x):
    return None if x is None or not np.isfinite(x) else float(x)


def _worst(rows, key, hi=True):
    """Per-crop-kind medians; returns (worst value, kind). Structure removal shows up on detail/mid
    crops only, so a plain median over all crops would hide it."""
    per = {}
    for k, m in rows:
        if np.isfinite(m[key]): per.setdefault(k, []).append(m[key])
    if not per or len(per) < len({k for k, _ in rows}):  # a kind with only NaN (nothing removed) is worst
        return float("nan"), next((k for k, _ in rows if k not in per), "")
    med = {k: float(np.median(v)) for k, v in per.items()}
    k = (max if hi else min)(med, key=med.get)
    return med[k], k


def judge(sec, mrows, brows, model_name="model", baseline_name="baseline", note=""):
    """Turn per-crop metric rows [(kind, metrics)] of model and baseline into Check rows.
    Whiteness metrics gate on the worst crop kind (absolute bar, or within WHITE_REL of the baseline but never
    past WHITE_HARD); var ratio on the median over all crops plus a per-kind ceiling; leftover noise and banding
    on flat+dark crops (texture/edges would masquerade as noise/stripes), banding per axis."""
    FLAT = ("flat", "dark")
    fl = FLAT if any(k in FLAT for k, _ in mrows) else None   # fall back to all crops if no flat/dark
    g = _med
    (lag1, k1), (flat, k2), (xc, k3) = _worst(mrows, "lag1"), _worst(mrows, "flatness", hi=False), _worst(mrows, "xchan")
    b_lag1, b_flat, b_xc = _worst(brows, "lag1")[0], _worst(brows, "flatness", hi=False)[0], _worst(brows, "xchan")[0]
    vr = g(mrows, "var_ratio")
    vk = {k: _med(mrows, "var_ratio", (k,)) for k in dict.fromkeys(k for k, _ in mrows)}
    vk_max, vk_kind = max(((v, k) for k, v in vk.items() if np.isfinite(v)), default=(float("nan"), ""))
    lo_m, lo_b = g(mrows, "leftover", fl), g(brows, "leftover", fl)
    bl_m, bl_b, bl_in = g(mrows, "blotch"), g(brows, "blotch"), g(mrows, "blotch_in")
    bd_m, bd_in, bd_amp, bd_new = g(mrows, "band", fl), g(mrows, "band_in", fl), g(mrows, "band_amp", fl), g(mrows, "band_new", fl)
    fin = np.isfinite
    per_kind = {k: round(v, 2) for k, v in vk.items()}

    def white(v, b, lim, hard, hi=True):
        """absolute bar, or within WHITE_REL of the baseline, never past the hard bar -> (ok, why)"""
        if not fin(v): return False, "NaN = nothing removed"
        le = (lambda a, c: a <= c) if hi else (lambda a, c: a >= c)
        if le(v, lim): return True, "abs"
        rel = b * (1 + WHITE_REL) if hi else b * (1 - WHITE_REL)
        if fin(b) and le(v, rel) and le(v, hard): return True, f"<= {baseline_name}" if hi else f">= {baseline_name}"
        return False, "hard bar" if not le(v, hard) else "abs+rel"
    (o1, w1), (o2, w2), (o3, w3) = white(lag1, b_lag1, AUTOCORR_MAX, WHITE_HARD["lag1"]), \
        white(flat, b_flat, FLATNESS_MIN, WHITE_HARD["flatness"], hi=False), white(xc, b_xc, XCHAN_MAX, WHITE_HARD["xchan"])
    rule = lambda op, lim, hard: f"worst kind {op} {lim}, or {op} {baseline_name}*{1 + WHITE_REL if op == '<=' else 1 - WHITE_REL:g} & {op} {hard}"
    bs = lambda b: f"{baseline_name}={b:.3f}" if fin(b) else f"{baseline_name}=NaN"
    out = [
        Check(sec, "residual_lag1_autocorr", _f(lag1), rule("<=", AUTOCORR_MAX, WHITE_HARD["lag1"]), common.status(o1),
              f"worst={k1}; {w1}; {bs(b_lag1)}" + (f"; {note}" if note else "")),
        Check(sec, "residual_spectral_flatness", _f(flat), rule(">=", FLATNESS_MIN, WHITE_HARD["flatness"]), common.status(o2),
              f"worst={k2}; {w2}; {bs(b_flat)}"),
        Check(sec, "residual_xchan_corr", _f(xc), rule("<=", XCHAN_MAX, WHITE_HARD["xchan"]), common.status(o3),
              f"worst={k3}; {w3}; {bs(b_xc)}"),
        Check(sec, "residual_var_ratio", _f(vr), f"{VAR_BAND[0]}..{VAR_BAND[1]}",
              common.status(fin(vr) and VAR_BAND[0] <= vr <= VAR_BAND[1]), f"<1 noise left, >1 detail removed; {per_kind}"),
        Check(sec, "residual_var_ratio_worst_kind", _f(vk_max), f"max kind <= {VAR_KIND_MAX}",
              common.status(fin(vk_max) and vk_max <= VAR_KIND_MAX), f"worst={vk_kind} (median over all crops hides detail removal)"),
        Check(sec, "leftover_noise_flat", _f(lo_m), f"<= {LEFTOVER_MAX}", common.status(fin(lo_m) and lo_m <= LEFTOVER_MAX),
              f"{baseline_name}={lo_b:.3f}"),
        Check(sec, "chroma_blotch_vs_baseline", _f(bl_m), f"<= {baseline_name}*(1+{BLOTCH_MARGIN})+{BLOTCH_ABS}",
              common.status(fin(bl_m) and fin(bl_b) and bl_m <= bl_b * (1 + BLOTCH_MARGIN) + BLOTCH_ABS),
              f"{baseline_name}={bl_b:.3f} input={bl_in:.3f} (1 = all input chroma noise left at that scale)"),
        Check(sec, "banding_not_amplified", _f(bd_amp), f"max axis out/in <= {BAND_AMPLIFY}",
              common.status(fin(bd_amp) and bd_amp <= BAND_AMPLIFY),
              f"out={bd_m:.2f} in={bd_in:.2f} (x white-noise row mean, max axis; ratio per axis per crop)"),
        Check(sec, "banding_ceiling", _f(bd_new), f"<= {BAND_CEIL} (axes above input only)",
              common.status(fin(bd_new) and bd_new <= BAND_CEIL), "0 = no axis stronger than in the input"),
    ]
    out.append(Check(sec, f"{baseline_name}:var_ratio", _f(g(brows, "var_ratio")), "info", "INFO"))
    return out


def _run(f, x, K, r):
    return np.clip(common.run_padded(f, x, K, r), -0.1, 1.5)


def gate_checks(model, baseline, ctx):
    """Real high-ISO RAWs (ctx.real_files). Missing files/rawpy/exiftool -> SKIP rows, never raises."""
    from . import realdata
    names = ("residual_lag1_autocorr", "residual_spectral_flatness", "residual_xchan_corr", "residual_var_ratio",
             "residual_var_ratio_worst_kind", "leftover_noise_flat", "chroma_blotch_vs_baseline", "banding_not_amplified", "banding_ceiling")
    files = list(ctx.real_files or [])
    ok, why = realdata.available(files)
    if not ok:
        return [Check(SEC_REAL, n, None, "", "SKIP", why) for n in names]
    files = files[: N_FILES_QUICK if ctx.quick else N_FILES]
    mrows, brows, used, errs = [], [], 0, []
    for i, fp in enumerate(files):
        try:
            p, K, r, meta = realdata.load_packed(fp, ctx.table)
        except Exception as e:  # unreadable file: report, do not crash the gate
            errs.append(f"{fp}: {type(e).__name__}"); continue
        for kind, x in realdata.pick_test_crops(p, n=N_CROPS, seed=common.SEED + i):  # all 4 kinds even in quick: detail crops are where removal shows
            mrows.append((kind, crop_metrics(x, _run(model, x, K, r), K, r)))
            brows.append((kind, crop_metrics(x, _run(baseline, x, K, r), K, r)))
        used += 1
    if not used:
        return [Check(SEC_REAL, n, None, "", "SKIP", "no file loaded: " + "; ".join(errs[:3])) for n in names]
    return judge(SEC_REAL, mrows, brows, ctx.model_name, ctx.baseline_name,
                 f"{used} files, {len(mrows)} crops" + (f", {len(errs)} unreadable" if errs else ""))


def selftest_rows(model, ctx, baseline=None):
    """Synthetic proxy: ctx.frames + calibrated noise at the highest ctx ISO -> per-crop metric rows."""
    from .regions import pick_regions, cut
    baseline = baseline or common.m_wiener
    iso = max(ctx.isos)
    frames = ctx.frames[:2] if ctx.quick else ctx.frames
    mrows, brows, truth = [], [], []
    for fi, fr in enumerate(frames):
        lo, hi = ctx.table.iso_range(fr.camera)
        K, r = ctx.table.params(fr.camera, float(np.clip(iso, lo, hi)))
        regs = [g for g in pick_regions(fr.clean) if g["kind"] in ("flat", "dark", "detail", "mid")]
        for ri, g in enumerate(regs):
            c = cut(fr.clean, g)
            x = common.add_noise(c, K, r, common.crop_seed(fi, ri, iso))
            mrows.append((g["kind"], crop_metrics(x, _run(model, x, K, r), K, r)))
            brows.append((g["kind"], crop_metrics(x, _run(baseline, x, K, r), K, r)))
            truth.append(whiteness(x - c, K, r, c, _valid(x, c)))  # the true noise: metric sanity
    return mrows, brows, truth


def noref_selftest_checks(model, ctx, baseline=None):
    """Same metrics/thresholds as gate_checks on synthetic noise over ctx.frames, so the cloud gate
    exercises the code path. Also INFO rows showing the metrics on the TRUE noise (should be ~white)."""
    try:
        mrows, brows, truth = selftest_rows(model, ctx, baseline)
    except Exception as e:
        return [Check(SEC_PROXY, "selftest", None, "", "SKIP", f"{type(e).__name__}: {e}")]
    if not mrows:
        return [Check(SEC_PROXY, "selftest", None, "", "SKIP", "no frames/crops")]
    bname = ctx.baseline_name if baseline is not None else "wiener"
    rows = judge(SEC_PROXY, mrows, brows, ctx.model_name, bname, f"{len(mrows)} synthetic crops @ISO{max(ctx.isos)}")
    tf = float(np.median([t["flatness"] for t in truth])); tl = float(np.median([t["lag1"] for t in truth]))
    ok = tf >= FLATNESS_MIN and tl <= AUTOCORR_MAX
    rows.append(Check(SEC_PROXY, "metric_sanity_true_noise", tf, f"flatness>={FLATNESS_MIN}, lag1<={AUTOCORR_MAX}", "INFO",
                      f"true-noise lag1={tl:.3f}; {'ok' if ok else 'METRIC MISCALIBRATED'}"))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="wiener"); ap.add_argument("--baseline", default="blur:1.0")
    ap.add_argument("--real", default=""); ap.add_argument("--quick", action="store_true")
    ap.add_argument("--calib", default=str(common.DEFAULT_CALIB))
    a = ap.parse_args()
    from . import realdata
    ctx = common.Ctx(common.NoiseTable(a.calib), common.clean_frames(n=2 if a.quick else 0),
                     real_files=realdata.list_files(a.real), quick=a.quick,
                     model_name=common.short_name(a.model), baseline_name=common.short_name(a.baseline))
    m, b = common.get_method(a.model), common.get_method(a.baseline)
    for c in gate_checks(m, b, ctx) + noref_selftest_checks(m, ctx, b):
        v = "-" if c.value is None else f"{c.value:.3f}"
        print(f"{c.status:5s} {c.section:28s} {c.name:30s} {v:>8s}  {c.threshold:32s} {c.note}")


if __name__ == "__main__":
    main()
