"""WS-03 round 3: Auto WB cast recovery, measured through `lumen-render autowb`.

A wrong as-shot is simulated with the engine's own model. A frame decoded at as-shot A
would have decoded at A' as  D' = adapt(A' -> A) . D  (CAT16, Rec.2020; `wbmodel.adobe_matrix(A, A')`),
which is exactly what makes the engine render D' at as-shot A' and Temp/Tint T identically to D at A
and T. So a cast-invariant Auto returns the SAME light on (D, A) and on (D', A'). The reference is
Auto's own answer on the uncast frame (T0). Recovery = 1 - |mired(T') - mired(T0)| / |cast| (tint
casts: the same in tint units). Residual = T' - T0 in mired and tint.

Casts: mired -150 -100 -50 -25 -10 +10 +25 +50 +100 +150 (positive = the camera thought the light
was warmer, so the frame comes out blue), tint -20 / +20, and two diagonal ones. A cast that
would put A' outside 2000-50000 K is skipped ("n/a").

  python3 docs/quality/lanes/WS-03/tools/cast_recovery.py [--frames 1346,967] [--json out.json]

Pass criterion used in BUILD-NOTES: |residual| <= 15 mired and <= 8 tint."""
import sys, os, json, subprocess
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
import numpy as np
from lr import BIN, ROOT, TMP, write_lfi, read_lfi, sidecar_asshot
from wbmodel import adobe_matrix

FRAMES = ['lfi/1346_canon-eos-5d', 'lfi/967_sony-ilce-7m2', 'lfi/983_canon-eos-5d-mark-iv', 'lfi/864_fujifilm-x-t2',
          'lfi/6929_sony-ilce-7m4', 'lfi/2545_panasonic-dmc-gx85', 'lfi/4213_nikon-z-7-2', 'lfi/3582_nikon-z-6',
          'lfi/1332_canon-eos-77d', 'lfi/7881_canon-eos-r5-mark-ii', 'synthetic/colorchecker', 'synthetic/skin_tones']
CASTS = [(c, 0) for c in (-150, -100, -50, -25, -10, 10, 25, 50, 100, 150)] + [(0, -20), (0, 20), (50, 20), (-50, -20)]

def autowb(lfi, a):
    out = subprocess.run([BIN, 'autowb', '--input', lfi, '--as-shot-kelvin', repr(float(a[0])),
                          '--as-shot-tint', repr(float(a[1]))], check=True, capture_output=True, text=True)
    return json.loads(out.stdout.strip().splitlines()[-1])

def run(frames):
    rows = []
    for name in frames:
        lfi = os.path.join(ROOT, 'corpus', name + '.lfi'); A = sidecar_asshot(lfi)
        T0 = autowb(lfi, A); im = read_lfi(lfi).astype(np.float64); cells = []
        for cm, ct in CASTS:
            Ap = (1e6 / (1e6 / A[0] + cm), A[1] + ct)
            if not (2000 <= Ap[0] <= 50000): cells.append(None); continue
            M = adobe_matrix(A, Ap)
            p = os.path.join(TMP, 'cast.lfi'); write_lfi(p, (im @ M.T).astype(np.float32))
            T = autowb(p, Ap)
            rm = 1e6 / T['kelvin'] - 1e6 / T0['kelvin']; rt = T['tint'] - T0['tint']
            rec = 1 - (abs(rm) / abs(cm) if cm else abs(rt) / abs(ct))
            cells.append(dict(cast=[cm, ct], asShot=Ap, auto=[T['kelvin'], T['tint']], residualMired=rm,
                              residualTint=rt, recovered=rec, confidence=T['confidence']))
            rows.append(dict(frame=name, **cells[-1]))
        print(f"{name.split('/')[1][:26]:26s} T0 {T0['kelvin']:5.0f}/{T0['tint']:+5.1f} | " +
              ' '.join('  n/a' if c is None else f"{100 * c['recovered']:+4.0f}%" for c in cells))
    print('casts (mired, tint):', CASTS)
    ok = [r for r in rows if abs(r['residualMired']) <= 15 and abs(r['residualTint']) <= 8]
    print(f'pass (|res| <= 15 mired and <= 8 tint): {len(ok)} of {len(rows)}')
    for band in ((-150, -100), (-50, -25), (-10, 10), (25, 50), (100, 150)):
        sel = [r for r in rows if r['cast'][1] == 0 and r['cast'][0] in band]
        if sel:
            print(f'  mired casts {band}: pass {sum(1 for r in sel if r in ok)}/{len(sel)}, '
                  f'median recovered {100 * np.median([r["recovered"] for r in sel]):.0f}%')
    sel = [r for r in rows if r['cast'][0] == 0]
    print(f'  tint casts +-20: pass {sum(1 for r in sel if r in ok)}/{len(sel)}')
    return rows

if __name__ == '__main__':
    frames = FRAMES
    if '--frames' in sys.argv:
        keys = sys.argv[sys.argv.index('--frames') + 1].split(',')
        frames = [f for f in FRAMES if any(k in f for k in keys)]
    rows = run(frames)
    if '--json' in sys.argv: json.dump(rows, open(sys.argv[sys.argv.index('--json') + 1], 'w'), indent=1)
