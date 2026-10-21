#!/usr/bin/env python3
"""Render every image the WS-15 SPEC measures, into one work directory.

Usage: spec_render.py OUTDIR [--bin PATH] [--jobs N] [--only full,res,sweep,syn,sheet,crops]

Layout written (all renders undithered except where noted):
  OUTDIR/full/<id>_L2400_d<v>.png       v in 0 50 100 -50 -100, plus <id>_L2400_unset.png
                                        (no --set at all: the identity reference)
  OUTDIR/res/<id>_L<e>_d<v>.png          e in 512 2048, v in 0 60 -60
  OUTDIR/sweep/<id>_fine_m.json          512 px sweep -100..100 step 10 (metrics JSON)
  OUTDIR/sweep/<id>_fine_sheet.png       its contact sheet, tiles in <id>_fine_tiles/
  OUTDIR/sheets/<id>_sheet.png           1024 px sheet at -100 -50 -25 0 25 50 100 (visual)
  OUTDIR/syn/<name>_L1024_d<v>.png       colorchecker, hard_edge, grey_ramp; v in 0 50 100 -100,
                                         plus <name>_L1024_unset.png
  OUTDIR/crops/<name>.png                100 % side-by-side crops from full/ (stage 'crops',
                                         runs after the renders; see CROPS below)
Frames: 983 1840 4213 3437 2545 6929 (as-shot WB from the sidecar recipe_hint).
"""
import argparse, json, os, subprocess, sys
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../../../..'))
FRAMES = {
    '983': '983_canon-eos-5d-mark-iv', '1840': '1840_nikon-d850', '4213': '4213_nikon-z-7-2',
    '3437': '3437_canon-eos-rebel-t7i', '2545': '2545_panasonic-dmc-gx85', '6929': '6929_sony-ilce-7m4'}
# name: (frame, [x0, y0, w, h] fractions, values, gain) -- the visual-claim crops (SPEC V-lines)
CROPS = {
    '4213_horizon': ('4213', [0.30, 0.30, 0.30, 0.25], [0, 50, 100], 1.0),
    '983_peak_snow': ('983', [0.38, 0.00, 0.35, 0.45], [0, 50, 100], 1.0),
    '983_snow_fg': ('983', [0.00, 0.62, 0.45, 0.30], [0, 100], 1.0),
    '1840_treeline': ('1840', [0.40, 0.00, 0.30, 0.30], [0, 50, 100], 1.6),
    '2545_sky_tree': ('2545', [0.78, 0.00, 0.22, 0.30], [0, 50, 100], 1.0),
    '3437_veil': ('3437', [0.00, 0.40, 0.35, 0.45], [0, -50, -100], 1.0),
    '3437_trunk': ('3437', [0.38, 0.40, 0.14, 0.25], [0, 100], 1.0),
    '6929_wall': ('6929', [0.72, 0.70, 0.28, 0.30], [0, 50, 100], 1.0),
    '4213_veil': ('4213', [0.00, 0.20, 0.50, 0.50], [0, -50, -100], 1.0),
}
SYN = ['colorchecker', 'hard_edge', 'grey_ramp']
FULL_VALUES = [0, 50, 100, -50, -100]
RES_VALUES = [0, 60, -60]
KEY = 'develop.detail.dehaze'


def lfi(fid):
    return os.path.join(ROOT, 'corpus/lfi', FRAMES[fid] + '.lfi') if fid in FRAMES \
        else os.path.join(ROOT, 'corpus/synthetic', fid + '.lfi')


def wb(fid):
    h = json.load(open(lfi(fid)[:-4] + '.json')).get('recipe_hint', {})
    return ['--as-shot-kelvin', str(h.get('asShotKelvin', 5500)), '--as-shot-tint', str(h.get('asShotTint', 0))]


def jobs(out, only):
    j = []
    def render(fid, edge, v, path):
        s = [] if v is None else ['--set', f'{KEY}={v}']
        return [BIN, 'render', '--input', lfi(fid), *s, '--long-edge', str(edge), '--no-dither', *wb(fid), '--out', path]
    if 'full' in only:
        for f in FRAMES:
            j.append(render(f, 2400, None, f'{out}/full/{f}_L2400_unset.png'))
            for v in FULL_VALUES:
                j.append(render(f, 2400, v, f'{out}/full/{f}_L2400_d{v}.png'))
    if 'res' in only:
        for f in FRAMES:
            for e in (512, 2048):
                for v in RES_VALUES:
                    j.append(render(f, e, v, f'{out}/res/{f}_L{e}_d{v}.png'))
    if 'syn' in only:
        for s in SYN:
            j.append(render(s, 1024, None, f'{out}/syn/{s}_L1024_unset.png'))
            for v in (0, 50, 100, -100):
                j.append(render(s, 1024, v, f'{out}/syn/{s}_L1024_d{v}.png'))
    if 'sweep' in only:
        for f in FRAMES:
            j.append([BIN, 'sweep', '--input', lfi(f), '--key', KEY, '--values', ','.join(str(v) for v in range(-100, 101, 10)),
                      '--long-edge', '512', '--columns', '7', '--no-dither', *wb(f), '--out', f'{out}/sweep/{f}_fine_sheet.png',
                      '--metrics', f'{out}/sweep/{f}_fine_m.json', '--tiles-dir', f'{out}/sweep/{f}_fine_tiles'])
    if 'sheet' in only:
        for f in FRAMES:
            j.append([BIN, 'sweep', '--input', lfi(f), '--key', KEY, '--values', '-100,-50,-25,0,25,50,100',
                      '--long-edge', '1024', *wb(f), '--out', f'{out}/sheets/{f}_sheet.png'])
    return j


def run(cmd):
    for a in cmd:
        if a.startswith(OUT + '/'):
            os.makedirs(os.path.dirname(a) if a.endswith(('.png', '.json')) else a, exist_ok=True)
    r = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
    if r.returncode:
        print('FAILED:', ' '.join(cmd), r.stderr[-400:], file=sys.stderr)
    return r.returncode


if __name__ == '__main__':
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('out'); ap.add_argument('--bin', default=os.environ.get('BIN', os.path.join(ROOT, '.build/x86_64-unknown-linux-gnu/release/lumen-render')))
    ap.add_argument('--jobs', type=int, default=4); ap.add_argument('--only', default='full,res,sweep,syn,sheet,crops')
    a = ap.parse_args()
    BIN = a.bin; OUT = os.path.abspath(a.out)
    js = jobs(OUT, set(a.only.split(',')))
    # biggest first so the pool drains evenly
    js.sort(key=lambda c: ('2400' not in c, 'sweep' != c[1]))
    with ThreadPoolExecutor(a.jobs) as ex:
        rc = list(ex.map(run, js))
    if 'crops' in set(a.only.split(',')):
        for name, (f, (x, y, w, h), vals, g) in CROPS.items():
            cmd = [sys.executable, os.path.join(HERE, 'crops.py'), f'{OUT}/crops/{name}.png', str(x), str(y), str(w), str(h),
                   *[f'{OUT}/full/{f}_L2400_d{v}.png' for v in vals]] + (['--gain', str(g)] if g != 1 else [])
            os.makedirs(f'{OUT}/crops', exist_ok=True); rc.append(subprocess.run(cmd, stdout=subprocess.DEVNULL).returncode)
    print(f'rendered {len(js) - sum(1 for r in rc if r)}/{len(js)} into {OUT}')
    sys.exit(1 if any(rc) else 0)
