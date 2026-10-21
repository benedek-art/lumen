"""Thin lumen-render driver for WS-03 measurements (tooling).

Colours are measured on the 8-bit output PNG WITH the default ordered dither, averaged over the whole
(uniform) image, which recovers the undithered value to ~1/64 code. Display OKLab / CIELAB are computed
from the mean of the sRGB-decoded pixels."""
import os, sys, json, subprocess, tempfile
import numpy as np
from PIL import Image
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'proof'))
from decode_raw import write_lfi, read_lfi  # noqa: E402
BIN = os.environ.get('LUMEN_RENDER') or os.path.join(ROOT, '.build', 'x86_64-unknown-linux-gnu', 'release', 'lumen-render')
TMP = tempfile.mkdtemp(prefix='ws03_')
SRGB_TO_XYZ = np.array([[0.4124564, 0.3575761, 0.1804375], [0.2126729, 0.7151522, 0.0721750], [0.0193339, 0.1191920, 0.9503041]])
OK1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929], [0.2119034982, 0.6806995451, 0.1073969566], [0.0883024619, 0.2817188376, 0.6299787005]])
OK2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099], [0.0259040371, 0.7827717662, -0.8086757660]])

def lin(code): c = code / 255.0; return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
def png_mean_linear(path, box=None):
    im = np.asarray(Image.open(path).convert('RGB')).astype(float)
    if box: x, y, w, h = box; im = im[y:y + h, x:x + w]
    return lin(im.reshape(-1, 3)).mean(0)
def oklab_srgb(linrgb): return OK2 @ np.cbrt(OK1 @ linrgb)
def cielab_srgb(linrgb):
    xyz = SRGB_TO_XYZ @ linrgb; wp = SRGB_TO_XYZ @ np.ones(3)
    f = lambda t: np.where(t > (6 / 29) ** 3, np.cbrt(t), t / (3 * (6 / 29) ** 2) + 4 / 29)
    fx, fy, fz = f(xyz / wp); return np.array([116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)])

def lfi_const(rgb, n=64, name=None):
    p = os.path.join(TMP, name or 'c.lfi'); write_lfi(p, np.tile(np.asarray(rgb, np.float32), (n, n, 1))); return p

def render(lfi, asshot, temp=None, tint=None, out=None, long_edge=None, extra=()):
    out = out or os.path.join(TMP, 'r.png')
    cmd = [BIN, 'render', '--input', lfi, '--as-shot-kelvin', repr(float(asshot[0])), '--as-shot-tint', repr(float(asshot[1])), '--out', out]
    if temp is not None: cmd += ['--set', f'develop.raw.temp={float(temp)!r}']
    if tint is not None: cmd += ['--set', f'develop.raw.tint={float(tint)!r}']
    if long_edge: cmd += ['--long-edge', str(long_edge)]
    cmd += list(extra)
    subprocess.run(cmd, check=True, capture_output=True)
    return out

def sweep(lfi, asshot, key, values, out, metrics, tiles, sets=(), long_edge=768, columns=6):
    cmd = [BIN, 'sweep', '--input', lfi, '--as-shot-kelvin', repr(float(asshot[0])), '--as-shot-tint', repr(float(asshot[1])),
           '--key', key, '--values', ','.join(repr(float(v)) for v in values), '--long-edge', str(long_edge),
           '--columns', str(columns), '--out', out, '--metrics', metrics, '--tiles-dir', tiles]
    for s in sets: cmd += ['--set', s]
    subprocess.run(cmd, check=True, capture_output=True)
    return json.load(open(metrics))

def sidecar_asshot(lfi):
    h = json.load(open(lfi[:-4] + '.json'))['recipe_hint']; return (h['asShotKelvin'], h['asShotTint'])
