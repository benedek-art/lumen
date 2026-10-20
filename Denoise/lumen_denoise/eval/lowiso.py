"""Low-ISO regression test: a clean base-ISO shot must come out (nearly) untouched.

python -m lumen_denoise.eval.lowiso --method wiener [--baseline identity] [--lowiso <list.txt|dir>] [--quick]
Out is compared against its INPUT (the point is "do not touch a clean photo"), and on synthetic frames
also against the clean truth (it must not get worse than the input was). Base ISO: A7 IV 100, GX85 200.
"""
import argparse, math
import numpy as np
from scipy.ndimage import gaussian_filter, uniform_filter
from . import common
from .common import Check, add_noise, crop_seed, tone

S = "low-iso"
BASE_ISOS = (100, 200)   # A7 IV base 100, GX85 base 200 (ISO clamped into each camera's calibrated range)
DN = 1 / 16383           # one 14-bit raw level in normalized units (A7 IV 14-bit ~1 DN; GX85 RW2 is 12-bit, so this is ~0.25 of its DN)
PSNR_MIN = 45.0          # tone-PSNR(out, inp): 45 dB = rms change 0.56 % of tone range (~1.4 8-bit levels), below visibility at 100 %
PSNR_MIN_CLEAN = 50.0    # exact-clean input: nothing to remove, so the bar is stricter (rms < 0.8 8-bit levels)
SHIFT_MAX = 1.0 * DN     # |mean signed change| per channel: a denoiser must not move black level / colour; an exact denoiser's worst crop/channel is 0.15-0.35 DN (noise mean of a 256^2 crop)
HF_MIN = 0.97            # texture HF kept (noise-corrected, ratio of sums over crops): lose <= 3 % (detail.HF_BAND: ~15 % is visible; 3 % = practically lossless)
HF_MIN_SHADOW = 0.85     # same on dark crops only (energy-weighting above hides them): <= 15 % loss = detail.HF_BAND visibility; perfect denoiser ~0.98
P999_MAX = 0.03          # 99.9th pct |tone change|: no local damage > ~8 8-bit levels (base-ISO shadow noise alone is ~0.011 at 3.3 sigma)
CLEAN_TOL = 0.1          # dB: PSNR(out, clean) may be at most this below PSNR(inp, clean) (seed spread of the comparison is < 0.02 dB)
REAL_N = 4               # crops per real RAW


# ------------------------------------------------------------- metrics ----
def _lum(x):
    return tone(np.asarray(x, np.float32).mean(0)).astype(np.float64)


def _hp(L, sigma=1.5):
    return L - gaussian_filter(L, sigma)


def tone_psnr(a, b):
    """PSNR in tone space, peak 1 (tone(1) ~ 1)."""
    mse = float(np.mean((tone(np.asarray(a, np.float64)) - tone(np.asarray(b, np.float64))) ** 2))
    return 99.0 if mse <= 1e-20 else -10 * math.log10(mse)


def texture_mask(img, sigma=1.5, pct=70, win=9, guide=2.0):
    """Top 30 % local HF energy of the INPUT luminance (no clean needed: works on real frames).
    Same definition as detail.texture_mask, but picked on a gauss(guide)-smoothed input so the mask does not
    select where the noise happens to be strong (that biased hf_kept low by 5-15 % on dark crops)."""
    x = np.asarray(img, np.float32)
    if guide: x = np.stack([gaussian_filter(c, guide) for c in x])
    e = uniform_filter(_hp(_lum(x), sigma) ** 2, win)
    m = e > np.percentile(e, pct)
    return m if m.any() else np.ones_like(m)   # constant image: whole crop


def hf_ratio(inp, out, mask=None, sigma=1.5):
    """sum HP(out)^2 / sum HP(inp)^2 on textured pixels (tone luminance, HP = L - gauss(L, 1.5))."""
    m = texture_mask(inp, sigma) if mask is None else mask
    hi, ho = _hp(_lum(inp), sigma), _hp(_lum(out), sigma)
    return _ratio((ho[m] ** 2).sum(), (hi[m] ** 2).sum())


EPS = 1e-12  # HF energy below this = no texture at all (all-black / constant crop): nothing to lose -> ratio 1


def _ratio(num, den):
    return 1.0 if den <= EPS and num <= EPS else float(num / max(den, EPS))


def _hp_gain(sigma):
    """Exact power gain of HP = delta - G_sigma on white noise (impulse response; ~1 - 3/(4 pi sigma^2))."""
    k = int(4 * sigma + 1) * 2 + 1
    d = np.zeros((k, k)); d[k // 2, k // 2] = 1
    return float(((d - gaussian_filter(d, sigma)) ** 2).sum())


def noise_hf_energy(inp, K, r, sigma=1.5):
    """Expected per-pixel HP(noise)^2 in tone luminance for Poisson-Gaussian var = K*x + r.
    Luminance = mean of 4 iid planes -> var/4; tone by first-order propagation (delta method);
    white noise through HP = delta - G_sigma keeps 1 - 2 G(0) + |G|^2 = 1 - 3/(4 pi sigma^2) of its power
    (0.894 at sigma 1.5; computed exactly from the discrete kernel)."""
    L = np.clip(uniform_filter(np.asarray(inp, np.float64).mean(0), 3), 0, None)
    dt = (1 / 2.2) * (L + 1e-3) ** (1 / 2.2 - 1)
    return (K * L + r) / 4 * dt * dt * _hp_gain(sigma)


def change_metrics(inp, out, K=None, r=None, mask=None, sigma=1.5):
    """How much did `out` change vs `inp` (both (4,h,w) linear)? dict:
    psnr: tone-space PSNR(out, inp) dB | p999: 99.9th pct |tone(out)-tone(inp)| |
    shift: per-channel mean signed linear change (list of 4) | max_shift: max |shift| |
    hf_ratio: textured HF energy out/inp | frac_changed: fraction of samples changed by > 1 DN (14-bit) |
    hf_kept (needs K,r): HF(out) / (HF(inp) - expected noise HF) on textured pixels, i.e. texture kept
    relative to what a perfect denoiser would leave (removing the noise itself is not penalised);
    hf_num/hf_den are its parts so crops aggregate as a ratio of sums."""
    inp, out = np.asarray(inp, np.float64), np.asarray(out, np.float64)
    d = out - inp
    sh = d.reshape(d.shape[0], -1).mean(1)
    m = texture_mask(inp, sigma) if mask is None else mask
    hi, ho = _hp(_lum(inp), sigma)[m] ** 2, _hp(_lum(out), sigma)[m] ** 2
    res = dict(psnr=tone_psnr(out, inp),
               p999=float(np.percentile(np.abs(tone(out) - tone(inp)), 99.9)),
               shift=[float(v) for v in sh], max_shift=float(np.abs(sh).max()),
               hf_ratio=_ratio(ho.sum(), hi.sum()),
               frac_changed=float(np.mean(np.abs(d) > DN)))
    if K is not None:
        den = max(hi.sum() - noise_hf_energy(inp, K, r, sigma)[m].sum(), 0.1 * hi.sum())  # floor: noise-only crops
        res.update(hf_num=float(ho.sum()), hf_den=float(den), hf_kept=_ratio(ho.sum(), den))
    return res


# ----------------------------------------------------------- synthetic ----
def _crops(clean):
    """Benchmark regions (dark/flat/detail/mid/centre) if eval.regions is importable, else centre crop."""
    try:
        from .regions import pick_regions, cut
        return [(g["kind"], cut(clean, g)) for g in pick_regions(clean)]
    except Exception:
        _, h, w = clean.shape
        c = min(common.CENTRE, h, w)
        y, x = (h - c) // 2, (w - c) // 2
        return [("centre", np.ascontiguousarray(clean[:, y:y + c, x:x + c], np.float32))]


def synthetic_lowiso(model, frames, table, isos=BASE_ISOS):
    """{iso: {"noisy": [metrics], "clean": [metrics]}}. noisy: base-ISO calibrated noise added, model
    output vs its input + dpsnr_clean = PSNR(out,clean) - PSNR(inp,clean). clean: the clean crop itself
    fed with base-ISO K,r (nothing to remove), output vs input."""
    res, crops = {}, [_crops(fr.clean) for fr in frames]
    for iso in isos:
        nl, cl = [], []
        for fi, fr in enumerate(frames):
            lo, hi = table.iso_range(fr.camera)
            K, r = table.params(fr.camera, min(max(iso, lo), hi))
            for ri, (kind, c) in enumerate(crops[fi]):
                x = add_noise(c, K, r, crop_seed(fi, ri + 200, iso))
                y = common.run_padded(model, x, K, r)
                m = change_metrics(x, y, K, r)
                m.update(kind=kind, frame=fr.name, dpsnr_clean=tone_psnr(y, c) - tone_psnr(x, c))
                nl.append(m)
                yc = common.run_padded(model, c, K, r)
                mc = change_metrics(c, yc, 0.0, 0.0); mc.update(kind=kind, frame=fr.name)
                cl.append(mc)
        res[iso] = dict(noisy=nl, clean=cl)
    return res


# ---------------------------------------------------------------- real ----
def real_lowiso(model, files, table, n=REAL_N):
    """(list[metrics], reason). Real base-ISO RAWs via eval.realdata; ([], why) if unavailable."""
    try:
        from . import realdata
    except Exception as e:
        return [], f"eval.realdata not importable ({type(e).__name__})"
    try:
        ok, why = realdata.available(files or [])
        if not ok:
            return [], why
        out = []
        for p in files:
            pk, K, r, meta = realdata.load_packed(p, table)
            for kind, c in realdata.pick_test_crops(pk, n):
                m = change_metrics(c, common.run_padded(model, c, K, r), K, r)
                m.update(kind=kind, file=str(p), iso=meta.get("iso"), model=meta.get("model"))
                out.append(m)
        return out, "ok" if out else "no crops"
    except Exception as e:  # a broken file / libraw must not crash the gate
        return [], f"real low-ISO failed: {type(e).__name__}: {e}"


# ---------------------------------------------------------------- gate ----
def _kept(ms):
    return _ratio(sum(m["hf_num"] for m in ms), sum(m["hf_den"] for m in ms))


def _agg(ms):
    """Means over crops; psnr also worst-crop; shift: worst crop/channel |mean change| (a shadow-only black
    shift must not average out against bright crops); hf_kept: ratio of sums (energy-weighted, so near-
    textureless flat crops do not dominate) + the same on dark crops alone (hf_shadow, None if no dark crop)."""
    if not ms: return None
    dark = [m for m in ms if m.get("kind") == "dark"]
    return dict(psnr=float(np.mean([m["psnr"] for m in ms])), psnr_min=float(min(m["psnr"] for m in ms)),
                p999=float(np.max([m["p999"] for m in ms])), max_shift=float(max(m["max_shift"] for m in ms)),
                hf_ratio=float(np.mean([m["hf_ratio"] for m in ms])),
                hf_kept=_kept(ms), hf_shadow=_kept(dark) if dark else None,
                frac_changed=float(np.mean([m["frac_changed"] for m in ms])),
                dpsnr_clean=float(np.mean([m["dpsnr_clean"] for m in ms])) if "dpsnr_clean" in ms[0] else None)


def _rows(tag, a, b, psnr_min, clean_check, shadow_gate=True):
    st = common.status
    bn = (lambda k, f: f"baseline {f.format(b[k])}") if b else (lambda k, f: "")
    out = [Check(S, f"psnr_vs_input{tag}", round(a["psnr"], 2), f">= {psnr_min} dB", st(a["psnr"] >= psnr_min),
                 f"worst crop {a['psnr_min']:.1f}; " + bn("psnr", "{:.2f}")),
           Check(S, f"mean_shift{tag}", round(a["max_shift"] / DN, 3), f"<= {SHIFT_MAX / DN:g} DN",
                 st(a["max_shift"] <= SHIFT_MAX), "worst crop+channel |mean change|, 14-bit DN; " +
                 (f"baseline {b['max_shift'] / DN:.3f}" if b else "")),
           Check(S, f"hf_kept{tag}", round(a["hf_kept"], 4), f">= {HF_MIN}", st(a["hf_kept"] >= HF_MIN),
                 f"raw out/inp {a['hf_ratio']:.3f}; " + bn("hf_kept", "{:.4f}")),
           Check(S, f"hf_kept_shadow{tag}", None if a["hf_shadow"] is None else round(a["hf_shadow"], 4),
                 f">= {HF_MIN_SHADOW}", "SKIP" if a["hf_shadow"] is None else
                 (st(a["hf_shadow"] >= HF_MIN_SHADOW) if shadow_gate else "INFO"),
                 "dark crops only" + ("" if shadow_gate else " (clean input told it is noisy: info)") + "; " +
                 (bn("hf_shadow", "{:.4f}") if b and b["hf_shadow"] is not None else "")),
           Check(S, f"p999_change{tag}", round(a["p999"], 4), f"<= {P999_MAX}", st(a["p999"] <= P999_MAX),
                 "tone units; " + bn("p999", "{:.4f}")),
           Check(S, f"frac_changed_1dn{tag}", round(a["frac_changed"], 3), "info", "INFO",
                 "any noise removal changes most samples by >1 DN; " + bn("frac_changed", "{:.3f}"))]
    if clean_check:
        d = a["dpsnr_clean"]
        out.append(Check(S, f"not_worse_vs_clean{tag}", round(d, 3), f">= -{CLEAN_TOL} dB", st(d >= -CLEAN_TOL),
                         "PSNR(out,clean) - PSNR(inp,clean); " + (f"baseline {b['dpsnr_clean']:+.3f}" if b else "")))
    return out


def gate_checks(model, baseline, ctx):
    out = []
    frames = ctx.frames[:2] if ctx.quick else ctx.frames
    if not frames:
        out.append(Check(S, "synthetic", None, "-", "SKIP", "no clean frames"))
    else:
        M = synthetic_lowiso(model, frames, ctx.table)
        B = synthetic_lowiso(baseline, frames, ctx.table) if baseline is not None else None
        for iso in BASE_ISOS:
            a, b = _agg(M[iso]["noisy"]), B and _agg(B[iso]["noisy"])
            out += _rows(f"@{iso}", a, b, PSNR_MIN, True)
            a, b = _agg(M[iso]["clean"]), B and _agg(B[iso]["clean"])
            out += [c for c in _rows(f"_clean_in@{iso}", a, b, PSNR_MIN_CLEAN, False, False)
                    if c.status != "INFO" or c.name.startswith("hf_kept_shadow")]
    files = list(ctx.lowiso_files or [])
    if not files:
        out.append(Check(S, "real", None, "-", "SKIP", "no base-ISO RAWs given (ctx.lowiso_files empty)"))
        return out
    rm, why = real_lowiso(model, files, ctx.table)
    if not rm:
        out.append(Check(S, "real", None, "-", "SKIP", why))
        return out
    rb, _ = real_lowiso(baseline, files, ctx.table) if baseline is not None else ([], "")
    rows = _rows("_real", _agg(rm), _agg(rb), PSNR_MIN, False)
    isos = sorted({m["iso"] for m in rm if m.get("iso")})
    for c in rows: c.note = (c.note + f"; {len(files)} files ISO {isos}").strip("; ")
    return out + rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--method", default="wiener"); ap.add_argument("--baseline", default="identity")
    ap.add_argument("--lowiso", default=""); ap.add_argument("--calib", default=str(common.DEFAULT_CALIB))
    ap.add_argument("--quick", action="store_true"); ap.add_argument("--synthetic", action="store_true")
    a = ap.parse_args()
    files = []
    try:
        from .realdata import list_files
        files = list_files(a.lowiso)
    except Exception:
        pass
    ctx = common.Ctx(table=common.NoiseTable(a.calib), frames=common.clean_frames(synthetic=True if a.synthetic else None),
                     lowiso_files=files, quick=a.quick)
    for c in gate_checks(common.get_method(a.method), common.get_method(a.baseline), ctx):
        v = "-" if c.value is None else c.value
        print(f"{c.status:5s} {c.name:28s} {str(v):>10s}  {c.threshold:18s} {c.note}")


if __name__ == "__main__":
    main()
