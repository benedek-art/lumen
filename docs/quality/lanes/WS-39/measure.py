#!/usr/bin/env python3
"""WS-39 halation acceptance measurements (SPEC.md lines M1-M12).

usage: python3 -I docs/quality/lanes/WS-39/measure.py OUTDIR [--corpus]

Renders through the release lumen-render (`swift build -c release --product lumen-render`
first) with --no-dither, so every number is deterministic. Synthetic frames are written
to OUTDIR; corpus frames are read from corpus/lfi. Prints one line per spec item.
"""
import json, os, subprocess, sys
import numpy as np
from PIL import Image

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..', '..', '..'))
BIN = os.path.join(REPO, '.build/x86_64-unknown-linux-gnu/release/lumen-render')
if not os.path.exists(BIN):
    BIN = os.path.join(REPO, '.build/release/lumen-render')
OUT = os.path.abspath(sys.argv[1])
CORPUS = '--corpus' in sys.argv
os.makedirs(OUT, exist_ok=True)
STOCK = 'lumen/portra400'


def write_lfi(path, a):
    h, w, _ = a.shape
    with open(path, 'wb') as f:
        f.write(b'LFI1' + np.array([w, h, 3], '<u4').tobytes() + a.astype('<f4').tobytes())


def render(inp, out, sets, le=-1, hint=None):
    args = [BIN, 'render', '--input', inp, '--no-dither', '--out', out]
    if le == -1:  # synthetic frames: render at their own size
        hh, ww = np.fromfile(inp, '<u4', 3, offset=4)[1::-1]
        le = int(max(hh, ww))
    args += ['--long-edge', str(le)]
    if hint:
        args += ['--as-shot-kelvin', str(hint[0]), '--as-shot-tint', str(hint[1])]
        if hint[2]:
            args += ['--iso', str(hint[2])]
    for k, v in sets.items():
        args += ['--set', f'{k}={v}']
    subprocess.run(args, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return np.asarray(Image.open(out).convert('RGB')).astype(float)


def lin(c):
    c = c / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def film(amount, size=None, red=None, stock=STOCK):
    s = {'look.filmLab.stock': stock, 'look.filmLab.halation': amount}
    if size is not None:
        s['look.filmLab.halationSize'] = size
    if red is not None:
        s['look.filmLab.halationRedness'] = red
    return s


def disk_frame(name, w, h, value, field=0.01, radius_frac=0.01):
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.hypot(xx - w / 2 + 0.5, yy - h / 2 + 0.5)
    a = np.full((h, w, 3), field, np.float32)
    a[r <= radius_frac * max(w, h)] = value
    p = os.path.join(OUT, name + '.lfi')
    write_lfi(p, a)
    return p


def radial(img, base, w=None, h=None, rdisk=None):
    """Mean added (R,G,B) in display-linear and in codes per 1-px ring outside the disk
    (the disk's radius is 1% of the rendered long edge)."""
    h, w = img.shape[:2]
    rdisk = 0.01 * max(w, h)
    yy, xx = np.mgrid[0:h, 0:w]
    r = np.hypot(xx - w / 2 + 0.5, yy - h / 2 + 0.5)
    ring = np.floor(r - rdisk).astype(int)
    dl = lin(img) - lin(base)
    dc = img - base
    rows = []
    for k in range(1, int(0.12 * max(w, h))):
        m = ring == k
        if not m.any():
            break
        rows.append((k, dl[m].mean(0), dc[m].mean(0)))
    return rows


def halo_stats(rows, le):
    """r2: farthest ring with mean dR >= 2 codes (% of long edge); peak dR codes;
    G/R of the added display-linear light near (ring 2) and far (where dR first drops
    under 25% of its peak)."""
    peak = max(rw[2][0] for rw in rows)
    r2 = max([rw[0] for rw in rows if rw[2][0] >= 2.0] or [0])
    near = rows[1]
    far = next((rw for rw in rows if rw[2][0] < 0.25 * peak), rows[-1])
    gr = lambda rw: rw[1][1] / rw[1][0] if rw[1][0] > 1e-6 else float('nan')
    return dict(r2_pct=100.0 * r2 / le, peak_dR=peak, gr_near=gr(near), gr_far=gr(far),
                far_pct=100.0 * far[0] / le,
                rgb_order=all(rw[1][0] + 1e-5 >= rw[1][1] >= rw[1][2] - 1e-5 for rw in rows[:far[0]]))


res = {}
W, H = 2400, 1600
# --- flat fields: no cast (M2)
for v in (0.18, 0.9, 1.0, 4.0):
    p = os.path.join(OUT, f'flat_{v}.lfi')
    write_lfi(p, np.full((256, 384, 3), v, np.float32))
    b = render(p, p[:-4] + '_a0.png', film(0))
    a = render(p, p[:-4] + '_a100.png', film(100, 2.0, 0))
    res[f'M2 flat {v} max|d| codes (A100 S2 R0)'] = float(np.abs(a - b)[64:-64, 64:-64].max())

# --- midtone / clip-2EV disks on a dark field: no glow (M3)
for v in (0.18, 0.25):
    p = disk_frame(f'disk_{v}', W, H, v)
    b = render(p, p[:-4] + '_a0.png', film(0))
    a = render(p, p[:-4] + '_a100.png', film(100, 2.0, 0))
    res[f'M3 disk {v} on 0.01: max dR codes outside disk (A100 S2)'] = float((a - b)[..., 0].max())

# --- clipped light source (M4-M8)
p = disk_frame('disk_clip', W, H, 1.0)
rd = 0.01 * W
b = render(p, p[:-4] + '_a0.png', film(0))
for tag, sets in (('default', film(35)), ('A100', film(100)), ('A100 S2 R80', film(100, 2.0, 80))):
    a = render(p, p[:-4] + f'_{tag.replace(" ", "_")}.png', sets)
    res[f'M4 clipped disk {tag}'] = halo_stats(radial(a, b, W, H, rd), W)
for s in (0.5, 1.0, 2.0):
    a = render(p, p[:-4] + f'_s{s}.png', film(100, s))
    res[f'M7 size {s} r2%'] = halo_stats(radial(a, b, W, H, rd), W)['r2_pct']
for rr in (0, 50, 100):
    a = render(p, p[:-4] + f'_r{rr}.png', film(100, 1.0, rr))
    res[f'M8 redness {rr} G/R near'] = halo_stats(radial(a, b, W, H, rd), W)['gr_near']
for am in (0, 25, 50, 75, 100):
    a = render(p, p[:-4] + f'_a{am}.png', film(am))
    rows = radial(a, b, W, H, rd)
    res[f'M9 amount {am} sum dR(lin) rings'] = float(sum(rw[1][0] for rw in rows))
# resolution independence (M6): same frame at 800 and 2400
p8 = disk_frame('disk_clip_800', 800, 533, 1.0)
b8 = render(p8, p8[:-4] + '_a0.png', film(0))
a8 = render(p8, p8[:-4] + '_A100.png', film(100))
s8 = halo_stats(radial(a8, b8, 800, 533, 8.0), 800)
res['M6 r2% at 800 / 2400'] = (s8['r2_pct'], res['M4 clipped disk A100']['r2_pct'])
res['M6 far% at 800 / 2400'] = (s8['far_pct'], res['M4 clipped disk A100']['far_pct'])

# --- stock defaults (M10)
from_stock = {}
for st in ('portra400', 'gold200', 'ektar100', 'triX400', 'velvia50', 'cine250D'):
    keys = subprocess.run([BIN, 'keys', '--json'], capture_output=True, text=True)
    sets = {'look.filmLab.stock': 'lumen/' + st}
    a0 = render(p, p[:-4] + f'_{st}_0.png', dict(sets, **{'look.filmLab.halation': 0}))
    # the stock's own default Amount is what the panel's reset value and defaultRecipe use
    dflt = {'portra400': 35, 'gold200': 45, 'ektar100': 15, 'triX400': 20, 'velvia50': 0,
            'cine250D': 30}[st]
    a1 = render(p, p[:-4] + f'_{st}_d.png', dict(sets, **{'look.filmLab.halation': dflt}))
    rows = radial(a1, a0, W, H, rd)
    from_stock[st] = float(sum(np.abs(rw[1]).sum() for rw in rows))
res['M10 stock default halo energy (sum |d| lin)'] = from_stock

if CORPUS:
    regs = {'983 snow interior': ('983_canon-eos-5d-mark-iv', 50, 830, 450, 70),
            '983 chart E1 white': ('983_canon-eos-5d-mark-iv', 1210, 535, 40, 40),
            '2545 sunlit lawn': ('2545_panasonic-dmc-gx85', 200, 700, 500, 150),
            '2545 sky': ('2545_panasonic-dmc-gx85', 1440, 40, 140, 120),
            '3582 white wall': ('3582_nikon-z-6', 20, 100, 220, 500),
            '6929 white wall': ('6929_sony-ilce-7m4', 1240, 820, 300, 150)}
    cache = {}
    for k, (n, x, y, w, h) in regs.items():
        if n not in cache:
            side = json.load(open(os.path.join(REPO, 'corpus/lfi', n + '.json')))
            rh = side.get('recipe_hint', {})
            hint = (rh.get('asShotKelvin', 5500), rh.get('asShotTint', 0), rh.get('captureISO', 0))
            inp = os.path.join(REPO, 'corpus/lfi', n + '.lfi')
            cache[n] = (render(inp, os.path.join(OUT, n + '_a0.png'), film(0), 1600, hint),
                        render(inp, os.path.join(OUT, n + '_a100.png'), film(100), 1600, hint))
        b0, b1 = cache[n]
        res[f'M11 {k} mean dRGB codes A100'] = (b1 - b0)[y:y + h, x:x + w].reshape(-1, 3).mean(0).round(2).tolist()

for k, v in res.items():
    print(f'{k}: {v}')
json.dump(res, open(os.path.join(OUT, 'measure.json'), 'w'), indent=1, default=float)
