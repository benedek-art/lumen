#!/usr/bin/env python3
"""grain_metrics.py - measure the grain a render added (WS-40, Grain).

Needs python3, numpy, Pillow. Render the SAME frame twice with lumen-render, once with
grain and once with grain amount 0, both with --no-dither so the difference is the grain
only. All measurements run on the luminance of the difference:

    Y = 0.2126 R + 0.7152 G + 0.0722 B      on the 8-bit sRGB code values (0..255)
    d = Y(grained) - Y(base)

SUB-COMMANDS

  analyze GRAINED BASE [--downsample N] [--crop x,y,w,h] [--lum-bins K] [--json out.json]
                       [--diff-png out.png --gain G]
      std        std of d in 8-bit codes; "rel" = std / mean(Y(base)) (fraction of level);
                 also std of d / Y(base) per pixel ("local relative").
      acf        normalised 2D autocorrelation (linear, zero-padded, divided by overlap
                 count) at lags 1,2,3,4,6,8,12,16,24,32,64,128,256,512: along x, along y,
                 and max |acf| over all directions on the ring of that radius.
                 For independent grain, acf at any lag >= a few cell sizes is ~0 (noise
                 floor ~ 1/sqrt(N_overlap)). A plate tiled with period P gives acf ~1
                 at lag P (and multiples); value noise gives slow decay.
      far_max    the largest acf at any 2D lag of length >= 8 px and where it is
                 (a tiled plate gives ~1 at its period).
      corr_len   lag (px, linear interpolation) where acf(x) and acf(y) first fall
                 below 1/e.
      spectrum   radially averaged power spectrum (Hann window), 48 bins over
                 0..0.5 cycles/px; "radial_spike" = max over bins of P[i] / median(P[i-2..i+2]
                 without i); "spike2d" = max over the 2D spectrum of P(f) / median of P in
                 f's radial bin, with the frequency and period (px) where it occurs.
                 Null reference: for Gaussian noise without structure, spike2d is
                 about ln(N)/ln(2) (N = number of FFT bins), i.e. ~20 at 1024x1024;
                 a lattice/tiling peak is far above that.
      --downsample N   box-average GRAINED and BASE by N before analysis (preview vs
                 export: render at long edge 2048, downsample by 2, compare with 1024).
      --lum-bins K     std of d per bin of base luminance code (std vs level; use on
                 corpus/synthetic/grey_ramp.lfi).

  scale  G1 B1 G2 B2 --factor F [--json out.json]
      G1/B1 rendered at long edge L, G2/B2 at F*L. G2/B2 are box-downsampled by F and
      the radial spectra of the two grains are compared: ratio P2/P1 per bin over
      0..0.5 Nyquist, std ratio, and the corr_len of both. A grain that is the same
      picture at both sizes gives ratio ~1 everywhere (high bins may drop: that is the
      box filter, ~sinc^2).

      Also prints the 0..0.25 cyc/px (half Nyquist) band power ratio and the per-bin
      ratio range over radial bins merged to >= 3000 FFT samples each (JSON:
      "half_nyquist"); the unmerged low bins are too noisy for a +-15% test.

  check  GRAINED BASE [--crop x,y,w,h] [--factor 3] [--block 8]
      One JSON line with everything run_spec.py thresholds: std, cl (1/e corr length),
      acf_beyond (ring-mean / axis / single-lag acf at lags >= factor*cl), radial_spike,
      spike2d and spike2d_interp (2D periodogram / radial mean interpolated at the
      sample's radius: null ~ln N, ~12 at 1024^2, robust on steep spectra), kurtosis,
      energy_cv (std/mean of the block x block mean of d^2), fine_frac (variance at
      f >= 0.125), chroma_rg/bg (std(dR-dG)/std(dY)) and logchroma_rg/bg
      (std(ln R'/R - ln G'/G)/std(ln Y'/Y) on pixels with every channel >= 64).

  envelope  GRAINED BASE [--bins 16] [--dmax 4] [--min-n 2000] [--min-frac 0.25] [--json]
      Per-bin std of d vs the density envelope sqrt(p(1-p)), p = -log10(Y)/Dmax, carried
      to 8-bit codes (x Y ln10 dsRGB/dY), least-squares scaled; reports max |deviation|.
      Use on corpus/synthetic/grey_ramp.lfi.

  sheet  --out sheet.png [--size 256] [--pos x,y|center] [--zoom 1] [--columns 4]
         [--diff BASE --gain 4] LABEL=PATH [LABEL=PATH ...]
      Cut a size x size crop at the same position from each image (100% pixels, or
      nearest-neighbour zoom) and tile them with labels. Saved as PNG; if over 400 KB it
      is re-saved with an adaptive 256-colour palette. --diff BASE adds, per image, a
      crop of 128 + gain*(image - BASE) so the grain itself is visible. An item written
      LABEL=PATH|BASEPATH uses its own base (e.g. a film stock at grain 0).

Example
  B=$(swift build -c release --show-bin-path)/lumen-render
  $B render --input corpus/synthetic/flat_grey.lfi --no-dither --long-edge 1024 \
      --set look.grain.amount=100 --out g.png
  $B render --input corpus/synthetic/flat_grey.lfi --no-dither --long-edge 1024 --out b.png
  python3 grain_metrics.py analyze g.png b.png
"""
import argparse
import json
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

LAGS = [1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 64, 128, 256, 512]


def load_rgb(path):
    im = Image.open(path)
    if im.mode not in ("RGB", "RGBA", "I;16", "I;16B"):
        im = im.convert("RGB")
    a = np.asarray(im).astype(np.float64)
    if a.ndim == 2:
        a = np.stack([a] * 3, -1)
    a = a[..., :3]
    if a.max() > 255.5:          # 16-bit PNG -> 8-bit code units
        a = a / 257.0
    return a


def luma(a):
    return a[..., 0] * 0.2126 + a[..., 1] * 0.7152 + a[..., 2] * 0.0722


def box_down(a, f):
    if f <= 1:
        return a
    h, w = a.shape[0] // f * f, a.shape[1] // f * f
    a = a[:h, :w]
    s = a.reshape(h // f, f, w // f, f, *a.shape[2:])
    return s.mean(axis=(1, 3))


def acf2d(d):
    """Linear (zero-padded) autocorrelation, normalised to 1 at lag 0, unbiased by overlap."""
    d = d - d.mean()
    h, w = d.shape
    H, W = 2 * h, 2 * w
    F = np.fft.rfft2(d, s=(H, W))
    r = np.fft.irfft2(F * np.conj(F), s=(H, W))
    ones = np.fft.rfft2(np.ones_like(d), s=(H, W))
    cnt = np.fft.irfft2(ones * np.conj(ones), s=(H, W))
    cnt = np.maximum(np.round(cnt), 1)
    r = r / cnt
    r = r / r[0, 0]
    return np.fft.fftshift(r), (h, w)   # centre at (h, w)


def acf_report(d):
    r, (h, w) = acf2d(d)
    cy, cx = h, w
    yy, xx = np.mgrid[-cy:r.shape[0] - cy, -cx:r.shape[1] - cx]
    rad = np.hypot(yy, xx)
    # restrict ring to lags with at least a quarter of the overlap in both axes
    valid = (np.abs(xx) <= w * 0.75) & (np.abs(yy) <= h * 0.75)
    out = {}
    for L in LAGS:
        ax = float(r[cy, cx + L]) if L < w else None
        ay = float(r[cy + L, cx]) if L < h else None
        ring = valid & (np.abs(rad - L) <= 0.5)
        rm = float(np.max(np.abs(r[ring]))) if ring.any() else None
        out[str(L)] = {"x": ax, "y": ay, "ring_max": rm}
    # correlation length (1/e) along x and y
    def clen(profile):
        t = 1 / math.e
        for i in range(1, len(profile)):
            if profile[i] < t:
                a, b = profile[i - 1], profile[i]
                return (i - 1) + (a - t) / (a - b) if a != b else float(i)
        return None
    px = r[cy, cx:cx + w // 2]
    py = r[cy:cy + h // 2, cx]
    # strongest correlation anywhere at distance >= 8 px: a tiled plate shows up here
    # as ~1 at the tile period (the lag list alone can miss a period such as 72 px).
    far = valid & (rad >= 8) & (yy >= 0)
    k = np.unravel_index(np.argmax(np.where(far, r, -2)), r.shape)
    out["far_max"] = {"value": float(r[k]), "lag_xy": [int(xx[k]), int(yy[k])]}
    rep = far & (r > 0.9)          # shortest exact repeat = the tile period
    if rep.any():
        j = np.argmin(np.where(rep, rad, np.inf))
        j = np.unravel_index(j, r.shape)
        out["repeat"] = {"value": float(r[j]), "lag_xy": [int(xx[j]), int(yy[j])],
                         "dist": float(rad[j])}
    else:
        out["repeat"] = None
    return out, {"x": clen(px), "y": clen(py)}


def radial_spectrum(d, nbins=48):
    d = d - d.mean()
    h, w = d.shape
    win = np.outer(np.hanning(h), np.hanning(w))
    P = np.abs(np.fft.fftshift(np.fft.fft2(d * win))) ** 2 / (win ** 2).sum()
    fy = np.fft.fftshift(np.fft.fftfreq(h))
    fx = np.fft.fftshift(np.fft.fftfreq(w))
    FX, FY = np.meshgrid(fx, fy)
    fr = np.hypot(FX, FY)
    edges = np.linspace(0, 0.5, nbins + 1)
    idx = np.clip(np.digitize(fr, edges) - 1, 0, nbins)   # nbins = beyond Nyquist ring
    rad = np.zeros(nbins)
    cnt = np.zeros(nbins, dtype=int)
    med = np.zeros(nbins + 1)
    for i in range(nbins + 1):
        m = idx == i
        if m.any():
            if i < nbins:
                rad[i] = P[m].mean()
                cnt[i] = int(m.sum())
            med[i] = np.median(P[m])
    centres = 0.5 * (edges[:-1] + edges[1:])
    # radial spike
    # (bins below 1e-3 of the peak are skipped: the far tail of a coarse grain's
    # spectrum is kernel side-lobes and 8-bit rounding, not structure anyone can see)
    rs, rsf = 0.0, None
    floor = 1e-3 * rad.max()
    for i in range(nbins):
        if rad[i] < floor:
            continue
        nb = [rad[j] for j in range(i - 2, i + 3) if 0 <= j < nbins and j != i]
        m = np.median(nb)
        if m > 0 and rad[i] / m > rs:
            rs, rsf = rad[i] / m, centres[i]
    # 2D spike vs radial median, ignoring DC neighbourhood
    ratio = P / np.maximum(med[idx], 1e-30)
    ratio[fr < 2.0 / max(h, w)] = 0
    k = np.unravel_index(np.argmax(ratio), ratio.shape)
    f2 = float(fr[k])
    # The same against the radial MEAN interpolated at the sample's own radius: on a
    # steep spectrum the bin median under-states the power at the bin's inner edge, so
    # the median version reads 50-80 for structureless coloured noise. This one has a
    # null of ~ln(N) (~14-20 at 1024^2) for any smooth isotropic spectrum.
    smooth = np.interp(fr, centres, rad)
    ri = P / np.maximum(smooth, 1e-30)
    ri[(fr < 2.0 / max(h, w)) | (fr > 0.5)] = 0
    ki = np.unravel_index(np.argmax(ri), ri.shape)
    fi = float(fr[ki])
    return {
        "freq": centres.tolist(),
        "power": rad.tolist(),
        "count": cnt.tolist(),
        "radial_spike": float(rs), "radial_spike_freq": rsf,
        "spike2d": float(ratio[k]),
        "spike2d_freq": [float(FX[k]), float(FY[k])],
        "spike2d_period_px": (1.0 / f2) if f2 > 0 else None,
        "spike2d_null": math.log(h * w) / math.log(2),
        "spike2d_interp": float(ri[ki]),
        "spike2d_interp_period_px": (1.0 / fi) if fi > 0 else None,
    }


def lum_bins(d, base_y, k):
    edges = np.linspace(0, 255, k + 1)
    rows = []
    for i in range(k):
        m = (base_y >= edges[i]) & (base_y < edges[i + 1])
        if m.sum() > 200:
            rows.append({"lum_lo": float(edges[i]), "lum_hi": float(edges[i + 1]),
                         "n": int(m.sum()), "std": float(d[m].std()),
                         "mean_shift": float(d[m].mean())})
    return rows


def prep(g, b, crop=None, down=1):
    G, Bs = load_rgb(g), load_rgb(b)
    if G.shape != Bs.shape:
        sys.exit(f"shape mismatch {G.shape} vs {Bs.shape}")
    if crop:
        x, y, w, h = crop
        G, Bs = G[y:y + h, x:x + w], Bs[y:y + h, x:x + w]
    G, Bs = box_down(G, down), box_down(Bs, down)
    yb = luma(Bs)
    return luma(G) - yb, yb


def cmd_analyze(a):
    crop = [int(v) for v in a.crop.split(",")] if a.crop else None
    d, yb = prep(a.grained, a.base, crop, a.downsample)
    acf, cl = acf_report(d)
    sp = radial_spectrum(d)
    rep = {
        "grained": a.grained, "base": a.base, "shape": list(d.shape),
        "downsample": a.downsample,
        "std_codes": float(d.std()), "mean_shift_codes": float(d.mean()),
        "base_mean_codes": float(yb.mean()),
        "std_rel": float(d.std() / max(yb.mean(), 1e-9)),
        "std_local_rel": float((d / np.maximum(yb, 1.0)).std()),
        "acf": acf, "corr_len_px": cl, "spectrum": sp,
    }
    if a.lum_bins:
        rep["std_vs_lum"] = lum_bins(d, yb, a.lum_bins)
    if a.diff_png:
        v = np.clip(128 + a.gain * d, 0, 255).astype(np.uint8)
        Image.fromarray(v).save(a.diff_png, optimize=True)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(rep, f, indent=1)
    # human summary
    print(f"{os.path.basename(a.grained)}  {d.shape[1]}x{d.shape[0]}  down={a.downsample}")
    print(f"  std {rep['std_codes']:.3f} codes  rel {100*rep['std_rel']:.2f}% "
          f"(local {100*rep['std_local_rel']:.2f}%)  mean shift {rep['mean_shift_codes']:+.3f}")
    print(f"  corr_len x {fmt(cl['x'])} y {fmt(cl['y'])} px")
    print("  lag   " + " ".join(f"{L:>6}" for L in LAGS))
    for key in ("x", "y", "ring_max"):
        print(f"  {key:<6}" + " ".join(f"{fmt(acf[str(L)][key]):>6}" for L in LAGS))
    fm = acf["far_max"]
    print(f"  acf max at |lag|>=8: {fm['value']:.3f} at lag {fm['lag_xy']}")
    rp = acf["repeat"]
    print("  shortest lag with acf>0.9 (tile period): " +
          (f"{rp['lag_xy']} ({rp['dist']:.1f} px, acf {rp['value']:.3f})" if rp else "none"))
    print(f"  radial_spike {sp['radial_spike']:.2f} at f={fmt(sp['radial_spike_freq'])}  "
          f"spike2d {sp['spike2d']:.1f} (null ~{sp['spike2d_null']:.0f}) at "
          f"f={sp['spike2d_freq'][0]:+.4f},{sp['spike2d_freq'][1]:+.4f} "
          f"period {fmt(sp['spike2d_period_px'])} px")
    if a.lum_bins:
        print("  std vs base luminance code:")
        for r in rep["std_vs_lum"]:
            print(f"    {r['lum_lo']:6.1f}-{r['lum_hi']:6.1f}  std {r['std']:.3f}  "
                  f"shift {r['mean_shift']:+.3f}  n={r['n']}")


def fmt(v):
    return "  -  " if v is None else f"{v:.3f}" if abs(v) < 100 else f"{v:.1f}"


def cmd_scale(a):
    d1, _ = prep(a.g1, a.b1)
    d2, _ = prep(a.g2, a.b2, down=a.factor)
    h, w = min(d1.shape[0], d2.shape[0]), min(d1.shape[1], d2.shape[1])
    d1, d2 = d1[:h, :w], d2[:h, :w]
    s1, s2 = radial_spectrum(d1), radial_spectrum(d2)
    _, c1 = acf_report(d1)
    _, c2 = acf_report(d2)
    ratio = [(q / p if p > 0 else None) for p, q in zip(s1["power"], s2["power"])]
    rep = {"std_small": float(d1.std()), "std_big_down": float(d2.std()),
           "std_ratio": float(d2.std() / max(d1.std(), 1e-12)),
           "corr_len_small": c1, "corr_len_big_down": c2,
           "freq": s1["freq"], "power_ratio": ratio,
           "half_nyquist": half_nyquist_ratio(s1, s2)}
    if a.json:
        with open(a.json, "w") as f:
            json.dump(rep, f, indent=1)
    print(f"std small {rep['std_small']:.3f}  big/{a.factor} {rep['std_big_down']:.3f}  "
          f"ratio {rep['std_ratio']:.3f}")
    print(f"corr_len small {fmt(c1['x'])}/{fmt(c1['y'])}  big/{a.factor} "
          f"{fmt(c2['x'])}/{fmt(c2['y'])}")
    hn = rep["half_nyquist"]
    print(f"0..0.25 cyc/px: band power ratio {hn['band_ratio']:.3f}  per-bin ratio "
          f"{hn['bin_ratio_min']:.3f}..{hn['bin_ratio_max']:.3f} over {hn['bins']} bins "
          f"(>= {hn['min_samples']} FFT samples each)")
    print("power ratio big/small by frequency (cycles/px):")
    for i in range(0, len(ratio), 4):
        print(f"  f {s1['freq'][i]:.3f}  {fmt(ratio[i])}")


def half_nyquist_ratio(s1, s2, fmax=0.25, min_samples=3000):
    """Power ratio s2/s1 over 0..fmax cyc/px (0..half Nyquist), band-integrated and per
    bin. Low-frequency radial bins hold few FFT samples, so their power estimate is
    noisy (each periodogram sample is ~exponential); consecutive bins are merged from
    the low end until each merged bin has >= min_samples samples."""
    f, c = np.array(s1["freq"]), np.array(s1["count"])
    p1, p2 = np.array(s1["power"]) * c, np.array(s2["power"]) * c
    keep = f <= fmax
    f, c, p1, p2 = f[keep], c[keep], p1[keep], p2[keep]
    groups, cur = [], []
    for i in range(len(f)):
        cur.append(i)
        if c[cur].sum() >= min_samples:
            groups.append(cur); cur = []
    if cur:
        if groups:
            groups[-1] += cur
        else:
            groups.append(cur)
    r = [p2[g].sum() / p1[g].sum() for g in groups if p1[g].sum() > 0]
    return {"band_ratio": float(p2.sum() / max(p1.sum(), 1e-30)),
            "bin_ratio_min": float(min(r)), "bin_ratio_max": float(max(r)),
            "bins": len(r), "min_samples": min_samples,
            "bin_freq_hi": [float(f[g[-1]]) for g in groups]}


def srgb_to_linear(c):
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def acf_beyond(d, cl, factor=3.0, rmax=512):
    """The acf where independent grain must have none: every lag of length >=
    factor * cl (cl = 1/e correlation length, px).
      ring_absmax  max over integer radii L in [L0, rmax] of |mean acf on the ring L|
                   (the ring mean averages ~6L lags, so it is not dominated by the
                   estimator noise of single lags)
      axis_absmax  max |acf| along +x and +y at the fixed lags 64, 128, 256, 512
      max2d        the largest acf at any single 2D lag with L0 <= |lag| <= rmax and
                   overlap >= 1/4 of the frame in each axis: a tiled/periodic pattern
                   gives ~1 at its period; independent grain gives only estimator noise
                   (~0.02-0.08 on a 1024^2 crop)."""
    r, (h, w) = acf2d(d)
    yy, xx = np.mgrid[-h:r.shape[0] - h, -w:r.shape[1] - w]
    rad = np.hypot(yy, xx)
    valid = (np.abs(xx) <= w // 2) & (np.abs(yy) <= h // 2)
    L0 = max(2, int(math.ceil(factor * cl)))
    top = min(rmax, h // 2, w // 2)
    # ring means via bincount over rounded radius
    ri = np.rint(rad).astype(int)
    m = valid & (ri >= L0) & (ri <= top)
    sums = np.bincount(ri[m], weights=r[m], minlength=top + 1)
    cnts = np.bincount(ri[m], minlength=top + 1)
    rm = np.where(cnts > 0, sums / np.maximum(cnts, 1), 0.0)
    Ls = np.arange(top + 1)
    sel = (Ls >= L0) & (cnts > 0)
    ring_L = int(Ls[sel][np.argmax(np.abs(rm[sel]))]) if sel.any() else None
    ring_absmax = float(np.max(np.abs(rm[sel]))) if sel.any() else None
    axis = {}
    for L in (64, 128, 256, 512):
        if L < w // 2 + 1 and L < h // 2 + 1:
            axis[str(L)] = [float(r[h, w + L]), float(r[h + L, w])]
    axis_absmax = max((abs(v) for xy in axis.values() for v in xy), default=None)
    far = m & (yy >= 0) & (rad >= max(8, L0))
    k = np.unravel_index(np.argmax(np.where(far, r, -2)), r.shape)
    return {"L0": L0, "rmax": top, "ring_absmax": ring_absmax, "ring_at": ring_L,
            "axis": axis, "axis_absmax": axis_absmax,
            "max2d": float(r[k]), "max2d_lag": [int(xx[k]), int(yy[k])]}


def cmd_check(a):
    """One JSON object with every number run_spec.py thresholds (see docstring)."""
    crop = [int(v) for v in a.crop.split(",")] if a.crop else None
    G, Bs = load_rgb(a.grained), load_rgb(a.base)
    if G.shape != Bs.shape:
        sys.exit(f"shape mismatch {G.shape} vs {Bs.shape}")
    if crop:
        x, y, w, h = crop
        G, Bs = G[y:y + h, x:x + w], Bs[y:y + h, x:x + w]
    D = G - Bs
    d = luma(G) - luma(Bs)
    sd = float(d.std())
    _, cl = acf_report(d)
    clx, cly = cl["x"] or 0.0, cl["y"] or 0.0
    sp = radial_spectrum(d)
    dc = d - d.mean()
    var = float((dc ** 2).mean())
    kurt = float((dc ** 4).mean() / var ** 2) if var > 0 else None
    # local energy CV over b x b blocks: clumpier grain -> more uneven local energy
    b = a.block
    hh, ww = dc.shape[0] // b * b, dc.shape[1] // b * b
    e = (dc[:hh, :ww] ** 2).reshape(hh // b, b, ww // b, b).mean(axis=(1, 3))
    ecv = float(e.std() / e.mean()) if e.mean() > 0 else None
    # fraction of grain variance at f >= 0.125 cyc/px (features <= 4 px)
    P = np.abs(np.fft.fft2(dc)) ** 2
    fr = np.hypot(*np.meshgrid(np.fft.fftfreq(dc.shape[1]), np.fft.fftfreq(dc.shape[0])))
    fine = float(P[fr >= 0.125].sum() / max(P.sum(), 1e-30))
    # chroma of the grain: R-G and B-G of the per-channel difference, as a fraction of
    # the luma grain std (8-bit codes)
    rg = float((D[..., 0] - D[..., 1]).std()); bg = float((D[..., 2] - D[..., 1]).std())
    # hue/chroma constancy on coloured pixels: a luminance-only grain multiplies R, G, B
    # by the same factor, so ln(R'/R) - ln(G'/G) = 0. Pixels with every channel >= 64
    # codes in base and grained (8-bit rounding noise stays well below the grain).
    lg, lb = srgb_to_linear(G), srgb_to_linear(Bs)
    ok = (G.min(axis=-1) >= 64) & (Bs.min(axis=-1) >= 64)
    lr = np.log(np.maximum(lg, 1e-6) / np.maximum(lb, 1e-6))
    ly = np.log(luma(lg)[ok] / luma(lb)[ok])
    if ok.sum() > 1000 and ly.std() > 0:
        lrg = float((lr[..., 0] - lr[..., 1])[ok].std() / ly.std())
        lbg = float((lr[..., 2] - lr[..., 1])[ok].std() / ly.std())
    else:
        lrg = lbg = None
    out = {
        "grained": a.grained, "shape": list(d.shape),
        "std": sd, "mean_shift": float(d.mean()), "base_mean": float(luma(Bs).mean()),
        "max_abs_diff": float(np.abs(D).max()),
        "clx": clx, "cly": cly, "cl": 0.5 * (clx + cly),
        "acf_beyond": acf_beyond(d, max(clx, cly), a.factor),
        "radial_spike": sp["radial_spike"], "radial_spike_freq": sp["radial_spike_freq"],
        "spike2d": sp["spike2d"], "spike2d_null": sp["spike2d_null"],
        "spike2d_period_px": sp["spike2d_period_px"],
        "spike2d_interp": sp["spike2d_interp"],
        "spike2d_interp_period_px": sp["spike2d_interp_period_px"],
        "kurtosis": kurt, "energy_cv": ecv, "fine_frac": fine,
        "chroma_rg": rg / sd if sd > 0 else None, "chroma_bg": bg / sd if sd > 0 else None,
        "logchroma_rg": lrg, "logchroma_bg": lbg, "logchroma_n": int(ok.sum()),
    }
    print(json.dumps(out))


def cmd_envelope(a):
    """Measured std of the grain per bin of base luminance vs the density envelope.

    The grain is a density offset: out = Y * 10^(-A(p) n s), A(p) = sqrt(p(1-p)),
    p = D/Dmax, D = -log10(Y), Y = linear luminance. In 8-bit codes the predicted std
    is therefore proportional to A(p(Y)) * Y * ln10 * dsRGB/dY * 255. The prediction
    is averaged (rms) over the pixels of each bin and scaled to the measurement by
    least squares over the bins used; "dev" is measured / (scale * predicted) - 1.
    Bins used: n >= min_n pixels and predicted >= min_frac * the largest prediction
    (near black and white the prediction -> 0 and a ratio says nothing)."""
    G, Bs = load_rgb(a.grained), load_rgb(a.base)
    d = luma(G) - luma(Bs)
    yb = luma(Bs)
    Y = np.clip(luma(srgb_to_linear(Bs)), 1e-6, 1.0)
    D = -np.log10(Y)
    p = np.clip(D / a.dmax, 0, 1)
    A = np.sqrt(p * (1 - p))
    slope = np.where(Y <= 0.0031308, 12.92, 1.055 / 2.4 * Y ** (1 / 2.4 - 1))
    pred_px = A * Y * math.log(10) * slope * 255
    edges = np.linspace(0, 255, a.bins + 1)
    rows = []
    for i in range(a.bins):
        m = (yb >= edges[i]) & (yb < edges[i + 1]) if i < a.bins - 1 else (yb >= edges[i])
        n = int(m.sum())
        if n < 50:
            continue
        rows.append({"lo": float(edges[i]), "hi": float(edges[i + 1]), "n": n,
                     "std": float(d[m].std()),
                     "pred": float(np.sqrt((pred_px[m] ** 2).mean()))})
    pmax = max(r["pred"] for r in rows)
    use = [r for r in rows if r["n"] >= a.min_n and r["pred"] >= a.min_frac * pmax]
    k = sum(r["std"] * r["pred"] for r in use) / max(sum(r["pred"] ** 2 for r in use), 1e-30)
    for r in rows:
        r["used"] = r in use
        r["dev"] = r["std"] / (k * r["pred"]) - 1 if r["pred"] > 0 and k > 0 else None
    peak = max(rows, key=lambda r: r["std"])
    out = {"scale": k, "max_abs_dev": max(abs(r["dev"]) for r in use),
           "bins_used": len(use), "peak_lo": peak["lo"], "peak_std": peak["std"],
           "first_over_peak": rows[0]["std"] / peak["std"],
           "last_over_peak": rows[-1]["std"] / peak["std"], "rows": rows}
    if a.json:
        print(json.dumps(out))
    else:
        for r in rows:
            print(f"  {r['lo']:6.1f}-{r['hi']:6.1f} n={r['n']:7d} std {r['std']:.3f} "
                  f"pred {k * r['pred']:.3f} dev {r['dev']:+.3f}{'' if r['used'] else '  (not used)'}")
        print(f"max |dev| over {len(use)} bins: {out['max_abs_dev']:.3f}; peak at code "
              f"{peak['lo']:.0f}; first/peak {out['first_over_peak']:.2f} "
              f"last/peak {out['last_over_peak']:.2f}")


def cmd_sheet(a):
    items = []
    for s in a.items:
        lab, _, p = s.partition("=")
        p, _, own_base = p.partition("|")
        items.append((lab, p, own_base))
    shared_base = load_rgb(a.diff) if a.diff else None
    tiles = []
    for lab, p, own_base in items:
        im = load_rgb(p)
        base = load_rgb(own_base) if own_base else shared_base
        h, w = im.shape[:2]
        S = a.size
        if a.pos == "center":
            x, y = (w - S) // 2, (h - S) // 2
        else:
            x, y = [int(v) for v in a.pos.split(",")]
        x, y = max(0, min(x, w - S)), max(0, min(y, h - S))
        c = im[y:y + S, x:x + S]
        tiles.append((f"{lab} @{x},{y}", c))
        if base is not None and base.shape == im.shape:
            dd = luma(c) - luma(base[y:y + S, x:x + S])
            v = np.clip(128 + a.gain * dd, 0, 255)
            tiles.append((f"{lab} grain x{a.gain:g}", np.stack([v] * 3, -1)))
    z, S, pad, lh = a.zoom, a.size * a.zoom, 6, 16
    cols = min(a.columns, len(tiles))
    rows = math.ceil(len(tiles) / cols)
    sheet = Image.new("RGB", (cols * (S + pad) + pad, rows * (S + lh + pad) + pad),
                      (30, 30, 30))
    dr = ImageDraw.Draw(sheet)
    for i, (lab, c) in enumerate(tiles):
        t = Image.fromarray(np.clip(c, 0, 255).astype(np.uint8))
        if z > 1:
            t = t.resize((S, S), Image.NEAREST)
        cx, cy = pad + (i % cols) * (S + pad), pad + (i // cols) * (S + lh + pad)
        dr.text((cx, cy), lab, fill=(235, 235, 235))
        sheet.paste(t, (cx, cy + lh))
    sheet.save(a.out, optimize=True)
    if os.path.getsize(a.out) > 400_000:
        sheet.quantize(256, method=Image.Quantize.MEDIANCUT).save(a.out, optimize=True)
    print(f"{a.out}  {os.path.getsize(a.out)//1024} KB  {len(tiles)} tiles")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("analyze")
    p.add_argument("grained"); p.add_argument("base")
    p.add_argument("--downsample", type=int, default=1)
    p.add_argument("--crop")
    p.add_argument("--lum-bins", type=int, default=0)
    p.add_argument("--json")
    p.add_argument("--diff-png"); p.add_argument("--gain", type=float, default=4)
    p.set_defaults(fn=cmd_analyze)
    p = sub.add_parser("scale")
    for k in ("g1", "b1", "g2", "b2"):
        p.add_argument(k)
    p.add_argument("--factor", type=int, default=2)
    p.add_argument("--json")
    p.set_defaults(fn=cmd_scale)
    p = sub.add_parser("check")
    p.add_argument("grained"); p.add_argument("base")
    p.add_argument("--crop")
    p.add_argument("--factor", type=float, default=3.0)
    p.add_argument("--block", type=int, default=8)
    p.set_defaults(fn=cmd_check)
    p = sub.add_parser("envelope")
    p.add_argument("grained"); p.add_argument("base")
    p.add_argument("--bins", type=int, default=16)
    p.add_argument("--dmax", type=float, default=4.0)
    p.add_argument("--min-n", type=int, default=2000)
    p.add_argument("--min-frac", type=float, default=0.25)
    p.add_argument("--json", action="store_true")
    p.set_defaults(fn=cmd_envelope)
    p = sub.add_parser("sheet")
    p.add_argument("--out", required=True)
    p.add_argument("--size", type=int, default=256)
    p.add_argument("--pos", default="center")
    p.add_argument("--zoom", type=int, default=1)
    p.add_argument("--columns", type=int, default=4)
    p.add_argument("--diff"); p.add_argument("--gain", type=float, default=4)
    p.add_argument("items", nargs="+")
    p.set_defaults(fn=cmd_sheet)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
