"""Star / point-source retention: erasing faint stars is a release blocker (astro is a key use case).

Synthetic: numpy port of train.add_stars painted on a night-sky background derived from each clean
frame, Poisson-Gaussian noise at high ISO, median 7x7-aperture flux kept per peak-SNR bucket, measured
differentially (fn(starry+n) - fn(clean+n), same n) so residual noise does not masquerade as star loss.
Real: stars detected on a smoothed copy of a sky region of a real night RAW; peak/3x3 flux kept.
python -m lumen_denoise.eval.stars --method wiener --baseline identity [--astro list.txt|dir] [--quick] [--synthetic]
"""
import argparse, math, os
from pathlib import Path
import numpy as np
from scipy.ndimage import gaussian_filter, maximum_filter
from . import common
from .common import Check

S = "stars"
BUCKETS = [(2.5, 5), (5, 10), (10, 25), (25, 60)]   # peak SNR (peak / local noise std), as starbench
GATE_ISOS = (6400, 12800)    # astro shooting ISOs for both bodies (A7 IV / GX85 Milky Way exposures)
SKY_LEVEL = 0.01             # night-sky background, normalized linear (~6.6 stops below white); at ISO 6400 read var is ~8 % (A7 IV) / ~30 % (GX85) of the total
N_STARS = 48                 # stars per crop (>=~8 land in each SNR bucket per crop: log-uniform 2.5-60x)
MIN_SEP = 12                 # px between stars so 7x7 apertures (+PSF tails) never overlap
LOST_FRAC = 0.3              # a star with < 30 % of its flux left is "lost" (same rule as realstars)
LOST_SNR_MIN = 5.0           # lost-rate counted on >= 5x stars; 2.5-5x sit at the detection limit (reported only)
FAINT_MIN = 0.70             # 5-10x bucket median flux kept: 30 % dimming of a faint star = ~0.4 mag, visible on a star field
BRIGHT_MIN = 0.90            # 10-25x and 25-60x: a bright star must keep >= 90 % (0.1 mag) - clear signal, no excuse
LOST_MAX = 0.05              # <= 5 % of >= 5x stars may drop below 30 % flux (identity scores ~0 %, noise spread incl.)
BASE_MARGIN = 0.05           # faint median may trail the baseline by at most 0.05 (seed spread ~0.02 at quick size)
REAL_BOX = 768               # real sky box side, packed px (as realstars)
REAL_FLUX_MIN = 0.75         # real: median 3x3 flux kept; an exact denoiser keeps 0.99-1.0 (faint half ~0.97: detection on the
                             # noisy frame favours upward noise); 0.75 leaves room for real PSFs/hot pixels, not for erasure
REAL_LOST_MAX = 0.10         # real: <= 10 % of detected stars lost; detection is ~9 sigma of the smoothed noise (0 false hits on a
                             # star-free synthetic 768^2 sky), so the slack is for hot pixels, which a denoiser should remove
ASTRO_WORDS = ("astro", "star", "night", "milky")   # not "sky": daytime skies have no stars


# ------------------------------------------------------------ synthetic ----
def add_stars(clean, K, r, rng, n=N_STARS, sigmas=(2.0, 60), min_sep=0):
    """numpy port of train.add_stars: elongated Gaussian PSF (sx 0.2-1.2 packed px, sy 1-2x sx), random
    angle, peak = k * local noise std with k log-uniform in `sigmas`, slight per-channel colour,
    painted on all 4 Bayer channels. n fixed (train draws 5..n_max). min_sep>0 rejects overlaps.
    -> (starry (4,h,w) clipped at 1, [(iy, ix, peak_snr)]) with peak_snr the REALISED pixel peak (4-ch mean)
    over the local noise std (train returns the nominal k; see comment below)."""
    c = np.array(clean, np.float32, copy=True)
    _, h, w = c.shape
    yy, xx = np.mgrid[-5:6, -5:6].astype(np.float64)
    pos = []
    tries = 0
    while len(pos) < n and tries < n * 50:
        tries += 1
        y, x = rng.uniform(5, h - 6), rng.uniform(5, w - 6)
        iy, ix = int(y), int(x)
        if min_sep and any(abs(iy - py) < min_sep and abs(ix - px) < min_sep for py, px, _ in pos):
            continue
        sx = math.exp(rng.uniform(math.log(0.2), math.log(1.2))); sy = sx * rng.uniform(1.0, 2.0)
        th = rng.uniform(0, math.pi)
        dx, dy = xx - (x - ix), yy - (y - iy)
        u = dx * math.cos(th) + dy * math.sin(th); v = -dx * math.sin(th) + dy * math.cos(th)
        psf = np.exp(-0.5 * ((u / sx) ** 2 + (v / sy) ** 2))
        bg = max(float(c[:, iy, ix].mean()), 0.0)
        k = math.exp(rng.uniform(math.log(sigmas[0]), math.log(sigmas[1])))
        peak = k * math.sqrt(K * bg + r)
        col = np.array([rng.uniform(0.6, 1.4), 1.0, 1.0, rng.uniform(0.6, 1.4)])[:, None, None]
        star = (peak * col * psf).astype(np.float32)
        c[:, iy - 5:iy + 6, ix - 5:ix + 6] += star
        # realised peak SNR: a compact PSF sampled off-centre can peak far below the nominal k
        # (sx=0.2 at a half-px offset keeps ~4 %), so bucket by what is actually in the pixels
        pos.append((iy, ix, float(star.mean(0).max()) / math.sqrt(K * bg + r)))
    return np.minimum(c, 1.0), pos


def flux_kept(clean, starry, out, positions, ap=3, ref=None):
    """Fraction of each star's flux kept: sum over a (2ap+1)^2 aperture of (out - ref) / (starry - clean).
    ref=None -> ref = clean, i.e. above the star-free scene (same as starbench). ref = the method's output on
    the star-free noisy frame (same noise) -> differential transfer: the method's own residual noise cancels,
    so the per-star value measures what the method does to the star only. 1 = kept, 0 = erased."""
    ref = clean if ref is None else ref
    k = []
    for iy, ix, _ in positions:
        sl = (slice(None), slice(iy - ap, iy + ap + 1), slice(ix - ap, ix + ap + 1))
        true = float((starry[sl] - clean[sl]).sum())
        k.append(float((out[sl] - ref[sl]).sum()) / max(true, 1e-9))
    return np.array(k)


def night_sky(clean, level=SKY_LEVEL, sigma=4.0):
    """Night-sky background from a clean crop: heavily smoothed (keeps gradients/vignetting-like structure,
    drops texture) and scaled so its mean is `level`."""
    s = np.stack([gaussian_filter(ch, sigma) for ch in clean])
    return (s * (level / max(float(s.mean()), 1e-9))).astype(np.float32)


def _sky_crop(clean, size):
    _, h, w = clean.shape
    size = min(size, h, w)
    y0, x0 = (h - size) // 2, (w - size) // 2
    return np.asarray(clean[:, y0:y0 + size, x0:x0 + size], np.float32)


def bucket_label(b):
    return f"{b[0]}-{b[1]}x"


def summarize(kept, snr):
    """kept/snr arrays -> {bucket label: median kept, 'lost': frac of >=LOST_SNR_MIN stars < LOST_FRAC, 'n'}."""
    kept, snr = np.asarray(kept, float), np.asarray(snr, float)
    out = {}
    for b in BUCKETS:
        m = (snr >= b[0]) & (snr < b[1])
        out[bucket_label(b)] = float(np.median(kept[m])) if m.any() else float("nan")
    m = snr >= LOST_SNR_MIN
    out["lost"] = float(np.mean(kept[m] < LOST_FRAC)) if m.any() else float("nan")
    out["n"] = int(len(kept))
    return out


def synthetic_star_bench(fn, frames, table, iso=6400, n_frames=None, seed=common.SEED, crop=common.CROP,
                         n_stars=N_STARS, sky=True, differential=True):
    """Median flux kept per SNR bucket + lost fraction for method fn over frames at one ISO.
    Fixed seeds per (frame, ISO): every method sees identical stars and noise.
    differential=True (gate default): kept = (fn(starry+n) - fn(clean+n)) / true flux with the SAME noise n, so
    a noisy output (identity) is not scored by its own aperture noise (spread +-0.1 at quick size, which made
    the vs-baseline check flaky); False = starbench rule (fn(starry+n) - clean)."""
    kept, snr = [], []
    for i, fr in enumerate(frames[: n_frames or None]):
        clean = _sky_crop(fr.clean, crop)
        if sky:
            clean = night_sky(clean)
        lo, hi = table.iso_range(fr.camera)
        K, r = table.params(fr.camera, float(np.clip(iso, lo, hi)))
        s = common.crop_seed(i, 50, iso) ^ seed
        starry, pos = add_stars(clean, K, r, np.random.default_rng(s), n=n_stars, min_sep=MIN_SEP)
        x = common.add_noise(starry, K, r, s + 1)
        y = common.run_padded(fn, x, K, r)
        ref = None
        if differential:  # same noise draw on the star-free scene (clipped at white like add_noise)
            x0 = np.minimum(clean + (x - starry), 1.0).astype(np.float32)
            ref = common.run_padded(fn, x0, K, r)
        kept += list(flux_kept(clean, starry, y, pos, ref=ref)); snr += [p[2] for p in pos]
    res = summarize(kept, snr)
    res["kept"], res["snr"] = np.array(kept), np.array(snr)
    return res


# ----------------------------------------------------------------- real ----
def sky_box(p, s=REAL_BOX):
    """Darkest-variance s x s region (half-overlapping grid, smoothed luminance) = sky. -> (y0, x0, s)."""
    _, h, w = p.shape
    s = min(s, h, w); g = p.mean(0); best = None
    for y0 in range(0, h - s, s // 2):   # same grid as the original realstars (last row/col excluded)
        for x0 in range(0, w - s, s // 2):
            v = np.std(gaussian_filter(g[y0:y0 + s, x0:x0 + s], 8))
            if best is None or v < best[0]: best = (v, y0, x0)
    if best is None:
        return 0, 0, s
    return best[1], best[2], s


def _median_at(img, ys, xs, size=25):
    """== median_filter(img, size)[ys, xs] (same 'reflect' border) but only at the given pixels:
    a full 25x25 median filter costs ~4.5 s per 768^2 box on CPU, this costs milliseconds."""
    if len(ys) == 0:
        return np.zeros(0, img.dtype)
    h = size // 2
    win = np.lib.stride_tricks.sliding_window_view(np.pad(img, h, mode="symmetric"), (size, size))
    return np.median(win[ys, xs].reshape(len(ys), -1), axis=1)


def detect_real_stars(packed, K, r, nsig=4 / 1.5, win=7, bg_win=25, border=4):
    """Stars on a smoothed copy so noise spikes do not count: local maxima of gaussian(lum, 1) that are
    > nsig * (noise std of the 4-channel mean) above a median_filter(25) background (realstars rule).
    gaussian(1) cuts white-noise std to 0.28x, so nsig=2.67 unsmoothed is ~9.4 sigma of the smoothed noise: no noise peaks
    pass; >= 5x per-plane-SNR synthetic stars are detected >= 90 %.
    -> (ys, xs)"""
    lum = packed.mean(0); sm = gaussian_filter(lum, 1.0)
    h, w = lum.shape
    ys, xs = np.nonzero(sm == maximum_filter(sm, win))   # candidates first, background only where needed
    keep = (ys > border - 1) & (xs > border - 1) & (ys < h - border) & (xs < w - border)
    ys, xs = ys[keep], xs[keep]
    bgm = _median_at(sm, ys, xs, bg_win)
    sd = np.sqrt(K * np.clip(bgm, 0, None) + r) / 2  # std of the 4-channel mean
    pk = sm[ys, xs] - bgm > nsig * sd
    return ys[pk], xs[pk]


def measure_img(img, ys, xs):
    """-> (peak, 3x3 flux) above a median_filter(25) background of the 4-channel mean, per star."""
    l = img.mean(0); ys, xs = np.asarray(ys, int), np.asarray(xs, int)
    bg = np.zeros_like(l); bg[ys, xs] = _median_at(l, ys, xs, 25)
    peak = np.array([l[y, x] - bg[y, x] for y, x in zip(ys, xs)])
    flux = np.array([(l[y - 1:y + 2, x - 1:x + 2] - bg[y, x]).sum() for y, x in zip(ys, xs)])
    return peak, flux


def measure_real(p0, p1, ys, xs):
    """Original p0 vs denoised p1 at detected stars -> dict(n, flux_kept, flux_kept_faint, peak_kept, lost)."""
    if len(ys) == 0:
        return dict(n=0, flux_kept=float("nan"), flux_kept_faint=float("nan"), peak_kept=float("nan"),
                    lost=float("nan"))
    pk0, f0 = measure_img(p0, ys, xs); pk1, f1 = measure_img(p1, ys, xs)
    ok = (f0 > 0) & (pk0 > 0)  # a detection whose noisy 3x3 flux is <= 0 has no meaningful ratio (sign flips)
    if not ok.any():
        return measure_real(p0, p1, ys[:0], xs[:0])
    pk0, f0, pk1, f1 = pk0[ok], f0[ok], pk1[ok], f1[ok]
    with np.errstate(divide="ignore", invalid="ignore"):
        fk, pkk = f1 / f0, pk1 / pk0
    faint = f0 < np.median(f0)
    return dict(n=int(len(f0)), flux_kept=float(np.median(fk)),
                flux_kept_faint=float(np.median(fk[faint])) if faint.any() else float(np.median(fk)),
                peak_kept=float(np.median(pkk)), lost=float(np.mean(fk < LOST_FRAC)))


def astro_files(ctx):
    """Real night shots: ctx.astro_files, else the list at $LUMEN_ASTRO_LIST, else ctx.real_files whose
    names contain astro/star/night/milky."""
    fs = list(getattr(ctx, "astro_files", None) or [])
    if not fs and os.environ.get("LUMEN_ASTRO_LIST"):
        try:
            from .realdata import list_files
            fs = list_files(os.environ["LUMEN_ASTRO_LIST"])
        except Exception:
            fs = []
    if not fs:
        fs = [f for f in (ctx.real_files or []) if any(w in Path(f).name.lower() for w in ASTRO_WORDS)]
    return fs


def real_star_check(fn, files, table, box=REAL_BOX, n_files=0):
    """-> (per-file results [dict(file, model, iso, n, flux_kept, ...)], reason)."""
    try:
        from . import realdata
    except Exception as e:
        return [], f"realdata unavailable ({type(e).__name__})"
    ok, why = realdata.available(files)
    if not ok:
        return [], why
    res = []
    for f in files[: n_files or None]:
        try:
            p, K, r, meta = realdata.load_packed(f, table)
        except Exception as e:
            res.append(dict(file=f, error=f"{type(e).__name__}: {e}")); continue
        y0, x0, s = sky_box(p, box); p = np.ascontiguousarray(p[:, y0:y0 + s, x0:x0 + s])
        ys, xs = detect_real_stars(p, K, r)
        m = measure_real(p, common.run_padded(fn, p, K, r), ys, xs)
        res.append(dict(file=f, **meta, **m))
    good = [x for x in res if "error" not in x and x["n"] > 0 and np.isfinite(x["flux_kept"])]
    if good:
        return good, "ok"
    errs = [x["error"] for x in res if "error" in x]
    return [], (f"{len(errs)}/{len(res)} files failed to load (first: {errs[0][:80]})" if errs
                else "no stars detected in the sky box")


def _pool(rs, key):
    v = [x[key] for x in rs if np.isfinite(x[key])]
    return float(np.median(v)) if v else float("nan")


# ----------------------------------------------------------------- gate ----
def _st(ok):
    return "PASS" if ok else "FAIL"


def gate_checks(model, baseline, ctx):
    out = []
    frames = ctx.frames[:2] if ctx.quick else ctx.frames
    if not frames:
        out.append(Check(S, "synthetic", None, "-", "SKIP", "no clean frames"))
    for iso in GATE_ISOS if frames else ():
        a = synthetic_star_bench(model, frames, ctx.table, iso)
        b = synthetic_star_bench(baseline, frames, ctx.table, iso) if baseline is not None else None
        bn = lambda k: f"; baseline {b[k]:.2f}" if b else ""
        n = f"{a['n']} stars, sky {SKY_LEVEL}"
        out.append(Check(S, f"star_faint_kept@{iso}", round(a["5-10x"], 3), f">= {FAINT_MIN}",
                         _st(a["5-10x"] >= FAINT_MIN), "5-10x median flux kept; " + n + bn("5-10x")))
        for lab in ("10-25x", "25-60x"):
            out.append(Check(S, f"star_{lab}_kept@{iso}", round(a[lab], 3), f">= {BRIGHT_MIN}",
                             _st(a[lab] >= BRIGHT_MIN), "median flux kept" + bn(lab)))
        out.append(Check(S, f"stars_lost@{iso}", round(a["lost"], 3), f"<= {LOST_MAX}", _st(a["lost"] <= LOST_MAX),
                         f">= {LOST_SNR_MIN:g}x stars with < {LOST_FRAC:.0%} flux" + bn("lost")))
        out.append(Check(S, f"star_2.5-5x_kept@{iso}", round(a["2.5-5x"], 3), "info", "INFO",
                         "detection-limit stars, not gated" + bn("2.5-5x")))
        if b:
            d = a["5-10x"] - b["5-10x"]
            out.append(Check(S, f"star_faint_vs_baseline@{iso}", round(d, 3), f">= -{BASE_MARGIN}",
                             _st(d >= -BASE_MARGIN), "faint kept minus baseline"))
    files = astro_files(ctx)
    if not files:
        out.append(Check(S, "real_stars", None, "-", "SKIP",
                         "no astro RAWs (ctx.astro_files, $LUMEN_ASTRO_LIST or astro/star/night in real_files)"))
        return out
    nf = 2 if ctx.quick else 0
    rm, why = real_star_check(model, files, ctx.table, n_files=nf)
    if not rm:
        out.append(Check(S, "real_stars", None, "-", "SKIP", why)); return out
    rb, _ = real_star_check(baseline, files, ctx.table, n_files=nf) if baseline is not None else ([], "")
    ns = sum(x["n"] for x in rm)
    fk, lost, ff = _pool(rm, "flux_kept"), _pool(rm, "lost"), _pool(rm, "flux_kept_faint")
    bfk = _pool(rb, "flux_kept") if rb else float("nan")
    note = f"{len(rm)} files, {ns} stars; faint half {ff:.2f}, peak {_pool(rm, 'peak_kept'):.2f}"
    out.append(Check(S, "real_star_flux_kept", round(fk, 3), f">= {REAL_FLUX_MIN}", _st(fk >= REAL_FLUX_MIN),
                     note + (f"; baseline {bfk:.2f}" if rb else "")))
    out.append(Check(S, "real_stars_lost", round(lost, 3), f"<= {REAL_LOST_MAX}", _st(lost <= REAL_LOST_MAX),
                     f"< {LOST_FRAC:.0%} 3x3 flux kept"))
    if rb and np.isfinite(bfk):
        out.append(Check(S, "real_star_flux_vs_baseline", round(fk - bfk, 3), f">= -{BASE_MARGIN}",
                         _st(fk - bfk >= -BASE_MARGIN), "median flux kept minus baseline"))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--method", default="wiener"); ap.add_argument("--baseline", default="identity")
    ap.add_argument("--astro", default="", help="txt list or dir of real night RAWs")
    ap.add_argument("--calib", default=str(common.DEFAULT_CALIB))
    ap.add_argument("--quick", action="store_true"); ap.add_argument("--synthetic", action="store_true")
    a = ap.parse_args()
    files = []
    if a.astro:
        try:
            from .realdata import list_files
            files = list_files(a.astro)
        except Exception:
            pass
    ctx = common.Ctx(table=common.NoiseTable(a.calib), frames=common.clean_frames(synthetic=True if a.synthetic else None),
                     real_files=[], quick=a.quick)
    ctx.astro_files = files
    for c in gate_checks(common.get_method(a.method), common.get_method(a.baseline), ctx):
        v = "-" if c.value is None else c.value
        print(f"{c.status:5s} {c.name:28s} {str(v):>10s}  {c.threshold:10s} {c.note}")


if __name__ == "__main__":
    main()
