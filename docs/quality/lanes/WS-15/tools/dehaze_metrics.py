#!/usr/bin/env python3
"""WS-15 Dehaze measurements on rendered sRGB PNGs (lumen-render output).

Every measurement compares an OUTPUT render against the BASE render (dehaze 0) of the
same frame at the same size. Regions come from tools/regions.json (fractional boxes).

Subcommands
  regions  --frame ID --base B.png --out O.png [O2.png ...]
           sky / neutral boxes: mean OKLab L, chroma C, hue h (deg, from mean a,b),
           delta hue, delta chroma, mean dE2000; neutral boxes also report the OKLab a,b
           drift (tint introduced). Far box: luminance std (local contrast) ratio.
  shadow   --base B.png --out O.png [...]
           % pixels newly clipped to 0 per channel, p1 / p5 linear luminance, zone
           deltas (10 equal bins of base encoded Y, mean encoded-Y change in 8-bit codes),
           mean linear luminance change in EV, mean dE2000.
  halo     --frame ID --base B.png --out O.png [...]
           luminance profiles across the frame's boundaries; log2(out/base) on each side
           as a function of distance from the edge; reports near-edge minus far-plateau
           deviation in EV and the band width (px) where |deviation| > 0.1 EV.
           Writes the profile as CSV next to the output when --csv-dir is given.
  veil     --frame ID --base B.png --out O.png [...]
           negative-dehaze veil per region (sky, far, near=bottom 15%): OKLab dL, da, db,
           veil hue, L-std ratio, far/near lift ratio.
  res      --low L.png --high H.png [--low0 L0.png --high0 H0.png]
           area-averages H (in linear light) down to L's size and reports mean/p95 dE2000;
           with the dehaze-0 pair, reports the excess over the baseline difference.
  all      --frame ID --dir DIR [--edge 2400] [--values 50,100,-100]
           runs regions/shadow/halo over DIR/<id>_L<edge>_d<v>.png with d0 as base.

Output is JSON on stdout (use --pretty for indentation).
"""
import argparse, json, math, os, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------- colour
def load(path):
    a = np.asarray(Image.open(path).convert('RGB'), dtype=np.float64) / 255.0
    return a

def srgb_to_linear(v):
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)

def linear_to_srgb(v):
    v = np.clip(v, 0, 1)
    return np.where(v <= 0.0031308, v * 12.92, 1.055 * v ** (1 / 2.4) - 0.055)

def luminance(lin):
    return lin @ np.array([0.2126, 0.7152, 0.0722])

def oklab(lin):
    M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                   [0.2119034982, 0.6806995451, 0.1073969566],
                   [0.0883024619, 0.2817188376, 0.6299787005]])
    M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                   [1.9779984951, -2.4285922050, 0.4505937099],
                   [0.0259040371, 0.7827717662, -0.8086757660]])
    lms = np.cbrt(lin @ M1.T)
    return lms @ M2.T

def cielab(lin):
    M = np.array([[0.4124564, 0.3575761, 0.1804375],
                  [0.2126729, 0.7151522, 0.0721750],
                  [0.0193339, 0.1191920, 0.9503041]])
    xyz = lin @ M.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    L = 116 * f[..., 1] - 16
    a = 500 * (f[..., 0] - f[..., 1])
    b = 200 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], -1)

def de2000(lab1, lab2):
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1 = np.hypot(a1, b1); C2 = np.hypot(a2, b2); Cb = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p = (1 + G) * a1; a2p = (1 + G) * a2
    C1p = np.hypot(a1p, b1); C2p = np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360; h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1; dCp = C2p - C1p
    dh = h2p - h1p
    dh = np.where(C1p * C2p == 0, 0, np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh)))
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh / 2))
    Lbp = (L1 + L2) / 2; Cbp = (C1p + C2p) / 2
    hs = h1p + h2p
    hbp = np.where(C1p * C2p == 0, hs,
                   np.where(np.abs(h1p - h2p) <= 180, hs / 2,
                            np.where(hs < 360, (hs + 360) / 2, (hs - 360) / 2)))
    T = (1 - 0.17 * np.cos(np.radians(hbp - 30)) + 0.24 * np.cos(np.radians(2 * hbp))
         + 0.32 * np.cos(np.radians(3 * hbp + 6)) - 0.20 * np.cos(np.radians(4 * hbp - 63)))
    dtheta = 30 * np.exp(-((hbp - 275) / 25) ** 2)
    Rc = 2 * np.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lbp - 50) ** 2 / np.sqrt(20 + (Lbp - 50) ** 2)
    Sc = 1 + 0.045 * Cbp; Sh = 1 + 0.015 * Cbp * T
    Rt = -np.sin(np.radians(2 * dtheta)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))

# ---------------------------------------------------------------- helpers
def box(img, frac):
    h, w = img.shape[:2]
    x0, y0, x1, y1 = frac
    return img[int(round(y0 * h)):max(int(round(y1 * h)), int(round(y0 * h)) + 1),
               int(round(x0 * w)):max(int(round(x1 * w)), int(round(x0 * w)) + 1)]

def lab_stats(lin):
    lab = oklab(lin.reshape(-1, 3))
    L, a, b = lab[:, 0].mean(), lab[:, 1].mean(), lab[:, 2].mean()
    return {"L": round(float(L), 4), "a": round(float(a), 4), "b": round(float(b), 4),
            "C": round(float(math.hypot(a, b)), 4),
            "C_pixmean": round(float(np.hypot(lab[:, 1], lab[:, 2]).mean()), 4),
            "h_deg": round(math.degrees(math.atan2(b, a)) % 360, 2)}

def hue_diff(h0, h1):
    d = (h1 - h0 + 180) % 360 - 180
    return round(d, 2)

def regions_json(frame):
    return json.load(open(os.path.join(HERE, 'regions.json')))[frame]

# ---------------------------------------------------------------- measurements
def m_regions(frame, base, outs):
    R = regions_json(frame)
    b = srgb_to_linear(load(base))
    res = {}
    for o in outs:
        oi = srgb_to_linear(load(o)); r = {}
        named = [(f"sky{i}", bx) for i, bx in enumerate(R.get('sky', []))] + list(R.get('neutral', {}).items())
        for name, bx in named:
            s0 = lab_stats(box(b, bx)); s1 = lab_stats(box(oi, bx))
            de = de2000(cielab(box(b, bx)), cielab(box(oi, bx))).mean()
            r[name] = {"base": s0, "out": s1, "dHue_deg": hue_diff(s0['h_deg'], s1['h_deg']),
                       "dC": round(s1['C'] - s0['C'], 4), "dL": round(s1['L'] - s0['L'], 4),
                       "da": round(s1['a'] - s0['a'], 4), "db": round(s1['b'] - s0['b'], 4),
                       "dE2000": round(float(de), 2)}
        if R.get('far'):
            y0 = np.log2(np.maximum(luminance(box(b, R['far'])), 1e-5))
            y1 = np.log2(np.maximum(luminance(box(oi, R['far'])), 1e-5))
            e0 = linear_to_srgb(luminance(box(b, R['far']))); e1 = linear_to_srgb(luminance(box(oi, R['far'])))
            r['far'] = {"std_log2Y_base": round(float(y0.std()), 4), "std_log2Y_out": round(float(y1.std()), 4),
                        "std_encY_base": round(float(e0.std()), 4), "std_encY_out": round(float(e1.std()), 4),
                        "encStdRatio": round(float(e1.std() / max(e0.std(), 1e-9)), 3),
                        "meanEncY_base": round(float(e0.mean()), 4), "meanEncY_out": round(float(e1.mean()), 4)}
        res[os.path.basename(o)] = r
    return res

def m_shadow(base, outs):
    b8 = np.asarray(Image.open(base).convert('RGB')); b = srgb_to_linear(b8 / 255.0)
    yb = luminance(b); eb = linear_to_srgb(yb)
    zones = np.minimum((eb * 10).astype(int), 9)
    res = {}
    for o in outs:
        o8 = np.asarray(Image.open(o).convert('RGB')); oi = srgb_to_linear(o8 / 255.0)
        yo = luminance(oi); eo = linear_to_srgb(yo)
        new0 = {c: round(float(((o8[..., i] == 0) & (b8[..., i] != 0)).mean() * 100), 3) for i, c in enumerate('rgb')}
        any0 = round(float((o8 == 0).any(-1).mean() * 100), 3)
        zd = [round(float(((eo - eb)[zones == z]).mean() * 255), 2) if (zones == z).any() else None for z in range(10)]
        de = de2000(cielab(b), cielab(oi))
        res[os.path.basename(o)] = {
            "newlyClippedTo0_pct": new0, "anyChannel0_pct_out": any0,
            "anyChannel0_pct_base": round(float((b8 == 0).any(-1).mean() * 100), 3),
            "p1_linY": [round(float(np.percentile(yb, 1)), 5), round(float(np.percentile(yo, 1)), 5)],
            "p5_linY": [round(float(np.percentile(yb, 5)), 5), round(float(np.percentile(yo, 5)), 5)],
            "zoneDeltaCodes": zd,
            "meanLinYDeltaEV": round(float(np.log2(yo.mean() / yb.mean())), 3),
            "dE2000_mean": round(float(de.mean()), 2), "dE2000_p95": round(float(np.percentile(de, 95)), 2),
            "rmsContrastEnc": [round(float(eb.std()), 4), round(float(eo.std()), 4)]}
    return res

def profile(img_lin, p, half=3):
    h, w = img_lin.shape[:2]
    Y = luminance(img_lin)
    if p['axis'] == 'v':
        x = int(p['at'] * w); a, z = int(p['from'] * h), int(p['to'] * h)
        return Y[a:z, max(x - half, 0):x + half + 1].mean(1), a
    y = int(p['at'] * h); a, z = int(p['from'] * w), int(p['to'] * w)
    return Y[max(y - half, 0):y + half + 1, a:z].mean(0), a

def m_halo(frame, base, outs, csv_dir=None):
    R = regions_json(frame)
    b = srgb_to_linear(load(base)); res = {}
    for o in outs:
        oi = srgb_to_linear(load(o)); r = {}
        for name, p in R.get('profiles', {}).items():
            pb, start = profile(b, p); po, _ = profile(oi, p)
            n = len(pb)
            # edge = steepest log step of the BASE profile near the stated position
            lg = np.log2(np.maximum(pb, 1e-5))
            guess = int((p['edge'] - p['from']) / (p['to'] - p['from']) * n)
            lo, hi = max(guess - n // 8, 1), min(guess + n // 8, n - 1)
            e = lo + int(np.argmax(np.abs(np.diff(lg[lo - 1:hi + 1]))[:hi - lo]))
            ratio = np.log2(np.maximum(po, 1e-6) / np.maximum(pb, 1e-6))
            sides = {"start": ratio[:e][::-1], "end": ratio[e + 1:]}
            lgs = {"start": lg[:e][::-1], "end": lg[e + 1:]}
            out = {"edge_px_from_start": int(e), "profile_len": n}
            for side, rr in sides.items():
                if len(rr) < 12:
                    continue
                # Mixed edge pixels (soft/defocused edge: part sky, part object) are not
                # a surface; the near window starts where the BASE profile, smoothed over
                # 5 px, has come within 0.5 EV of this side's own base plateau, capped
                # at 30 % of the side (amendment H-a). A halo is a change at pixels that
                # already belong to the surface, so it cannot hide in this skip.
                lb = lgs[side]
                lbs = np.convolve(lb, np.ones(5) / 5, mode='same')
                bfar = float(np.median(lb[int(len(lb) * 0.6):]))
                ok = np.nonzero(np.abs(lbs[2:] - bfar) <= 0.5)[0]
                sk = int(p['skip']) if 'skip' in p else min(2 + (int(ok[0]) if len(ok) else 0), max(int(len(lb) * 0.3), 2))
                far = float(np.median(rr[int(len(rr) * 0.6):]))
                dev = rr - far
                near = dev[sk:max(int(len(rr) * 0.4), sk + 2)]
                k = int(np.argmax(np.abs(near)))
                over = np.abs(dev) > 0.1
                width = int(np.argmax(~over[sk:])) if over[sk:].any() and not over[sk:].all() else (len(rr) if over[sk:].all() else 0)
                label = ("bright" if p['bright_side'] == side else "dark") + "_side"
                out[label] = {"skip_px": sk, "far_plateau_EV": round(far, 3), "max_near_dev_EV": round(float(near[k]), 3),
                              "at_px": k + sk, "band_width_px_gt0.1EV": width,
                              "dev_EV_at_px": {str(d): round(float(dev[d]), 3) for d in (2, 5, 10, 20, 40) if d < len(dev)}}
            r[name] = out
            if csv_dir:
                os.makedirs(csv_dir, exist_ok=True)
                fn = os.path.join(csv_dir, f"{frame}_{name}_{os.path.basename(o)}.csv")
                with open(fn, 'w') as f:
                    f.write("i,base_Y,out_Y,log2ratio\n")
                    for i in range(n):
                        f.write(f"{i},{pb[i]:.6f},{po[i]:.6f},{ratio[i]:.4f}\n")
        res[os.path.basename(o)] = r
    return res

def m_veil(frame, base, outs):
    """Negative-dehaze veil: per region (sky boxes, 'far', and the bottom 15% strip as
    'near'), the OKLab L lift, a/b drift, and the drop in local contrast. Atmospheric haze
    should lift far/sky MORE than near, and the veil colour should match the sky/airlight."""
    R = regions_json(frame)
    b = srgb_to_linear(load(base)); res = {}
    boxes = [(f"sky{i}", bx) for i, bx in enumerate(R.get('sky', []))]
    if R.get('far'): boxes.append(('far', R['far']))
    boxes.append(('near', R.get('near', [0.0, 0.85, 1.0, 1.0])))
    for o in outs:
        oi = srgb_to_linear(load(o)); r = {}
        for name, bx in boxes:
            l0 = oklab(box(b, bx).reshape(-1, 3)); l1 = oklab(box(oi, bx).reshape(-1, 3))
            d = (l1 - l0).mean(0)
            r[name] = {"dL": round(float(d[0]), 4), "da": round(float(d[1]), 4), "db": round(float(d[2]), 4),
                       "veil_hue_deg": round(math.degrees(math.atan2(d[2], d[1])) % 360, 1),
                       "Lstd_ratio": round(float(l1[:, 0].std() / max(l0[:, 0].std(), 1e-9)), 3),
                       "minL": [round(float(np.percentile(l0[:, 0], 1)), 3), round(float(np.percentile(l1[:, 0], 1)), 3)]}
        if 'far' in r:
            r['far_over_near_dL'] = round(r['far']['dL'] / r['near']['dL'], 2) if abs(r['near']['dL']) > 1e-6 else None
        res[os.path.basename(o)] = r
    return res

def area_down(lin, shape):
    h, w = shape[:2]; H, W = lin.shape[:2]
    fy, fx = H // h, W // w
    if fy * h != H or fx * w != W:
        # crop to an integer multiple; renders differ by a rounding pixel at most
        lin = lin[:fy * h, :fx * w]
    return lin.reshape(h, fy, w, fx, 3).mean((1, 3))

def m_res(low, high, low0=None, high0=None):
    def one(l, hh):
        L = srgb_to_linear(load(l)); H = srgb_to_linear(load(hh))
        f = round(H.shape[1] / L.shape[1])
        h = min(L.shape[0], H.shape[0] // f)
        L = L[:h]; H = H[:h * f, :L.shape[1] * f]
        D = area_down(H, L.shape)
        de = de2000(cielab(L), cielab(D))
        dl = linear_to_srgb(luminance(D)) - linear_to_srgb(luminance(L))
        return {"dE_mean": round(float(de.mean()), 3), "dE_p95": round(float(np.percentile(de, 95)), 3),
                "meanEncYDiff_codes": round(float(dl.mean() * 255), 2)}
    r = {"pair": one(low, high)}
    if low0 and high0:
        r["baseline_dehaze0"] = one(low0, high0)
        r["excess_dE_mean"] = round(r["pair"]["dE_mean"] - r["baseline_dehaze0"]["dE_mean"], 3)
        r["excess_dE_p95"] = round(r["pair"]["dE_p95"] - r["baseline_dehaze0"]["dE_p95"], 3)
    return r


# ---------------------------------------------------------------- spec extensions (SPEC.md)
def box_blur(a, r):
    """Mean over a (2r+1)^2 window, edge-replicated, via an integral image."""
    if r <= 0:
        return a.copy()
    p = np.pad(a, r, mode='edge')
    c = np.cumsum(np.cumsum(p, 0), 1)
    c = np.pad(c, ((1, 0), (1, 0)))
    k = 2 * r + 1
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)

def frac_slice(shape, frac):
    h, w = shape[:2]
    x0, y0, x1, y1 = frac
    ya, xa = int(round(y0 * h)), int(round(x0 * w))
    return slice(ya, max(int(round(y1 * h)), ya + 1)), slice(xa, max(int(round(x1 * w)), xa + 1))

def local_contrast(lin, frac, r=None):
    """Local RMS contrast: std of (encoded Y - its (2r+1)^2 box mean) inside the box,
    r = 0.4 % of the long edge (10 px at 2400). The blur runs on the whole frame, so the
    box border sees real neighbours. Detail amplitude, not the box's global gradient."""
    e = linear_to_srgb(luminance(lin))
    r = r or max(2, int(round(0.004 * max(e.shape))))
    hp = e - box_blur(e, r)
    sy, sx = frac_slice(e.shape, frac)
    return float(hp[sy, sx].std())

def band_std_L(lin, frac, r_lo=None, r_hi=None):
    """Mottling metric: std of the OKLab-L band-pass (box r_lo minus box r_hi) inside the
    box. r_lo = 0.1 % and r_hi = 1 % of the long edge (2 / 24 px at 2400): blotches, not
    pixel noise and not the wall's own shading."""
    L = oklab(lin.reshape(-1, 3))[:, 0].reshape(lin.shape[:2])
    m = max(L.shape)
    r_lo = r_lo or max(1, int(round(0.001 * m))); r_hi = r_hi or max(r_lo + 2, int(round(0.01 * m)))
    bp = box_blur(L, r_lo) - box_blur(L, r_hi)
    sy, sx = frac_slice(L.shape, frac)
    return float(bp[sy, sx].std())

def mottle_index(lin_base, lin_out, frac, r=2):
    """Mottling on a flat surface: OKLab L (box-blurred, r px, to drop pixel noise) of the
    output is fitted to the base by an affine map L_out ~ g*L_base + c over the box; the
    residual std divided by the base L std is the part of the change that is neither an
    exposure nor a contrast change, i.e. new blotches. 0 = no new structure."""
    def Lp(x):
        return dm_box(oklab(x.reshape(-1, 3))[:, 0].reshape(x.shape[:2]), r)
    sy, sx = frac_slice(lin_base.shape, frac)
    b = Lp(lin_base)[sy, sx].ravel(); o = Lp(lin_out)[sy, sx].ravel()
    A = np.stack([b, np.ones_like(b)], 1)
    c, *_ = np.linalg.lstsq(A, o, rcond=None)
    return float((o - A @ c).std() / max(b.std(), 1e-9)), float(c[0])

dm_box = lambda a, r: box_blur(a, r)

def sky_bands(frame, base, out, strip=0.02, min_px=None):
    """Per-band sky hue shift. Sky pixels = base pixels in the frame's 'skyband' box whose
    OKLab hue is within 25 deg of the sky0 box's mean hue, chroma >= 0.6x and L >= sky L -
    0.12. The box is cut into horizontal strips of `strip` x frame height; for each strip
    with enough sky pixels, the hue of the mean (a,b) is compared base vs out.
    Returns {'bands': [(y_frac, n, dh_deg, C_ratio)], 'max_abs_dh', 'spread_dh'}."""
    R = regions_json(frame)
    b = srgb_to_linear(load(base)); o = srgb_to_linear(load(out))
    lb = oklab(b.reshape(-1, 3)).reshape(b.shape); lo = oklab(o.reshape(-1, 3)).reshape(o.shape)
    sy, sx = frac_slice(b.shape, R['sky'][0])
    ref = lb[sy, sx].reshape(-1, 3).mean(0)
    href = math.degrees(math.atan2(ref[2], ref[1])); Cref = math.hypot(ref[1], ref[2])
    H = b.shape[0]
    hue = np.degrees(np.arctan2(lb[..., 2], lb[..., 1])); C = np.hypot(lb[..., 1], lb[..., 2])
    mask = (np.abs((hue - href + 180) % 360 - 180) < 25) & (C >= 0.6 * Cref) & (lb[..., 0] >= ref[0] - 0.12)
    by, bx = frac_slice(b.shape, R['skyband'])
    min_px = min_px or max(50, int(0.15 * (bx.stop - bx.start) * strip * H))
    bands = []
    y = by.start; step = max(1, int(round(strip * H)))
    while y < by.stop:
        m = mask[y:y + step, bx]
        n = int(m.sum())
        if n >= min_px:
            a0 = lb[y:y + step, bx][m].mean(0); a1 = lo[y:y + step, bx][m].mean(0)
            dh = hue_diff(math.degrees(math.atan2(a0[2], a0[1])) % 360, math.degrees(math.atan2(a1[2], a1[1])) % 360)
            bands.append((round(y / H, 3), n, dh, round(math.hypot(a1[1], a1[2]) / max(math.hypot(a0[1], a0[2]), 1e-9), 3)))
        y += step
    dhs = [x[2] for x in bands]
    return {'bands': bands, 'max_abs_dh': max((abs(d) for d in dhs), default=float('nan')),
            'spread_dh': (max(dhs) - min(dhs)) if dhs else float('nan')}

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest='cmd', required=True)
    for c in ('regions', 'shadow', 'halo', 'veil'):
        s = sp.add_parser(c); s.add_argument('--base', required=True); s.add_argument('--out', nargs='+', required=True)
        if c != 'shadow': s.add_argument('--frame', required=True)
        if c == 'halo': s.add_argument('--csv-dir')
    s = sp.add_parser('res'); [s.add_argument(a) for a in ('--low', '--high', '--low0', '--high0')]
    s = sp.add_parser('all'); s.add_argument('--frame', required=True); s.add_argument('--dir', required=True)
    s.add_argument('--edge', default='2400'); s.add_argument('--values', default='50,100,-100')
    s.add_argument('--csv-dir')
    ap.add_argument('--pretty', action='store_true')
    a = ap.parse_args()
    if a.cmd == 'regions': r = m_regions(a.frame, a.base, a.out)
    elif a.cmd == 'shadow': r = m_shadow(a.base, a.out)
    elif a.cmd == 'halo': r = m_halo(a.frame, a.base, a.out, a.csv_dir)
    elif a.cmd == 'veil': r = m_veil(a.frame, a.base, a.out)
    elif a.cmd == 'res': r = m_res(a.low, a.high, a.low0, a.high0)
    else:
        f = lambda v: os.path.join(a.dir, f"{a.frame}_L{a.edge}_d{v}.png")
        outs = [f(v) for v in a.values.split(',')]
        r = {"regions": m_regions(a.frame, f(0), outs), "shadow": m_shadow(f(0), outs),
             "halo": m_halo(a.frame, f(0), outs, a.csv_dir), "veil": m_veil(a.frame, f(0), outs)}
    json.dump(r, sys.stdout, indent=1 if a.pretty else None); print()

if __name__ == '__main__':
    main()
