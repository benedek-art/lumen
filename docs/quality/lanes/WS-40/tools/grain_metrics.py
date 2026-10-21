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
    med = np.zeros(nbins + 1)
    for i in range(nbins + 1):
        m = idx == i
        if m.any():
            if i < nbins:
                rad[i] = P[m].mean()
            med[i] = np.median(P[m])
    centres = 0.5 * (edges[:-1] + edges[1:])
    # radial spike
    rs, rsf = 0.0, None
    for i in range(nbins):
        nb = [rad[j] for j in range(i - 2, i + 3) if 0 <= j < nbins and j != i]
        m = np.median(nb)
        if m > 0 and rad[i] / m > rs:
            rs, rsf = rad[i] / m, centres[i]
    # 2D spike vs radial median, ignoring DC neighbourhood
    ratio = P / np.maximum(med[idx], 1e-30)
    ratio[fr < 2.0 / max(h, w)] = 0
    k = np.unravel_index(np.argmax(ratio), ratio.shape)
    f2 = float(fr[k])
    return {
        "freq": centres.tolist(),
        "power": rad.tolist(),
        "radial_spike": float(rs), "radial_spike_freq": rsf,
        "spike2d": float(ratio[k]),
        "spike2d_freq": [float(FX[k]), float(FY[k])],
        "spike2d_period_px": (1.0 / f2) if f2 > 0 else None,
        "spike2d_null": math.log(h * w) / math.log(2),
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
           "freq": s1["freq"], "power_ratio": ratio}
    if a.json:
        with open(a.json, "w") as f:
            json.dump(rep, f, indent=1)
    print(f"std small {rep['std_small']:.3f}  big/{a.factor} {rep['std_big_down']:.3f}  "
          f"ratio {rep['std_ratio']:.3f}")
    print(f"corr_len small {fmt(c1['x'])}/{fmt(c1['y'])}  big/{a.factor} "
          f"{fmt(c2['x'])}/{fmt(c2['y'])}")
    print("power ratio big/small by frequency (cycles/px):")
    for i in range(0, len(ratio), 4):
        print(f"  f {s1['freq'][i]:.3f}  {fmt(ratio[i])}")


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
