#!/usr/bin/env python3
"""Feather-0 edge on any crop aspect (SPEC Amendment A1, line 29).

Renders flat32 (768x512 output) with a crop of the given aspect, feather 0, and measures
the hard edge INSIDE the crop rectangle (the uncropped CPU output, as crop.py does):

  w_min    smallest 10-90 % width of the edge, in output px, measured ALONG THE
           GRADIENT: per column (top half) and per row (left half) the 10/50/90 %
           crossings, linear between pixel centres, projected onto the contour normal
           (wherever the contour is within 45 deg of that axis). Must be >= 1.0 px. A
           true step reads about 0.8 px through the interpolation, so 1.0 separates.
  aa_rms   stair-step check: RMS (px) of the 50 % crossing against a local quadratic
           fit over +-6 lines. An aliased edge is a +-0.5 px sawtooth (about 0.29).

  edge.py [--aspect 1:1|3:2|6:1|1:6 ...] [--set k=v ...]
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib

CROPS = {  # fractions of the 3:2 frame giving these crop aspects in pixels
    '1:1': (1 / 6, 0, 2 / 3, 1), '3:2': (0, 0, 1, 1),
    '6:1': (0, 0.375, 1, 0.25), '1:6': (0.4444444, 0, 0.1111111, 1)}


def crossing(t, f, level):
    i = np.argmax(f >= level)
    if f[i] < level or i == 0:
        return float('nan')
    return float(t[i - 1] + (level - f[i - 1]) * (t[i] - t[i - 1]) / max(f[i] - f[i - 1], 1e-9))


def lines(f, X0, Y0, X1, Y1, vertical):
    """Per column (vertical=True: the edge's top half) or per row (left half): sub-pixel
    10/50/90 % crossings walking from the crop's middle toward its edge, linear between
    pixel centres. Returns (positions, r10, r50, r90) in px."""
    pos, out = [], []
    if vertical:
        mid = int((Y0 + Y1) / 2)
        for x in range(int(np.ceil(X0)), int(X1)):
            col = f[int(np.ceil(Y0)):mid + 1, x][::-1]
            out.append([crossing(np.arange(col.size, dtype=float), col, l) for l in (.1, .5, .9)])
            pos.append(x)
    else:
        mid = int((X0 + X1) / 2)
        for y in range(int(np.ceil(Y0)), int(Y1)):
            row = f[y, int(np.ceil(X0)):mid + 1][::-1]
            out.append([crossing(np.arange(row.size, dtype=float), row, l) for l in (.1, .5, .9)])
            pos.append(y)
    o = np.array(out)
    return np.array(pos, float), o[:, 0], o[:, 1], o[:, 2]


def measure(aspect, sets, amount=-2.0):
    cx, cy, cw, ch = CROPS[aspect]
    W, H = 768, 512
    geo = ['develop.geometry.crop.x=%g' % cx, 'develop.geometry.crop.y=%g' % cy,
           'develop.geometry.crop.w=%g' % cw, 'develop.geometry.crop.h=%g' % ch]
    img, _ = lib.render(lib.frame('flat32'), ['look.vignette=%g' % amount,
                        'look.vignetteFeather=0'] + list(sets) + geo, long_edge=W)
    f = lib.ev_of(img[..., 1]) / amount
    X0, Y0, X1, Y1 = cx * W, cy * H, (cx + cw) * W, (cy + ch) * H
    widths, residuals = [], []
    for vertical in (True, False):
        pos, a, b, c = lines(f, X0, Y0, X1, Y1, vertical)
        ok = np.isfinite(a) & np.isfinite(b) & np.isfinite(c)
        pos, a, b, c = pos[ok], a[ok], b[ok], c[ok]
        if pos.size < 15:
            continue
        slope = np.gradient(b, pos)
        flat = np.abs(slope) <= 1
        widths += list(((c - a) / np.sqrt(1 + slope ** 2))[flat])
        # stair-step: residual of the 50 % crossing against a local quadratic over +-6
        for k in np.nonzero(flat)[0]:
            lo, hi = max(0, k - 6), min(pos.size, k + 7)
            if hi - lo < 9:
                continue
            fit = np.polyval(np.polyfit(pos[lo:hi], b[lo:hi], 2), pos[k])
            residuals.append(b[k] - fit)
    w = np.array(widths); r = np.array(residuals)
    return dict(w_min=float(w.min()) if w.size else float('nan'),
                w_median=float(np.median(w)) if w.size else float('nan'),
                aa_rms=float(np.sqrt(np.mean(r ** 2))) if r.size else float('nan'),
                rays=int(w.size))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--aspect', action='append')
    ap.add_argument('--set', action='append', default=[])
    a = ap.parse_args()
    for asp in a.aspect or list(CROPS):
        m = measure(asp, a.set)
        print('%-4s w_min %.2f px  w_median %.2f px  aa_rms %.3f px  (%d lines)' % (
            asp, m['w_min'], m['w_median'], m['aa_rms'], m['rays']))


if __name__ == '__main__':
    main()
