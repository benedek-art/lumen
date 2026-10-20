"""Fit row/column (banding) noise, per-channel black offset, hot-pixel rate and per-channel gain
spread from REAL frames -> data/noise_ext.json (loaded by noise_ext.py).

python -m lumen_denoise.calibrate_rows <list.txt> [--calib data/calib.json] [--out data/noise_ext.json]

Works on ordinary photos (texture-robust, fewer usable pixels) and is much more accurate on dark
frames (lens-cap shots, auto-detected by mean < 0.003): there every block is flat and the
per-channel black offset is measurable. ELD (Wei et al. CVPR 2020) measures row noise on bias
frames as the std of row means; here the same quantity is measured texture-robustly:
  * row offsets are per RAW row: packed row i = raw row 2i (channels 0,1) and 2i+1 (channels 2,3),
    so channels {0,1} and {2,3} form two row groups that are estimated separately, then pooled;
  * a vertical second difference d = x_i - (x_{i-1}+x_{i+1})/2 (same channel, 2 raw rows apart)
    cancels scene gradients; iid row offsets give var(hp) = 1.5 * row_var;
  * only flat blocks are used (horizontal-diff variance close to the Poisson-Gaussian prediction,
    and vertical/horizontal variance ratio close to the frame's median);
  * flat segment means of d are split into two interleaved column sets A, B; the row offset is
    common to both, pixel noise is independent, so mean((A+B)/2)^2 - mean((A-B)/2)^2 is an
    unbiased estimate of the offset variance with no dependence on K/read_var accuracy.
Columns: same thing on the transposed frame (raw column 2j = channels {0,2}, 2j+1 = {1,3}).
"""
import argparse, json, math
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor
import numpy as np
from . import noise

DARK_MEAN = 0.003   # frame mean below this (normalized) -> treat as dark / bias frame
HOT_T = 6.0         # hot pixel: exceeds the max of its 8 same-channel neighbours by HOT_T sigma


def _sh(a, dy, dx):
    """a shifted by (dy, dx) with edge replication (same shape)."""
    p = np.pad(a, ((1, 1), (1, 1)), mode="edge")
    return p[1 + dy: 1 + dy + a.shape[0], 1 + dx: 1 + dx + a.shape[1]]


def hot_pixels(packed, K, read_var):
    """Boolean mask (4,h,w) of isolated single-raw-pixel outliers (hot pixels).
    A real point light hits several raw pixels = several packed channels at one site; a hot pixel
    is one channel only, so it must stand out from its own 8 neighbours while the other channels
    at the same site do not."""
    z = np.empty_like(packed)
    for c, ch in enumerate(packed):
        mx, sm = np.full_like(ch, -np.inf), np.zeros_like(ch)
        for dy, dx in ((-1, -1), (-1, 0), (-1, 1), (0, -1), (0, 1), (1, -1), (1, 0), (1, 1)):
            n = _sh(ch, dy, dx); np.maximum(mx, n, out=mx); sm += n
        mean = sm / 8
        z[c] = (ch - mx) / np.sqrt(K * np.clip(mean, 0, None) + read_var)
    cand = z > HOT_T
    others = np.stack([np.max(np.delete(z, c, 0), 0) for c in range(4)])
    return cand & (others < HOT_T / 2)


def _fill(packed, mask):
    """Replace masked pixels by the mean of their 4 same-channel neighbours (keeps row means sane)."""
    if not mask.any(): return packed
    out = packed.copy()
    for c in range(4):
        if mask[c].any():
            ch = packed[c]
            nb = (_sh(ch, -1, 0) + _sh(ch, 1, 0) + _sh(ch, 0, -1) + _sh(ch, 0, 1)) / 4
            out[c][mask[c]] = nb[mask[c]]
    return out


def _row_var(p, K, read_var, extra_var=0.0, dark=False, br=16, sw=32):
    """Row-offset variance per group [{0,1}, {2,3}] -> (var (2,) signed, n_rows (2,), std err (2,)).
    p: (4,h,w) with hot pixels removed. extra_var: known offset variance along the other axis
    (it enters the horizontal-diff flatness test)."""
    _, h, w = p.shape
    nby, nbx = (h - 2) // br, w // sw
    none = np.zeros(2), np.zeros(2, int), np.full(2, np.inf)
    if nby < 2 or nbx < 4: return none
    H, W = nby * br, nbx * sw
    x = p[:, :H + 2, :W]
    d = x[:, 1:-1] - (x[:, :-2] + x[:, 2:]) / 2                          # (4,H,W) vertical hp
    xc = x[:, 1:-1]
    e = np.diff(xc, axis=2)                                               # horizontal diff, no row offset
    e = np.concatenate([e, e[:, :, -1:]], 2)
    blk = lambda a: a.reshape(4, nby, br, nbx, sw)
    m = blk(xc).mean((2, 4))
    vh = blk(e).var((2, 4)) / 2                                           # pixel var (+ col var)
    vd = blk(d).var((2, 4)) / 1.5                                         # pixel var + row var (+texture)
    exp = K * np.clip(m, 0, None) + read_var + extra_var
    ok = vh < 1.3 * exp
    if not dark: ok &= (m > 0.002) & (m < 0.6)                           # clipping at both ends
    if ok.sum() < 8: return none
    if not dark:  # horizontal edges / texture. Not on dark frames: no texture there, and vd holds the
        ratio = vd / np.maximum(vh, 1e-20)  # row variance, so the test would drop high-banding blocks
        ok &= ratio < 1.2 * np.median(ratio[ok])
    seg = d.reshape(4, H, nbx, sw).mean(3)                                # (4,H,nbx) row-segment means
    okr = np.repeat(ok, br, 1)                                            # (4,H,nbx)
    var, n, se = np.zeros(2), np.zeros(2, int), np.full(2, np.inf)
    for g, chans in enumerate(((0, 1), (2, 3))):
        s, f = seg[list(chans)], okr[list(chans)].astype(np.float32)
        A, B = slice(0, nbx // 2), slice(nbx // 2, None)  # far apart: texture uncorrelated
        na, nb = f[:, :, A].sum((0, 2)), f[:, :, B].sum((0, 2))
        a = (s[:, :, A] * f[:, :, A]).sum((0, 2)) / np.maximum(na, 1)
        b = (s[:, :, B] * f[:, :, B]).sum((0, 2)) / np.maximum(nb, 1)
        use = (na > 0) & (nb > 0)
        S, D = ((a + b) / 2)[use], ((a - b) / 2)[use]
        if len(S) < 16: continue
        mad = lambda v: 1.4826 * np.median(np.abs(v - np.median(v))) + 1e-12
        keep = (np.abs(S - np.median(S)) < 5 * mad(S)) & (np.abs(D) < 5 * mad(D))
        wt = (na * nb / (na + nb + 1e-9))[use][keep]                          # rows with more flat area count more
        z = S[keep] ** 2 - D[keep] ** 2
        var[g] = np.sum(wt * z) / wt.sum() / 1.5                          # signed: unbiased when averaged
        se[g] = np.sqrt(np.sum(wt ** 2 * (z - var[g] * 1.5) ** 2)) / wt.sum() / 1.5
        n[g] = keep.sum()
    return var, n, se


def _pool(var, n, se=None):
    if not n.sum(): return (0.0, np.inf) if se is not None else 0.0
    v = float(np.sum(var * n) / n.sum())
    return (v, float(np.sqrt(np.sum((np.where(n > 0, se, 0) * n) ** 2)) / n.sum())) if se is not None else max(v, 0.0)


def _sd(v, se):
    """Detection threshold: below 2 standard errors report 0 (no measurable banding)."""
    return v ** .5 if v > 2 * se else 0.0


def estimate_rowcol(packed, K=None, read_var=None):
    """packed (4,h,w) float32 normalized RGGB -> dict(row_sd, col_sd, black_offset (4,), hot_rate,
    hot_amp, chan_gain (4,), dark, n_rows, n_cols, row_var/col_var (signed, for unbiased averaging over
    files), row_se/col_se). row_sd/col_sd are 0 below 2 standard errors. black_offset / chan_gain are NaN when not
    measurable (photos / dark frames respectively). K/read_var: calibrated values for this
    camera+ISO; estimated from the frame when None."""
    p = np.asarray(packed, np.float32)
    dark = abs(float(p.mean())) < DARK_MEAN
    if read_var is None or K is None:
        if dark:
            e = np.diff(p, axis=2)
            K, read_var = 1e-8, float(np.median((1.4826 * np.median(np.abs(e), (1, 2))) ** 2) / 2)
        else:
            K, read_var = noise.estimate(p)
    hot = hot_pixels(p, K, read_var)
    hot_amp = float(np.median((p - _fill(p, hot))[hot])) if hot.any() else 0.0
    q = _fill(p, hot)
    pt = q.transpose(0, 2, 1)[[0, 2, 1, 3]]          # columns -> rows; raw col groups {0,2},{1,3}
    rv, nr, _ = _row_var(q, K, read_var, 0.0, dark)
    cv, nc, cs = _row_var(pt, K, read_var, _pool(rv, nr), dark)
    rv, nr, rs = _row_var(q, K, read_var, _pool(cv, nc), dark)   # 2nd pass with column var known
    (rvar, rse), (cvar, cse) = _pool(rv, nr, rs), _pool(cv, nc, cs)
    bo = np.full(4, np.nan, np.float32)
    if dark:
        for c in range(4):
            v = q[c]; s = 1.4826 * np.median(np.abs(v - np.median(v)))
            bo[c] = v[np.abs(v - np.median(v)) < 6 * s].mean()
    gain = np.full(4, np.nan, np.float32)
    if not dark:
        try:
            Kc = np.array([noise.estimate(q[c:c + 1])[0] for c in range(4)])
            gain = (Kc / Kc.mean()).astype(np.float32)
        except Exception:
            pass
    return dict(row_sd=_sd(rvar, rse), col_sd=_sd(cvar, cse), row_var=rvar, col_var=cvar, row_se=rse, col_se=cse, black_offset=bo,
                hot_rate=float(hot.mean()), hot_amp=hot_amp, chan_gain=gain, dark=dark,
                n_rows=int(nr.sum()), n_cols=int(nc.sum()), K=float(K), read_var=float(read_var))


def calib_params(calib, model, iso):
    """(K, read_var) from calibrate.py's table, log-log interpolated (same as train.NoiseTable)."""
    if not calib or model not in calib: return None, None
    a = np.array(sorted(calib[model]), np.float64)
    li = math.log(iso)
    return (math.exp(np.interp(li, np.log(a[:, 0]), np.log(a[:, 1]))),
            math.exp(np.interp(li, np.log(a[:, 0]), np.log(a[:, 2]))))


_CALIB = None


def _init(calib):
    global _CALIB
    _CALIB = calib


def load_packed(path):
    """(model, iso, packed). Real data only: needs rawpy + exiftool."""
    from . import raw
    r = raw.load(path)
    return r.model, r.iso, raw.pack(r.cfa)


def one(path, loader=None):
    try:
        m, iso, p = (loader or load_packed)(path)
        K, rv = calib_params(_CALIB, m, iso)
        return m, iso, estimate_rowcol(p, K, rv), path
    except Exception as e:
        return None, 0, None, f"{path}: {e}"


def aggregate(results):
    """[(model, iso, est dict)] -> noise_ext JSON dict. Per (model, ISO): medians over files;
    black_offset_sd = RMS per-channel offset over dark frames (0 if none); chan_gain_sd per camera =
    std over channels of the per-channel median gain (medians kill per-frame estimation noise)."""
    per = defaultdict(list)
    for m, iso, e in results: per[(m, iso)].append(e)
    out = {}
    for m in sorted({k[0] for k in per}):
        isos = sorted(i for mm, i in per if mm == m)
        d = dict(iso=[], row_sd=[], col_sd=[], black_offset_sd=[], hot_rate=[], hot_amp=[], n=[], n_dark=[])
        gains = []
        for iso in isos:
            es = per[(m, iso)]
            dk = [e for e in es if e["dark"]]
            src = dk or es                               # dark frames are far more accurate: prefer them
            bo = np.array([e["black_offset"] for e in dk], np.float64)
            d["iso"].append(float(iso))
            # median of the SIGNED per-file variances, then sqrt: no positive bias from clipping at 0
            d["row_sd"].append(float(max(np.median([e["row_var"] for e in src]), 0) ** .5))
            d["col_sd"].append(float(max(np.median([e["col_var"] for e in src]), 0) ** .5))
            d["black_offset_sd"].append(float(np.sqrt(np.nanmean(bo ** 2))) if len(bo) else 0.0)
            d["hot_rate"].append(float(np.median([e["hot_rate"] for e in src])))
            d["hot_amp"].append(float(np.median([e["hot_amp"] for e in src])))
            d["n"].append(len(es)); d["n_dark"].append(len(dk))
            gains += [e["chan_gain"] for e in es if not e["dark"] and np.all(np.isfinite(e["chan_gain"]))]
        d["chan_gain_sd"] = float(np.std(np.median(gains, 0))) if gains else 0.0
        out[m] = d
    return out


def _synth(h, w, K, rv, row_sd, col_sd, rng, dark=False):
    """Textured packed scene + Poisson-Gaussian + raw-level row/col offsets (for validation/tests)."""
    yy, xx = np.mgrid[0:h, 0:w] / max(h, w)
    s = 0.03 + 0.3 * xx + 0.1 * yy + 0.08 * (np.sin(xx * 60 + 3 * yy) > 0.7) + 0.05 * ((xx - 0.5) ** 2 + (yy - 0.4) ** 2 < 0.04)
    clean = np.zeros((4, h, w)) if dark else np.stack([s * g for g in (0.5, 1, 1, 0.7)])
    x = rng.poisson(clean / K) * K + rng.normal(0, rv ** .5, clean.shape)
    ro, co = rng.normal(0, row_sd, (2, h)), rng.normal(0, col_sd, (2, w))
    x[[0, 1]] += ro[0][None, :, None]; x[[2, 3]] += ro[1][None, :, None]
    x[[0, 2]] += co[0][None, None, :]; x[[1, 3]] += co[1][None, None, :]
    return x.astype(np.float32)


def validate(table, calib, rng=np.random.default_rng(0)):
    """Re-measure synthetic frames carrying the measured params: if 'out' ~ 'meas', the estimator is
    unbiased at this operating point (otherwise distrust that row of the table)."""
    print("\nvalidation (synthetic frame with measured params, 768x1024 packed)")
    print("model ISO  row_meas  row_synth  col_meas  col_synth")
    for m, d in table.items():
        for i, iso in enumerate(d["iso"]):
            K, rv = calib_params(calib, m, iso)
            if K is None: continue
            x = _synth(768, 1024, K, rv, d["row_sd"][i], d["col_sd"][i], rng)
            e = estimate_rowcol(x, K, rv)
            print(f"{m} {iso:.0f} {d['row_sd'][i]:.2e} {e['row_sd']:.2e} {d['col_sd'][i]:.2e} {e['col_sd']:.2e}")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("list"); ap.add_argument("--calib", default="data/calib.json")
    ap.add_argument("--out", default="data/noise_ext.json"); ap.add_argument("--workers", type=int, default=6)
    a = ap.parse_args(argv)
    try: calib = json.load(open(a.calib))
    except OSError: calib = None; print("no calib table; estimating K/read_var per frame")
    files = [l.strip() for l in open(a.list) if l.strip()]
    res = []
    with ProcessPoolExecutor(a.workers, initializer=_init, initargs=(calib,)) as ex:
        for m, iso, e, p in ex.map(one, files, chunksize=4):
            if m is None: print("skip", p); continue
            res.append((m, iso, e))
            rs = e["read_var"] ** .5
            print(f"{m} ISO{iso:.0f} {'DARK ' if e['dark'] else ''}row={e['row_sd']:.2e} ({e['row_sd'] / rs:.3f} read)"
                  f" col={e['col_sd']:.2e} hot={e['hot_rate']:.1e} rows={e['n_rows']}", flush=True)
    table = aggregate(res)
    print("\nmodel ISO n dark  row_sd  col_sd  row/read  black_off_sd  hot_rate")
    for m, d in table.items():
        for i, iso in enumerate(d["iso"]):
            K, rv = calib_params(calib, m, iso)
            rr = d["row_sd"][i] / rv ** .5 if rv else float("nan")
            print(f"{m} {iso:.0f} {d['n'][i]} {d['n_dark'][i]} {d['row_sd'][i]:.2e} {d['col_sd'][i]:.2e}"
                  f" {rr:.3f} {d['black_offset_sd'][i]:.2e} {d['hot_rate'][i]:.1e}")
        print(f"{m} chan_gain_sd={d['chan_gain_sd']:.4f}")
    if calib: validate(table, calib)
    json.dump(table, open(a.out, "w"), indent=1)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
