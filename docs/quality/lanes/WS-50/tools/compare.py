"""Before/after sheet: rows = before, after; columns = control values. usage:
compare.py BEFORE AFTER base key v1,v2,... y0,y1,x0,x1 out.png [scale]"""
import sys, numpy as np, mtool
from PIL import Image
B, A, base, key, vals, crop, out = sys.argv[1:8]
scale = float(sys.argv[8]) if len(sys.argv) > 8 else 1.0
y0, y1, x0, x1 = map(int, crop.split(','))
vals = vals.split(',')
src = mtool.srgb_preview(mtool.read_lfi(f'{A}/{base}/_source.lfi'))[y0:y1, x0:x1]
tiles, labs = [], []
for tag, root in (('before', B), ('after', A)):
    tiles.append(src); labs.append(f'{tag}: source 100%')
    for v in vals:
        a = mtool.read_f32(f'{root}/{base}/{key}_{v}.f32')[y0:y1, x0:x1]
        tiles.append((np.clip(a, 0, 1) * 255 + .5).astype(np.uint8)); labs.append(f'{tag} {key} {v}')
mtool.sheet(tiles, labs, out, cols=len(vals) + 1, scale=scale)
im = Image.open(out); im.save(out, optimize=True); print(out, im.size)
