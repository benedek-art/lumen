#!/usr/bin/env python3
"""WS-32 / WS-33 measurements (quality lane K3). Every number in SPEC.md and REPORT.md.

    python3 docs/quality/lanes/WS-32/tools/measure.py --bin NEW_lumen-render \
        [--base-bin BASE_lumen-render] --work /tmp/k3 [--evidence docs/quality/lanes]

Needs numpy, Pillow, scipy and the corpus (scripts/proof/fetch_corpus.sh,
scripts/proof/gen_synthetic.py). With --base-bin, every line is measured on both builds.
"""
import argparse, json, os, struct, subprocess, sys
import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../../..'))
LFI = os.path.join(ROOT, 'corpus/lfi')
SYN = os.path.join(ROOT, 'corpus/synthetic')

# ---- io ---------------------------------------------------------------------------
def read_lfi(p):
    b = open(p, 'rb').read(); w, h, c = struct.unpack('<III', b[4:16])
    return np.frombuffer(b[16:], dtype='<f4').reshape(h, w, 3).copy()

def write_lfi(p, a):
    a = np.ascontiguousarray(a, dtype='<f4'); h, w, _ = a.shape
    open(p, 'wb').write(b'LFI1' + struct.pack('<III', w, h, 3) + a.tobytes())

def load(p): return np.asarray(Image.open(p).convert('RGB')).astype(np.float64)

def render(binary, inp, recipe, out, long_edge, extra=()):
    rp = out + '.json'; json.dump(recipe, open(rp, 'w'))
    cmd = [binary, 'render', '--input', inp, '--recipe', rp, '--out', out, '--no-dither',
           '--long-edge', str(long_edge), *extra]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode: sys.exit(r.stderr)
    return load(out)

# ---- colour -------------------------------------------------------------------------
M1S = np.array([[0.4122214708, 0.5363325363, 0.0514459929], [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468], [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])
def srgb8_to_oklab(rgb8):
    c = np.asarray(rgb8, dtype=np.float64) / 255.0
    lin = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    return np.cbrt(lin @ M1S.T) @ M2.T

def chroma(lab): return np.hypot(lab[..., 1], lab[..., 2])

def hue(lab): return np.degrees(np.arctan2(lab[..., 2], lab[..., 1])) % 360

def rec2020_to_xyz():
    def xyz(x, y): return np.array([x / y, 1, (1 - x - y) / y])
    P = np.stack([xyz(.708, .292), xyz(.170, .797), xyz(.131, .046)], 1)
    return P * np.linalg.solve(P, xyz(.3127, .3290))
M1X = np.array([[0.8189330101, 0.3618667424, -0.1288597137], [0.0329845436, 0.9293118715, 0.0361456387],
                [0.0482003018, 0.2643662691, 0.6338517070]])
LIN_OPP = M2 @ M1X @ rec2020_to_xyz()        # working rgb -> linear opponent (L, a, b)

def swatch(sample, l=0, s=0, h=0, rng=50, var=0, **refine):
    d = {"sample": [float(v) for v in sample], "range": rng, "variance": var,
         "shift": {"h": h, "s": s, "l": l}}
    d.update(refine); return d

def point_recipe(*swatches): return {"develop": {"pointColors": list(swatches)}}

# ---- WS-32 S5: frame 2062, a petal's soft edge under Saturation -100 -----------------
def petal_rim(bins, work):
    src = read_lfi(os.path.join(LFI, '2062_canon-eos-kiss-x9.lfi'))[1050:1550, 1350:2050]
    inp = os.path.join(work, 'c2062.lfi'); write_lfi(inp, src)
    ex = ['--iso', '6400', '--as-shot-kelvin', '3841.6', '--as-shot-tint', '12.69']
    petal = src[96:105, 446:455].reshape(-1, 3).mean(0)
    plate = src[196:205, 296:305].reshape(-1, 3).mean(0)
    v = plate - petal
    alpha = 1 - np.clip(((src - petal) @ v) / (v @ v), 0, 1)
    resid = np.linalg.norm(src - (petal + (1 - alpha)[..., None] * v), axis=-1) / np.linalg.norm(v)
    band = (resid < 0.08) & (alpha > 0.3) & (alpha < 0.7)
    out = {}
    for name, b in bins.items():
        ident = render(b, inp, point_recipe(), os.path.join(work, f'2062_id_{name}.png'), 700, ex)
        sat = render(b, inp, point_recipe(swatch(petal, s=-100)),
                     os.path.join(work, f'2062_sat_{name}.png'), 700, ex)
        lum = render(b, inp, point_recipe(swatch(petal, l=-80)),
                     os.path.join(work, f'2062_lum_{name}.png'), 700, ex)
        c0 = chroma(srgb8_to_oklab(ident)); c1 = chroma(srgb8_to_oklab(sat))
        core = alpha > 0.95
        out[name] = dict(rim_chroma_left=float((c1[band] / np.maximum(c0[band], 1e-6)).mean()),
                         core_chroma_left=float((c1[core] / np.maximum(c0[core], 1e-6)).mean()),
                         band_px=int(band.sum()))
    return out

# ---- WS-32 S6: frame 2348, the satin stripe under Luminance -80 ---------------------
def stripe_holes(bins, work):
    src = read_lfi(os.path.join(LFI, '2348_panasonic-dc-g9.lfi'))[700:1100, 700:1400]
    inp = os.path.join(work, 'c2348.lfi'); write_lfi(inp, src)
    ex = ['--iso', '3200', '--as-shot-kelvin', '3376.5', '--as-shot-tint', '0.79']
    red = gaussian_filter(src[..., 0] / (src.sum(-1) + 1e-6), 2)
    y, x = np.unravel_index(np.argmax(red), red.shape)
    sample = src[y - 3:y + 4, x - 3:x + 4].reshape(-1, 3).mean(0)
    # The stripe: pixels whose linear opponent chroma points within 25 deg of the
    # sample's and carries at least 40% of it - the red, its sheen and its shadow.
    chi = (src @ LIN_OPP.T)[..., 1:]; ct = (sample @ LIN_OPP.T)[1:]
    share = (chi @ ct) / (ct @ ct)
    ang = np.degrees(np.abs(np.arctan2(chi[..., 1], chi[..., 0]) - np.arctan2(ct[1], ct[0])))
    ang = np.minimum(ang, 360 - ang)
    stripe = gaussian_filter(((share > 0.4) & (ang < 25)).astype(float), 1.5) > 0.9
    out = {}
    for name, b in bins.items():
        ident = render(b, inp, point_recipe(), os.path.join(work, f'2348_id_{name}.png'), 700, ex)
        lum = render(b, inp, point_recipe(swatch(sample, l=-80)),
                     os.path.join(work, f'2348_lum_{name}.png'), 700, ex)
        L0 = srgb8_to_oklab(ident)[..., 0]; L1 = srgb8_to_oklab(lum)[..., 0]
        drop = (L0 - L1) / np.maximum(L0, 1e-3)
        full = np.percentile(drop[stripe], 90)
        out[name] = dict(holes_pct=float(100 * (drop[stripe] < 0.5 * full).mean()),
                         stripe_px=int(stripe.sum()))
    return out

# ---- WS-32 S8: blotchy skin, Variance ----------------------------------------------
def skin(bins, work):
    rng = np.random.default_rng(3); H, W = 500, 800
    S2R = np.array([[0.6274039, 0.32928304, 0.04331307], [0.06909729, 0.9195404, 0.01136232],
                    [0.01639144, 0.08801331, 0.89559525]])
    def lin(c): c = np.asarray(c) / 255; return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4) @ S2R.T
    f = gaussian_filter(rng.standard_normal((H, W)), 30); f = (f - f.mean()) / f.std()
    t = np.clip(0.5 + 0.35 * f, 0, 1)[..., None]
    img = lin([196, 146, 120]) * (1 - t) + lin([200, 120, 110]) * t
    pores = gaussian_filter(rng.standard_normal((H, W)), 1.2); pores /= pores.std()
    img = img * (1 + 0.04 * pores)[..., None] * (1 + 0.01 * rng.standard_normal((H, W, 3)))
    img[:, 700:] = lin([60, 110, 190]); img[400:, :100] = 0.18
    inp = os.path.join(work, 'skin.lfi'); write_lfi(inp, img.astype(np.float32))
    sample = img[20:380, 20:680].reshape(-1, 3).mean(0)
    reg = (slice(20, 380), slice(20, 680))
    def lf(lab):
        a = gaussian_filter(lab[..., 1], 6)[reg]; b = gaussian_filter(lab[..., 2], 6)[reg]
        return np.degrees(np.arctan2(b, a)).std(), np.hypot(a, b).std()
    def hf(lab): L = lab[..., 0]; return (L - gaussian_filter(L, 2.5))[reg].std()
    out = {}
    for name, b in bins.items():
        ident = srgb8_to_oklab(render(b, inp, point_recipe(), os.path.join(work, f'skin_id_{name}.png'), 800))
        ev = srgb8_to_oklab(render(b, inp, point_recipe(swatch(sample, var=-100)),
                                   os.path.join(work, f'skin_v100_{name}.png'), 800))
        (h0, c0), (h1, c1) = lf(ident), lf(ev)
        out[name] = dict(hue_lf_ratio=float(h1 / h0), chroma_lf_ratio=float(c1 / c0),
                         pore_hf_ratio=float(hf(ev) / hf(ident)),
                         blue_max_dE=float(np.abs(ev[50:450, 710:790] - ident[50:450, 710:790]).max()),
                         grey_max_dE=float(np.abs(ev[410:490, 10:90] - ident[410:490, 10:90]).max()))
    return out

# ---- WS-33: the chart under every primaries slider ---------------------------------
def primaries(bins, work):
    cc = os.path.join(SYN, 'colorchecker')
    patches = json.load(open(cc + '.json'))['truth']['patches']
    def patch_lab(png):
        im = load(png); res = {}
        for p in patches:
            x, y, w, h = p['rect']
            res[p['name']] = srgb8_to_oklab(im[y + h // 4:y + h - h // 4, x + w // 4:x + w - w // 4].reshape(-1, 3).mean(0))
        return res
    own = {'r': 'red', 'g': 'green', 'b': 'blue'}
    neutrals = ['white 9.5', 'neutral 8', 'neutral 6.5', 'neutral 5', 'neutral 3.5', 'black 2']
    out = {}
    for name, b in bins.items():
        ident = patch_lab(_r(b, cc, {}, os.path.join(work, f'cc_id_{name}.png')))
        rows = {}
        worst_neutral = 0.0
        for ch in 'rgb':
            for kind in ('Hue', 'Purity'):
                series = []
                for v in range(-100, 101, 20):
                    png = os.path.join(work, f'cc_{ch}{kind}{v}_{name}.png')
                    P = patch_lab(_r(b, cc, {"look": {"primaries": {ch + kind: v}}}, png))
                    lab = P[own[ch]]
                    series.append(float(hue(lab)) if kind == 'Hue' else float(chroma(lab)))
                    for n in neutrals:
                        worst_neutral = max(worst_neutral, float(np.abs(P[n][1:] - ident[n][1:]).max()))
                if kind == 'Hue':
                    h0 = series[5]; series = [h0 + ((s - h0 + 180) % 360) - 180 for s in series]
                steps = np.diff(series)
                rows[ch + kind] = dict(series=[round(s, 4) for s in series],
                                       dead_steps=int((np.abs(steps) < 0.15 * np.abs(steps).mean()).sum()),
                                       reversals=int((np.sign(steps) != np.sign(steps.sum())).sum()))
        out[name] = dict(rows=rows, worst_neutral_ab_shift=worst_neutral)
    return out

def _r(b, cc, recipe, png):
    render(b, cc + '.lfi', recipe, png, 1368); return png

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--bin', required=True); ap.add_argument('--base-bin')
    ap.add_argument('--work', default='/tmp/k3-measure')
    ap.add_argument('--only', default='rim,stripe,skin,primaries')
    a = ap.parse_args(); os.makedirs(a.work, exist_ok=True)
    bins = {'new': a.bin}
    if a.base_bin: bins = {'base': a.base_bin, 'new': a.bin}
    res = {}
    for k, f in [('rim', petal_rim), ('stripe', stripe_holes), ('skin', skin), ('primaries', primaries)]:
        if k in a.only.split(','): res[k] = f(bins, a.work)
    print(json.dumps(res, indent=1))
