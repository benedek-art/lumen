"""Finding 3b: banding in real skies (1840 D850 blue sky, 4213 Z7II overcast)."""
import numpy as np
from PIL import Image
crops = {'1840': (0, 280, 600, 1800), '4213': (0, 620, 600, 1800)}
for p, (r0, r1, c0, c1) in crops.items():
    for c in ('none', 'S', 'steep'):
        for L in (33, 65):
            for D in ('n', 'd'):
                a = np.asarray(Image.open(f'r3/{p}_{c}_{L}_{D}.png').convert('RGB'))[r0:r1, c0:c1].astype(int)
                g = a[..., 1]
                lo, hi = np.percentile(g, [1, 99]).astype(int)
                h = np.bincount(g.ravel(), minlength=256)[lo:hi + 1]
                gaps = int((h == 0).sum())
                # vertical gradient smoothness: column-mean profile down the crop, 2nd difference
                prof = a[..., 1].mean(axis=1)
                d2 = np.abs(np.diff(prof, 2)).max()
                # fraction of 4-neighbour pairs differing by >=2 codes (posterization step proxy)
                big = float(np.mean(np.abs(np.diff(g, axis=0)) >= 2) * 100)
                print(f'{p} {c:5s} lut{L} {"dith" if D=="d" else "nodi"}: G range p1-p99 [{lo},{hi}] span {hi-lo:3d} codes, empty bins {gaps:3d}, '
                      f'unique {len(np.unique(g)):3d}, vert steps>=2 {big:5.2f}%')
        if c == 'none':
            pass
    # save crops for viewing: none / steep33 nodither / steep65 dither
    tiles = [Image.open(f'r3/{p}_{n}.png').crop((c0, r0, c1, r1)) for n in ('none_65_n', 'steep_33_n', 'steep_65_n', 'steep_33_d')]
    W, H = tiles[0].size
    sheet = Image.new('RGB', (W, H * 4))
    for i, t in enumerate(tiles): sheet.paste(t, (0, H * i))
    sheet.save(f'm3_sky_{p}_crops.png')
