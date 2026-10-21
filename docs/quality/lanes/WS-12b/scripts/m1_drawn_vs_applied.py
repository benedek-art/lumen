"""Finding 1: drawn vs applied on grey_ramp continuous rows (0..199)."""
import json, sys, os
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(__file__))
from curvelib import MonotoneCubic, bake_parametric, master

D = os.path.join(os.path.dirname(__file__), 'r1')
R = os.path.join(os.path.dirname(__file__), 'recipes')


def load(name):
    a = np.asarray(Image.open(os.path.join(D, name + '.png')).convert('RGB')).astype(float)
    return a[0:200, :, 1]  # continuous rows, G channel (neutral)


def x_exact():
    # dithered 65 render, average over 192 rows (24 full Bayer periods), then 8-col box -> sub-code precision
    a = load('none_65_d')[0:192].mean(axis=0) / 255
    k = np.ones(9) / 9
    sm = np.convolve(np.pad(a, 4, mode='edge'), k, mode='valid')
    return sm


def curve_for(name):
    rec = json.load(open(os.path.join(R, name + '.json')))['develop']['curve']
    pt = rec.get('point')
    par = None
    if 'parametric' in rec:
        p = rec['parametric']
        par, sc = bake_parametric(p.get('highlights', 0), p.get('lights', 0), p.get('darks', 0),
                                  p.get('shadows', 0), p.get('splits', [.25, .5, .75]))
    return lambda x: master(x, pt, par)


x = x_exact()
und = load('none_65_n')[0]
print('reconstruction check: |round(255x) - A65 nodither| max', np.abs(np.round(255 * x) - und).max(),
      'frac exact', np.mean(np.round(255 * x) == und))
# A's own LUT error at 33 vs 65
a33 = load('none_33_n')[0]
print('A33 vs A65 nodither: max code diff', np.abs(a33 - und).max())

rows = []
for c in ['S', 'steep', 'lift', 'hs', 'darks', 'darks_narrow', 'darks_wide']:
    f = curve_for(c)
    ideal = np.round(255 * f(x))
    idealf = 255 * f(x)
    for L in (33, 65):
        b = load(f'{c}_{L}_n')[0]
        e = b - ideal
        bd = load(f'{c}_{L}_d')
        ed = bd - ideal[None, :]
        mean_d = bd[0:192].mean(axis=0) - idealf
        imax = int(np.argmax(np.abs(e)))
        rows.append(dict(curve=c, lut=L, max_nodither=int(np.abs(e).max()), p99_nodither=float(np.percentile(np.abs(e), 99)),
                         mean_abs_nodither=round(float(np.abs(e).mean()), 3),
                         worst_x=round(float(x[imax]), 3), worst_sign=int(np.sign(e[imax])),
                         max_dither_px=int(np.abs(ed).max()), p99_dither_px=float(np.percentile(np.abs(ed), 99)),
                         max_dither_rowmean=round(float(np.abs(mean_d).max()), 2)))
        # error profile by input bin
        bins = np.linspace(0, 1, 11)
        prof = []
        for i in range(10):
            m = (x >= bins[i]) & (x < bins[i + 1])
            prof.append(round(float(np.abs(e[m]).max()) if m.any() else 0, 1))
        rows[-1]['max_err_by_input_decile'] = prof
for r in rows:
    print(json.dumps(r))
json.dump(rows, open(os.path.join(os.path.dirname(__file__), 'm1.json'), 'w'), indent=1)
np.save(os.path.join(os.path.dirname(__file__), 'x_exact.npy'), x)
