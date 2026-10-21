#!/usr/bin/env python3
"""WS-30 creative-LUT reference: generates the test cubes and an independent numpy
implementation of each tap, then compares Lumen's `CreativeLUTStage` (via the scratch
`lutprobe` binary, path in $LUTPROBE) against it in CIEDE2000 on the sRGB display output.

    python3 lutref.py gen <outdir>            # write the .cube files
    python3 lutref.py check <outdir>          # run every case, print a table, exit 1 on a fail

The reference is written from the declared spaces (CreativeLUT.swift header), not from
Lumen's code: Rec.2020 -> sRGB matrices from the primaries, IEC 61966-2-1 sRGB curve,
LumenLog from its definition, tetrahedral AND trilinear interpolation (the result must hold
against either, so the bound is about the stage, not the interpolant choice), and the
analytic function the cube samples (the truth a perfect LUT would give)."""
import sys, os, subprocess, math
import numpy as np

# ---------------- colour maths -------------------------------------------------------
def prim_matrix(xy, white=(0.3127, 0.3290)):
    xyz = lambda x, y: np.array([x / y, 1.0, (1 - x - y) / y])
    P = np.stack([xyz(*p) for p in xy], axis=1)
    S = np.linalg.solve(P, xyz(*white))
    return P * S
M2020 = prim_matrix([(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)])
M709 = prim_matrix([(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)])
W2D = np.linalg.solve(M709, M2020)          # Rec.2020 linear -> sRGB linear
D2W = np.linalg.inv(W2D)

def srgb_enc(x):
    x = np.asarray(x, float)
    return np.where(x <= 0.0031308, 12.92 * x, 1.055 * np.sign(x) * np.abs(x) ** (1 / 2.4) - 0.055)
def srgb_dec(x):
    x = np.asarray(x, float)
    return np.where(x <= 0.04045, x / 12.92, np.sign(x + 0.055) * (np.abs(x + 0.055) / 1.055) ** 2.4)

G, MINEV, MAXEV = 0.18, -12.0, 12.0
RANGE = MAXEV - MINEV
CUT = G * 2 ** (MINEV + 1.5)
TOE_S = (1 / RANGE) / (CUT * math.log(2))
TOE_O = 1.5 / RANGE - TOE_S * CUT
def llog_enc(x):
    x = np.asarray(x, float)
    return np.where(x >= CUT, (np.log2(np.maximum(x, 1e-30) / G) - MINEV) / RANGE, TOE_S * x + TOE_O)
def llog_dec(y):
    y = np.asarray(y, float)
    cy = TOE_S * CUT + TOE_O
    return np.where(y >= cy, G * 2 ** (y * RANGE + MINEV), (y - TOE_O) / TOE_S)

def xyz_to_lab(xyz):
    w = M709 @ np.ones(3)
    t = xyz / w
    d = 6 / 29
    f = np.where(t > d ** 3, np.cbrt(t), t / (3 * d * d) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)
def srgb_code_to_lab(code):  # display sRGB code values (0..1) -> CIELAB D65
    lin = srgb_dec(np.clip(code, 0, 1))
    return xyz_to_lab(lin @ M709.T)

def de2000(l1, l2):
    L1, a1, b1 = l1[..., 0], l1[..., 1], l1[..., 2]
    L2, a2, b2 = l2[..., 0], l2[..., 1], l2[..., 2]
    C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    Gf = 0.5 * (1 - np.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p, a2p = (1 + Gf) * a1, (1 + Gf) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1
    dCp = C2p - C1p
    dh = h2p - h1p
    dh = np.where(C1p * C2p == 0, 0, np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh)))
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh / 2))
    Lbp = (L1 + L2) / 2
    Cbp = (C1p + C2p) / 2
    hs = h1p + h2p
    hbp = np.where(C1p * C2p == 0, hs, np.where(np.abs(h1p - h2p) <= 180, hs / 2,
                   np.where(hs < 360, (hs + 360) / 2, (hs - 360) / 2)))
    T = (1 - 0.17 * np.cos(np.radians(hbp - 30)) + 0.24 * np.cos(np.radians(2 * hbp))
         + 0.32 * np.cos(np.radians(3 * hbp + 6)) - 0.20 * np.cos(np.radians(4 * hbp - 63)))
    dth = 30 * np.exp(-(((hbp - 275) / 25) ** 2))
    Rc = 2 * np.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lbp - 50) ** 2 / np.sqrt(20 + (Lbp - 50) ** 2)
    Sc = 1 + 0.045 * Cbp
    Sh = 1 + 0.015 * Cbp * T
    Rt = -np.sin(np.radians(2 * dth)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))

# ---------------- the test functions (what each cube samples) ------------------------
def f_identity(v):
    return v
def f_contrast709(v):
    """A 'known Rec.709 contrast LUT': a normalised logistic S-curve per channel on the
    encoded value (k = 6, pivot 0.5) followed by a 15% pull toward Rec.709 luma, which is
    cross-channel so the interpolant's off-diagonal behaviour is exercised."""
    s = lambda x: 1 / (1 + np.exp(-6 * (x - 0.5)))
    y = (s(v) - s(0.0)) / (s(1.0) - s(0.0))
    luma = y @ np.array([0.2126, 0.7152, 0.0722])
    return y + 0.15 * (luma[..., None] - y)
def f_logcontrast(v):
    """Log-domain grade (LumenLog in, LumenLog out): 1.25x contrast about mid-grey's code,
    a warm offset (+0.01 R, -0.01 B code = about +-1/4 stop)."""
    g = llog_enc(np.array(G))
    y = g + 1.25 * (v - g)
    return y + np.array([0.01, 0.0, -0.01])
def f_log_to_709(v):
    """A camera-style log-to-Rec.709 technical LUT for LumenLog/Rec.2020: decode, convert to
    Rec.709 primaries, a Reinhard-style shoulder (x/(x+0.6))*1.6 clipped, sRGB encode.
    Input LumenLog, output display sRGB: a different space out than in."""
    lin = llog_dec(v) @ W2D.T
    lin = np.maximum(lin, 0)
    t = np.clip(lin * 1.6 / (lin + 0.6), 0, 1)
    return srgb_enc(t)

def f_twist(v):
    """Deliberately hard for an interpolant: a saturation-dependent hue twist plus a
    per-channel gamma. On a size-9 cube tetrahedral and trilinear disagree visibly, so
    this case says WHICH interpolant the stage uses (it must be tetrahedral, the
    Resolve/OCIO-best choice the LUT3D header documents)."""
    mx, mn = v.max(-1, keepdims=True), v.min(-1, keepdims=True)
    sat = mx - mn
    y = v ** np.array([0.8, 1.0, 1.25])
    ang = 1.2 * sat
    c, s_ = np.cos(ang), np.sin(ang)
    m = y.mean(-1, keepdims=True)
    r, g, b = (y - m)[..., 0:1], (y - m)[..., 1:2], (y - m)[..., 2:3]
    return np.clip(np.concatenate([m + c * r - s_ * g, m + s_ * r + c * g, m + b], -1), 0, 1)

FUNCS = {"twist": f_twist, "identity": f_identity, "contrast709": f_contrast709,
         "logcontrast": f_logcontrast, "log2709": f_log_to_709}

def write_cube(path, n, f, title):
    g = np.linspace(0, 1, n)
    b, gg, r = np.meshgrid(g, g, g, indexing="ij")         # red fastest
    v = np.stack([r, gg, b], -1).reshape(-1, 3)
    out = f(v)
    with open(path, "w") as fh:
        fh.write(f'TITLE "{title}"\nLUT_3D_SIZE {n}\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n')
        for row in out:
            fh.write("%.9f %.9f %.9f\n" % tuple(row))

def read_cube(path):
    n = None; vals = []
    for line in open(path):
        p = line.split()
        if not p or p[0].startswith("#"): continue
        if p[0] == "LUT_3D_SIZE": n = int(p[1]); continue
        if p[0][0].isalpha() or p[0][0] == "_": continue
        vals.append([float(x) for x in p[:3]])
    return n, np.array(vals, np.float32).astype(float).reshape(n, n, n, 3)  # [b][g][r]

def interp(lut, n, v, mode):
    x = np.clip(v, 0, 1) * (n - 1)
    i0 = np.minimum(np.floor(x).astype(int), n - 1)
    i1 = np.minimum(i0 + 1, n - 1)
    t = x - i0
    C = lambda r, g, b: lut[b, g, r]
    r0, g0, b0 = i0[:, 0], i0[:, 1], i0[:, 2]
    r1, g1, b1 = i1[:, 0], i1[:, 1], i1[:, 2]
    tr, tg, tb = t[:, :1], t[:, 1:2], t[:, 2:]
    if mode == "trilinear":
        c00 = C(r0, g0, b0) * (1 - tr) + C(r1, g0, b0) * tr
        c10 = C(r0, g1, b0) * (1 - tr) + C(r1, g1, b0) * tr
        c01 = C(r0, g0, b1) * (1 - tr) + C(r1, g0, b1) * tr
        c11 = C(r0, g1, b1) * (1 - tr) + C(r1, g1, b1) * tr
        c0 = c00 * (1 - tg) + c10 * tg
        c1 = c01 * (1 - tg) + c11 * tg
        return c0 * (1 - tb) + c1 * tb
    out = np.empty_like(v)
    c000, c111 = C(r0, g0, b0), C(r1, g1, b1)
    for k in range(len(v)):
        a, b, c = t[k]
        p = lambda r, g, bb: C(np.array([r]), np.array([g]), np.array([bb]))[0]
        R0, G0, B0, R1, G1, B1 = r0[k], g0[k], b0[k], r1[k], g1[k], b1[k]
        if a >= b >= c:   o = (1-a)*c000[k] + (a-b)*p(R1,G0,B0) + (b-c)*p(R1,G1,B0) + c*c111[k]
        elif a >= c >= b: o = (1-a)*c000[k] + (a-c)*p(R1,G0,B0) + (c-b)*p(R1,G0,B1) + b*c111[k]
        elif c >= a >= b: o = (1-c)*c000[k] + (c-a)*p(R0,G0,B1) + (a-b)*p(R1,G0,B1) + b*c111[k]
        elif c >= b >= a: o = (1-c)*c000[k] + (c-b)*p(R0,G0,B1) + (b-a)*p(R0,G1,B1) + a*c111[k]
        elif b >= c >= a: o = (1-b)*c000[k] + (b-c)*p(R0,G1,B0) + (c-a)*p(R0,G1,B1) + a*c111[k]
        else:             o = (1-b)*c000[k] + (b-a)*p(R0,G1,B0) + (a-c)*p(R1,G1,B0) + c*c111[k]
        out[k] = o
    return out

# ---------------- the stage, independently ------------------------------------------
def ref_stage(x, tap, amount, lut_fn):
    """The declared contract, in the form this lane specifies (SPEC.md L1-L6):
    display: d = W2D x; u = clip(d,0,1); e = enc(u); b = max(e + a(L(e) - e), 0);
             out = D2W (dec(b) + (d - u))           -- the residual keeps what the cube can't see
    log:     e = llog(x); u = clip(e,0,1); out = llog^-1(e + a(L(u) - u))"""
    a = amount / 100.0
    if tap == "display":
        d = x @ W2D.T
        u = np.clip(d, 0, 1)
        e = srgb_enc(u)
        b = np.maximum(e + a * (lut_fn(e) - e), 0)
        return (srgb_dec(b) + (d - u)) @ D2W.T
    e = llog_enc(x)
    u = np.clip(e, 0, 1)
    return llog_dec(e + a * (lut_fn(u) - u))

def display_code(x_working):
    """Working-space display-linear -> what a viewer sees: sRGB code, clipped (the preview)."""
    return srgb_enc(np.clip(x_working @ W2D.T, 0, 1))

def samples(rng, n=4000, tap="display"):
    if tap == "display":
        # display-linear working values: the in-gamut SDR cube, plus a wide-gamut and an
        # HDR slice, plus a dense neutral ramp
        u = rng.random((n, 3)) ** 2.2
        d = u @ D2W.T
        wide = rng.random((n // 4, 3)) ** 2.2            # Rec.2020 values: many outside sRGB
        hdr = rng.random((n // 8, 3)) * 3.0
        ramp = np.repeat(np.linspace(0, 1, 256)[:, None], 3, 1)
        return np.concatenate([d, wide, hdr, ramp])
    ev = rng.uniform(-10, 8, (n, 3))
    x = G * 2 ** ev
    ramp = np.repeat((G * 2 ** np.linspace(-10, 8, 256))[:, None], 3, 1)
    return np.concatenate([x, ramp, np.zeros((1, 3))])

def probe(cube, tap, amount, x):
    exe = os.environ.get("LUTPROBE")
    inp = "\n".join("%.17g %.17g %.17g" % tuple(r) for r in x) + "\n"
    out = subprocess.run([exe, cube, tap, str(amount)], input=inp, capture_output=True, text=True, check=True).stdout
    return np.array([[float(v) for v in l.split()] for l in out.strip().split("\n")])

CASES = [  # (name, cube file, tap, size, amounts)
    ("identity", "identity_33.cube", "display"), ("identity", "identity_32.cube", "display"),
    ("identity", "identity_65.cube", "display"), ("identity", "identity_33.cube", "log"),
    ("contrast709", "contrast709_33.cube", "display"), ("contrast709", "contrast709_65.cube", "display"),
    ("logcontrast", "logcontrast_33.cube", "log"),
    ("twist", "twist_9.cube", "display"),
]

def main():
    cmd, d = sys.argv[1], sys.argv[2]
    os.makedirs(d, exist_ok=True)
    if cmd == "gen":
        for name, n in [("identity", 32), ("identity", 33), ("identity", 65), ("identity", 17),
                        ("contrast709", 33), ("contrast709", 65), ("logcontrast", 33), ("log2709", 33),
                        ("twist", 9)]:
            write_cube(f"{d}/{name}_{n}.cube", n, FUNCS[name], name)
        return
    rng = np.random.default_rng(7)
    fail = False
    print("%-22s %-7s %5s  %10s %10s %10s %10s  %s" % ("cube", "tap", "amt", "maxAbs", "dE(tetra)", "dE(tri)", "dE(true)", "verdict"))
    for name, cube, tap in CASES:
        x = samples(rng, tap=tap)
        if tap == "log":
            pass
        n, lut = read_cube(f"{d}/{cube}")
        for amount in ([0, 50, 100, 150, 200] if name != "identity" else [0, 37, 100, 200]):
            got = probe(f"{d}/{cube}", tap, amount, x)
            ref_tet = ref_stage(x, tap, amount, lambda e: interp(lut, n, e, "tetra"))
            ref_tri = ref_stage(x, tap, amount, lambda e: interp(lut, n, e, "trilinear"))
            ref_true = ref_stage(x, tap, amount, FUNCS[name])
            # compare in the viewer's terms; the log tap is followed by the display
            # transform in the app, so compare its scene values via a fixed view (x/(x+1)).
            view = (lambda w: display_code(w)) if tap == "display" else (lambda w: display_code(np.clip(w, 0, None) / (np.clip(w, 0, None) + 0.18)))
            lab = lambda w: srgb_code_to_lab(view(w))
            de_tet = de2000(lab(got), lab(ref_tet)); de_tri = de2000(lab(got), lab(ref_tri)); de_true = de2000(lab(got), lab(ref_true))
            maxabs = np.max(np.abs(got - x)) if name == "identity" else np.max(np.abs(got - ref_tet))
            if name == "identity":
                ok = maxabs < 1e-6
            else:
                ok = de_tet.max() < 0.5
            fail |= not ok
            print("%-22s %-7s %5d  %10.2e %10.4f %10.4f %10.4f  %s" % (cube, tap, amount, maxabs, de_tet.max(), de_tri.max(), np.percentile(de_true, 99), "PASS" if ok else "FAIL"))
    sys.exit(1 if fail else 0)

if __name__ == "__main__":
    main()
