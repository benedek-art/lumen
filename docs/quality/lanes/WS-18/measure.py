#!/usr/bin/env python3
"""WS-18 creative-sharpening measurement (lane T3). python3 + numpy + Pillow only.

USAGE
  python3 docs/quality/lanes/WS-18/measure.py --set develop.detail.sharpen.amount=100 \
      [--set develop.detail.sharpen.radius=2 ...] [--label a100] [--scratch DIR] \
      [--bin PATH] [--extra-args "--iso 3200"] [--check-identity] [--out result.json]

WHAT IT DOES
  1. Builds test frames in --scratch (default /tmp/claude-0/ws18) from corpus/synthetic:
       hard_edge_blur1.lfi   hard_edge, Gaussian blur sigma 1.0 px in linear light
       zone_plate_blur1.lfi  zone_plate, same blur
       edge2ev_blur1.lfi     hard_edge's 5-deg square at 0.09 on a 0.36 field, same blur
       flat_grey_noise.lfi   flat_grey (0.18) + N(0, 0.012) linear, seed 18, no blur
     and uses the pristine hard_edge.lfi as well. Inputs are cached (rebuilt if absent).
  2. Renders each with `lumen-render render --input X --long-edge <native> --no-dither`
     twice: with the --set values ("on") and with develop.detail.sharpen.amount=0 plus
     the same non-sharpen --set values ("off"). Off renders are cached by argument hash.
  3. Metrics, every one relative to the matching "off" render:
       mtf50_edge   slanted-edge MTF50 (cycles/px) on the left edge of the 5-deg square of
                    edge2ev_blur1 (the hard_edge square at 0.09 on 0.36, i.e. a 2 EV step
                    whose plateaus the display transform does not clip; same blur), and
                    mtf50_hardedge on hard_edge_blur1 itself. Rows 350..550 (away from
                    the corners) of the edge at x ~ 980: per-row edge
                    centroid -> line fit -> 4x super-sampled ESF -> LSF (diff) -> Hann ->
                    |FFT|, normalised at DC. Display-LINEAR (sRGB-decoded PNG) values.
       mtf50_zone   zone-plate MTF50 on zone_plate_blur1: modulation (max-min)/(max+min) of
                    display-linear output in annuli, f = 0.5 r/R; MTF50 = first f
                    where modulation < 50% of its mean over f in [0.02, 0.04]; window
                    1.2 local periods wide so it holds a full cycle.
                    (Analytic optical value for the sigma-1 blur alone: 0.187.)
       gain_*       on/off ratios; zone_mod_gain_at_f = modulation ratio at f = .05...35.
       halo_edge2ev square edges of edge2ev_blur1 (the informative halo number).
       halo_*       ENCODED (sRGB 0..1) overshoot in % of step height, bright side
                    (peak above bright plateau) and dark side (trough below dark plateau),
                    from the radial profile of the disk and the signed-distance profile of
                    the square's four edges (corners excluded), 0.25-px bins; both on the
                    pristine and the blurred hard_edge. Plateaus: median at 30..60 px.
       lines_*      grey-band 1/2/4 px bright and dark lines (pristine + blurred): ringing
                    = flank excursion on the opposite side of the grey, in % of the off
                    render's line contrast; peak_gain = line contrast on/off.
       noise_gain   std(on)/std(off) of encoded luminance, central 80% of flat_grey_noise;
                    noise_mean_shift_codes = mean(on) - mean(off) there, in 8-bit codes.
  Do not pass --iso in --extra-args for creative-sharpening numbers: --iso switches on
  S3 denoise and (since the S4 landing) capture sharpening, which confound them.
  --check-identity also renders each frame with NO --set and with amount=0 and reports
  whether the PNG pixels are identical (they must be: default recipe = sharpen off).
  Prints one JSON object (also written to --out if given).
NOTE  sharpen sigma is frame-denominated: sigma = radius * longEdge / 2560. hard_edge
  renders at 1600 (sigma 0.625 r), zone_plate at 2048 (0.8 r). The JSON reports both.
"""
import argparse, hashlib, json, os, shlex, struct, subprocess, sys
import numpy as np
from PIL import Image

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
DEF_BIN = os.path.join(REPO, ".build/x86_64-unknown-linux-gnu/release/lumen-render")
SYN = os.path.join(REPO, "corpus/synthetic")


def read_lfi(p):
    with open(p, "rb") as f:
        mg, w, h, c = struct.unpack("<4sIII", f.read(16))
        assert mg == b"LFI1" and c == 3, p
        return np.frombuffer(f.read(), "<f4").reshape(h, w, 3).copy()


def write_lfi(p, img):
    img = np.ascontiguousarray(img, "<f4")
    h, w, _ = img.shape
    with open(p + ".tmp", "wb") as f:
        f.write(struct.pack("<4sIII", b"LFI1", w, h, 3)); f.write(img.tobytes())
    os.replace(p + ".tmp", p)


def gblur(img, s):
    r = int(np.ceil(4 * s)); x = np.arange(-r, r + 1); k = np.exp(-x * x / (2 * s * s)); k /= k.sum()
    def conv(a, ax):
        pad = [(0, 0)] * a.ndim; pad[ax] = (r, r)
        a = np.pad(a, pad, mode="reflect"); out = np.zeros_like(a)
        for i, kv in enumerate(k):
            out += kv * np.roll(a, r - i, axis=ax)
        sl = [slice(None)] * a.ndim; sl[ax] = slice(r, -r)
        return out[tuple(sl)]
    return conv(conv(img.astype(np.float64), 0), 1).astype(np.float32)


def make_inputs(d):
    os.makedirs(d, exist_ok=True)
    out = {"hard_edge": os.path.join(SYN, "hard_edge.lfi")}
    for name in ("hard_edge", "zone_plate"):
        p = os.path.join(d, name + "_blur1.lfi")
        if not os.path.exists(p):
            write_lfi(p, gblur(read_lfi(os.path.join(SYN, name + ".lfi")), 1.0))
        out[name + "_blur1"] = p
    p = os.path.join(d, "edge2ev_blur1.lfi")
    if not os.path.exists(p):                    # hard_edge's 5-deg square, 0.09 on 0.36
        ss = 4; yy, xx = (np.mgrid[0:1200 * ss, 0:1600 * ss] + 0.5) / ss; t = np.radians(5)
        u = (xx - 1200) * np.cos(t) + (yy - 450) * np.sin(t)
        v = -(xx - 1200) * np.sin(t) + (yy - 450) * np.cos(t)
        img = np.where((np.abs(u) < 220) & (np.abs(v) < 220), 0.09, 0.36).astype(np.float32)
        img = img.reshape(1200, ss, 1600, ss).mean((1, 3)); del yy, xx, u, v
        write_lfi(p, gblur(np.repeat(img[..., None], 3, -1), 1.0))
    out["edge2ev_blur1"] = p
    p = os.path.join(d, "flat_grey_noise.lfi")
    if not os.path.exists(p):
        g = read_lfi(os.path.join(SYN, "flat_grey.lfi"))
        n = np.random.default_rng(18).normal(0, 0.012, g.shape[:2]).astype(np.float32)
        write_lfi(p, g + n[..., None])            # neutral (luminance) noise
    out["flat_grey_noise"] = p
    return out


def render(binp, inp, sets, extra, d):
    with open(inp, "rb") as f:
        _, w, h, _ = struct.unpack("<4sIII", f.read(16))
    args = ["render", "--input", inp, "--long-edge", str(max(w, h)), "--no-dither"]
    for s in sets:
        args += ["--set", s]
    args += extra
    key = hashlib.sha1(("\0".join(args) + str(os.path.getmtime(binp))).encode()).hexdigest()[:16]
    out = os.path.join(d, "r_%s_%s.png" % (os.path.basename(inp)[:-4], key))
    if not os.path.exists(out):
        r = subprocess.run([binp] + args + ["--out", out], capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("lumen-render failed: %s\n%s" % (" ".join(args), r.stderr))
    return out


def load(png):
    e = np.asarray(Image.open(png).convert("RGB"), np.float64) / 255.0
    lin = np.where(e <= 0.04045, e / 12.92, ((e + 0.055) / 1.055) ** 2.4)
    w = np.array([0.2126, 0.7152, 0.0722])
    return e @ w, lin @ w        # encoded luminance-ish (neutral frames), linear luminance


def mtf_curve(lsf, ss):
    n = len(lsf); lsf = lsf * np.hanning(n)
    m = np.abs(np.fft.rfft(lsf)); m /= m[0]
    return np.fft.rfftfreq(n, 1.0 / ss), m


def mtf50(f, m):
    i = np.where(m < 0.5)[0]
    if len(i) == 0 or i[0] == 0:
        return None
    i = i[0]
    return float(f[i - 1] + (0.5 - m[i - 1]) * (f[i] - f[i - 1]) / (m[i] - m[i - 1]))


def edge_mtf(lin):
    y0, y1, x0, x1 = 350, 550, 940, 1020        # left edge of the square, x ~ 980
    roi = lin[y0:y1, x0:x1]
    g = np.abs(np.diff(roi, axis=1)); xs = np.arange(roi.shape[1] - 1) + 0.5
    cen = (g * xs).sum(1) / np.maximum(g.sum(1), 1e-12)
    ys = np.arange(roi.shape[0]); a, b = np.polyfit(ys, cen, 1)
    ss = 4; X, Y = np.meshgrid(np.arange(roi.shape[1]), ys)
    dist = (X - (a * Y + b)) / np.sqrt(1 + a * a)
    bins = np.round(dist * ss).astype(int); sel = np.abs(bins) <= 30 * ss
    bb = bins[sel] + 30 * ss
    cnt = np.bincount(bb, minlength=60 * ss + 1); sm = np.bincount(bb, roi[sel], minlength=60 * ss + 1)
    esf = np.interp(np.arange(len(cnt)), np.nonzero(cnt)[0], sm[cnt > 0] / cnt[cnt > 0])
    f, m = mtf_curve(np.diff(esf), ss)
    return mtf50(f, m), f, m


def zone_mod(lin):
    """Modulation in annular windows 1.2 local periods wide (so each holds a full cycle)."""
    n = lin.shape[0]; R = n / 2
    yy, xx = np.mgrid[0:n, 0:n] + 0.5 - R
    r = np.hypot(xx, yy).ravel(); o = np.argsort(r); r = r[o]; v = lin.ravel()[o]
    fs = np.arange(0.02, 0.48, 0.005); mod = []
    for fc in fs:
        rc = 2 * R * fc; hw = max(1.0, 0.6 / fc)
        i0, i1 = np.searchsorted(r, [rc - hw, rc + hw])
        mx, mn = v[i0:i1].max(), v[i0:i1].min(); mod.append((mx - mn) / max(mx + mn, 1e-12))
    return fs, np.array(mod)


def zone_mtf50(f, mod):
    lo = mod[(f >= 0.02) & (f <= 0.04)].mean(); rel = mod / lo
    i = np.where((rel < 0.5) & (f > 0.04))[0]
    if len(i) == 0:
        return None, rel
    i = i[0]
    return float(f[i - 1] + (0.5 - rel[i - 1]) * (f[i] - f[i - 1]) / (rel[i] - rel[i - 1])), rel


def profile(enc, dist, mask, lo=-60, hi=60, ss=4):
    b = np.round(dist[mask] * ss).astype(int); s = (b >= lo * ss) & (b <= hi * ss)
    b = b[s] - lo * ss; v = enc[mask][s]; n = (hi - lo) * ss + 1
    c = np.bincount(b, minlength=n); t = np.bincount(b, v, minlength=n)
    x = np.arange(n) / ss + lo
    return x[c > 0], t[c > 0] / c[c > 0]


def overshoot(x, p, bright_neg):
    """bright side at x<0 when bright_neg else at x>0. Returns (bright%, dark%)."""
    xb, xd = (x < 0, x > 0) if bright_neg else (x > 0, x < 0)
    far = (np.abs(x) >= 30) & (np.abs(x) <= 60); near = np.abs(x) < 30
    pb = np.median(p[xb & far]); pd = np.median(p[xd & far]); step = pb - pd
    ob = max(0.0, p[xb & near].max() - pb); od = max(0.0, pd - p[xd & near].min())
    return 100 * ob / step, 100 * od / step


def halos(enc, square_only=False):
    h, w = enc.shape; yy, xx = np.mgrid[0:h, 0:w] + 0.5
    disk = (np.nan, np.nan) if square_only else \
        overshoot(*profile(enc, np.hypot(xx - 400, yy - 450) - 220, xx < 790), True)
    t = np.radians(5)
    u = (xx - 1200) * np.cos(t) + (yy - 450) * np.sin(t)
    v = -(xx - 1200) * np.sin(t) + (yy - 450) * np.cos(t)
    d = np.maximum(np.abs(u), np.abs(v)) - 220
    m = (np.minimum(np.abs(u), np.abs(v)) < 150) & (xx > 810) & (yy < 930)
    sq = overshoot(*profile(enc, d, m), False)      # bright outside (x>0)
    return {"disk_bright_pct": disk[0], "disk_dark_pct": disk[1],
            "square_bright_pct": sq[0], "square_dark_pct": sq[1]}


def lines(enc_on, enc_off):
    pon = enc_on[1000:1150].mean(0); poff = enc_off[1000:1150].mean(0); out = {}
    for x, wd, kind in ((100, 1, "b"), (220, 2, "b"), (340, 4, "b"),
                        (460, 1, "d"), (580, 2, "d"), (700, 4, "d")):
        plate = np.median(np.r_[pon[x - 40:x - 15], pon[x + wd + 15:x + wd + 40]])
        plo = np.median(np.r_[poff[x - 40:x - 15], poff[x + wd + 15:x + wd + 40]])
        core = slice(x - 1, x + wd + 1); fl = np.r_[pon[x - 10:x], pon[x + wd:x + wd + 10]]
        sgn = 1 if kind == "b" else -1
        c_on = sgn * (pon[core] - plate).max() if kind == "b" else -(pon[core] - plate).min()
        c_off = (poff[core] - plo).max() if kind == "b" else -(poff[core] - plo).min()
        ring = max(0.0, -sgn * (fl - plate).min() if kind == "b" else (fl - plate).max())
        out["%s%dpx" % ("bright" if kind == "b" else "dark", wd)] = {
            "ringing_pct": round(100 * ring / c_off, 2), "peak_gain": round(c_on / c_off, 3)}
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--label", default=None)
    ap.add_argument("--scratch", default="/tmp/claude-0/ws18")
    ap.add_argument("--bin", default=os.environ.get("LUMEN_RENDER", DEF_BIN))
    ap.add_argument("--extra-args", default="")
    ap.add_argument("--check-identity", action="store_true")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    extra = shlex.split(a.extra_args)
    inp = make_inputs(a.scratch)
    rd = os.path.join(a.scratch, "renders"); os.makedirs(rd, exist_ok=True)
    others = [s for s in a.set if not s.startswith("develop.detail.sharpen.amount=")]
    off_sets = others + ["develop.detail.sharpen.amount=0"]
    R = lambda k, s: load(render(a.bin, inp[k], s, extra, rd))
    res = {"label": a.label or (" ".join(a.set) or "default"), "set": a.set, "extra_args": extra}

    for tag, frame in (("edge", "edge2ev_blur1"), ("hardedge", "hard_edge_blur1")):
        e1, l1 = R(frame, a.set); e0, l0 = R(frame, off_sets)
        m_on, f, c_on = edge_mtf(l1); m_off, _, c_off = edge_mtf(l0)
        res["mtf50_%s_on" % tag], res["mtf50_%s_off" % tag] = m_on, m_off
        res["mtf50_%s_gain" % tag] = m_on / m_off if m_on and m_off else None
        res["%s_mtf_gain_at_f" % tag] = {str(q): round(float(np.interp(q, f, c_on) / np.interp(q, f, c_off)), 3)
                                         for q in (0.1, 0.2, 0.3, 0.4)}
        res["%s_mtf_peak_on" % tag] = round(float(c_on[f <= 0.5].max()), 3)
        if tag == "edge":
            h1, h0 = halos(e1, square_only=True), halos(e0, square_only=True)
            res["halo_edge2ev"] = {q: round(h1[q], 2) for q in h1}
            res["halo_edge2ev_off"] = {q: round(h0[q], 2) for q in h0}
        else:
            eon, eoff = e1, e0

    _, zon = R("zone_plate_blur1", a.set); _, zoff = R("zone_plate_blur1", off_sets)
    fz, mon = zone_mod(zon); _, moff = zone_mod(zoff)
    z_on, rel_on = zone_mtf50(fz, mon); z_off, rel_off = zone_mtf50(fz, moff)
    res["mtf50_zone_on"], res["mtf50_zone_off"] = z_on, z_off
    res["mtf50_zone_gain"] = z_on / z_off if z_on and z_off else None
    res["zone_mod_gain_at_f"] = {str(q): round(float(np.interp(q, fz, mon) / np.interp(q, fz, moff)), 3)
                                 for q in (0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35)}
    res["zone_rel_mod_peak_on"] = round(float(rel_on[fz < 0.45].max()), 3)

    for k, (e1, e0) in {"blur1": (eon, eoff), "pristine": (R("hard_edge", a.set)[0], R("hard_edge", off_sets)[0])}.items():
        h_on, h_off = halos(e1), halos(e0)
        res["halo_" + k] = {q: round(h_on[q], 2) for q in h_on}
        res["halo_" + k + "_off"] = {q: round(h_off[q], 2) for q in h_off}
        res["lines_" + k] = lines(e1, e0)

    non, _ = R("flat_grey_noise", a.set); noff, _ = R("flat_grey_noise", off_sets)
    h, w = non.shape; c = (slice(h // 10, h - h // 10), slice(w // 10, w - w // 10))
    res["noise_std_off"], res["noise_std_on"] = float(noff[c].std()), float(non[c].std())
    res["noise_gain"] = res["noise_std_on"] / res["noise_std_off"]
    res["noise_mean_shift_codes"] = 255 * float(non[c].mean() - noff[c].mean())
    rad = next((float(s.split("=")[1]) for s in a.set if s.startswith("develop.detail.sharpen.radius=")), 1.0)
    res["sigma_px"] = {"hard_edge@1600": rad * 1600 / 2560, "zone_plate@2048": rad * 2048 / 2560,
                       "flat_grey@1024": rad * 1024 / 2560}

    if a.check_identity:
        ident = {}
        for k in inp:
            p0 = render(a.bin, inp[k], [], extra, rd)
            p1 = render(a.bin, inp[k], ["develop.detail.sharpen.amount=0"], extra, rd)
            ident[k] = bool(np.array_equal(np.asarray(Image.open(p0)), np.asarray(Image.open(p1))))
        res["identity_amount0_vs_default"] = ident
    js = json.dumps(res, indent=1, default=lambda o: round(float(o), 4))
    print(js)
    if a.out:
        open(a.out, "w").write(js)


if __name__ == "__main__":
    main()
