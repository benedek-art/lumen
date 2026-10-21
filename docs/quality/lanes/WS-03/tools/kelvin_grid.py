"""SPEC 3 (Kelvin accuracy) and SPEC 9 (presets), measured through lumen-render.

For every as-shot A and target illuminant L (Adobe/DNG K, tint): a uniform 64 px frame holding a
Y=0.18 neutral lit by L and decoded at A (wbmodel.decoded_grey) is rendered with develop.raw.temp/tint
set to L's Adobe numbers. CIEDE2000 of the display output vs the neutral of the same L*.
  python3 docs/quality/lanes/WS-03/tools/kelvin_grid.py [--json out.json]"""
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from wbmodel import decoded_grey, de2000
from lr import lfi_const, render, png_mean_linear, cielab_srgb

AS = [(2850, 0), (3200, 0), (4000, 5), (4708, 48.2), (5000, 8), (5500, 10), (6503.7072, 9.77), (7500, 10), (9365, 16.4), (5500, -15)]
KS = [2500, 2850, 3200, 3800, 4500, 5500, 6500, 7500, 10000, 15000]
TS = [-20, -10, 0, 10, 21]
PRESETS = [('Daylight', 5500, 10), ('Cloudy', 6500, 10), ('Shade', 7500, 10), ('Tungsten', 2850, 0), ('Fluorescent', 3800, 21), ('Flash', 5500, 0)]

def de_display(asshot, illum):
    p = lfi_const(decoded_grey(illum, asshot))
    lab = cielab_srgb(png_mean_linear(render(p, asshot, illum[0], illum[1])))
    return float(de2000(lab, np.array([lab[0], 0, 0])))

if __name__ == '__main__':
    rows = []
    for a in AS:
        for k in KS:
            for t in TS:
                rows.append(dict(asShot=a, target=(k, t), dE00=de_display(a, (k, t))))
    d = np.array([r['dE00'] for r in rows])
    worst = sorted(rows, key=lambda r: -r['dE00'])[:3]
    print(f'grid {len(rows)} pairs: dE00 median {np.median(d):.3f} p90 {np.percentile(d, 90):.3f} max {d.max():.3f}')
    for r in worst: print('  worst', r)
    pres = {}
    for n, k, t in PRESETS:
        v = [de_display(a, (k, t)) for a in AS]; pres[n] = max(v)
    print('presets (max dE00 over the as-shot set):', {n: round(v, 3) for n, v in pres.items()})
    ok = d.max() < 0.5 and max(pres.values()) < 0.5
    print('SPEC-3/9a', 'PASS' if ok else 'FAIL', '(threshold: every pair and every preset dE00 < 0.5)')
    if '--json' in sys.argv: json.dump(dict(rows=rows, presets=pres), open(sys.argv[sys.argv.index('--json') + 1], 'w'), indent=1)
