"""WS-14 shared helpers: LFI read/write, PNG -> linear / log / encoded luminance, OKLab,
regression gain, box blur, and the fixed geometry of the WS-14 probe frames.
Self-contained: Python 3 + numpy + Pillow only."""
import os, struct
import numpy as np
from PIL import Image

# ---------------------------------------------------------------- LFI I/O
def write_lfi(path, rgb):
    rgb = np.ascontiguousarray(rgb, dtype="<f4")
    h, w, c = rgb.shape
    assert c == 3
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".part"
    with open(tmp, "wb") as f:
        f.write(b"LFI1")
        f.write(struct.pack("<III", w, h, c))
        f.write(rgb.tobytes())
    os.replace(tmp, path)

def read_lfi(path):
    with open(path, "rb") as f:
        assert f.read(4) == b"LFI1", path
        w, h, c = struct.unpack("<III", f.read(12))
        a = np.frombuffer(f.read(w * h * c * 4), dtype="<f4")
    return a.reshape(h, w, c)

# sRGB(linear) -> Rec.2020(linear), D65 (the renderer's input convention)
SRGB_TO_REC2020 = np.array([[0.6274039, 0.3292830, 0.0433131],
                            [0.0690973, 0.9195404, 0.0113623],
                            [0.0163914, 0.0880133, 0.8955953]])

# ---------------------------------------------------------------- PNG analysis
def load(path):
    return np.asarray(Image.open(path).convert("RGB")).astype(np.float64)

def lin(c):
    v = c / 255.0
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)

def Y(img):
    l = lin(img)
    return 0.2126 * l[..., 0] + 0.7152 * l[..., 1] + 0.0722 * l[..., 2]

def enc(y):
    v = np.where(y <= 0.0031308, 12.92 * y, 1.055 * np.power(np.maximum(y, 0), 1 / 2.4) - 0.055)
    return v * 255

def encY(img):
    """encoded luma in codes 0..255 (sRGB transfer of linear Y)"""
    return enc(Y(img))

def logY(img):
    return np.log2(np.maximum(Y(img), 1e-5))

_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]])
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])

def oklab(img):
    return np.cbrt(lin(img) @ _M1.T) @ _M2.T

def gain(out, ref, mask=None):
    """regression gain of out onto ref (both zero-meaned within mask)"""
    if mask is not None:
        out, ref = out[mask], ref[mask]
    o = out - out.mean(); r = ref - ref.mean()
    return float((o * r).sum() / max((r * r).sum(), 1e-12))

def box(a, r):
    """separable box mean, radius r, edge-replicated"""
    if r <= 0:
        return a.copy()
    p = np.pad(a, ((0, 0), (r + 1, r)), mode="edge")
    c = np.cumsum(p, 1); a1 = (c[:, 2 * r + 1:] - c[:, :-2 * r - 1]) / (2 * r + 1)
    p = np.pad(a1, ((r + 1, r), (0, 0)), mode="edge")
    c = np.cumsum(p, 0); return (c[2 * r + 1:] - c[:-2 * r - 1]) / (2 * r + 1)

def lowpass(a, r):
    """three box passes ~ Gaussian of sigma ~ r*sqrt((2r+1)^2-1)/sqrt(12)*..."""
    return box(box(box(a, r), r), r)

def render_name(d, p, n):
    return os.path.join(d, f"{p}_{n}.png")

# ---------------------------------------------------------------- probe geometry (shared with gen_frames.py)
STEPS_EV = (0.5, 1.0, 2.0, 3.0, 6.0)        # steps_6000: one horizontal strip per step, edge at x = W/2
SKIN = dict(W=6000, H=1200,
            pore_region=(200, 100, 3800, 1100),       # x0, y0, x1, y1 (no lashes, no lip)
            lash_x0=4100, lash_pitch=30, lash_n=25, lash_w=3, lash_y=(100, 600),
            lip_y=900, lip_x=(4000, 6000))
BLOBS = [(15, 1.0), (15, -1.0), (30, 1.0), (30, -1.0), (60, 1.0), (60, -1.0), (120, 1.0), (120, -1.0)]
