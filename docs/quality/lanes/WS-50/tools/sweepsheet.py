import mtool, numpy as np, sys
from cases import SWEEPS
root, base, key, crop, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
y0, y1, x0, x1 = map(int, crop.split(','))
src = mtool.srgb_preview(mtool.read_lfi(f'{root}/{base}/_source.lfi'))
tiles = [src[y0:y1, x0:x1]]; labs = ['source 100%']
for v in SWEEPS[key]:
    a = mtool.read_f32(f'{root}/{base}/{key}_{v}.f32')
    tiles.append((np.clip(a[y0:y1, x0:x1], 0, 1) * 255 + .5).astype(np.uint8)); labs.append(f'{key} {v}')
mtool.sheet(tiles, labs, out, cols=int(sys.argv[6]) if len(sys.argv) > 6 else 4)
