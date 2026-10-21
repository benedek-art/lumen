"""Finding 6: parametric curve shape analysis (exact port of bakeParametric)."""
import numpy as np, sys; sys.path.insert(0, '.')
from curvelib import bake_parametric, region_centres
from plot import plot
x = np.linspace(0, 1, 1024)
names = ['shadows', 'darks', 'lights', 'highlights']
cols = [(0, 0, 200), (0, 150, 0), (200, 120, 0), (200, 0, 0)]
print('default centres', region_centres([.25, .5, .75]))
for k in names:
    peaks = []
    for v in (-100, -50, 50, 100):
        y, sc = bake_parametric(**{k: v})
        d = y - x
        i = np.argmax(np.abs(d))
        sl = np.diff(y) * 1023
        d2 = np.diff(y, 2) * 1023 ** 2
        peaks.append(f'{v:+d}: peak {d[i]*255:+6.1f} codes @x={x[i]:.3f}, min slope {sl.min():.3f}, max |y\'\'| {np.abs(d2).max():6.1f}, scale {sc:.3f}')
    print(k, '\n   ' + '\n   '.join(peaks))
    # zone (decile) mean shift at +100
    y, _ = bake_parametric(**{k: 100})
    print('   +100 shift by input decile (codes):', [round(float(((y - x)[(x >= a) & (x < a + .1)]).mean() * 255), 1) for a in np.arange(0, 1, .1)])
# dead ranges: consecutive integer slider values giving identical baked curve (to 8-bit everywhere)
for k in names:
    prev = None; dead = []
    for v in range(-100, 101):
        y, _ = bake_parametric(**{k: v})
        q = np.round(y * 255 * 16)
        if prev is not None and np.array_equal(q, prev): dead.append(v)
        prev = q
    # also linearity of response: peak displacement vs slider
    pk = [np.abs(bake_parametric(**{k: v})[0] - x).max() * 255 for v in (25, 50, 75, 100)]
    print(f'{k}: identical (1/16 code) neighbours {dead[:10]}{"..." if len(dead)>10 else ""} count {len(dead)}; peak codes at 25/50/75/100 = {[round(p,1) for p in pk]}')
# combination
for combo in ({'highlights': -100, 'shadows': 100}, {'shadows': 100, 'darks': -100}, {'lights': 100, 'highlights': -100},
              {'highlights': 100, 'lights': 100, 'darks': 100, 'shadows': 100}):
    y, sc = bake_parametric(**combo)
    sl = np.diff(y) * 1023
    print(combo, f'scale {sc:.3f} min slope {sl.min():.4f} at x={x[np.argmin(sl)]:.3f} max slope {sl.max():.2f} peak {(np.abs(y-x)).max()*255:.1f}')
# kinks: second derivative discontinuity at region centres (raised-cosine crossfade has zero slope at pivots -> C1, but envelope*flat region)
for k in names:
    y, _ = bake_parametric(**{k: 100})
    d2 = np.diff(y, 2) * 1023 ** 2
    d3 = np.abs(np.diff(d2))
    idx = np.argsort(d3)[-3:]
    print(k, '+100 largest jumps in y\'\' at x =', [round(float(x[i + 1]), 3) for i in idx], 'size', [round(float(d3[i]), 1) for i in idx])
# splits
for sp in ([.25, .5, .75], [.1, .5, .9], [.4, .5, .6], [.1, .2, .3]):
    out = []
    for k in names:
        y, _ = bake_parametric(**{k: 100, 'splits': sp})
        d = (y - x) * 255; i = np.argmax(np.abs(d))
        sup = x[np.abs(d) > 1]
        out.append(f'{k} peak {d[i]:+.1f}@{x[i]:.2f} support(>1 code) [{sup.min():.2f},{sup.max():.2f}]')
    print('splits', sp, '; '.join(out))
# plots
ser = []
for j, k in enumerate(names):
    for v in (-100, 100):
        y, _ = bake_parametric(**{k: v}); ser.append((x, y, cols[j]))
ser.append((x, x, (0, 0, 0)))
plot(ser, 'm6_param_curves.png', yr=(0, 1), title='parametric curves, each region +/-100 alone (default splits)', labels=['shadows +/-', '', 'darks', '', 'lights', '', 'highlights'])
ser = []
for j, k in enumerate(names):
    for v in (-100, 100):
        y, _ = bake_parametric(**{k: v}); ser.append((x[1:], np.diff(y) * 1023, cols[j]))
plot(ser, 'm6_param_slopes.png', yr=(0, 2.2), title="parametric slope y'(x), each region +/-100", labels=['shadows', '', 'darks', '', 'lights', '', 'highlights'])
