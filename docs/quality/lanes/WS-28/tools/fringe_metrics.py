#!/usr/bin/env python3
"""fringe_metrics.py -- independent lateral-CA and colour-fringe measurement (WS-28 auditor).

Written by the WS-28 auditor. Shares no code with LumenCore or with the builder's
implementation: numpy for the maths, Pillow only to read PNG files.

USAGE
    python3 fringe_metrics.py IMAGE [--out metrics.json] [--max-edges N] [--seed S]
                              [--fringe-threshold 0.03] [--space auto|rec2020|srgb]
    python3 fringe_metrics.py --compare BEFORE AFTER [--out compare.json]
    python3 fringe_metrics.py --selftest [--out selftest.json]

--compare measures both images with identical settings (same seed) and prints a
per-zone table: R-G / B-G median shift, fit shift at r = 0.5/0.75/1.0, fringe width
median/p90/mean, fringed fraction, purple/green fringe edges per 1000, and the AFTER
minus BEFORE change; the JSON (--out) holds both full results plus the deltas. BEFORE
and AFTER must have the same size. Each of BEFORE/AFTER may also be a JSON file this
tool wrote earlier, which is reused instead of re-measured.

IMAGE is either
  * a `.lfi` (b"LFI1", uint32 w,h,c=3, float32 RGB, row-major): scene-linear Rec.2020,
    read as is; or
  * an 8-bit (or 16-bit) sRGB PNG, e.g. lumen-render output: decoded with the sRGB
    transfer function to display-linear sRGB primaries.

GEOMETRY. The optical centre is assumed at the image centre. r is the distance from the
centre normalised to the half-diagonal (r = 1 at the corners). Zones: Z1 0-0.3, Z2 0.3-0.6,
Z3 0.6-0.8, Z4 0.8-1.0.

(a) LATERAL MISREGISTRATION (R vs G, B vs G), in px, positive = the channel is displaced
    OUTWARD (away from the centre) relative to G, i.e. the channel image is magnified.
    A channel scaled by s about the centre reads shift(r) = (s - 1) * r * halfdiag_px.
    Method:
      1. log2(G) is smoothed with a [1,2,1]^2 binomial; Sobel gradient; non-maximum
         suppression along the gradient; keep pixels with gradient >= 0.25 stop/px and
         whose gradient direction is within 25 deg of the radial direction (|cos| >= 0.906).
         Points with r < 0.08 are skipped (radial direction ill defined, shift ~ 0).
      2. Along the radial unit vector, each channel is sampled by bilinear interpolation at
         t in [-10, 10] px, step 0.1 px.
      3. Each channel's profile is normalised to a 0..1 step using the means of its own
         two ends (|t| in [5, 6] px on each side), so the colour/white balance of the two
         sides does not matter.
      4. For d in [-4, 4] px (step 0.1), SSD(d) = sum over t in [-5, 5] of
         (C_n(t) - G_n(t - d))^2; the minimum is refined with a parabola -> sub-0.1-px d.
      5. Rejected: any channel above 97 % of its image maximum anywhere on the profile
         (clipping), a channel whose step is < 0.5 stop or opposite in sign to G, G step
         < 1 stop, minimum at the search boundary, residual SSD/sample > 0.01, or a
         profile that is not a single step (overshoot outside [-0.25, 1.25]).
      6. Reported per zone: count, median, MAD of the R-G and B-G shifts. Globally: a
         least-squares fit shift(r) = k1*r + k3*r^3 (r normalised), iterated 4 times
         with 3-MAD rejection, evaluated at r = 0.5, 0.75, 1.0, plus the equivalent
         scale factor 1 + shift(1)/halfdiag_px.

(b) COLOUR-FRINGE WIDTH, in px, across strong luminance edges.
      1. Luminance Y = linear-light luminance of the input primaries. log2(Y) is
         smoothed, Sobel gradient, non-maximum suppression, gradient >= 0.25 stop/px.
      2. Profile along the gradient direction, t in [-10, 10] px, step 0.5 px.
      3. The two flat sides are |t| in [7, 10]. Kept only if contrast
         |log2(Y_hi/Y_lo)| >= 1.5 stops and each side is flat (std of log2 Y <= 0.25).
      4. Fringe-free prediction: any blur with the SAME point-spread function in all three
         channels makes every transition pixel a linear-light mix of the two sides,
         expected = A + alpha (B - A) with alpha = (Y - Y_A)/(Y_B - Y_A) clamped to [0,1].
         Both the measured and the expected pixel go to OKLab (via XYZ, D65); the fringe
         excess is the Euclidean distance between their (a, b).
      5. Width = (number of samples with |t| <= 6 px and excess > THRESHOLD) * 0.5 px.
         THRESHOLD defaults to 0.03 OKLab ab units (about 3 x the OKLab JND of ~0.01;
         roughly Delta E 2000 of 2.5-3 for these colours).
      6. Hue of the excess vector (measured - expected) at every over-threshold sample:
         OKLab hue angle h = atan2(b, a) in degrees. Classes:
             purple  [270, 350)   (blue-violet .. magenta: the axial-CA "purple fringe")
             green   [100, 170)   (yellow-green .. green)
             red     [350, 40)    orange [40, 100)  cyan [170, 230)   blue [230, 270)
         An edge is a "purple fringe" if >= 2 over-threshold samples (1 px) are purple, likewise
         for green. Counts are reported per zone.
      Reported per zone: edges measured, median and p90 width, mean width, fraction of
      edges with any fringe (width > 0), purple- and green-fringe edge counts (and per
      1000 edges), hue-class histogram of over-threshold samples.

For a display-referred PNG the linear-mix prediction is only approximate (the tone curve is
not linear), so compare PNG numbers with PNG numbers and LFI with LFI.

Deterministic: candidate points are subsampled with a fixed seed (default 1234).
"""

import argparse
import json
import math
import os
import struct
import sys
import time

import numpy as np

ZONES = [(0.0, 0.3), (0.3, 0.6), (0.6, 0.8), (0.8, 1.0)]
ZONE_NAMES = ["0.0-0.3", "0.3-0.6", "0.6-0.8", "0.8-1.0"]
# Edge candidates: non-maximum-suppressed Sobel gradient of the smoothed log2 signal
# (G for the lateral measurement, luminance for the fringe width) of at least this many
# stops per pixel.
GRAD_THR_STOPS_PER_PX = 0.25

# Linear RGB -> XYZ (D65)
M_REC2020_XYZ = np.array([[0.636958048301291, 0.144616903586208, 0.168880975164172],
                          [0.262700212011267, 0.677998071518871, 0.059301716469862],
                          [0.000000000000000, 0.028072693049087, 1.060985057710791]])
M_SRGB_XYZ = np.array([[0.4123907992659595, 0.357584339383878, 0.1804807884018343],
                       [0.21263900587151036, 0.715168678767756, 0.07219231536073371],
                       [0.01933081871559185, 0.11919477979462599, 0.9505321522496606]])
# OKLab (Ottosson), XYZ D65 -> LMS
M_XYZ_LMS = np.array([[0.8189330101, 0.3618667424, -0.1288597137],
                      [0.0329845436, 0.9293118715, 0.0361456387],
                      [0.0482003018, 0.2643662691, 0.6338517070]])
M_LMS_LAB = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                      [1.9779984951, -2.4285922050, 0.4505937099],
                      [0.0259040371, 0.7827717662, -0.8086757660]])


# ----------------------------------------------------------------------------- I/O

def read_lfi(path):
    with open(path, "rb") as f:
        head = f.read(16)
        if head[:4] != b"LFI1":
            raise ValueError("not an LFI1 file: %s" % path)
        w, h, c = struct.unpack("<III", head[4:16])
        if c != 3:
            raise ValueError("LFI channels must be 3")
        a = np.fromfile(f, dtype="<f4", count=w * h * 3)
    return a.reshape(h, w, 3).astype(np.float32, copy=False)


def srgb_to_linear(v):
    v = v.astype(np.float32)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4).astype(np.float32)


def read_png(path):
    from PIL import Image
    im = Image.open(path)
    mode = im.mode
    if mode in ("I;16", "I;16B", "I;16L", "I"):
        raise ValueError("greyscale 16-bit PNG not supported")
    im = im.convert("RGB") if mode not in ("RGB",) else im
    a = np.asarray(im)
    scale = 65535.0 if a.dtype == np.uint16 else 255.0
    return srgb_to_linear(a.astype(np.float32) / scale)


def load_image(path, space="auto"):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".lfi":
        img = read_lfi(path)
        sp = "rec2020" if space == "auto" else space
        kind = "lfi (scene-linear)"
    else:
        img = read_png(path)
        sp = "srgb" if space == "auto" else space
        kind = "png (sRGB-decoded display-linear)"
    return img, sp, kind


# ------------------------------------------------------------------- image helpers

def binomial_smooth(a):
    """[1,2,1]/4 separable, edge-replicated."""
    p = np.pad(a, 1, mode="edge")
    t = (p[:-2, :] + 2 * p[1:-1, :] + p[2:, :]) * 0.25
    return ((t[:, :-2] + 2 * t[:, 1:-1] + t[:, 2:]) * 0.25)[:, :].astype(np.float32)


def sobel(a):
    p = np.pad(a, 1, mode="edge")
    gx = ((p[:-2, 2:] + 2 * p[1:-1, 2:] + p[2:, 2:]) - (p[:-2, :-2] + 2 * p[1:-1, :-2] + p[2:, :-2])) * 0.125
    gy = ((p[2:, :-2] + 2 * p[2:, 1:-1] + p[2:, 2:]) - (p[:-2, :-2] + 2 * p[:-2, 1:-1] + p[:-2, 2:])) * 0.125
    return gx.astype(np.float32), gy.astype(np.float32)


def nms_mask(mag, gx, gy):
    """Non-maximum suppression along the gradient, 4 quantised directions."""
    h, w = mag.shape
    ang = np.arctan2(gy, gx)  # -pi..pi, y down
    q = (np.round(ang / (np.pi / 4)).astype(np.int8)) % 4  # 0: x, 1: diag(+x,+y), 2: y, 3: diag(-x,+y)
    p = np.pad(mag, 1, mode="constant")
    c = p[1:-1, 1:-1]
    keep = np.zeros((h, w), dtype=bool)
    nb = {0: ((0, 1), (0, -1)), 1: ((1, 1), (-1, -1)), 2: ((1, 0), (-1, 0)), 3: ((1, -1), (-1, 1))}
    for k, ((dy1, dx1), (dy2, dx2)) in nb.items():
        n1 = p[1 + dy1:1 + dy1 + h, 1 + dx1:1 + dx1 + w]
        n2 = p[1 + dy2:1 + dy2 + h, 1 + dx2:1 + dx2 + w]
        keep |= (q == k) & (c >= n1) & (c > n2)
    return keep


def bilinear(img, x, y):
    """img (h,w,3) float32; x,y arrays of any shape (pixel-centre coordinates). Edge-clamped."""
    h, w = img.shape[:2]
    x = np.clip(x, 0, w - 1.000001)
    y = np.clip(y, 0, h - 1.000001)
    x0 = np.floor(x).astype(np.int64)
    y0 = np.floor(y).astype(np.int64)
    fx = (x - x0)[..., None].astype(np.float32)
    fy = (y - y0)[..., None].astype(np.float32)
    i00 = img[y0, x0]
    i01 = img[y0, x0 + 1]
    i10 = img[y0 + 1, x0]
    i11 = img[y0 + 1, x0 + 1]
    return (i00 * (1 - fx) * (1 - fy) + i01 * fx * (1 - fy) + i10 * (1 - fx) * fy + i11 * fx * fy)


def to_oklab(rgb, m_rgb_xyz):
    """rgb (...,3) linear -> OKLab (...,3). Negative LMS is cube-rooted with sign."""
    xyz = rgb @ m_rgb_xyz.T.astype(np.float32)
    lms = xyz @ M_XYZ_LMS.T.astype(np.float32)
    lms = np.cbrt(lms)
    return lms @ M_LMS_LAB.T.astype(np.float32)


def radial_coords(h, w, ys, xs):
    cy, cx = (h - 1) / 2.0, (w - 1) / 2.0
    hd = math.hypot(w / 2.0, h / 2.0)
    dx = xs - cx
    dy = ys - cy
    rr = np.hypot(dx, dy)
    return dx, dy, rr / hd, hd


def zone_index(r):
    z = np.full(r.shape, -1, dtype=np.int64)
    for i, (lo, hi) in enumerate(ZONES):
        sel = (r >= lo) & ((r < hi) if i < len(ZONES) - 1 else (r <= 1.0 + 1e-9))
        z[sel] = i
    return z


def subsample_per_zone(idx_y, idx_x, r, max_per_zone, rng):
    z = zone_index(r)
    keep = []
    for i in range(len(ZONES)):
        ii = np.nonzero(z == i)[0]
        if len(ii) > max_per_zone:
            ii = np.sort(rng.choice(ii, max_per_zone, replace=False))
        keep.append(ii)
    k = np.concatenate(keep) if keep else np.zeros(0, dtype=np.int64)
    return idx_y[k], idx_x[k], r[k]


# ------------------------------------------------------- (a) lateral misregistration

def measure_lateral(img, max_per_zone=25000, rng=None, chunk=4000):
    h, w = img.shape[:2]
    g = img[..., 1]
    gfloor = max(float(np.percentile(g, 0.1)), 1e-5)
    G = binomial_smooth(np.log2(np.maximum(g, gfloor)).astype(np.float32))
    gx, gy = sobel(G)
    mag = np.hypot(gx, gy)
    nms = nms_mask(mag, gx, gy)
    cand = nms & (mag >= GRAD_THR_STOPS_PER_PX)
    ys, xs = np.nonzero(cand)
    ys = ys.astype(np.float64)
    xs = xs.astype(np.float64)
    dx, dy, r, hd = radial_coords(h, w, ys, xs)
    rr = np.maximum(np.hypot(dx, dy), 1e-9)
    ux, uy = dx / rr, dy / rr
    cosang = np.abs(gx[cand] * ux + gy[cand] * uy) / np.maximum(mag[cand], 1e-12)
    margin = 14
    ok = (cosang >= math.cos(math.radians(25))) & (r >= 0.08) & \
         (xs >= margin) & (xs < w - margin) & (ys >= margin) & (ys < h - margin)
    ys, xs, r = ys[ok], xs[ok], r[ok]
    ys, xs, r = subsample_per_zone(ys, xs, r, max_per_zone, rng)
    del G, gx, gy, mag, nms, cand

    chmax = np.array([float(np.max(img[..., c])) for c in range(3)], dtype=np.float32)
    clip = 0.97 * chmax

    step = 0.1
    T = 10.0
    t = np.arange(-T, T + 1e-9, step)            # 201 samples
    nT = len(t)
    c0 = int(round(T / step))                    # index of t=0
    win = int(round(5.0 / step))                 # comparison window |t| <= 5
    dmax = int(round(4.0 / step))                # shifts |d| <= 4
    endlo = (t >= -6.0) & (t <= -5.0)
    endhi = (t >= 5.0) & (t <= 6.0)

    out_shift = {"R": [], "B": []}
    out_r = []
    out_ok = {"R": [], "B": []}
    n = len(ys)
    for s0 in range(0, n, chunk):
        cy_, cx_, rc = ys[s0:s0 + chunk], xs[s0:s0 + chunk], r[s0:s0 + chunk]
        ddx, ddy, _, _ = radial_coords(h, w, cy_, cx_)
        nrm = np.maximum(np.hypot(ddx, ddy), 1e-9)
        ux, uy = (ddx / nrm)[:, None], (ddy / nrm)[:, None]
        px = cx_[:, None] + ux * t[None, :]
        py = cy_[:, None] + uy * t[None, :]
        prof = bilinear(img, px, py)            # (m, nT, 3)
        m = prof.shape[0]
        clipped = np.any(prof >= clip[None, None, :], axis=(1, 2))
        lo = prof[:, endlo, :].mean(axis=1)    # (m,3)
        hi = prof[:, endhi, :].mean(axis=1)
        stepv = hi - lo
        # stops of contrast per channel (sign-aware)
        eps = 1e-6
        stops = np.log2(np.maximum(np.maximum(hi, lo), eps) / np.maximum(np.minimum(hi, lo), eps))
        sgn = np.sign(stepv)
        good = (~clipped) & (stops[:, 1] >= 1.0) & (np.minimum(lo, hi).min(axis=1) > 0)
        pn = (prof - lo[:, None, :]) / np.where(np.abs(stepv) < 1e-12, 1e-12, stepv)[:, None, :]
        Gn = pn[:, :, 1]
        cw = slice(c0 - win, c0 + win + 1)
        overshoot_ok_G = (Gn[:, cw].min(axis=1) > -0.25) & (Gn[:, cw].max(axis=1) < 1.25)
        for ci, name in ((0, "R"), (2, "B")):
            Cn = pn[:, cw, ci]                  # (m, 2win+1)
            okc = good & overshoot_ok_G & (stops[:, ci] >= 0.5) & (sgn[:, ci] == sgn[:, 1]) & \
                (Cn.min(axis=1) > -0.25) & (Cn.max(axis=1) < 1.25)
            ssd = np.empty((m, 2 * dmax + 1), dtype=np.float32)
            for k, d in enumerate(range(-dmax, dmax + 1)):
                # G_n(t - d): index shift of -d samples
                gs = Gn[:, c0 - win - d: c0 + win + 1 - d]
                ssd[:, k] = np.sum((Cn - gs) ** 2, axis=1)
            kmin = np.argmin(ssd, axis=1)
            interior = (kmin > 0) & (kmin < 2 * dmax)
            kk = np.clip(kmin, 1, 2 * dmax - 1)
            rows = np.arange(m)
            s_m, s_0, s_p = ssd[rows, kk - 1], ssd[rows, kk], ssd[rows, kk + 1]
            den = s_m - 2 * s_0 + s_p
            frac = np.where(den > 1e-12, 0.5 * (s_m - s_p) / np.where(den > 1e-12, den, 1), 0.0)
            frac = np.clip(frac, -0.5, 0.5)
            d_px = ((kk - dmax) + frac) * step
            resid = s_0 / (2 * win + 1)
            okc &= interior & (resid <= 0.01)
            out_shift[name].append(d_px)
            out_ok[name].append(okc)
        out_r.append(rc)
    if n == 0:
        rr_all = np.zeros(0)
        sh = {k: np.zeros(0) for k in ("R", "B")}
        okm = {k: np.zeros(0, dtype=bool) for k in ("R", "B")}
    else:
        rr_all = np.concatenate(out_r)
        sh = {k: np.concatenate(v) for k, v in out_shift.items()}
        okm = {k: np.concatenate(v) for k, v in out_ok.items()}

    res = {"candidates": int(n), "halfdiag_px": hd if n else math.hypot(w / 2, h / 2),
           "sign_convention": "px, + = channel displaced outward (magnified) relative to G",
           "zones": {}, "fit": {}}
    z = zone_index(rr_all)
    for i, zn in enumerate(ZONE_NAMES):
        zr = {}
        for name in ("R", "B"):
            sel = okm[name] & (z == i)
            v = sh[name][sel]
            if len(v):
                med = float(np.median(v))
                mad = float(np.median(np.abs(v - med)))
                zr[name + "-G"] = {"n": int(len(v)), "median_px": round(med, 4),
                                   "mad_px": round(mad, 4),
                                   "median_abs_px": round(float(np.median(np.abs(v))), 4)}
            else:
                zr[name + "-G"] = {"n": 0, "median_px": None, "mad_px": None, "median_abs_px": None}
        res["zones"][zn] = zr
    for name in ("R", "B"):
        sel = okm[name]
        rv, dv = rr_all[sel], sh[name][sel]
        res["fit"][name + "-G"] = robust_fit(rv, dv, res["halfdiag_px"])
    return res


def robust_fit(r, d, hd):
    if len(r) < 20:
        return {"n": int(len(r)), "k1": None, "k3": None}
    keep = np.ones(len(r), dtype=bool)
    for _ in range(4):
        A = np.stack([r[keep], r[keep] ** 3], axis=1)
        coef, *_ = np.linalg.lstsq(A, d[keep], rcond=None)
        pred = coef[0] * r + coef[1] * r ** 3
        res = d - pred
        mad = np.median(np.abs(res[keep] - np.median(res[keep])))
        keep = np.abs(res) <= max(3 * 1.4826 * mad, 0.05)
    k1, k3 = float(coef[0]), float(coef[1])
    ev = {("shift_at_r%.2f_px" % rv): round(k1 * rv + k3 * rv ** 3, 4) for rv in (0.5, 0.75, 1.0)}
    # bootstrap-free standard error from residuals
    A = np.stack([r[keep], r[keep] ** 3], axis=1)
    resid = d[keep] - A @ np.array([k1, k3])
    dof = max(int(keep.sum()) - 2, 1)
    s2 = float(resid @ resid) / dof
    try:
        cov = s2 * np.linalg.inv(A.T @ A)
        se1 = math.sqrt(cov[0, 0] + cov[1, 1] + 2 * cov[0, 1])
    except np.linalg.LinAlgError:
        se1 = None
    out = {"n": int(len(r)), "n_inliers": int(keep.sum()), "k1": round(k1, 5), "k3": round(k3, 5)}
    out.update(ev)
    out["stderr_shift_at_r1.00_px"] = None if se1 is None else round(se1, 4)
    out["equivalent_scale_at_r1"] = round(1.0 + (k1 + k3) / hd, 7)
    return out


# ------------------------------------------------------------- (b) fringe width

HUE_CLASSES = [("red", 350, 40), ("orange", 40, 100), ("green", 100, 170), ("cyan", 170, 230),
               ("blue", 230, 270), ("purple", 270, 350)]


def hue_class(h):
    out = np.empty(h.shape, dtype=np.int8)
    for i, (_, lo, hi) in enumerate(HUE_CLASSES):
        if lo < hi:
            out[(h >= lo) & (h < hi)] = i
        else:
            out[(h >= lo) | (h < hi)] = i
    return out


def luminance(img, m):
    wts = m[1].astype(np.float32)
    return img[..., 0] * wts[0] + img[..., 1] * wts[1] + img[..., 2] * wts[2]


def measure_fringe(img, m_rgb_xyz, threshold=0.03, max_per_zone=25000, rng=None, chunk=4000):
    h, w = img.shape[:2]
    Y = luminance(img, m_rgb_xyz)
    floor = max(float(np.percentile(Y, 0.1)), 1e-5)
    LY = np.log2(np.maximum(Y, floor)).astype(np.float32)
    del Y
    LYs = binomial_smooth(LY)
    del LY
    gx, gy = sobel(LYs)
    mag = np.hypot(gx, gy)
    nms = nms_mask(mag, gx, gy)
    cand = nms & (mag >= GRAD_THR_STOPS_PER_PX)
    ys, xs = np.nonzero(cand)
    gxc, gyc, mc = gx[cand], gy[cand], mag[cand]
    del LYs, mag, nms
    margin = 14
    ok = (xs >= margin) & (xs < w - margin) & (ys >= margin) & (ys < h - margin)
    ys, xs = ys[ok].astype(np.float64), xs[ok].astype(np.float64)
    gxc, gyc, mc = gxc[ok], gyc[ok], mc[ok]
    _, _, r, _ = radial_coords(h, w, ys, xs)
    # subsample keeping gradient arrays aligned
    z = zone_index(r)
    keep = []
    for i in range(len(ZONES)):
        ii = np.nonzero(z == i)[0]
        if len(ii) > max_per_zone:
            ii = np.sort(rng.choice(ii, max_per_zone, replace=False))
        keep.append(ii)
    k = np.concatenate(keep)
    ys, xs, r, gxc, gyc, mc = ys[k], xs[k], r[k], gxc[k], gyc[k], mc[k]
    del gx, gy

    step = 0.5
    T = 10.0
    t = np.arange(-T, T + 1e-9, step)   # 41 samples
    side_lo = t <= -7.0
    side_hi = t >= 7.0
    core = np.abs(t) <= 6.0
    wts = m_rgb_xyz[1].astype(np.float32)

    width_all, r_all, purple_all, green_all, cls_counts_all = [], [], [], [], []
    n = len(ys)
    for s0 in range(0, n, chunk):
        sl = slice(s0, s0 + chunk)
        ux = (gxc[sl] / mc[sl])[:, None]
        uy = (gyc[sl] / mc[sl])[:, None]
        px = xs[sl][:, None] + ux * t[None, :]
        py = ys[sl][:, None] + uy * t[None, :]
        prof = bilinear(img, px, py)                    # (m,41,3) linear
        Yp = prof @ wts
        A = prof[:, side_lo, :].mean(axis=1)            # dark/low-t side
        B = prof[:, side_hi, :].mean(axis=1)
        YA, YB = A @ wts, B @ wts
        eps = 1e-6
        lA = np.log2(np.maximum(Yp[:, side_lo], eps))
        lB = np.log2(np.maximum(Yp[:, side_hi], eps))
        contrast = np.abs(np.log2(np.maximum(YB, eps) / np.maximum(YA, eps)))
        flat = (lA.std(axis=1) <= 0.25) & (lB.std(axis=1) <= 0.25)
        okm = (contrast >= 1.5) & flat & (YA > 0) & (YB > 0)
        dY = YB - YA
        alpha = np.clip((Yp - YA[:, None]) / np.where(np.abs(dY) < 1e-12, 1e-12, dY)[:, None], 0, 1)
        expct = A[:, None, :] + alpha[..., None] * (B - A)[:, None, :]
        labm = to_oklab(prof, m_rgb_xyz)
        labe = to_oklab(expct, m_rgb_xyz)
        da = labm[..., 1] - labe[..., 1]
        db = labm[..., 2] - labe[..., 2]
        ex = np.hypot(da, db)
        over = (ex > threshold) & core[None, :]
        width = over.sum(axis=1) * step
        hue = (np.degrees(np.arctan2(db, da)) + 360.0) % 360.0
        hc = hue_class(hue)
        cls_counts = np.stack([np.sum(over & (hc == i), axis=1) for i in range(len(HUE_CLASSES))], axis=1)
        purple = cls_counts[:, 5] >= 2
        green = cls_counts[:, 2] >= 2
        width_all.append(width[okm])
        r_all.append(r[sl][okm])
        purple_all.append(purple[okm])
        green_all.append(green[okm])
        cls_counts_all.append(cls_counts[okm])
    if n:
        W = np.concatenate(width_all)
        R = np.concatenate(r_all)
        P = np.concatenate(purple_all)
        Gr = np.concatenate(green_all)
        C = np.concatenate(cls_counts_all)
    else:
        W = R = np.zeros(0)
        P = Gr = np.zeros(0, dtype=bool)
        C = np.zeros((0, len(HUE_CLASSES)))
    res = {"candidates": int(n), "edges_measured": int(len(W)), "threshold_oklab_ab": threshold,
           "min_contrast_stops": 1.5, "zones": {}}
    z = zone_index(R)
    for i, zn in enumerate(ZONE_NAMES):
        sel = z == i
        wv = W[sel]
        if len(wv) == 0:
            res["zones"][zn] = {"edges": 0}
            continue
        ccount = C[sel].sum(axis=0)
        res["zones"][zn] = {
            "edges": int(len(wv)),
            "width_median_px": float(np.median(wv)),
            "width_p90_px": float(np.percentile(wv, 90)),
            "width_mean_px": round(float(np.mean(wv)), 3),
            "fringed_fraction": round(float(np.mean(wv > 0)), 4),
            "purple_edges": int(P[sel].sum()),
            "green_edges": int(Gr[sel].sum()),
            "purple_per_1000": round(1000.0 * float(P[sel].mean()), 1),
            "green_per_1000": round(1000.0 * float(Gr[sel].mean()), 1),
            "overthreshold_samples_by_hue": {HUE_CLASSES[j][0]: int(ccount[j]) for j in range(len(HUE_CLASSES))},
        }
    return res


# ------------------------------------------------------------------------ driver

def analyse(img, space, threshold=0.03, max_edges=25000, seed=1234):
    m = M_REC2020_XYZ if space == "rec2020" else M_SRGB_XYZ
    rng = np.random.default_rng(seed)
    t0 = time.time()
    lat = measure_lateral(img, max_per_zone=max_edges, rng=rng)
    rng = np.random.default_rng(seed + 1)
    fr = measure_fringe(img, m, threshold=threshold, max_per_zone=max_edges, rng=rng)
    return {"width": int(img.shape[1]), "height": int(img.shape[0]), "primaries": space,
            "lateral": lat, "fringe": fr, "seconds": round(time.time() - t0, 1)}


# ---------------------------------------------------------------------- self-test

def _gauss_blur(a, sigma):
    if sigma <= 0:
        return a
    rad = int(math.ceil(3 * sigma))
    k = np.exp(-0.5 * (np.arange(-rad, rad + 1) / sigma) ** 2)
    k = (k / k.sum()).astype(np.float32)
    p = np.pad(a, ((rad, rad), (0, 0)), mode="edge")
    out = np.zeros_like(a)
    for i, kv in enumerate(k):
        out += kv * p[i:i + a.shape[0], :]
    p = np.pad(out, ((0, 0), (rad, rad)), mode="edge")
    out2 = np.zeros_like(a)
    for i, kv in enumerate(k):
        out2 += kv * p[:, i:i + a.shape[1]]
    return out2


def synth_disks(w, h, scales=(1.0, 1.0, 1.0), blur=(0.7, 0.7, 0.7), noise=0.002, seed=7, ndisks=None):
    """Random dark disks on a bright background, rendered analytically (coverage =
    clip(R - dist + 0.5)), each channel sampled through its own radial magnification
    `scales[c]` about the image centre: channel_c(p) = scene(c0 + (p - c0)/s_c).
    The disks' radii (12-90 px) make edges in every direction at every radius."""
    rng = np.random.default_rng(seed)
    cy, cx = (h - 1) / 2.0, (w - 1) / 2.0
    if ndisks is None:
        ndisks = int(w * h / 9000)
    centres = np.stack([rng.uniform(0, w, ndisks), rng.uniform(0, h, ndisks)], axis=1)
    radii = rng.uniform(12, 90, ndisks)
    vals = rng.uniform(0.02, 0.2, ndisks)
    img = np.empty((h, w, 3), dtype=np.float32)
    for c in range(3):
        s = scales[c]
        ch = np.full((h, w), 0.8, dtype=np.float32)
        for (dxc, dyc), rad, v in zip(centres, radii, vals):
            # bounding box in output pixel coordinates
            ox, oy = cx + (dxc - cx) * s, cy + (dyc - cy) * s
            rr = rad * s + 2
            x0, x1 = max(int(ox - rr), 0), min(int(ox + rr) + 2, w)
            y0, y1 = max(int(oy - rr), 0), min(int(oy + rr) + 2, h)
            if x0 >= x1 or y0 >= y1:
                continue
            yy, xx = np.mgrid[y0:y1, x0:x1].astype(np.float64)
            qx = cx + (xx - cx) / s
            qy = cy + (yy - cy) / s
            dist = np.hypot(qx - dxc, qy - dyc)
            cov = np.clip(rad - dist + 0.5, 0, 1).astype(np.float32)
            ch[y0:y1, x0:x1] = cov * v + (1 - cov) * ch[y0:y1, x0:x1]
        ch = _gauss_blur(ch, blur[c])
        img[..., c] = ch
    if noise > 0:
        img += rng.normal(0, noise, img.shape).astype(np.float32)
    return img


def synth_purple_band(w=1200, h=800, band_px=3):
    """Vertical and horizontal straight edges (bright 0.8 / dark 0.05, neutral) with a
    purple band of exactly `band_px` px on the dark side of every edge."""
    img = np.full((h, w, 3), 0.8, dtype=np.float32)
    dark = np.zeros((h, w), dtype=bool)
    for x0 in range(100, w - 100, 200):
        dark[:, x0:x0 + 100] = True
    img[dark] = 0.05
    band = np.zeros((h, w), dtype=bool)
    for x0 in range(100, w - 100, 200):
        band[:, x0:x0 + band_px] = True
        band[:, x0 + 100 - band_px:x0 + 100] = True
    img[band] = np.array([0.10, 0.03, 0.16], dtype=np.float32)   # purple, dark-ish
    return img


def selftest():
    out = {}
    # 1. lateral: known scales, two image sizes
    cases = [
        ("3000x2000 R x1.0005 B x0.9995", 3000, 2000, (1.0005, 1.0, 0.9995)),
        ("6000x4000 R x1.0005 B x0.9995", 6000, 4000, (1.0005, 1.0, 0.9995)),
        ("6000x4000 R x0.9997 B x1.0008", 6000, 4000, (0.9997, 1.0, 1.0008)),
        ("6000x4000 zero CA", 6000, 4000, (1.0, 1.0, 1.0)),
    ]
    for name, w, h, sc in cases:
        img = synth_disks(w, h, scales=sc)
        hd = math.hypot(w / 2.0, h / 2.0)
        res = measure_lateral(img, max_per_zone=25000, rng=np.random.default_rng(1))
        rows = {}
        for ch, ci in (("R-G", 0), ("B-G", 2)):
            f = res["fit"][ch]
            truth = {rv: (sc[ci] - 1.0) * rv * hd for rv in (0.5, 0.75, 1.0)}
            meas = {rv: f.get("shift_at_r%.2f_px" % rv) for rv in (0.5, 0.75, 1.0)}
            err = max(abs(meas[rv] - truth[rv]) for rv in truth) if f["k1"] is not None else None
            zt = {}
            for zi, zn in enumerate(ZONE_NAMES):
                lo, hi = ZONES[zi]
                zt[zn] = {"measured_median": res["zones"][zn][ch]["median_px"],
                          "n": res["zones"][zn][ch]["n"]}
            rows[ch] = {"truth_px": {str(k): round(v, 4) for k, v in truth.items()},
                        "measured_px": {str(k): v for k, v in meas.items()},
                        "max_abs_error_px": None if err is None else round(err, 4),
                        "n": f["n"], "zones": zt}
        out["lateral: " + name] = rows
        print(name, json.dumps({k: (v["max_abs_error_px"], v["measured_px"], v["truth_px"]) for k, v in rows.items()}),
              file=sys.stderr)
    # 2. fringe: zero-CA synthetic disks (blur identical) must read ~0 width
    img = synth_disks(3000, 2000, scales=(1, 1, 1))
    fr = measure_fringe(img, M_REC2020_XYZ, rng=np.random.default_rng(2))
    out["fringe: 3000x2000 zero CA"] = fr
    # 3. fringe: lateral CA 1.0005/0.9995 on 6000x4000
    img = synth_disks(6000, 4000, scales=(1.0005, 1.0, 0.9995))
    fr = measure_fringe(img, M_REC2020_XYZ, rng=np.random.default_rng(2))
    out["fringe: 6000x4000 R x1.0005 B x0.9995"] = fr
    del img
    # 4. fringe: known 3-px purple band
    for bp in (2, 3, 5):
        img = synth_purple_band(band_px=bp)
        fr = measure_fringe(img, M_REC2020_XYZ, rng=np.random.default_rng(3))
        out["fringe: purple band %d px" % bp] = fr
    # 5. axial-CA-like: B and R blurred more than G -> purple on dark side
    img = synth_disks(3000, 2000, scales=(1, 1, 1), blur=(1.6, 0.7, 2.4))
    fr = measure_fringe(img, M_REC2020_XYZ, rng=np.random.default_rng(2))
    out["fringe: 3000x2000 axial-like blur R1.6 G0.7 B2.4"] = fr
    return out


def _load_or_measure(path, a):
    if path.lower().endswith(".json"):
        with open(path) as f:
            return json.load(f)
    img, sp, kind = load_image(path, a.space)
    res = analyse(img, sp, threshold=a.fringe_threshold, max_edges=a.max_edges, seed=a.seed)
    res["input"] = os.path.abspath(path)
    res["input_kind"] = kind
    return res


def compare(b, c):
    """Print and return per-zone before/after/delta rows."""
    rows = {"lateral_fit": {}, "zones": {}}
    lines = []
    if (b["width"], b["height"]) != (c["width"], c["height"]):
        lines.append("WARNING: sizes differ %dx%d vs %dx%d" % (b["width"], b["height"], c["width"], c["height"]))

    def fmt(v):
        return "   -  " if v is None else "%7.3f" % v

    def dl(x, y):
        return None if (x is None or y is None) else round(y - x, 4)

    lines.append("LATERAL fit shift(r) px (+ = channel outward vs G)    before   after   delta")
    for ch in ("R-G", "B-G"):
        for rv in ("0.50", "0.75", "1.00"):
            k = "shift_at_r%s_px" % rv
            x, y = b["lateral"]["fit"][ch].get(k), c["lateral"]["fit"][ch].get(k)
            rows["lateral_fit"]["%s r=%s" % (ch, rv)] = {"before": x, "after": y, "delta": dl(x, y)}
            lines.append("  %s r=%s %38s %s %s %s" % (ch, rv, "", fmt(x), fmt(y), fmt(dl(x, y))))
    keys_l = [("R-G", "median_px"), ("B-G", "median_px")]
    keys_f = ["width_median_px", "width_p90_px", "width_mean_px", "fringed_fraction",
              "purple_per_1000", "green_per_1000"]
    for zn in ZONE_NAMES:
        zr = {}
        lines.append("ZONE r %s" % zn)
        for ch, k in keys_l:
            x = b["lateral"]["zones"][zn][ch][k]
            y = c["lateral"]["zones"][zn][ch][k]
            zr["%s median shift px" % ch] = {"before": x, "after": y, "delta": dl(x, y),
                                            "n_before": b["lateral"]["zones"][zn][ch]["n"],
                                            "n_after": c["lateral"]["zones"][zn][ch]["n"]}
            lines.append("  %-28s %s %s %s" % (ch + " median shift px", fmt(x), fmt(y), fmt(dl(x, y))))
        fb, fc = b["fringe"]["zones"][zn], c["fringe"]["zones"][zn]
        for k in keys_f:
            x, y = fb.get(k), fc.get(k)
            zr[k] = {"before": x, "after": y, "delta": dl(x, y)}
            lines.append("  %-28s %s %s %s" % (k, fmt(x), fmt(y), fmt(dl(x, y))))
        zr["edges"] = {"before": fb.get("edges"), "after": fc.get("edges")}
        lines.append("  %-28s %7s %7s" % ("fringe edges measured", fb.get("edges"), fc.get("edges")))
        rows["zones"][zn] = zr
    print("\n".join(lines))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", nargs="?")
    ap.add_argument("--out")
    ap.add_argument("--max-edges", type=int, default=25000, help="max edge points per zone, per measurement")
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--fringe-threshold", type=float, default=0.03)
    ap.add_argument("--space", default="auto", choices=["auto", "rec2020", "srgb"])
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    a = ap.parse_args()
    if a.compare:
        b = _load_or_measure(a.compare[0], a)
        c = _load_or_measure(a.compare[1], a)
        res = {"before": b, "after": c, "delta": compare(b, c)}
        if a.out:
            with open(a.out, "w") as f:
                f.write(json.dumps(res, indent=1) + "\n")
        return
    if a.selftest:
        res = selftest()
    else:
        if not a.image:
            ap.error("IMAGE required")
        img, sp, kind = load_image(a.image, a.space)
        res = analyse(img, sp, threshold=a.fringe_threshold, max_edges=a.max_edges, seed=a.seed)
        res["input"] = os.path.abspath(a.image)
        res["input_kind"] = kind
    s = json.dumps(res, indent=1)
    if a.out:
        with open(a.out, "w") as f:
            f.write(s + "\n")
    else:
        print(s)


if __name__ == "__main__":
    main()
