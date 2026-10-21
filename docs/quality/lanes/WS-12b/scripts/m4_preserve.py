"""Finding 4/5: preserveLuminance on/off, brightening clamp, R-channel curve; per-patch OKLCh."""
import numpy as np, json, sys
sys.path.insert(0, '.')
from curvelib import *
from PIL import Image
def patches(im):
    d = json.load(open(f'/home/user/lumen/corpus/synthetic/{im}.json'))['truth']['patches']
    return [(p['name'], p['rect']) for p in d]
def meas(path, rects):
    a = np.asarray(Image.open(path).convert('RGB')).astype(float)
    out = []
    for n, (x, y, w, h) in rects:
        c = a[y + h // 4:y + 3 * h // 4, x + w // 4:x + 3 * w // 4].reshape(-1, 3).mean(0)
        L, C, H = oklch_from_png(c[None, :])
        out.append((n, float(L[0]), float(C[0]), float(H[0]), c))
    return out
def dh(a, b): return (b - a + 180) % 360 - 180
res = {}
for im in ('colorchecker', 'skin_tones'):
    rects = patches(im)
    for L in (65, 33):
        base = meas(f'r4/{im}_none_{L}.png', rects)
        for r in ('S', 'S_pl', 'bright', 'bright_pl', 'rlift'):
            m = meas(f'r4/{im}_{r}_{L}.png', rects)
            rows = []
            for (n, L0, C0, H0, c0), (_, L1, C1, H1, c1) in zip(base, m):
                rows.append((n, L1 - L0, C1 / max(C0, 1e-6), dh(H0, H1) if C0 > 0.02 else 0.0, C0, c1))
            chrom = [q for q in rows if q[4] > 0.02]
            mh = max(chrom, key=lambda q: abs(q[3]))
            print(f'{im:12s} lut{L} {r:9s}: |dHue| max {abs(mh[3]):5.1f} deg ({mh[0]}), median {np.median([abs(q[3]) for q in chrom]):4.1f};'
                  f' chroma ratio median {np.median([q[2] for q in chrom]):.3f} range [{min(q[2] for q in chrom):.2f},{max(q[2] for q in chrom):.2f}];'
                  f' dL range [{min(q[1] for q in rows):+.3f},{max(q[1] for q in rows):+.3f}]')
            res[f'{im}_{r}_{L}'] = [(q[0], round(q[1], 4), round(q[2], 3), round(q[3], 2), [int(v) for v in q[5]]) for q in rows]
json.dump(res, open('m4.json', 'w'), indent=0)
