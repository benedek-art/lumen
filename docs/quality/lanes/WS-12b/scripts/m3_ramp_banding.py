"""Finding 3a: banding on grey_ramp continuous row."""
import numpy as np, sys, os, json
sys.path.insert(0, os.path.dirname(__file__))
from curvelib import MonotoneCubic
from PIL import Image
x = np.load('x_exact.npy')
def row(n, r=0): return np.asarray(Image.open(f'r1/{n}.png').convert('RGB'))[r, :, 1].astype(int)
for c in ('none', 'S', 'steep'):
    for L in (33, 65):
        for D in ('n', 'd'):
            img = np.asarray(Image.open(f'r1/{c}_{L}_{D}.png').convert('RGB'))[0:192, :, 1].astype(int)
            r0 = img[0]
            u = len(np.unique(r0)); lo, hi = r0.min(), r0.max()
            jumps = np.abs(np.diff(r0)); maxjump = jumps.max()
            # longest run of identical code among columns where input is in 0.05..0.95
            m = (x > 0.05) & (x < 0.95)
            runs = []; cur = 1
            for i in range(1, len(r0)):
                if r0[i] == r0[i-1] and m[i]: cur += 1
                else: runs.append(cur); cur = 1
            missing = (hi - lo + 1) - u
            # kinkiness: slope of row-mean output wrt input x, how many slope discontinuities (2nd diff spikes)
            mean = img.mean(axis=0)
            print(f'{c:6s} lut{L} {"dither" if D=="d" else "nodith"}: unique {u:3d} in [{lo},{hi}] missing codes {missing:3d} max adj jump {maxjump} longest flat run(mid) {max(runs)} px')
