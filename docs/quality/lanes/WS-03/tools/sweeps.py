"""SPEC 5 (monotone sweeps), 6 (clipping) and the evidence sheets.

Temp sweep (Tint as shot) and Tint sweep (Temp = as-shot K) on 2 synthetic + 6 real frames at
--long-edge 768. Per tile: whole-frame mean display OKLab a/b (from the dithered tile PNG) and the
lumen-render clipping metrics. Checks: b non-decreasing with Temp, a non-decreasing with Tint (tolerance
5e-4; the 2000 K tile is printed but excluded, see SPEC.md note N3); clipping per tile vs tools/baseline_sweeps.json (the pre-WS-03 binary, same values).
  python3 docs/quality/lanes/WS-03/tools/sweeps.py [--out DIR] [--write-baseline]"""
import sys, os, json, glob
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import numpy as np
from lr import ROOT, sweep, sidecar_asshot, png_mean_linear, oklab_srgb, TMP

FRAMES = ['synthetic/flat_grey', 'synthetic/skin_tones', 'lfi/6929_sony-ilce-7m4', 'lfi/2545_panasonic-dmc-gx85',
          'lfi/1346_canon-eos-5d', 'lfi/983_canon-eos-5d-mark-iv', 'lfi/3914_fujifilm-x-t4', 'lfi/864_fujifilm-x-t2']
TEMPS = [2000, 2500, 3200, 4000, 5000, 6500, 8000, 12000, 20000, 50000]
TINTS = [-150, -100, -50, -25, 25, 50, 100, 150]
HI_TOL, LO_TOL, MONO_TOL = 0.5, 1.0, 5e-4   # percentage points, percentage points, OKLab

def run(out):
    res = {}
    for f in FRAMES:
        lfi = os.path.join(ROOT, 'corpus', f + '.lfi'); a = sidecar_asshot(lfi); tag = f.split('/')[1].split('_')[0]
        for key, vals, sets, comp in (('develop.raw.temp', sorted(set(TEMPS + [a[0]])), [], 2),
                                      ('develop.raw.tint', sorted(set(TINTS + [a[1]])), [f'develop.raw.temp={a[0]!r}'], 1)):
            name = f'{tag}_{key.split(".")[-1]}'; tiles = os.path.join(out, name + '_tiles'); os.makedirs(tiles, exist_ok=True)
            m = sweep(lfi, a, key, vals, os.path.join(out, name + '.png'), os.path.join(out, name + '.json'), tiles, sets)
            rows = []
            for i, t in enumerate(m['tiles']):
                lab = oklab_srgb(png_mean_linear(glob.glob(os.path.join(tiles, f'tile_{i}_*.png'))[0]))
                c = t['metrics']['clipping']
                rows.append(dict(value=t['value'], a=float(lab[1]), b=float(lab[2]),
                                 hi=c['highlightsPct']['any'], lo=c['shadowsPct']['any']))
            res[name] = dict(component=comp, rows=rows)
    return res

if __name__ == '__main__':
    out = sys.argv[sys.argv.index('--out') + 1] if '--out' in sys.argv else os.path.join(TMP, 'sweeps')
    os.makedirs(out, exist_ok=True); res = run(out)
    if '--write-baseline' in sys.argv:
        json.dump(res, open(os.path.join(HERE, 'baseline_sweeps.json'), 'w'), indent=1); print('baseline written')
    base = json.load(open(os.path.join(HERE, 'baseline_sweeps.json')))
    mono_fail = []; clip_fail = []; worst_hi = worst_lo = 0
    for name, r in res.items():
        comp = 'b' if r['component'] == 2 else 'a'; s = [x[comp] for x in r['rows'] if x['value'] != 2000]
        drops = [s[i] - s[i + 1] for i in range(len(s) - 1)]
        if max(drops) > MONO_TOL: mono_fail.append((name, round(max(drops), 4)))
        bmap = {x['value']: x for x in base[name]['rows']}
        for x in r['rows']:
            b = bmap.get(x['value'])
            if not b: continue
            dh, dl = x['hi'] - b['hi'], x['lo'] - b['lo']; worst_hi = max(worst_hi, dh); worst_lo = max(worst_lo, dl)
            if dh > HI_TOL or dl > LO_TOL: clip_fail.append((name, x['value'], round(dh, 2), round(dl, 2)))
        print(f"{name:16s} {comp}: " + ' '.join(f"{x[comp]:+.4f}" for x in r['rows']) + f" | hi% max {max(x['hi'] for x in r['rows']):.2f} lo% max {max(x['lo'] for x in r['rows']):.2f}")
    print('SPEC-5 monotone:', 'PASS' if not mono_fail else f'FAIL {mono_fail}')
    print(f'SPEC-6 clipping vs baseline: worst +{worst_hi:.2f} pp highlights, +{worst_lo:.2f} pp shadows ->', 'PASS' if not clip_fail else f'FAIL {clip_fail}')
    print('sheets in', out)
