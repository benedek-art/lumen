"""Shared helpers for the WS-41 (vignette) measurements. python3 + numpy + PIL only.

Every script renders through `lumen-render` (the CPU reference) and reads its 8-bit sRGB
PNG. BIN: $LUMEN_RENDER, else .build/*/release/lumen-render. Scratch: $WS41_OUT (default
/tmp/ws41). Frames: `frames.py` writes them to $WS41_OUT/frames.
"""
import glob, hashlib, json, os, struct, subprocess, sys
import numpy as np
from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..'))
OUT = os.environ.get('WS41_OUT', '/tmp/ws41')
FRAMES = os.path.join(OUT, 'frames')
os.makedirs(OUT, exist_ok=True)


def binary():
    b = os.environ.get('LUMEN_RENDER')
    if b:
        return b
    c = sorted(glob.glob(os.path.join(ROOT, '.build', '*', 'release', 'lumen-render')))
    if not c:
        sys.exit('lumen-render not built: swift build -c release --product lumen-render')
    return c[0]


def frame(name):
    """A frame by short name: ws41 synthetic (frames.py), corpus/synthetic, or corpus/lfi id."""
    for p in [os.path.join(FRAMES, name + '.lfi'),
              os.path.join(ROOT, 'corpus', 'synthetic', name + '.lfi')]:
        if os.path.exists(p):
            return p
    c = glob.glob(os.path.join(ROOT, 'corpus', 'lfi', name + '_*.lfi'))
    if c:
        return c[0]
    if os.path.exists(name):
        return name
    sys.exit('no frame %r (run frames.py / fetch_corpus.sh)' % name)


def sidecar_args(lfi):
    j = lfi[:-4] + '.json'
    k, t, iso = 6503.7072, 9.77, None
    if os.path.exists(j):
        h = json.load(open(j)).get('recipe_hint', {})
        k, t, iso = h.get('asShotKelvin', k), h.get('asShotTint', t), h.get('captureISO')
    a = ['--as-shot-kelvin', str(k), '--as-shot-tint', str(t)]
    if iso:
        a += ['--iso', str(int(iso))]
    return a


def render(lfi, sets=(), long_edge=768, dither=False, tag=None, metrics=False):
    """Render; return (uint8 HxWx3 array, metrics dict or None)."""
    tag = tag or hashlib.sha1(repr((lfi, sorted(sets), long_edge, dither)).encode()).hexdigest()[:16]
    png = os.path.join(OUT, 'r_' + tag + '.png')
    cmd = [binary(), 'render', '--input', lfi, '--long-edge', str(long_edge), '--out', png]
    cmd += sidecar_args(lfi)
    for s in sets:
        cmd += ['--set', s]
    if not dither:
        cmd.append('--no-dither')
    mj = None
    if metrics:
        mj = png[:-4] + '.json'
        cmd += ['--metrics', mj]
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout).strip().splitlines()[-1])
    img = np.asarray(Image.open(png).convert('RGB'))
    return img, (json.load(open(mj)) if mj else None)


def write_lfi(path, a):
    h, w, _ = a.shape
    with open(path, 'wb') as f:
        f.write(b'LFI1' + struct.pack('<III', w, h, 3))
        f.write(np.ascontiguousarray(a, dtype='<f4').tobytes())
    json.dump({'recipe_hint': {'asShotKelvin': 6503.7072, 'asShotTint': 9.77,
                               'captureISO': None}}, open(path[:-4] + '.json', 'w'))


def read_lfi(path):
    w, h, c = struct.unpack('<III', open(path, 'rb').read(16)[4:])
    return np.fromfile(path, dtype='<f4', offset=16).reshape(h, w, 3)


def oklab(img8):
    c = img8.astype(float) / 255
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    l = np.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m = np.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s = np.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return L, A, B


_CAL = None


def calibration():
    """code(EV) for a 0.18 neutral through the default pipeline, undithered: the green
    code of a scene-linear ramp 0.18*2^ev, ev in [-7, +4]. The vignette is a scene-linear
    multiply at S13 and the default recipe's S6-S12 are identities, so a flat 0.18 frame's
    output code inverts to the EV the vignette applied there (verified against today's
    analytic falloff by `profile.py --selftest`)."""
    global _CAL
    if _CAL is None:
        p = os.path.join(FRAMES, 'cal_ramp.lfi')
        os.makedirs(FRAMES, exist_ok=True)
        ev = np.linspace(-7, 4, 2048)
        if not os.path.exists(p):
            write_lfi(p, np.repeat((0.18 * 2 ** ev)[None, :, None], 4, 0).repeat(3, 2))
        img, _ = render(p, long_edge=2048, tag='cal_ramp')
        code = img[1, :, 1].astype(float)
        _CAL = (ev, code)
    return _CAL


def ev_of(codes):
    """Inverse calibration: 8-bit green code(s) of a flat 0.18 frame -> applied EV."""
    ev, code = calibration()
    # first index per code value, linear interpolation between code-level midpoints
    u, idx = np.unique(code, return_index=True)
    centres = np.array([ev[code == v].mean() for v in u])
    return np.interp(np.asarray(codes, float), u, centres)


def parse_sets(items):
    return [s for s in (items or [])]
