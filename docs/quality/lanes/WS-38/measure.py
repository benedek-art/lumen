#!/usr/bin/env python3
"""WS-38 film stocks: one reproducible measurement for every line of SPEC.md.

    python3 docs/quality/lanes/WS-38/measure.py                  # all lines
    python3 docs/quality/lanes/WS-38/measure.py --only S7,S12    # some lines
    python3 docs/quality/lanes/WS-38/measure.py --out /tmp/ws38  # + contact sheets there

Renders through the real `lumen-render` binary (CPU ReferenceRenderer, the finish LUT
the GPU uses), always with grain 0, halation 0 and --no-dither, so every number is
deterministic. Synthetic frames come from corpus/synthetic (with their sidecar
rectangles); three extra frames this script authors itself (an extended -12..+8 EV
ramp, a stress card and a bright colour card) are written into the work dir.
Real photos are rendered at --long-edge 768.

Every metric is computed here from the 8-bit PNGs (sRGB decode -> linear -> Rec.709 Y,
OKLab, CIELAB D65 / CIEDE2000), not from the CLI's metrics JSON, so the definitions
are in one file. Results: a PASS/FAIL table on stdout and JSON (--json).

Build first:  export PATH=/opt/swift/usr/bin:$PATH; swift build -c release --product lumen-render
"""
import argparse, hashlib, json, math, os, struct, subprocess, sys, tempfile
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PIL import Image, ImageDraw

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", ".."))
SYN = os.path.join(REPO, "corpus", "synthetic")
LFI = os.path.join(REPO, "corpus", "lfi")

STOCKS = ["portra400", "gold200", "ektar100", "trix400", "velvia50", "cine250d"]
COLOUR = ["portra400", "gold200", "ektar100", "velvia50", "cine250d"]
NEGATIVES = ["portra400", "gold200", "ektar100", "trix400", "cine250d"]
COLOUR_NEG = ["portra400", "gold200", "ektar100", "cine250d"]
SHORT = {"portra400": "Portra", "gold200": "Gold", "ektar100": "Ektar", "trix400": "Tri-X",
         "velvia50": "Velvia", "cine250d": "Cine", "neutral": "neutral"}
PHOTOS = {"6929": "6929_sony-ilce-7m4", "2545": "2545_panasonic-dmc-gx85",
          "4694": "4694_canon-eos-r5", "7881": "7881_canon-eos-r5-mark-ii",
          "983": "983_canon-eos-5d-mark-iv", "1840": "1840_nikon-d850"}
PHOTO_EDGE = 768
EXPOSURES = [-2, -1.5, -1, -0.5, 0, 0.5, 1, 1.5, 2, 2.5, 3]
PUSHES = [-1, -0.5, 0, 0.5, 1, 1.5, 2]
AMOUNTS = [0, 10, 25, 50, 75, 100]

# Regions on the 768-px renders, as fractions (x0, y0, x1, y1).
R_983_SKY = (0.02, 0.02, 0.30, 0.16)
R_4694_LEMON = (0.50, 0.30, 0.58, 0.48)
R_4694_DISH = (0.90, 0.36, 0.97, 0.52)   # lit right side of the green dish
R_4694_TOMATO = (0.66, 0.69, 0.71, 0.75)

# Extended ramp authored here: EV(x) = -12 + (x + 0.5)/100, value 0.18 * 2^EV.
XR_EV0, XR_PX, XR_W, XR_H = -12.0, 100, 2000, 48

# --------------------------------------------------------------------------- colour


def dec(code):
    c = np.asarray(code, float) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def enc(lin):
    v = np.clip(np.asarray(lin, float), 0, 1)
    return 255.0 * np.where(v <= 0.0031308, 12.92 * v, 1.055 * np.power(v, 1 / 2.4) - 0.055)


def lum_lin(rgb_code):
    l = dec(rgb_code)
    return l[..., 0] * 0.2126 + l[..., 1] * 0.7152 + l[..., 2] * 0.0722


def lum_code(rgb_code):
    return enc(lum_lin(rgb_code))


_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]])
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])


def oklab(rgb_code):
    l = dec(rgb_code)
    return np.cbrt(l @ _M1.T) @ _M2.T


def lch(rgb_code):
    lab = oklab(rgb_code)
    return lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360


_XYZ = np.array([[0.4124564, 0.3575761, 0.1804375],
                 [0.2126729, 0.7151522, 0.0721750],
                 [0.0193339, 0.1191920, 0.9503041]])
_WN = np.array([0.95047, 1.0, 1.08883])


def cielab(rgb_code):
    xyz = (dec(rgb_code) @ _XYZ.T) / _WN
    f = np.where(xyz > (6 / 29) ** 3, np.cbrt(xyz), xyz / (3 * (6 / 29) ** 2) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def de2000(lab1, lab2):
    L1, a1, b1 = lab1[..., 0], lab1[..., 1], lab1[..., 2]
    L2, a2, b2 = lab2[..., 0], lab2[..., 1], lab2[..., 2]
    C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cb ** 7 / (Cb ** 7 + 25.0 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp, dCp = L2 - L1, C2p - C1p
    dh = h2p - h1p
    dh = np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh))
    dh = np.where(C1p * C2p == 0, 0, dh)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh) / 2)
    Lbp, Cbp = (L1 + L2) / 2, (C1p + C2p) / 2
    hs = h1p + h2p
    hbp = np.where(np.abs(h1p - h2p) > 180, np.where(hs < 360, (hs + 360) / 2, (hs - 360) / 2), hs / 2)
    hbp = np.where(C1p * C2p == 0, hs, hbp)
    T = (1 - 0.17 * np.cos(np.radians(hbp - 30)) + 0.24 * np.cos(np.radians(2 * hbp))
         + 0.32 * np.cos(np.radians(3 * hbp + 6)) - 0.20 * np.cos(np.radians(4 * hbp - 63)))
    dth = 30 * np.exp(-(((hbp - 275) / 25) ** 2))
    RC = 2 * np.sqrt(Cbp ** 7 / (Cbp ** 7 + 25.0 ** 7))
    SL = 1 + 0.015 * (Lbp - 50) ** 2 / np.sqrt(20 + (Lbp - 50) ** 2)
    SC, SH = 1 + 0.045 * Cbp, 1 + 0.015 * Cbp * T
    RT = -np.sin(np.radians(2 * dth)) * RC
    return np.sqrt((dLp / SL) ** 2 + (dCp / SC) ** 2 + (dHp / SH) ** 2 + RT * (dCp / SC) * (dHp / SH))


def dhue(h2, h1):
    return (np.asarray(h2) - np.asarray(h1) + 180) % 360 - 180

# --------------------------------------------------------------------------- inputs


def write_lfi(path, arr):
    arr = np.ascontiguousarray(arr, dtype="<f4")
    h, w, _ = arr.shape
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(b"LFI1" + struct.pack("<III", w, h, 3) + arr.tobytes())
    os.replace(tmp, path)


def author_inputs(work):
    os.makedirs(work, exist_ok=True)
    # extended ramp
    ev = XR_EV0 + (np.arange(XR_W) + 0.5) / XR_PX
    row = 0.18 * 2.0 ** ev
    a = np.repeat(np.repeat(row[None, :, None], 3, 2), XR_H, 0)
    write_lfi(os.path.join(work, "xramp.lfi"), a)
    # stress card: 16 patches of 64 px
    vals = [(0, 0, 0), (1e-6,) * 3, (-0.01,) * 3, (100,) * 3, (1e4,) * 3, (1e6,) * 3,
            (1, 0, 0), (30, 0, 0), (1000, 0, 0), (0, 30, 0), (0, 0, 30), (0, 30, 30),
            (30, 0, 30), (-0.05, 0.3, 0.3), (0.3, -0.05, 0.3), (5, 4, -1)]
    a = np.zeros((64, 64 * len(vals), 3), np.float32)
    for i, v in enumerate(vals):
        a[:, i * 64:(i + 1) * 64] = v
    write_lfi(os.path.join(work, "stress.lfi"), a)
    # bright colour card: CC chromatic patches 1..18 at +2.5 EV, 6x3 tiles of 96 px
    P = json.load(open(os.path.join(SYN, "colorchecker.json")))["truth"]["patches"][:18]
    a = np.full((3 * 96, 6 * 96, 3), 0.18, np.float32)
    for i, p in enumerate(P):
        r, c = divmod(i, 6)
        a[r * 96:(r + 1) * 96, c * 96:(c + 1) * 96] = np.array(p["rec2020_linear"]) * 2 ** 2.5
    write_lfi(os.path.join(work, "ccbright.lfi"), a)
    return vals


INPUTS = {}


def input_path(name, work):
    if name in ("xramp", "stress", "ccbright"):
        return os.path.join(work, name + ".lfi"), None
    if name in ("grey_ramp", "colorchecker", "skin_tones", "hue_wheel"):
        return os.path.join(SYN, name + ".lfi"), None
    return os.path.join(LFI, PHOTOS[name] + ".lfi"), PHOTO_EDGE


NATIVE = {"xramp": XR_W, "stress": 1024, "ccbright": 576, "grey_ramp": 2800,
          "colorchecker": 1368, "skin_tones": 1530, "hue_wheel": 1200}

# --------------------------------------------------------------------------- render


class R:
    """Render cache: key = binary identity + input + settings."""

    def __init__(self, binary, work, jobs):
        self.bin, self.work, self.jobs = binary, work, jobs
        st = os.stat(binary)
        self.binid = f"{st.st_size}-{int(st.st_mtime)}"
        self.pending = {}
        os.makedirs(os.path.join(work, "png"), exist_ok=True)

    @staticmethod
    def sets(stock=None, amount=100, exposure=None, push=None):
        if stock in (None, "neutral"):
            return ()
        s = [("look.filmLab.stock", "lumen/" + stock), ("look.filmLab.amount", amount),
             ("look.filmLab.grain.amount", 0), ("look.filmLab.halation", 0)]
        if exposure is not None:
            s.append(("look.filmLab.exposure", exposure))
        if push is not None:
            s.append(("look.filmLab.pushPull", push))
        return tuple(s)

    def path(self, img, stock=None, amount=100, exposure=None, push=None, lut=33):
        sets = self.sets(stock, amount, exposure, push)
        key = json.dumps([self.binid, img, sets, lut])
        h = hashlib.sha1(key.encode()).hexdigest()[:16]
        p = os.path.join(self.work, "png", f"{img}_{stock or 'neutral'}_{h}.png")
        if not os.path.exists(p):
            self.pending[p] = (img, sets, lut)
        return p

    def need(self, *a, **k):
        self.path(*a, **k)

    def flush(self):
        jobs = list(self.pending.items())
        self.pending = {}
        if not jobs:
            return

        def run(item):
            p, (img, sets, lut) = item
            inp, edge = input_path(img, self.work)
            edge = edge or NATIVE[img]
            cmd = [self.bin, "render", "--input", inp, "--long-edge", str(edge), "--no-dither",
                   "--lut-size", str(lut), "--out", p + ".tmp.png"]
            for k, v in sets:
                cmd += ["--set", f"{k}={v}"]
            r = subprocess.run(cmd, capture_output=True, text=True)
            if r.returncode != 0:
                raise RuntimeError(f"render failed: {' '.join(cmd)}\n{r.stderr}")
            os.replace(p + ".tmp.png", p)

        print(f"rendering {len(jobs)} frames ...", file=sys.stderr)
        with ThreadPoolExecutor(self.jobs) as ex:
            list(ex.map(run, jobs))

    def img(self, *a, **k):
        p = self.path(*a, **k)
        if p in self.pending:
            self.flush()
        return np.asarray(Image.open(p).convert("RGB")).astype(np.float64)

# --------------------------------------------------------------------------- helpers


def patch_means(im, rects, inset=0.2):
    out = []
    for x, y, w, h in rects:
        dx, dy = int(w * inset), int(h * inset)
        out.append(im[y + dy:y + h - dy, x + dx:x + w - dx].reshape(-1, 3).mean(0))
    return np.array(out)


def region(im, fr):
    H, W, _ = im.shape
    x0, y0, x1, y1 = fr
    return im[int(y0 * H):int(y1 * H), int(x0 * W):int(x1 * W)]


def cc_patches():
    return json.load(open(os.path.join(SYN, "colorchecker.json")))["truth"]["patches"]


def skin_patches():
    return json.load(open(os.path.join(SYN, "skin_tones.json")))["truth"]["patches"]


class Ramp:
    """Row-averaged ramp with EV per column."""

    def __init__(self, im, ev0, px, rows):
        self.rgb = im[rows[0]:rows[1]].mean(0)  # codes, float
        self.ev = ev0 + (np.arange(self.rgb.shape[0]) + 0.5) / px
        self.ylin = lum_lin(self.rgb)
        self.y = enc(self.ylin)

    def idx(self, e):
        return int(np.clip(np.argmin(np.abs(self.ev - e)), 0, len(self.ev) - 1))

    def at(self, e, w=0.05):
        m = np.abs(self.ev - e) <= w
        return self.rgb[m].mean(0)

    def yat(self, e, w=0.05):
        m = np.abs(self.ev - e) <= w
        return float(enc(self.ylin[m].mean()))

    def ylin_at(self, e, w=0.05):
        m = np.abs(self.ev - e) <= w
        return float(self.ylin[m].mean())

    def slope(self, a, b):
        """log2(display-linear Y) per EV, least squares over [a, b]."""
        m = (self.ev >= a) & (self.ev <= b) & (self.ylin > 0)
        return float(np.polyfit(self.ev[m], np.log2(self.ylin[m]), 1)[0])

    def code_slope(self, a, b):
        return (self.yat(b, 0.1) - self.yat(a, 0.1)) / (b - a)

    def first_ev(self, code, chan=None):
        v = self.y if chan is None else self.rgb.max(1) if chan == "max" else self.rgb[:, chan]
        i = np.where(v >= code)[0]
        return float(self.ev[i[0]]) if len(i) else None


def xramp(r, stock=None, exposure=None, push=None):
    return Ramp(r.img("xramp", stock, exposure=exposure, push=push), XR_EV0, XR_PX, (8, 40))


def gramp(r, stock=None):
    return Ramp(r.img("grey_ramp", stock), -10.0, 200, (20, 180))


def fmt(v, nd=2):
    if v is None:
        return "None"
    if isinstance(v, (bool, np.bool_)):
        return str(bool(v))
    if isinstance(v, (float, np.floating)):
        return f"{v:.{nd}f}"
    return str(v)

# --------------------------------------------------------------------------- spec lines
# Each line: (id, title, needs(r), measure(r) -> (pass, summary, detail))

LINES = []


def line(sid, title):
    def deco(fn):
        LINES.append((sid, title, fn))
        return fn
    return deco


def all_ok(d):
    return all(d.values())


# ---- S1..S3 tone identity ----------------------------------------------------------

GAMMA_BAND = {"portra400": (1.10, 1.32), "gold200": (1.36, 1.52), "ektar100": (1.50, 1.70),
              "trix400": (1.40, 1.62), "velvia50": (1.75, 2.20), "cine250d": (1.25, 1.48)}


@line("S1", "mid-grey anchor: EV 0 renders within 1 code of neutral in R, G and B (every stock)")
def s1(r):
    n = xramp(r).at(0.0)
    det, ok = {}, {}
    for s in STOCKS:
        d = xramp(r, s).at(0.0) - n
        det[s] = float(np.abs(d).max())
        ok[s] = det[s] <= 1.0
    return all_ok(ok), "max|d| " + " ".join(f"{SHORT[s]}={det[s]:.2f}" for s in STOCKS), det


@line("S2", "display contrast at grey (log2 Y per EV, fit -0.5..+0.5 EV on grey_ramp) inside the stock's band")
def s2(r):
    det, ok = {"neutral": gramp(r).slope(-0.5, 0.5)}, {}
    for s in STOCKS:
        det[s] = gramp(r, s).slope(-0.5, 0.5)
        lo, hi = GAMMA_BAND[s]
        ok[s] = lo <= det[s] <= hi
    return all_ok(ok), " ".join(f"{SHORT[k]}={v:.2f}" for k, v in det.items()), det


@line("S3", "contrast order: Velvia >= Ektar+0.15, Ektar >= Gold+0.08, Gold >= Portra+0.08, Tri-X >= Portra+0.08, Cine <= Gold")
def s3(r):
    g = {s: gramp(r, s).slope(-0.5, 0.5) for s in STOCKS}
    ok = {"V>E": g["velvia50"] >= g["ektar100"] + 0.15, "E>G": g["ektar100"] >= g["gold200"] + 0.08,
          "G>P": g["gold200"] >= g["portra400"] + 0.08, "T>P": g["trix400"] >= g["portra400"] + 0.08,
          "C<=G": g["cine250d"] <= g["gold200"]}
    return all_ok(ok), " ".join(f"{k}:{'ok' if v else 'NO'}" for k, v in ok.items()), {"gamma": g, "ok": ok}


# ---- S4..S6 highlights --------------------------------------------------------------

EV250_BAND = {s: (3.5, 6.0) for s in NEGATIVES}
EV250_BAND["cine250d"] = (4.0, 6.5)
EV250_BAND["velvia50"] = (2.0, 3.5)


@line("S4", "EV above grey where luminance first reaches code 250 (extended ramp) inside band: negatives +3.5..+6.0, Cine +4.0..+6.5, Velvia +2.0..+3.5")
def s4(r):
    det, ok = {"neutral": xramp(r).first_ev(250)}, {}
    for s in STOCKS:
        det[s] = xramp(r, s).first_ev(250)
        lo, hi = EV250_BAND[s]
        ok[s] = det[s] is not None and lo <= det[s] <= hi
    return all_ok(ok), " ".join(f"{SHORT[k]}={fmt(v)}" for k, v in det.items()), det


def shoulder(rp):
    """Luminance code slope per EV in 0.25-EV bins from +1 EV to the first bin >= 254.5."""
    edges = np.arange(1.0, 8.0, 0.25)
    codes = np.array([float(enc(rp.ylin[(rp.ev >= a) & (rp.ev < a + 0.25)].mean())) for a in edges])
    end = np.where(codes >= 254.5)[0]
    n = end[0] + 1 if len(end) else len(codes)
    d = np.diff(codes[:n]) / 0.25
    rises = np.diff(d)
    worst_rise = float(rises.max()) if len(rises) else 0.0
    ev255 = rp.first_ev(254.5, "max")
    ev250 = rp.first_ev(250)
    land = None
    if ev255 is not None:
        land = (rp.yat(ev255 - 0.05, 0.05) - rp.yat(ev255 - 0.55, 0.05)) / 0.5
    return worst_rise, ev250, ev255, land


@line("S5", "smooth shoulder, no hard clip: shoulder slope never rises by > 2 code/EV between 0.25-EV bins above +1 EV; any channel reaches 255 only >= 0.25 EV after luminance 250 and with a landing slope <= 12 code/EV")
def s5(r):
    det, ok = {}, {}
    for s in ["neutral"] + STOCKS:
        wr, e250, e255, land = shoulder(xramp(r, None if s == "neutral" else s))
        det[s] = {"worst_rise": wr, "ev250": e250, "ev255": e255, "landing": land}
        if s == "neutral":
            continue
        clip_ok = e255 is None or (e250 is not None and e255 >= e250 + 0.25 and land <= 12)
        ok[s] = wr <= 2.0 and clip_ok
    return all_ok(ok), " ".join(f"{SHORT[s]}:rise={d['worst_rise']:.1f},255@{fmt(d['ev255'])},land={fmt(d['landing'],1)}"
                                for s, d in det.items()), det


def photo_stats(im):
    y = lum_code(im)
    L, C, h = lch(im)
    return {"p1": float(np.percentile(y, 1)), "p50": float(np.percentile(y, 50)),
            "p999": float(np.percentile(y, 99.9)), "max": float(y.max()),
            "zero": float((im.min(2) <= 0).mean() * 100), "clip": float((im.max(2) >= 255).mean() * 100),
            "C": float(C.mean())}


_PS = {}


def pstats(r, pid, s):
    k = (pid, s)
    if k not in _PS:
        _PS[k] = photo_stats(r.img(pid, None if s == "neutral" else s))
    return _PS[k]


@line("S6", "real photos: p99.9 luminance within 6 codes of neutral (Velvia: >= neutral - 6) on 6929 2545 4694 7881 983 1840")
def s6(r):
    det, ok = {}, {}
    for s in STOCKS:
        d = [pstats(r, p, s)["p999"] - pstats(r, p, "neutral")["p999"] for p in PHOTOS]
        det[s] = {p: round(v, 1) for p, v in zip(PHOTOS, d)}
        ok[s] = all(v >= -6 for v in d) and (s == "velvia50" or all(v <= 6 for v in d))
    return all_ok(ok), " ".join(f"{SHORT[s]}:[{min(d.values()):+.1f},{max(d.values()):+.1f}]" for s, d in det.items()), det


# ---- S7..S11 shadows and neutrality ----------------------------------------------------

@line("S7", "real photos: p1 luminance minus neutral within [-4, +4] codes for negatives, [-4, +2] for Velvia")
def s7(r):
    det, ok = {}, {}
    for s in STOCKS:
        d = [pstats(r, p, s)["p1"] - pstats(r, p, "neutral")["p1"] for p in PHOTOS]
        det[s] = {p: round(v, 1) for p, v in zip(PHOTOS, d)}
        hi = 2 if s == "velvia50" else 4
        ok[s] = all(-4 <= v <= hi for v in d)
    return all_ok(ok), " ".join(f"{SHORT[s]}:[{min(d.values()):+.1f},{max(d.values()):+.1f}]" for s, d in det.items()), det


@line("S8", "black floor: luminance code at -6 EV and -8 EV on grey_ramp <= neutral + 3 for every negative")
def s8(r):
    n = gramp(r)
    det, ok = {"neutral": (n.yat(-6), n.yat(-8))}, {}
    for s in NEGATIVES:
        g = gramp(r, s)
        det[s] = (g.yat(-6), g.yat(-8))
        ok[s] = det[s][0] <= det["neutral"][0] + 3 and det[s][1] <= det["neutral"][1] + 3
    return all_ok(ok), " ".join(f"{SHORT[k]}={v[0]:.1f}/{v[1]:.1f}" for k, v in det.items()), det


@line("S9", "no crushed shadows: % pixels with any channel at 0 on each photo <= max(2 x neutral, neutral + 0.5); Velvia grey_ramp share at code 0 <= 8%")
def s9(r):
    det, ok = {}, {}
    for s in STOCKS:
        bad = {}
        for p in PHOTOS:
            n, f = pstats(r, p, "neutral")["zero"], pstats(r, p, s)["zero"]
            bad[p] = round(f, 2)
            ok[(s, p)] = f <= max(2 * n, n + 0.5)
        det[s] = bad
    v = gramp(r, "velvia50")
    det["velvia_ramp_zero_pct"] = float((v.rgb.min(1) < 0.5).mean() * 100)
    ok["velvia_ramp"] = det["velvia_ramp_zero_pct"] <= 8
    det["neutral"] = {p: round(pstats(r, p, "neutral")["zero"], 2) for p in PHOTOS}
    worst = {s: max(det[s].values()) for s in STOCKS}
    return all_ok(ok), "worst zero% " + " ".join(f"{SHORT[s]}={worst[s]:.2f}" for s in STOCKS) + \
        f" (neutral max {max(det['neutral'].values()):.2f}); Velvia ramp 0-share {det['velvia_ramp_zero_pct']:.1f}%", det


def cast(rp, a, b):
    m = (rp.ev >= a) & (rp.ev <= b)
    c = rp.rgb[m]
    return c[:, 0] - c[:, 1], c[:, 2] - c[:, 1], c[:, 0] - c[:, 2], c[:, 1] - (c[:, 0] + c[:, 2]) / 2


@line("S10", "grey-ramp neutrality over -6..+3.5 EV: max |R-G|,|B-G| <= 3 codes for Portra, Ektar, Velvia; <= 1 for Tri-X")
def s10(r):
    det, ok = {}, {}
    for s in ["neutral", "portra400", "ektar100", "velvia50", "trix400"]:
        rg, bg, _, _ = cast(gramp(r, None if s == "neutral" else s), -6, 3.5)
        det[s] = float(max(np.abs(rg).max(), np.abs(bg).max()))
        if s != "neutral":
            ok[s] = det[s] <= (1 if s == "trix400" else 3)
    return all_ok(ok), " ".join(f"{SHORT[k]}={v:.1f}" for k, v in det.items()), det


@line("S11", "authored crossover, bounded and of the documented sign (grey_ramp): Gold warm everywhere (R-B in [0,+8] over -4..+3 EV, mean R-B over +1..+3 >= +2); Cine cool shadows (mean B-R over -4..-2 in [+1,+6]) and warm-neutral highlights (mean R-B over +1..+3 in [0,+6]); both |G-(R+B)/2| <= 3")
def s11(r):
    det, ok = {}, {}
    _, _, rb, gm = cast(gramp(r, "gold200"), -4, 3)
    _, _, rbh, _ = cast(gramp(r, "gold200"), 1, 3)
    det["gold"] = {"R-B min": float(rb.min()), "R-B max": float(rb.max()), "R-B hi mean": float(rbh.mean()),
                   "|G-m| max": float(np.abs(gm).max())}
    ok["gold"] = rb.min() >= 0 and rb.max() <= 8 and rbh.mean() >= 2 and np.abs(gm).max() <= 3
    _, _, rbs, gm1 = cast(gramp(r, "cine250d"), -4, -2)
    _, _, rbh, gm2 = cast(gramp(r, "cine250d"), 1, 3)
    det["cine"] = {"B-R shadow mean": float(-rbs.mean()), "R-B hi mean": float(rbh.mean()),
                   "|G-m| max": float(max(np.abs(gm1).max(), np.abs(gm2).max()))}
    ok["cine"] = 1 <= -rbs.mean() <= 6 and 0 <= rbh.mean() <= 6 and det["cine"]["|G-m| max"] <= 3
    return all_ok(ok), "Gold " + ", ".join(f"{k}={v:+.1f}" for k, v in det["gold"].items()) + \
        "; Cine " + ", ".join(f"{k}={v:+.1f}" for k, v in det["cine"].items()), det


# ---- S12..S21 colour ---------------------------------------------------------------

CHROMA_CC = {"portra400": (1.00, 1.15), "cine250d": (0.95, 1.15), "gold200": (1.12, 1.30),
             "ektar100": (1.25, 1.45), "velvia50": (1.35, 1.60)}
CHROMA_PH = {"portra400": (1.00, 1.20), "cine250d": (0.95, 1.20), "gold200": (1.10, 1.35),
             "ektar100": (1.25, 1.50), "velvia50": (1.35, 1.70)}


def cc_lch(r, s, img="colorchecker"):
    P = cc_patches() if img == "colorchecker" else skin_patches()
    m = patch_means(r.img(img, None if s == "neutral" else s), [p["rect"] for p in P])
    return lch(m), m


def cc_ratios(r, s):
    (L0, C0, h0), _ = cc_lch(r, "neutral")
    (L1, C1, h1), _ = cc_lch(r, s)
    return (C1 / C0)[:18], dhue(h1, h0)[:18], (L1 - L0)[:18]


@line("S12", "colorchecker mean chroma ratio vs neutral (OKLab C, 18 chromatic patches) in band: Portra 1.00-1.15, Cine 0.95-1.15, Gold 1.12-1.30, Ektar 1.25-1.45, Velvia 1.35-1.60")
def s12(r):
    det, ok = {}, {}
    for s in COLOUR:
        det[s] = float(cc_ratios(r, s)[0].mean())
        ok[s] = CHROMA_CC[s][0] <= det[s] <= CHROMA_CC[s][1]
    return all_ok(ok), " ".join(f"{SHORT[k]}={v:.2f}" for k, v in det.items()), det


def photo_chroma(r, s):
    return float(np.exp(np.mean([math.log(pstats(r, p, s)["C"] / pstats(r, p, "neutral")["C"]) for p in PHOTOS])))


@line("S13", "chroma order on the colorchecker AND on photos: Velvia > Ektar > Gold > Portra with gaps >= 0.05, Cine <= Portra + 0.03")
def s13(r):
    det, ok = {}, {}
    for tag, f in (("cc", lambda s: float(cc_ratios(r, s)[0].mean())), ("photo", lambda s: photo_chroma(r, s))):
        c = {s: f(s) for s in COLOUR}
        det[tag] = c
        ok[tag] = (c["velvia50"] >= c["ektar100"] + 0.05 and c["ektar100"] >= c["gold200"] + 0.05
                   and c["gold200"] >= c["portra400"] + 0.05 and c["cine250d"] <= c["portra400"] + 0.03)
    return all_ok(ok), " | ".join(f"{t}: " + ">".join(f"{SHORT[s]}{v:.2f}" for s, v in sorted(c.items(), key=lambda x: -x[1]))
                                  for t, c in det.items()), det


@line("S14", "real-photo mean chroma ratio vs neutral (geometric mean over 6 photos) in band: Portra 1.00-1.20, Cine 0.95-1.20, Gold 1.10-1.35, Ektar 1.25-1.50, Velvia 1.35-1.70")
def s14(r):
    det, ok = {}, {}
    for s in COLOUR:
        det[s] = photo_chroma(r, s)
        ok[s] = CHROMA_PH[s][0] <= det[s] <= CHROMA_PH[s][1]
    return all_ok(ok), " ".join(f"{SHORT[k]}={v:.2f}" for k, v in det.items()), det


@line("S15", "chroma is stock colour, not vibrance: max/min per-patch chroma ratio over the 18 colorchecker patches <= 1.40")
def s15(r):
    det, ok = {}, {}
    for s in COLOUR:
        c = cc_ratios(r, s)[0]
        det[s] = float(c.max() / c.min())
        ok[s] = det[s] <= 1.40
    return all_ok(ok), " ".join(f"{SHORT[k]}={v:.2f}" for k, v in det.items()), det


def skin_set(r, s):
    """skin_tones (12 patches) + colorchecker 1, 2; hue only where neutral C >= 0.02."""
    (L0, C0, h0), _ = cc_lch(r, "neutral", "skin_tones")
    (L1, C1, h1), _ = cc_lch(r, s, "skin_tones")
    (cL0, cC0, ch0), _ = cc_lch(r, "neutral")
    (cL1, cC1, ch1), _ = cc_lch(r, s)
    names = [p["name"] for p in skin_patches()] + ["CC dark skin", "CC light skin"]
    L0, L1 = np.r_[L0, cL0[:2]], np.r_[L1, cL1[:2]]
    C0, C1 = np.r_[C0, cC0[:2]], np.r_[C1, cC1[:2]]
    h0, h1 = np.r_[h0, ch0[:2]], np.r_[h1, ch1[:2]]
    m = C0 >= 0.02
    return {"names": [n for n, k in zip(names, m) if k], "ratio": (C1 / C0)[m], "dh": dhue(h1, h0)[m], "dL": (L1 - L0)[m]}


SKIN_DH = {"gold200": (-3, 8), "ektar100": (-8, 4), "velvia50": (-6, 6), "cine250d": (-6, 6)}


@line("S16", "Portra skin (Monk 1-10 + CC skins, light AND dark): chroma ratio 0.95-1.20, |dh| <= 4 deg, |dL| <= 0.03 on every patch")
def s16(r):
    k = skin_set(r, "portra400")
    ok = k["ratio"].min() >= 0.95 and k["ratio"].max() <= 1.20 and np.abs(k["dh"]).max() <= 4 and np.abs(k["dL"]).max() <= 0.03
    det = {n: (round(float(a), 2), round(float(b), 1), round(float(c), 3)) for n, a, b, c in zip(k["names"], k["ratio"], k["dh"], k["dL"])}
    return bool(ok), f"C ratio [{k['ratio'].min():.2f},{k['ratio'].max():.2f}] dh [{k['dh'].min():+.1f},{k['dh'].max():+.1f}] dL [{k['dL'].min():+.3f},{k['dL'].max():+.3f}]", det


@line("S17", "other colour stocks on skin: chroma ratio 0.85-1.45 every patch (no burnt orange, no grey); hue shift in band Gold -3..+8, Ektar -8..+4, Velvia -6..+6, Cine -6..+6 deg")
def s17(r):
    det, ok = {}, {}
    for s in ["gold200", "ektar100", "velvia50", "cine250d"]:
        k = skin_set(r, s)
        lo, hi = SKIN_DH[s]
        det[s] = {"ratio": (float(k["ratio"].min()), float(k["ratio"].max())), "dh": (float(k["dh"].min()), float(k["dh"].max()))}
        ok[s] = k["ratio"].min() >= 0.85 and k["ratio"].max() <= 1.45 and k["dh"].min() >= lo and k["dh"].max() <= hi
    return all_ok(ok), " ".join(f"{SHORT[s]}:C[{d['ratio'][0]:.2f},{d['ratio'][1]:.2f}]h[{d['dh'][0]:+.0f},{d['dh'][1]:+.0f}]" for s, d in det.items()), det


BLUE_IDX = {"blue sky": 2, "blue flower": 4, "purplish blue": 7, "blue": 12}
BLUE_DH = {"portra400": (-5, 5), "gold200": (-6, 3), "cine250d": (-5, 5), "ektar100": (-9, 3), "velvia50": (-3, 8)}


@line("S18", "blue hue (CC blue sky, blue flower, purplish blue, blue): Portra/Cine |dh| <= 5, Gold -6..+3 (slight cyan allowed), Ektar -9..+3 (cyan lean authored), Velvia -3..+8 (violet lean authored, never cyan)")
def s18(r):
    det, ok = {}, {}
    for s in COLOUR:
        _, dh, _ = cc_ratios(r, s)
        v = {n: float(dh[i]) for n, i in BLUE_IDX.items()}
        lo, hi = BLUE_DH[s]
        det[s] = v
        ok[s] = all(lo <= x <= hi for x in v.values())
    return all_ok(ok), " ".join(f"{SHORT[s]}:[{min(v.values()):+.1f},{max(v.values()):+.1f}]" for s, v in det.items()), det


def wheel_ring(im, frac):
    out = []
    for a in np.arange(0, 360, 10):
        x = 600 + frac * 576 * math.cos(math.radians(a))
        y = 600 - frac * 576 * math.sin(math.radians(a))
        out.append(im[int(y) - 3:int(y) + 4, int(x) - 3:int(x) + 4].reshape(-1, 3).mean(0))
    return np.array(out)


@line("S19", "hue fidelity on hue_wheel ring r=0.35 (36 hues): mean |dh| <= 4 deg and max |dh| <= 10 deg (Ektar, Velvia: max <= 12)")
def s19(r):
    _, _, h0 = lch(wheel_ring(r.img("hue_wheel"), 0.35))
    det, ok = {}, {}
    for s in COLOUR:
        _, _, h1 = lch(wheel_ring(r.img("hue_wheel", s), 0.35))
        d = np.abs(dhue(h1, h0))
        det[s] = (float(d.mean()), float(d.max()))
        ok[s] = d.mean() <= 4 and d.max() <= (12 if s in ("ektar100", "velvia50") else 10)
    return all_ok(ok), " ".join(f"{SHORT[s]}={a:.1f}/{b:.1f}" for s, (a, b) in det.items()), det


def clip_pct(px):
    px = px.reshape(-1, 3)
    return float(((px.min(1) <= 0) | (px.max(1) >= 255)).mean() * 100)


@line("S20", "gamut-mapped sky: 983 deep sky (top-left region) % pixels with a channel at 0 or 255 <= neutral + 1.0 pt, and its min channel p5 >= 6 codes")
def s20(r):
    n = region(r.img("983"), R_983_SKY)
    det = {"neutral": (clip_pct(n), float(np.percentile(n.min(2), 5)))}
    ok = {}
    for s in STOCKS:
        f = region(r.img("983", s), R_983_SKY)
        det[s] = (clip_pct(f), float(np.percentile(f.min(2), 5)))
        ok[s] = det[s][0] <= det["neutral"][0] + 1.0 and det[s][1] >= 6
    return all_ok(ok), " ".join(f"{SHORT[k]}={a:.1f}%/p5min={b:.0f}" for k, (a, b) in det.items()), det


def wheel_radial(im, radii):
    out = []
    for a in np.arange(0, 360, 10):
        row = []
        for f in radii:
            x = 600 + f * 576 * math.cos(math.radians(a))
            y = 600 - f * 576 * math.sin(math.radians(a))
            row.append(im[int(y) - 2:int(y) + 3, int(x) - 2:int(x) + 3].reshape(-1, 3).mean(0))
        out.append(row)
    return np.array(out)  # 36 hues x radii x 3


OUTER = np.arange(0.6, 0.951, 0.05)


@line("S21", "gamut-mapped, not clipped, at the gamut edge (hue_wheel r 0.6..0.95, 36 hues x 8 radii): p90 |hue difference vs neutral| <= 8 deg (Ektar, Velvia <= 10); radial gradation kept (share of adjacent radial steps with CIEDE2000 < 0.5) <= neutral + 3 pts; over-range light desaturates toward white like film (stress card x30 and x1000 primaries: luminance >= 0.75 x neutral's)")
def s21(r):
    p0 = wheel_radial(r.img("hue_wheel"), OUTER)
    _, _, h0 = lch(p0)
    lab0 = cielab(p0)
    col0 = float((de2000(lab0[:, 1:], lab0[:, :-1]) < 0.5).mean() * 100)
    st0 = r.img("stress")
    det, ok = {"neutral": {"collapse": col0}}, {}
    for s in COLOUR:
        p = wheel_radial(r.img("hue_wheel", s), OUTER)
        _, _, h = lch(p)
        lab = cielab(p)
        col = float((de2000(lab[:, 1:], lab[:, :-1]) < 0.5).mean() * 100)
        tw = float(np.percentile(np.abs(dhue(h, h0)), 90))
        st = r.img("stress", s)
        prim = [float(lum_code(st[32, i * 64 + 32]) / max(1.0, lum_code(st0[32, i * 64 + 32]))) for i in (7, 8, 9, 10, 11, 12)]
        det[s] = {"p90_dh": tw, "collapse": col, "overrange_lum_ratio_min": min(prim)}
        ok[s] = tw <= (10 if s in ("ektar100", "velvia50") else 8) and col <= col0 + 3 and min(prim) >= 0.75
    return all_ok(ok), f"neutral collapse={col0:.1f}% " + " ".join(
        f"{SHORT[s]}:dh90={d['p90_dh']:.1f},col={d['collapse']:.1f}%,over={d['overrange_lum_ratio_min']:.2f}" for s, d in det.items() if s != "neutral"), det


# ---- S22..S24 Tri-X ------------------------------------------------------------------

TRIX_BAND = {"blue": (4, 40), "purplish blue": (2, 40), "blue sky": (0, 30), "red": (-14, -2),
             "green": (-12, 8), "yellow": (-10, 6)}
TRIX_IDX = {"blue sky": 2, "purplish blue": 7, "blue": 12, "green": 13, "red": 14, "yellow": 15}


def luma_deviation(r, s):
    """Patch luminance code minus the code the SAME stock gives a grey of the patch's
    scene luminance (Rec.2020 Y of the patch's linear value), read off its own extended
    ramp. Isolates spectral response from the tone curve."""
    P = cc_patches()
    rp = xramp(r, None if s == "neutral" else s)
    m = patch_means(r.img("colorchecker", None if s == "neutral" else s), [p["rect"] for p in P])
    y = lum_code(m)
    out = {}
    for n, i in TRIX_IDX.items():
        lin = np.array(P[i]["rec2020_linear"])
        Y = float(lin @ np.array([0.2627, 0.6780, 0.0593]))
        e = math.log2(Y / 0.18)
        out[n] = float(y[i] - np.interp(e, rp.ev, rp.y))
    return out


@line("S22", "Tri-X panchromatic response (CC patch luminance minus a grey of equal scene luma through Tri-X's own curve): blue >= +4, purplish blue >= +2, blue sky >= 0, red -14..-2, green -12..+8, yellow -10..+6 codes")
def s22(r):
    t = luma_deviation(r, "trix400")
    n = luma_deviation(r, "neutral")
    ok = {k: TRIX_BAND[k][0] <= v <= TRIX_BAND[k][1] for k, v in t.items()}
    return all_ok(ok), "Tri-X " + " ".join(f"{k}={v:+.1f}" for k, v in t.items()) + " | neutral-luma ref " + \
        " ".join(f"{k}={v:+.1f}" for k, v in n.items()), {"trix": t, "neutral": n}


TRIX_VARIANTS = [dict(push=p) for p in (-1, 0, 1, 2)] + [dict(exposure=e) for e in (-2, 3)] + [dict(exposure=3, push=2), dict(exposure=-2, push=-1)]


@line("S23", "Tri-X output exactly neutral: max |R-G|, |B-G| <= 1 code on colorchecker, grey_ramp-extended and 4694 at push -1,0,1,2, exposure -2,+3 and both combined extremes")
def s23(r):
    worst = {}
    for v in TRIX_VARIANTS:
        w = 0.0
        for img in ("colorchecker", "xramp", "4694"):
            im = r.img(img, "trix400", **v)
            w = max(w, float(np.abs(im[..., 0] - im[..., 1]).max()), float(np.abs(im[..., 2] - im[..., 1]).max()))
        worst[json.dumps(v)] = w
    return max(worst.values()) <= 1, "worst " + " ".join(f"{k}={v:.0f}" for k, v in worst.items()), worst


@line("S24", "Tri-X tonal separation on 4694: lemon minus lit green dish >= 42 codes (neutral colour render: 37; x Tri-X/neutral contrast) AND tomato >= 0.75 x its neutral-render luminance (not black)")
def s24(r):
    det = {}
    for s in ("neutral", "trix400"):
        im = r.img("4694", None if s == "neutral" else s)
        det[s] = {k: float(lum_code(region(im, R)).mean()) for k, R in
                  (("lemon", R_4694_LEMON), ("dish", R_4694_DISH), ("tomato", R_4694_TOMATO))}
    t, n = det["trix400"], det["neutral"]
    ok = t["lemon"] - t["dish"] >= 42 and t["tomato"] >= 0.75 * n["tomato"]
    return bool(ok), f"Tri-X lemon-dish={t['lemon']-t['dish']:.1f} tomato={t['tomato']:.1f} (neutral lemon-dish={n['lemon']-n['dish']:.1f} tomato={n['tomato']:.1f})", det


# ---- S25..S26 amount -------------------------------------------------------------------

@line("S25", "amount 0 is bit-identical to no film block (6929 and colorchecker, every stock, also with exposure +3 and push +2 set)")
def s25(r):
    det = {}
    for img in ("6929", "colorchecker"):
        n = r.img(img)
        for s in STOCKS:
            for v in ({}, {"exposure": 3, "push": 2}):
                det[f"{img}/{s}/{json.dumps(v)}"] = float(np.abs(r.img(img, s, amount=0, **v) - n).max())
    return max(det.values()) == 0, f"max |d| = {max(det.values()):.0f} codes over {len(det)} renders", det


def mean_de(a, b):
    return float(de2000(cielab(a), cielab(b)).mean())


@line("S26", "amount is monotone and near-linear: mean CIEDE2000 from neutral on 2545 at 10/25/50/75 within +-0.10 of amount/100 of the amount-100 value, strictly increasing, every stock")
def s26(r):
    n = r.img("2545")
    det, ok = {}, {}
    for s in STOCKS:
        d = [mean_de(r.img("2545", s, amount=a), n) for a in AMOUNTS]
        frac = [x / d[-1] for x in d]
        det[s] = {"de100": d[-1], "frac": [round(f, 3) for f in frac]}
        ok[s] = all(np.diff(d) > 0) and all(abs(f - a / 100) <= 0.10 for f, a in zip(frac, AMOUNTS))
    return all_ok(ok), " ".join(f"{SHORT[s]}:dE100={v['de100']:.2f},frac50={v['frac'][3]:.2f}" for s, v in det.items()), det


# ---- S27..S30 film exposure --------------------------------------------------------------

def grey_shift(r, s, **v):
    base = xramp(r, s).ylin_at(0)
    return math.log2(xramp(r, s, **v).ylin_at(0) / base)


@line("S27", "Film Exposure on negatives is lab-normalised: grey shift within +-0.25 EV at every value -2..+3 (0.5 steps), and steps between adjacent values <= 0.15 EV")
def s27(r):
    det, ok = {}, {}
    for s in NEGATIVES:
        sh = [grey_shift(r, s, exposure=e) for e in EXPOSURES]
        det[s] = [round(x, 3) for x in sh]
        ok[s] = max(abs(x) for x in sh) <= 0.25 and max(abs(x) for x in np.diff(sh)) <= 0.15
    return all_ok(ok), " ".join(f"{SHORT[s]}:[{min(v):+.2f},{max(v):+.2f}]" for s, v in det.items()), det


@line("S28", "Film Exposure +2 on negatives: shadows not lifted (code at -5 EV <= exp-0 + 1) and at least as contrasty (log-log slope -5..-3 EV >= exp 0); highlights softer (code/EV over +1.5..+3 <= exp 0) and paler but not bleached (bright +2.5 EV colour card mean chroma 0.60..0.97 x exp 0, colour stocks)")
def s28(r):
    det, ok = {}, {}
    P = cc_patches()[:18]
    rects = [[c * 96, r_ * 96, 96, 96] for r_, c in (divmod(i, 6) for i in range(18))]
    for s in NEGATIVES:
        a, b = xramp(r, s), xramp(r, s, exposure=2)
        d = {"code-5": (a.yat(-5), b.yat(-5)), "shadow_slope": (a.slope(-5, -3), b.slope(-5, -3)),
             "hi_slope": (a.code_slope(1.5, 3), b.code_slope(1.5, 3))}
        o = b.yat(-5) <= a.yat(-5) + 1 and b.slope(-5, -3) >= a.slope(-5, -3) and b.code_slope(1.5, 3) <= a.code_slope(1.5, 3)
        if s != "trix400":
            c0 = lch(patch_means(r.img("ccbright", s), rects))[1].mean()
            c2 = lch(patch_means(r.img("ccbright", s, exposure=2), rects))[1].mean()
            d["bright_C_ratio"] = float(c2 / c0)
            o = o and 0.60 <= c2 / c0 <= 0.97
        det[s], ok[s] = d, bool(o)
    return all_ok(ok), " ".join(f"{SHORT[s]}:{'ok' if ok[s] else 'NO'}(Cr={fmt(d.get('bright_C_ratio'))},sh={d['shadow_slope'][0]:.2f}->{d['shadow_slope'][1]:.2f})" for s, d in det.items()), det


@line("S29", "Film Exposure -2 on negatives: muddy, fogged shadows: log-log slope -4..-2 EV <= 0.85 x exp 0, code at -4 EV >= exp 0 (not crushed); colour negatives get a cool/green shadow cast ((G+B)/2-R over -4..-2 EV, mean) in [+1, +6] codes")
def s29(r):
    det, ok = {}, {}
    for s in NEGATIVES:
        a, b = xramp(r, s), xramp(r, s, exposure=-2)
        m = (b.ev >= -4) & (b.ev <= -2)
        c = b.rgb[m]
        castv = float(((c[:, 1] + c[:, 2]) / 2 - c[:, 0]).mean())
        d = {"slope_ratio": b.slope(-4, -2) / a.slope(-4, -2), "code-4": (a.yat(-4), b.yat(-4)), "cast": castv}
        o = d["slope_ratio"] <= 0.85 and b.yat(-4) >= a.yat(-4)
        if s != "trix400":
            o = o and 1 <= castv <= 6
        det[s], ok[s] = d, bool(o)
    return all_ok(ok), " ".join(f"{SHORT[s]}:ratio={d['slope_ratio']:.2f},cast={d['cast']:+.1f}" for s, d in det.items()), det


@line("S30", "Velvia (reversal, no print): Film Exposure IS scene exposure: grey at film exposure e equals Velvia's own ramp at EV e within 0.20 display EV for every e in -2..+3, and grey strictly increasing with e")
def s30(r):
    base = xramp(r, "velvia50")
    y0 = base.ylin_at(0)
    sh = [grey_shift(r, "velvia50", exposure=e) for e in EXPOSURES]
    want = [math.log2(max(base.ylin_at(e), 1e-9) / y0) for e in EXPOSURES]
    err = [a - b for a, b in zip(sh, want)]
    ok = all(np.diff(sh) > 0) and max(abs(x) for x in err) <= 0.20
    return bool(ok), f"max|err|={max(abs(x) for x in err):.2f} EV; shifts=" + ",".join(f"{x:+.2f}" for x in sh) + \
        " want=" + ",".join(f"{x:+.2f}" for x in want), {"shifts": sh, "want": want, "err": err}


# ---- S31..S34 push/pull -------------------------------------------------------------------

@line("S31", "push/pull contrast (negatives): grey log-log slope strictly increasing over push -1..+2; slope(+1)/slope(0) 1.10-1.30, slope(+2)/slope(0) 1.20-1.55, slope(-1)/slope(0) 0.75-0.92; grey shift |.| <= 0.15 EV at every push")
def s31(r):
    det, ok = {}, {}
    for s in NEGATIVES:
        g = [xramp(r, s, push=p).slope(-0.5, 0.5) for p in PUSHES]
        g0 = g[PUSHES.index(0)]
        rat = {p: g[PUSHES.index(p)] / g0 for p in (1, 2, -1)}
        sh = [grey_shift(r, s, push=p) for p in PUSHES]
        det[s] = {"slopes": [round(x, 3) for x in g], "ratios": rat, "grey_shift_max": max(abs(x) for x in sh)}
        ok[s] = (all(np.diff(g) > 0) and 1.10 <= rat[1] <= 1.30 and 1.20 <= rat[2] <= 1.55
                 and 0.75 <= rat[-1] <= 0.92 and det[s]["grey_shift_max"] <= 0.15)
    return all_ok(ok), " ".join(f"{SHORT[s]}:x{d['ratios'][-1]:.2f}/x{d['ratios'][1]:.2f}/x{d['ratios'][2]:.2f},sh{d['grey_shift_max']:.2f}" for s, d in det.items()), det


def toe_ev(rp, code=12):
    return rp.first_ev(code)


@line("S32", "push loses shadow detail (negatives): the toe (EV where luminance first reaches code 12) moves up >= 0.8 EV at push +1 and >= 1.5 EV at push +2 vs push 0 (shadows the underexposure never recorded); pull -1 moves it down >= 0.3 EV")
def s32(r):
    det, ok = {}, {}
    for s in NEGATIVES:
        t = {p: toe_ev(xramp(r, s, push=p)) for p in (-1, 0, 1, 2)}
        d = {p: t[p] - t[0] for p in (-1, 1, 2)}
        det[s] = {"toe": t, "delta": d}
        ok[s] = d[1] >= 0.8 and d[2] >= 1.5 and d[-1] <= -0.3
    return all_ok(ok), " ".join(f"{SHORT[s]}:{v['delta'][-1]:+.2f}/{v['delta'][1]:+.2f}/{v['delta'][2]:+.2f}" for s, v in det.items()), det


@line("S33", "push hardens highlights, pull softens (negatives): code/EV over +1..+2.5 at push +2 >= push 0 + 3, at pull -1 <= push 0 - 3")
def s33(r):
    det, ok = {}, {}
    for s in NEGATIVES:
        h = {p: xramp(r, s, push=p).code_slope(1, 2.5) for p in (-1, 0, 2)}
        det[s] = h
        ok[s] = h[2] >= h[0] + 3 and h[-1] <= h[0] - 3
    return all_ok(ok), " ".join(f"{SHORT[s]}:{v[-1]:.1f}/{v[0]:.1f}/{v[2]:.1f}" for s, v in det.items()), det


@line("S34", "Velvia push range follows the datasheet (-1/2..+1 stop): extended ramp at push +2 equals push +1, push -1 equals push -0.5, within 1 code everywhere")
def s34(r):
    a = np.abs(r.img("xramp", "velvia50", push=2) - r.img("xramp", "velvia50", push=1)).max()
    b = np.abs(r.img("xramp", "velvia50", push=-1) - r.img("xramp", "velvia50", push=-0.5)).max()
    return bool(a <= 1 and b <= 1), f"|push2-push1|max={a:.0f} |pull1-pull0.5|max={b:.0f}", {"push": float(a), "pull": float(b)}


# ---- S35..S37 identity & safety -----------------------------------------------------------

def mono_variants():
    v = [dict()] + [dict(exposure=e) for e in EXPOSURES if e != 0] + [dict(push=p) for p in PUSHES if p != 0]
    return v + [dict(exposure=3, push=2), dict(exposure=-2, push=-1), dict(exposure=3, push=-1), dict(exposure=-2, push=2)]


@line("S35", "monotone per channel: on the extended ramp (-12..+8 EV) no channel code ever decreases, every stock, every exposure and push value and the four combined extremes")
def s35(r):
    bad = {}
    n = 0
    for s in STOCKS:
        for v in mono_variants():
            row = r.img("xramp", s, **v)[24]
            k = int((np.diff(row, axis=0) < 0).sum())
            n += 1
            if k:
                bad[f"{s}/{json.dumps(v)}"] = k
    return not bad, f"{len(bad)} of {n} ramps non-monotone" + (": " + ", ".join(list(bad)[:6]) if bad else ""), bad


@line("S36", "no NaN/garbage (proxy, PNG cannot hold NaN): on the stress card (0, 1e-6, -0.01, 1e2, 1e4, 1e6 greys, x30/x1000 primaries, negative components) every patch is uniform (max-min <= 1 code per channel), greys >= 1e2 render luminance >= 250, and patches 0 / 1e-6 / -0.01 render within 3 codes of neutral")
def s36(r):
    det, ok = {}, {}
    for s in ["neutral"] + STOCKS:
        im = r.img("stress", None if s == "neutral" else s)
        pats = [im[8:56, i * 64 + 8:i * 64 + 56] for i in range(16)]
        uni = max(float((p.reshape(-1, 3).max(0) - p.reshape(-1, 3).min(0)).max()) for p in pats)
        y = [float(lum_code(p.reshape(-1, 3).mean(0))) for p in pats]
        det[s] = {"uniform": uni, "lum": [round(v) for v in y]}
    n = det["neutral"]["lum"]
    for s in STOCKS:
        y = det[s]["lum"]
        ok[s] = det[s]["uniform"] <= 1 and min(y[3:6]) >= 250 and all(abs(y[i] - n[i]) <= 3 for i in range(3))
    return all_ok(ok), " ".join(f"{SHORT[s]}:{'ok' if ok[s] else 'NO'}" for s in STOCKS), det


@line("S37", "finish-LUT accuracy (what the GPU uses): CIEDE2000 between --lut-size 33 and 129 (proxy for exact) over colorchecker+skin_tones+hue_wheel: p99 <= neutral p99 + 0.5 and max <= 4.0 (8-bit quantisation included)")
def s37(r):
    det, ok = {}, {}
    for s in ["neutral"] + STOCKS:
        ds = []
        for img in ("colorchecker", "skin_tones", "hue_wheel"):
            a = r.img(img, None if s == "neutral" else s, lut=33)
            b = r.img(img, None if s == "neutral" else s, lut=129)
            ds.append(de2000(cielab(a), cielab(b)).ravel())
        d = np.concatenate(ds)
        det[s] = (float(np.percentile(d, 99)), float(d.max()))
    for s in STOCKS:
        ok[s] = det[s][0] <= det["neutral"][0] + 0.5 and det[s][1] <= 4.0
    return all_ok(ok), " ".join(f"{SHORT[k]}={a:.2f}/{b:.1f}" for k, (a, b) in det.items()), det


# ---- S38..S39 distinctness --------------------------------------------------------------------

@line("S38", "distinct stocks on the colorchecker: mean CIEDE2000 over the 24 patch means >= 3.0 for every pair of colour stocks and for every colour stock vs neutral")
def s38(r):
    labs = {s: cielab(cc_lch(r, s)[1]) for s in ["neutral"] + COLOUR}
    det = {}
    keys = ["neutral"] + COLOUR
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            det[f"{SHORT[keys[i]]}-{SHORT[keys[j]]}"] = float(de2000(labs[keys[i]], labs[keys[j]]).mean())
    worst = min(det, key=det.get)
    return det[worst] >= 3.0, f"min {worst}={det[worst]:.2f}; " + " ".join(f"{k}={v:.1f}" for k, v in det.items()), det


@line("S39", "distinct stocks on real photos: per-pixel mean CIEDE2000, averaged over the 6 photos, >= 2.0 for every pair of colour stocks and every colour stock vs neutral")
def s39(r):
    keys = ["neutral"] + COLOUR
    labs = {p: {s: cielab(r.img(p, None if s == "neutral" else s)) for s in keys} for p in PHOTOS}
    det = {}
    for i in range(len(keys)):
        for j in range(i + 1, len(keys)):
            det[f"{SHORT[keys[i]]}-{SHORT[keys[j]]}"] = float(np.mean([de2000(labs[p][keys[i]], labs[p][keys[j]]).mean() for p in PHOTOS]))
    worst = min(det, key=det.get)
    return det[worst] >= 2.0, f"min {worst}={det[worst]:.2f}; " + " ".join(f"{k}={v:.1f}" for k, v in det.items()), det


# --------------------------------------------------------------------------- sheets

SHEET_IMAGES = ["4694", "983", "6929", "2545", "skin_tones", "colorchecker", "grey_ramp"]


def sheets(r, out):
    os.makedirs(out, exist_ok=True)
    keys = ["neutral"] + STOCKS
    for img in SHEET_IMAGES:
        for s in keys:
            r.need(img, None if s == "neutral" else s)
        r.flush()
        tiles = [(SHORT[s], Image.open(r.path(img, None if s == "neutral" else s))) for s in keys]
        _sheet(os.path.join(out, f"sheet_{img}.png"), tiles, 400 if img != "grey_ramp" else 800, 4 if img != "grey_ramp" else 1)
    # Portra exposure and push sweeps on 2545
    for key, vals in (("exposure", [-2, -1, 0, 1, 2, 3]), ("push", [-1, 0, 1, 2])):
        for v in vals:
            r.need("2545", "portra400", **{key: v})
        r.flush()
        tiles = [(f"Portra {key} {v:+g}", Image.open(r.path("2545", "portra400", **{key: v}))) for v in vals]
        _sheet(os.path.join(out, f"sheet_portra_{key}_2545.png"), tiles, 400, 3 if key == "exposure" else 2)


def _sheet(path, tiles, tw, cols):
    ims = []
    for lab, im in tiles:
        im = im.convert("RGB")
        ims.append((lab, im.resize((tw, max(1, int(im.height * tw / im.width))), Image.LANCZOS)))
    th = max(i.height for _, i in ims)
    rows = (len(ims) + cols - 1) // cols
    sh = Image.new("RGB", (cols * tw + (cols + 1) * 6, rows * (th + 22) + 6), (40, 40, 40))
    d = ImageDraw.Draw(sh)
    for k, (lab, im) in enumerate(ims):
        rr, cc = divmod(k, cols)
        x, y = 6 + cc * (tw + 6), 6 + rr * (th + 22)
        sh.paste(im, (x, y + 18))
        d.text((x + 2, y + 3), lab, fill=(255, 255, 255))
    sh.save(path)

# --------------------------------------------------------------------------- prefetch


def prefetch(r, ids):
    """Queue every render the selected lines need, so they run in parallel."""
    q = r.need
    full = ["neutral"] + STOCKS
    for s in full:
        st = None if s == "neutral" else s
        for img in ("xramp", "grey_ramp", "colorchecker", "skin_tones", "hue_wheel", "stress", *PHOTOS):
            q(img, st)
    for s in STOCKS:
        for v in mono_variants():
            q("xramp", s, **v)
        for img in ("colorchecker", "skin_tones", "hue_wheel"):
            q(img, s, lut=129)
        for a in AMOUNTS:
            q("2545", s, amount=a)
        for img in ("6929", "colorchecker"):
            q(img, s, amount=0)
            q(img, s, amount=0, exposure=3, push=2)
        q("ccbright", s)
        q("ccbright", s, exposure=2)
    for img in ("colorchecker", "skin_tones", "hue_wheel"):
        q(img, None, lut=129)
    for v in TRIX_VARIANTS:
        for img in ("colorchecker", "xramp", "4694"):
            q(img, "trix400", **v)
    r.flush()

# --------------------------------------------------------------------------- main


def find_bin():
    if os.environ.get("LUMEN_RENDER"):
        return os.environ["LUMEN_RENDER"]
    swift = "/opt/swift/usr/bin/swift" if os.path.exists("/opt/swift/usr/bin/swift") else "swift"
    p = subprocess.run([swift, "build", "-c", "release", "--show-bin-path"], cwd=REPO,
                       capture_output=True, text=True).stdout.strip()
    b = os.path.join(p, "lumen-render")
    if not os.path.exists(b):
        sys.exit(f"lumen-render not found at {b}; build: swift build -c release --product lumen-render")
    return b


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", help="comma list of spec ids, e.g. S7,S12")
    ap.add_argument("--out", help="write contact sheets into this dir")
    ap.add_argument("--json", help="write results JSON here (default <work>/results.json)")
    ap.add_argument("--work", default=os.path.join(tempfile.gettempdir(), "ws38_measure"))
    ap.add_argument("--bin", default=None)
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2)))
    ap.add_argument("--build", action="store_true", help="swift build -c release --product lumen-render first")
    a = ap.parse_args()
    if a.build:
        swift = "/opt/swift/usr/bin/swift" if os.path.exists("/opt/swift/usr/bin/swift") else "swift"
        subprocess.run([swift, "build", "-c", "release", "--product", "lumen-render"], cwd=REPO, check=True)
    binary = a.bin or find_bin()
    author_inputs(a.work)
    r = R(binary, a.work, a.jobs)
    ids = None if not a.only else {x.strip().upper() for x in a.only.split(",")}
    sel = [l for l in LINES if ids is None or l[0] in ids]
    if ids is None:
        prefetch(r, ids)
    results = {}
    npass = 0
    print(f"{'id':4s} {'verdict':7s} measured")
    for sid, title, fn in sel:
        ok, summary, det = fn(r)
        r.flush()
        npass += bool(ok)
        results[sid] = {"title": title, "pass": bool(ok), "summary": summary, "detail": det}
        print(f"{sid:4s} {'PASS' if ok else 'FAIL':7s} {summary}")
    print(f"\n{npass}/{len(sel)} lines pass")
    if a.out:
        sheets(r, a.out)
        print(f"sheets -> {a.out}")
    jp = a.json or os.path.join(a.work, "results.json")
    with open(jp, "w") as f:
        json.dump(results, f, indent=1, default=lambda o: o.item() if hasattr(o, "item") else str(o))
    print(f"json -> {jp}")


if __name__ == "__main__":
    main()
