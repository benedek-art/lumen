"""WS-31 measurement helpers. python3 + numpy + Pillow only; every path is an argument.

OKLab here is the audit's (CAT-normalised cone matrix, zero-sum a/b rows), which matches
LumenCore's OKLabTransform closely enough for hue/chroma/lightness deltas. Renders go
through the release `lumen-render` binary passed as --bin.
"""
import json, os, struct, subprocess
import numpy as np
from PIL import Image

BANDS = ["red", "orange", "yellow", "green", "aqua", "blue", "purple", "magenta"]

def _rgb_to_xyz(prim, white):
    m = np.array([[x / y, 1.0, (1 - x - y) / y] for x, y in prim]).T
    wx, wy = white
    s = np.linalg.solve(m, np.array([wx / wy, 1.0, (1 - wx - wy) / wy]))
    return m * s

D65 = (0.3127, 0.3290)
REC2020_TO_XYZ = _rgb_to_xyz([(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)], D65)
SRGB_TO_XYZ = _rgb_to_xyz([(0.64, 0.33), (0.30, 0.60), (0.15, 0.06)], D65)
SRGB_TO_2020 = np.linalg.inv(REC2020_TO_XYZ) @ SRGB_TO_XYZ
M1 = np.array([[0.8189330101, 0.3618667424, -0.1288597137],
               [0.0329845436, 0.9293118715, 0.0361456387],
               [0.0482003018, 0.2643662691, 0.6338517070]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])
M2z = M2.copy()
for r in (1, 2):
    M2z[r] -= M2z[r].sum() / 3
M2zi = np.linalg.inv(M2z)

def _ctx(toxyz):
    t = M1 @ toxyz
    t = np.diag(1 / (t @ np.ones(3))) @ t
    return t, np.linalg.inv(t)

R2L, L2R = _ctx(REC2020_TO_XYZ)
S2L, L2S = _ctx(SRGB_TO_XYZ)

def to_lab(rgb, space="2020"):
    m = R2L if space == "2020" else S2L
    return np.cbrt(np.asarray(rgb, float) @ m.T) @ M2z.T

def from_lab(lab, space="2020"):
    m = L2R if space == "2020" else L2S
    return ((np.asarray(lab, float) @ M2zi.T) ** 3) @ m.T

def lch(lab):
    lab = np.asarray(lab, float)
    return lab[..., 0], np.hypot(lab[..., 1], lab[..., 2]), np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360

def lch2lab(L, C, h):
    r = np.radians(h)
    return np.stack(np.broadcast_arrays(L, C * np.cos(r), C * np.sin(r)), -1)

def hd(a, b):
    """signed b-a, wrapped to [-180,180)."""
    return (np.asarray(b, float) - np.asarray(a, float) + 180) % 360 - 180

def circ_mean(h, w=None):
    z = np.exp(1j * np.radians(np.asarray(h, float)))
    return np.degrees(np.angle(np.average(z, weights=w))) % 360

def srgb_dec(v):
    v = np.asarray(v, float)
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)

def png_codes(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(np.int32)

def png_lin(path):
    return srgb_dec(png_codes(path) / 255.0)

def lin_Y(lin):
    return lin @ np.array([0.2126, 0.7152, 0.0722])

def png_lab(path):
    return to_lab(png_lin(path), "srgb")

def box(a, r):
    k = 2 * r + 1
    p = np.pad(a, r, mode="edge")
    c = np.pad(np.cumsum(np.cumsum(p, 0), 1), ((1, 0), (1, 0)))
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)

# ---- CIEDE2000 on sRGB-encoded PNGs (CIELAB D65) ----
def _lab76(lin):
    xyz = lin @ SRGB_TO_XYZ.T
    wn = SRGB_TO_XYZ @ np.ones(3)
    t = xyz / wn
    d = 6 / 29
    f = np.where(t > d ** 3, np.cbrt(t), t / (3 * d * d) + 4 / 29)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)

def de2000(lin1, lin2):
    l1, l2 = _lab76(lin1), _lab76(lin2)
    L1, a1, b1 = l1[..., 0], l1[..., 1], l1[..., 2]
    L2, a2, b2 = l2[..., 0], l2[..., 1], l2[..., 2]
    C1, C2 = np.hypot(a1, b1), np.hypot(a2, b2)
    Cb = (C1 + C2) / 2
    G = 0.5 * (1 - np.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)))
    a1p, a2p = (1 + G) * a1, (1 + G) * a2
    C1p, C2p = np.hypot(a1p, b1), np.hypot(a2p, b2)
    h1p = np.degrees(np.arctan2(b1, a1p)) % 360
    h2p = np.degrees(np.arctan2(b2, a2p)) % 360
    dLp = L2 - L1
    dCp = C2p - C1p
    dh = h2p - h1p
    dh = np.where(dh > 180, dh - 360, np.where(dh < -180, dh + 360, dh))
    dh = np.where(C1p * C2p == 0, 0, dh)
    dHp = 2 * np.sqrt(C1p * C2p) * np.sin(np.radians(dh / 2))
    Lbp = (L1 + L2) / 2
    Cbp = (C1p + C2p) / 2
    hs = h1p + h2p
    hbp = np.where(np.abs(h1p - h2p) > 180, np.where(hs < 360, hs + 360, hs - 360) / 2, hs / 2)
    hbp = np.where(C1p * C2p == 0, hs, hbp)
    T = (1 - 0.17 * np.cos(np.radians(hbp - 30)) + 0.24 * np.cos(np.radians(2 * hbp))
         + 0.32 * np.cos(np.radians(3 * hbp + 6)) - 0.20 * np.cos(np.radians(4 * hbp - 63)))
    dth = 30 * np.exp(-(((hbp - 275) / 25) ** 2))
    Rc = 2 * np.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    Sl = 1 + 0.015 * (Lbp - 50) ** 2 / np.sqrt(20 + (Lbp - 50) ** 2)
    Sc = 1 + 0.045 * Cbp
    Sh = 1 + 0.015 * Cbp * T
    Rt = -np.sin(np.radians(2 * dth)) * Rc
    return np.sqrt((dLp / Sl) ** 2 + (dCp / Sc) ** 2 + (dHp / Sh) ** 2 + Rt * (dCp / Sc) * (dHp / Sh))

# ---- LFI I/O ----
def write_lfi(path, rgb, hint=None):
    rgb = np.ascontiguousarray(rgb, dtype="<f4")
    h, w, c = rgb.shape
    with open(path, "wb") as f:
        f.write(b"LFI1")
        f.write(struct.pack("<III", w, h, c))
        f.write(rgb.tobytes())
    side = {"recipe_hint": hint or {"asShotKelvin": 6503.7072, "asShotTint": 9.77}}
    json.dump(side, open(path[:-4] + ".json", "w"))

def read_lfi(path):
    with open(path, "rb") as f:
        assert f.read(4) == b"LFI1", path
        w, h, c = struct.unpack("<III", f.read(12))
        return np.frombuffer(f.read(w * h * c * 4), dtype="<f4").reshape(h, w, c)

def sidecar(lfi):
    p = lfi[:-4] + ".json"
    if not os.path.exists(p):
        return []
    j = json.load(open(p))
    rh = j.get("recipe_hint") or {}
    if rh:
        o = ["--as-shot-kelvin", str(rh["asShotKelvin"]), "--as-shot-tint", str(rh["asShotTint"])]
        if rh.get("captureISO"):
            o += ["--iso", str(int(rh["captureISO"]))]
        return o
    a = j.get("as_shot") or {}
    if a:
        return ["--as-shot-kelvin", str(a["kelvin"]), "--as-shot-tint", str(a["tint"])]
    return []

def render(binpath, lfi, out, sets=(), long_edge=None, dither=False, cache=True):
    if cache and os.path.exists(out):
        return out
    cmd = [binpath, "render", "--input", lfi, "--out", out] + sidecar(lfi)
    if not dither:
        cmd.append("--no-dither")
    for s in sets:
        cmd += ["--set", s]
    if long_edge is not None:
        cmd += ["--long-edge", str(long_edge)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(" ".join(cmd) + "\n" + r.stderr + r.stdout)
    return out

def key(b, comp):
    return f"develop.mixer.bands.{b}.{comp}"

def verdict(ok):
    return "PASS" if ok else "FAIL"
