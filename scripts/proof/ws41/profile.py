#!/usr/bin/env python3
"""Radial falloff of the vignette, measured on a rendered flat 0.18 frame.

Renders flat32 (3:2) or flat_grey (1:1) undithered through lumen-render, inverts each
output code to the EV applied there (lib.calibration) and divides by Amount, giving the
fraction of Amount delivered per pixel. Reports, per setting:

  centre, corner        fraction at the frame centre / mean of the 4 corner pixels
  side_mid, top_mid     fraction at the middle of the left/right edges / top/bottom edges
  r10 r50 r90 w         radii (half-diagonal units, along the centre->corner diagonal)
                        where 10/50/90 % of Amount is reached; w = r90 - r10
  w_px                  w in output pixels
  edge_px               pixels with 0.1 < fraction < 0.9 along the centre row (right half)
  aa_rms                stair-step check: RMS (px) of the de-meaned residual between each
                        row's sub-pixel 50 % crossing and the roundness-0 ellipse through r50
  circ                  50%-contour radius in PIXELS along rays at 0..45 deg: max/min
                        (1.00 = circle in pixel space; only rays whose 50 % point is inside)
  top_var side_var      max-min fraction along the middle 60 % of the top / side edge
  mean                  frame-mean fraction

  profile.py [--frame flat32|flat_grey] [--amount -2] [--set k=v ...]
             [--key look.vignetteMidpoint --values 0,10,...,100] [--json out.json]
  profile.py --selftest     # today's default against smoothstep(0.375, 1, r)
Sweeps also print the worst reversal of r50/w/side_mid/top_mid/corner and the smallest
change per step (dead-range check).
"""
import argparse, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib


def bilinear(a, x, y):
    H, W = a.shape
    x = np.clip(x, 0, W - 1.001); y = np.clip(y, 0, H - 1.001)
    x0 = np.floor(x).astype(int); y0 = np.floor(y).astype(int)
    fx = x - x0; fy = y - y0
    return (a[y0, x0] * (1 - fx) * (1 - fy) + a[y0, x0 + 1] * fx * (1 - fy)
            + a[y0 + 1, x0] * (1 - fx) * fy + a[y0 + 1, x0 + 1] * fx * fy)


def crossing(t, f, level):
    i = np.argmax(f >= level)
    if f[i] < level:
        return float('nan')
    if i == 0:
        return float(t[0])
    return float(t[i - 1] + (level - f[i - 1]) * (t[i] - t[i - 1]) / max(f[i] - f[i - 1], 1e-9))


def measure(frame, amount, sets, long_edge=768):
    img, _ = lib.render(lib.frame(frame), ['look.vignette=%g' % amount] + list(sets),
                        long_edge=long_edge)
    ev = lib.ev_of(img[..., 1])
    f = ev / amount
    H, W = f.shape
    cx, cy = W / 2 - 0.5, H / 2 - 0.5
    t = np.linspace(0, 1, 1001)
    diag = bilinear(f, cx + t * W / 2, cy + t * H / 2)
    row = f[H // 2, W // 2:]
    hd = np.hypot(W / 2, H / 2)
    circ = []
    rr = np.linspace(0, hd, 4000)
    for ang in range(0, 50, 5):
        a = np.radians(ang)
        xs, ys = cx + rr * np.cos(a), cy + rr * np.sin(a)
        inside = (xs <= W - 1) & (ys <= H - 1)
        r50 = crossing(rr[inside], bilinear(f, xs[inside], ys[inside]), 0.5)
        if r50 == r50:
            circ.append(r50)
    # stair-step check: sub-pixel x of the 50 % crossing in each row with |v| <= 0.6 (right
    # half), against the roundness-0 ellipse through that r50; RMS of the de-meaned residual
    # in px. An aliased hard edge is a +-0.5 px sawtooth (RMS ~0.29); anti-aliased ~< 0.1.
    r50d = crossing(t, diag, 0.5)
    res = []
    for yy in range(int(cy - 0.6 * H / 2), int(cy + 0.6 * H / 2) + 1):
        v = (yy - cy) / (H / 2)
        q = 2 * r50d * r50d - v * v
        if not (r50d == r50d) or q <= 0 or np.sqrt(q) >= 0.995:
            continue
        rowv = f[yy, W // 2:]
        xs = crossing(np.arange(rowv.size, dtype=float), rowv, 0.5)
        if xs == xs:
            res.append(W // 2 + xs - (cx + np.sqrt(q) * W / 2))
    res = np.array(res)
    aa = float(np.sqrt(np.mean((res - res.mean()) ** 2))) if res.size > 10 else float('nan')
    m = slice(int(0.2 * W), int(0.8 * W)); n = slice(int(0.2 * H), int(0.8 * H))
    return dict(
        centre=float(f[H // 2 - 1:H // 2 + 1, W // 2 - 1:W // 2 + 1].mean()),
        corner=float(np.mean([f[0, 0], f[0, -1], f[-1, 0], f[-1, -1]])),
        side_mid=float(np.mean([f[H // 2 - 1:H // 2 + 1, 0], f[H // 2 - 1:H // 2 + 1, -1]])),
        top_mid=float(np.mean([f[0, W // 2 - 1:W // 2 + 1], f[-1, W // 2 - 1:W // 2 + 1]])),
        r10=crossing(t, diag, 0.1), r50=crossing(t, diag, 0.5), r90=crossing(t, diag, 0.9),
        edge_px=int(np.sum((row > 0.1) & (row < 0.9))), aa_rms=aa,
        w_px=(crossing(t, diag, 0.9) - crossing(t, diag, 0.1)) * hd,
        circ=float(max(circ) / min(circ)) if len(circ) > 1 else float('nan'),
        top_var=float(np.ptp(np.r_[f[0, m], f[-1, m]])),
        side_var=float(np.ptp(np.r_[f[n, 0], f[n, -1]])),
        mean=float(f.mean()), W=W, H=H)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frame', default='flat32')
    ap.add_argument('--amount', type=float, default=-2.0)
    ap.add_argument('--set', action='append', default=[])
    ap.add_argument('--key'); ap.add_argument('--values')
    ap.add_argument('--long-edge', type=int, default=768)
    ap.add_argument('--json'); ap.add_argument('--selftest', action='store_true')
    a = ap.parse_args()
    if a.selftest:
        r = measure('flat32', -2, [])
        ss = lambda x: np.clip((x - .375) / .625, 0, 1) ** 2 * (3 - 2 * np.clip((x - .375) / .625, 0, 1))
        print('measured r50 %.4f (analytic 0.6875)  w %.4f (analytic 0.3803)  side_mid %.3f top_mid %.3f'
              ' (analytic %.3f)  corner %.3f' % (r['r50'], r['r90'] - r['r10'], r['side_mid'],
                                                 r['top_mid'], ss(np.sqrt(.5)), r['corner']))
        return
    vals = a.values.split(',') if a.key else [None]
    rows = []
    for v in vals:
        sets = a.set + (['%s=%s' % (a.key, v)] if a.key else [])
        r = measure(a.frame, a.amount, sets, a.long_edge)
        r['w'] = r['r90'] - r['r10']
        r['value'] = v
        rows.append(r)
        print('%-8s centre %.3f corner %.3f side_mid %.3f top_mid %.3f | r10 %.3f r50 %.3f r90 %.3f '
              'w %.3f (%.1f px) edge_px %3d aa_rms %.3f | circ %.3f top_var %.3f side_var %.3f mean %.3f' % (
                  v, r['centre'], r['corner'], r['side_mid'], r['top_mid'], r['r10'], r['r50'],
                  r['r90'], r['w'], r['w_px'], r['edge_px'], r['aa_rms'], r['circ'], r['top_var'], r['side_var'], r['mean']))
    if len(rows) > 2:
        for k in ['r50', 'w', 'side_mid', 'top_mid', 'corner', 'mean']:
            d = np.diff([r[k] for r in rows])
            print('%-9s worst reversal vs overall direction %.4f   smallest |step| %.4f' % (
                k, max(0.0, float(-np.sign(d.sum()) * d.min() if d.sum() else 0)) if d.size else 0,
                float(np.abs(d).min()) if d.size else 0))
    if a.json:
        json.dump(rows, open(a.json, 'w'), indent=1)


if __name__ == '__main__':
    main()
