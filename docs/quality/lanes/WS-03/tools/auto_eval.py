"""SPEC 12-17: Auto WB, measured through the new `lumen-render autowb` command (SPEC.md, line 12).

  lumen-render autowb --input F.lfi --as-shot-kelvin K --as-shot-tint T [--exclude x,y,w,h ...]
  -> stdout: one JSON object {"kelvin": .., "tint": .., "confidence": .., "seconds": ..}
     (Adobe/DNG convention; `seconds` = time inside AutoWhiteBalance only, file read excluded)

  python3 docs/quality/lanes/WS-03/tools/auto_eval.py [--sheet docs/quality/lanes/WS-03/evidence/after_auto_charts.png]

Chart residuals use charts.py (scene-linear, Adobe-convention matrix, same definition as charts.json)."""
import sys, os, json, subprocess, statistics
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import numpy as np
from lr import BIN, ROOT, TMP, write_lfi, read_lfi, render, sidecar_asshot
from wbmodel import adobe_matrix, oklab, hue_deg
from charts import FRAMES, CHART_MASK, as_shot, chart_neutral, residual, short

def autowb(lfi, a, exclude=None):
    cmd = [BIN, 'autowb', '--input', lfi, '--as-shot-kelvin', repr(float(a[0])), '--as-shot-tint', repr(float(a[1]))]
    if exclude: cmd += ['--exclude', ','.join(map(str, exclude))]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout.strip().splitlines()[-1]
    return json.loads(out), out
def dm(k1, k2): return 1e6 / k1 - 1e6 / k2
def lfi(name): return os.path.join(ROOT, 'corpus', name + '.lfi')

def skin_only():
    js = json.load(open(lfi('synthetic/skin_tones')[:-4] + '.json'))
    pats = [np.array(p['rec2020_linear']) for p in js['truth']['patches']]
    sk = pats[1:8] + pats[10:12]                        # MST 2-8, ColorChecker dark + light skin; no neutral
    im = np.zeros((600, 600, 3), np.float32)
    for i, c in enumerate(sk): r, q = divmod(i, 3); im[r * 200:(r + 1) * 200, q * 200:(q + 1) * 200] = c
    p = os.path.join(TMP, 'skin_only.lfi'); write_lfi(p, im); return p, sk

if __name__ == '__main__':
    R = {}; ok = {}
    # 13/14: chart frames, chart IN and OUT
    rows = []
    for f in FRAMES:
        a = as_shot(f); cn = chart_neutral(f)
        i, _ = autowb(lfi('lfi/' + f), a); o, _ = autowb(lfi('lfi/' + f), a, CHART_MASK[f])
        rows.append(dict(frame=short(f), asShotDE=residual(f, *a), inDE=residual(f, i['kelvin'], i['tint']),
                         outDE=residual(f, o['kelvin'], o['tint']), inDM=dm(i['kelvin'], cn[0]), inDT=i['tint'] - cn[1],
                         auto_in=(round(i['kelvin']), round(i['tint'], 1)), auto_out=(round(o['kelvin']), round(o['tint'], 1)),
                         chartNeutral=(round(cn[0]), round(cn[1], 1))))
    for r in rows:
        print(f"{r['frame']:5s} as-shot dE {r['asShotDE']:5.2f} | chart-neutral {r['chartNeutral']} | IN {r['auto_in']} dE {r['inDE']:5.2f} dMired {r['inDM']:+6.1f} dTint {r['inDT']:+5.1f} | OUT {r['auto_out']} dE {r['outDE']:5.2f}")
    mean = lambda k: sum(r[k] for r in rows) / len(rows)
    ok['13a per-frame IN dE <= max(2.0, asShot+0.3)'] = all(r['inDE'] <= max(2.0, r['asShotDE'] + 0.3) for r in rows)
    ok['13b mean IN dE <= 3.20'] = mean('inDE') <= 3.20
    ok['13c IN |dMired|<=12 & |dTint|<=8 (1346,967,983,864)'] = all(abs(r['inDM']) <= 12 and abs(r['inDT']) <= 8 for r in rows if r['frame'] != '3914')
    ok['14 OUT: each <= asShot+2.5 and mean <= asShot mean+0.5'] = all(r['outDE'] <= r['asShotDE'] + 2.5 for r in rows) and mean('outDE') <= mean('asShotDE') + 0.5
    print(f"mean dE: as-shot {mean('asShotDE'):.2f}  IN {mean('inDE'):.2f}  OUT {mean('outDE'):.2f}")
    # 15: ordinary daylight frames stay near as-shot
    for name in ('lfi/6929_sony-ilce-7m4', 'lfi/2545_panasonic-dmc-gx85'):
        a = sidecar_asshot(lfi(name)); r, _ = autowb(lfi(name), a)
        d = (dm(r['kelvin'], a[0]), r['tint'] - a[1]); print(f'{name}: auto {r["kelvin"]:.0f}/{r["tint"]:+.1f}  dMired {d[0]:+.1f} dTint {d[1]:+.1f}')
        ok[f'15 {name[4:8]} |dMired|<=15 & |dTint|<=10'] = abs(d[0]) <= 15 and abs(d[1]) <= 10
    # 16: skin
    a = sidecar_asshot(lfi('synthetic/skin_tones')); r, _ = autowb(lfi('synthetic/skin_tones'), a)
    d = (dm(r['kelvin'], a[0]), r['tint'] - a[1]); print(f'skin_tones: dMired {d[0]:+.2f} dTint {d[1]:+.2f}')
    ok['16a skin_tones |dMired|<=3 & |dTint|<=3'] = abs(d[0]) <= 3 and abs(d[1]) <= 3
    p, sk = skin_only(); r, _ = autowb(p, a); M = adobe_matrix(a, (r['kelvin'], r['tint']))
    c0 = np.mean([np.hypot(*oklab(c)[1:]) for c in sk]); c1 = np.mean([np.hypot(*oklab(M @ c)[1:]) for c in sk])
    dh = max(abs((hue_deg(oklab(M @ c)) - hue_deg(oklab(c)) + 180) % 360 - 180) for c in sk if np.hypot(*oklab(c)[1:]) >= 0.03)
    d = (dm(r['kelvin'], a[0]), r['tint'] - a[1])
    print(f'skin_only: auto {r["kelvin"]:.0f}/{r["tint"]:+.1f} dMired {d[0]:+.1f} dTint {d[1]:+.1f}  chroma kept {c1 / c0:.2f}  max |dHue| {dh:.1f}')
    ok['16b skin_only |dMired|<=12 & |dTint|<=6, chroma kept >=0.80, max|dHue|<=8 (patches C>=0.03)'] = abs(d[0]) <= 12 and abs(d[1]) <= 6 and c1 / c0 >= 0.80 and dh <= 8
    # 17: neutral frame -> as-shot; determinism; time
    r, _ = autowb(lfi('synthetic/flat_grey'), (4000, 5)); d = (dm(r['kelvin'], 4000), r['tint'] - 5)
    print(f'flat_grey @4000/+5: dMired {d[0]:+.3f} dTint {d[1]:+.3f}')
    ok['17a neutral frame returns as-shot (|dMired|,|dTint| <= 0.1)'] = abs(d[0]) <= 0.1 and abs(d[1]) <= 0.1
    f = lfi('lfi/6929_sony-ilce-7m4'); a = sidecar_asshot(f); runs = [autowb(f, a) for _ in range(5)]
    outs = {json.dumps([x[0]['kelvin'], x[0]['tint']]) for x in runs}; t = statistics.median(x[0]['seconds'] for x in runs)
    print(f'6929 x5: distinct results {len(outs)}; median seconds {t:.3f}')
    ok['17b deterministic (5 identical runs)'] = len(outs) == 1
    ok['17c median time <= 0.25 s on 2400x1600'] = t <= 0.25
    for k, v in ok.items(): print('PASS' if v else 'FAIL', k)
    if '--sheet' in sys.argv:
        from PIL import Image
        out = sys.argv[sys.argv.index('--sheet') + 1]; tiles = []
        for f in ('3914_fujifilm-x-t4', '864_fujifilm-x-t2', '967_sony-ilce-7m2'):
            a = as_shot(f); i, _ = autowb(lfi('lfi/' + f), a); cn = chart_neutral(f); row = []
            for tag, wb in (('asshot', (None, None)), ('auto', (i['kelvin'], i['tint'])), ('chartneutral', cn)):
                row.append(Image.open(render(lfi('lfi/' + f), a, wb[0], wb[1], out=os.path.join(TMP, f'{f}_{tag}.png'), long_edge=440)).convert('RGB'))
            tiles.append(row)
        w, h = tiles[0][0].size; sheet = Image.new('RGB', (3 * w, sum(r[0].size[1] for r in tiles)), 'white'); y = 0
        for row in tiles:
            for j, im in enumerate(row): sheet.paste(im, (j * w, y))
            y += row[0].size[1]
        sheet.save(out, optimize=True); print('sheet (columns: as-shot | Auto | chart-neutral; rows 3914, 864, 967) ->', out)
