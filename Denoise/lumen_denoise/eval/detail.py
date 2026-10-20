"""Detail / texture-retention metrics on packed RGGB (4,h,w) crops, plus the "detail" gate section.

python -m lumen_denoise.eval.detail --model wiener --baseline blur:1.0 [--quick] [--isos 1600,6400]
Spaces: hf_ratio, resid_corr's structure term and gmsd use tone-mapped luminance L = tone(mean of the
4 planes) (what the eye sees; planes are half-res so no demosaic is needed). Residuals for resid_corr
and method_noise stay linear (noise model var = K*x + r lives there), averaged over planes for
resid_corr (structure is common to all planes, noise is not) and per plane for method_noise.
"""
import argparse, os
import numpy as np
from scipy.ndimage import gaussian_filter, uniform_filter, convolve
from . import common
from .common import Check, tone, add_noise, crop_seed, noise_std

TEX_PCT = 70            # textured mask: top 30 % of clean local HF energy (texture, not edges alone)
WIN = 9                 # local window (packed px) for energy maps / local NCC
FLAT_PCT = 25           # flat mask: lowest 25 % of smoothed-gradient energy (method-independent: from noisy)
GMSD_C = 170 / 255 ** 2  # Xue et al. 2014 use c=170 on [0,255]; same constant rescaled to [0,1]

# --- gate thresholds (aggregated mean over detail crops of all frames, per ISO) ---
HF_BAND = (0.85, 1.15)       # +-15 % HF energy is about the smallest texture change visible at 100 % zoom
HF_BAND_HIGH = (0.70, 1.30)  # above HF_BAND_MAX_ISO true texture is buried in noise; any denoiser loses some
HF_BAND_MAX_ISO = 6400
HF_MARGIN = 0.05             # |log hf_ratio| may exceed the baseline's by 0.05 (~5 %) before we call it worse
RC_MARGIN = 0.10             # NCC flags *any* structured residual (wiener 0.2-0.56, blur 0.9+), so only relative
SR_MAX = 0.10                # <= 10 % of clean texture HP removed (LS slope) at ISO <= HF_BAND_MAX_ISO (blur:0.7 = 0.28)
SR_MAX_HIGH = 0.20           # high ISO: texture below the noise floor, some loss is unavoidable
SR_MARGIN = 0.03             # seed-to-seed spread of struct_removed is < 0.005; 0.03 is a real extra loss
GMSD_REL = 1.20              # GMSD may be <= 1.2x baseline + GMSD_ABS (wiener 0.001-0.016, blur:1 0.024, blur:2 0.074)
GMSD_ABS = 0.002             # absolute floor so tiny GMSDs at low ISO do not fail on seed noise
MN_BAND = (0.5, 1.5)         # flat-area residual / predicted noise var: <0.5 = most noise left, >1.5 = eats signal
# relative checks (hf vs base, resid_corr, struct_removed margin) only mean something when the baseline itself
# denoises: vs identity (method_noise 0) every real denoiser has a "more structured" residual. Below
# MN_BAND[0] the baseline counts as a non-denoiser and those rows become INFO / absolute-only.


# ------------------------------------------------------------- helpers ----
def lum(x):
    """Tone-mapped luminance (h,w) of a packed RGGB (4,h,w) image."""
    return tone(np.asarray(x, np.float32).mean(0)).astype(np.float64)


def highpass(L, sigma=1.5):
    return L - gaussian_filter(L, sigma)


def texture_mask(clean, sigma=1.5, pct=TEX_PCT):
    """Pixels whose local HF energy (window WIN) of the clean luminance is above the pct percentile."""
    e = uniform_filter(highpass(lum(clean), sigma) ** 2, WIN)
    return e > np.percentile(e, pct)


def flat_mask(noisy, pct=FLAT_PCT):
    """Flat, unclipped pixels from heavily smoothed noisy: same mask for every method on one crop."""
    s = gaussian_filter(np.asarray(noisy, np.float64).mean(0), 2.0)
    gy, gx = np.gradient(s)
    e = uniform_filter(gx * gx + gy * gy, 15)
    return (e <= np.percentile(e, pct)) & (np.asarray(noisy).max(0) < 0.9)


# ------------------------------------------------------------- metrics ----
def hf_energy_ratio(clean, out, mask=None, sigma=1.5):
    """sum HP(out)^2 / sum HP(clean)^2 on textured pixels, HP = L - gauss(L, sigma) on tone luminance.
    1.0 = texture kept, <1 = smoothed, >1 = noise left / over-sharpened."""
    m = texture_mask(clean, sigma) if mask is None else mask
    hc, ho = highpass(lum(clean), sigma), highpass(lum(out), sigma)
    ec = float((hc[m] ** 2).sum())
    return float((ho[m] ** 2).sum() / ec) if ec > 1e-12 * max(int(m.sum()), 1) else float("nan")  # no texture: undefined


def residual_structure_corr(noisy, out, clean=None, K=None, r=None, sigma=1.5, mask=None):
    """Method-noise test (Buades, Coll & Morel 2005: the removed part noisy-out should look like noise).
    Local NCC (window WIN) between the removed residual (plane-mean, divided by predicted noise std
    when K,r are given so bright/dark areas weigh equally) and the signed high-pass of the structure
    reference (clean if given, else out), averaged over textured pixels of the reference.
    ~0 = only noise removed; >0 = edges/texture removed (blur: residual = HP(image) + noise).
    Without clean it is a no-reference proxy: an adaptive filter's leftover noise couples res and out."""
    noisy = np.asarray(noisy, np.float64); out = np.asarray(out, np.float64)
    res = (noisy - out).mean(0)
    if K is not None and r is not None:
        res = res / noise_std(out.astype(np.float32), K, r)[0]
    ref = out if clean is None else np.asarray(clean, np.float64)
    s = highpass(lum(ref), sigma)
    m = texture_mask(ref, sigma) if mask is None else mask
    res = res - uniform_filter(res, WIN); s = s - uniform_filter(s, WIN)
    num = uniform_filter(res * s, WIN)
    den = np.sqrt(np.clip(uniform_filter(res * res, WIN) * uniform_filter(s * s, WIN), 0, None))
    ncc = np.where(den > 1e-20, num / np.maximum(den, 1e-20), 0.0)
    return float(ncc[m].mean()) if m.any() else 0.0


def structure_removed(noisy, out, clean, mask=None, sigma=1.5):
    """Fraction of the clean texture that went into the residual: least-squares slope of HP(noisy-out) on
    HP(clean) (linear luminance, textured pixels). Noise is independent of clean, so its expectation is
    0 for any amount of noise removed and the value does not drift with ISO (unlike the NCC above, which
    says *whether* the residual is structured, not *how much* structure left). blur:2 ~0.6, wiener ~0.01."""
    m = texture_mask(clean, sigma) if mask is None else mask
    s = np.asarray(clean, np.float64).mean(0); s = s - gaussian_filter(s, sigma)
    d = (np.asarray(noisy, np.float64) - out).mean(0); d = d - gaussian_filter(d, sigma)
    return float((d[m] * s[m]).sum() / max((s[m] ** 2).sum(), 1e-30))


def method_noise_ratio(noisy, out, K, r, mask=None):
    """mean (noisy-out)^2 / predicted noise var (K*x + r) on flat pixels. ~1 = removed exactly the noise,
    <1 = noise left (identity -> 0), >>1 = removed signal too."""
    noisy = np.asarray(noisy, np.float64); out = np.asarray(out, np.float64)
    m = flat_mask(noisy) if mask is None else mask
    if not m.any(): return float("nan")
    pv = K * np.clip(gaussian_filter(noisy.mean(0), 2.0), 0, None) + r
    return float(((noisy - out) ** 2).mean(0)[m].mean() / pv[m].mean())


_PX = np.array([[1, 0, -1]] * 3, np.float64) / 3   # Prewitt, as in the GMSD paper


def gmsd(clean, out, downsample=True):
    """Gradient Magnitude Similarity Deviation (Xue, Zhang, Mou, Bovik, IEEE TIP 2014) on tone luminance,
    with the paper's 2x2 average + 2x downsample (without it GMSD is non-monotone in blur on fine
    texture: the GMS map saturates and its std falls). 0 = identical gradients; larger = worse."""
    a, b = lum(clean), lum(out)
    if downsample:
        a, b = (uniform_filter(v, 2)[::2, ::2] for v in (a, b))

    def gm(L):
        return np.sqrt(convolve(L, _PX, mode="reflect") ** 2 + convolve(L, _PX.T, mode="reflect") ** 2)
    a, b = gm(a), gm(b)
    gms = (2 * a * b + GMSD_C) / (a * a + b * b + GMSD_C)
    return float(gms.std())


def crop_metrics(clean, noisy, out, K, r):
    """Stable dict API (consumed by eval/synth_bench.py): hf_ratio, resid_corr, method_noise, gmsd,
    struct_removed (+ lpips when perceptual is available and LUMEN_LPIPS=1)."""
    d = dict(hf_ratio=hf_energy_ratio(clean, out),
             resid_corr=residual_structure_corr(noisy, out, clean, K, r),
             method_noise=method_noise_ratio(noisy, out, K, r),
             gmsd=gmsd(clean, out),
             struct_removed=structure_removed(noisy, out, clean))
    if os.environ.get("LUMEN_LPIPS") == "1":
        from . import perceptual
        if perceptual.available():
            v = perceptual.lpips_distance(clean, out)
            if v is not None: d["lpips"] = v
    return d


# ---------------------------------------------------------------- gate ----
def _regions(clean, kind, n):
    """Crops of a kind from regions.pick_regions; fallback: top/bottom HF windows on a stride grid."""
    try:
        from .regions import pick_regions, cut
        regs = [g for g in pick_regions(clean, n_per_kind=n) if g["kind"] == kind][:n]
        if regs: return [cut(clean, g) for g in regs]
    except ImportError:
        pass
    _, h, w = clean.shape
    b = min(common.CROP, h, w); st = max(b // 2, 1)
    cand = [(y, x) for y in range(0, h - b + 1, st) for x in range(0, w - b + 1, st)]
    e = [float((highpass(lum(clean[:, y:y + b, x:x + b])) ** 2).mean()) for y, x in cand]
    order = np.argsort(e)[::-1] if kind == "detail" else np.argsort(e)
    return [np.ascontiguousarray(clean[:, y:y + b, x:x + b]) for y, x in (cand[i] for i in order[:n])]


def collect(fn, ctx, n_crops=None):
    """{iso: {"detail": [metrics dicts], "flat": [method_noise floats]}} for one method fn."""
    frames = ctx.frames[:2] if ctx.quick else ctx.frames
    n = n_crops or (1 if ctx.quick else 2)
    res = {}
    for iso in ctx.isos:
        dl, fl = [], []
        for fi, fr in enumerate(frames):
            if fr.camera not in ctx.table.t: continue   # uncalibrated camera: no noise model
            lo, hi = ctx.table.iso_range(fr.camera)
            K, r = ctx.table.params(fr.camera, min(max(iso, lo), hi))
            for kind in ("detail", "flat"):
                for ri, c in enumerate(_regions(fr.clean, kind, n)):
                    x = add_noise(c, K, r, crop_seed(fi, ri + (0 if kind == "detail" else 100), iso))
                    y = common.run_padded(fn, x, K, r)
                    if kind == "detail":
                        dl.append(crop_metrics(c, x, y, K, r))
                    else:
                        fl.append(method_noise_ratio(x, y, K, r))
        res[iso] = dict(detail=dl, flat=fl)
    return res


def _mean(lst, k):
    v = np.array([d[k] for d in lst], np.float64)
    return float(np.nanmean(v)) if np.isfinite(v).any() else float("nan")


def gate_checks(model, baseline, ctx):
    S = "detail"
    if not ctx.frames:
        return [Check(S, "detail", None, "-", "SKIP", "no clean frames")]
    M, B = collect(model, ctx), collect(baseline, ctx)
    out = []

    def add(name, v, thr, ok, note, nd=3, rel_only=False):
        if not np.isfinite(v):
            out.append(Check(S, name, None, thr, "SKIP", "undefined (no textured/flat pixels or no calibrated frames)"))
        elif rel_only and not bden:
            out.append(Check(S, name, round(v, nd), thr, "INFO", note + "; baseline removes no noise, n/a"))
        else:
            out.append(Check(S, name, round(v, nd), thr, common.status(ok), note))

    for iso in ctx.isos:
        md, bd = M[iso]["detail"], B[iso]["detail"]
        mn = float(np.nanmean(M[iso]["flat"])) if np.isfinite(M[iso]["flat"]).any() else float("nan")
        mb = float(np.nanmean(B[iso]["flat"])) if np.isfinite(B[iso]["flat"]).any() else float("nan")
        bden = bool(mb >= MN_BAND[0])
        hm, hb = _mean(md, "hf_ratio"), _mean(bd, "hf_ratio")
        lo, hi = HF_BAND if iso <= HF_BAND_MAX_ISO else HF_BAND_HIGH
        add(f"hf_ratio@{iso}", hm, f"in [{lo}, {hi}]", lo <= hm <= hi, f"baseline {hb:.3f}")
        with np.errstate(divide="ignore", invalid="ignore"):
            dm, db = abs(np.log(hm)), abs(np.log(hb))
        add(f"hf_ratio_vs_baseline@{iso}", dm - db, f"|log| excess <= {HF_MARGIN}", dm <= db + HF_MARGIN,
            f"|log hf| model {dm:.3f} baseline {db:.3f}", rel_only=True)
        rm, rb = _mean(md, "resid_corr"), _mean(bd, "resid_corr")
        add(f"resid_corr@{iso}", rm, f"<= base+{RC_MARGIN}", rm <= rb + RC_MARGIN, f"baseline {rb:.3f}", rel_only=True)
        sm, sb = _mean(md, "struct_removed"), _mean(bd, "struct_removed")
        cap = SR_MAX if iso <= HF_BAND_MAX_ISO else SR_MAX_HIGH
        rel = sm <= sb + SR_MARGIN if bden else True   # vs a non-denoiser only the absolute cap applies
        add(f"struct_removed@{iso}", sm, f"<= {cap}" + (f" and <= base+{SR_MARGIN}" if bden else ""),
            sm <= cap and rel, f"baseline {sb:.3f}")
        gm, gb = _mean(md, "gmsd"), _mean(bd, "gmsd")
        add(f"gmsd@{iso}", gm, f"<= {GMSD_REL}*base+{GMSD_ABS}", gm <= GMSD_REL * gb + GMSD_ABS,
            f"baseline {gb:.4f}", nd=4)
        add(f"method_noise@{iso}", mn, f"in [{MN_BAND[0]}, {MN_BAND[1]}]", MN_BAND[0] <= mn <= MN_BAND[1],
            f"baseline {mb:.3f}")
        if md and "lpips" in md[0]:
            out.append(Check(S, f"lpips@{iso}", round(_mean(md, "lpips"), 4), "info", "INFO",
                             f"baseline {_mean(bd, 'lpips'):.4f}"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="wiener"); ap.add_argument("--baseline", default="blur:1.0")
    ap.add_argument("--isos", default="1600,6400,25600"); ap.add_argument("--quick", action="store_true")
    ap.add_argument("--synthetic", action="store_true"); ap.add_argument("--calib", default=str(common.DEFAULT_CALIB))
    a = ap.parse_args()
    ctx = common.Ctx(common.NoiseTable(a.calib), common.clean_frames(synthetic=True if a.synthetic else None),
                     tuple(map(int, a.isos.split(","))), quick=a.quick,
                     model_name=a.model, baseline_name=a.baseline)
    for c in gate_checks(common.get_method(a.model), common.get_method(a.baseline), ctx):
        print(f"{c.status:4s} {c.name:28s} {str(c.value):>8s}  {c.threshold:28s} {c.note}")


if __name__ == "__main__":
    main()
