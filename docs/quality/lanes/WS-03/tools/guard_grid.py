"""SPEC 8 reference numbers (the Swift test is the measurement of the build; this states BEFORE and
shows why a naive port of the guard is not enough).

Grid: as-shot AS x target Kelvin (20-mired steps, 2000-50000 K) x tint -150..+150 step 2.5.
For each (as-shot, Kelvin) line, a 0.18 grey through the WB matrix (scene-linear Rec.2020):
  neg  = any channel < -1e-6;   drop = largest fall of OKLab a below its running max as tint rises.
  python3 docs/quality/lanes/WS-03/tools/guard_grid.py old     # pre-WS-03 Lumen model (port)
  python3 docs/quality/lanes/WS-03/tools/guard_grid.py naive   # DNG convention + old guard re-derived
                                                               # on the DNG axis against a fixed 5500/0 reference"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from functools import lru_cache
from wbmodel import *

AS = [(2500, 0), (2850, 0), (3200, 0), (4000, 5), (4708, 48.2), (5000, 8), (5500, 10), (6503.7072, 9.77), (7500, 10), (9365, 16.4), (10000, 10), (12000, 10), (5500, -20)]
KS = [1e6 / m for m in np.arange(20, 500.1, 20)]
TS = np.arange(-150, 150.1, 2.5)

def _cone(k, t): return CAT16 @ xyz_of(*dng_xy(k, t))
def _bisect(ok, hi):
    if ok(hi): return hi
    lo = 0.0
    for _ in range(40):
        m = (lo + hi) / 2
        if ok(m): lo = m
        else: hi = m
    return lo
def _ra(k, t):
    o = adobe_matrix((5500, 0), (k, t)) @ np.full(3, 0.18)
    return None if (not np.isfinite(o).all() or o.min() < 0) else oklab(o)[1]
@lru_cache(None)
def naive_limit(k):
    b = _cone(k, 0); f = _bisect(lambda t: (_cone(k, t) >= 0.15 * b).all(), 300.0)
    def mono(t):
        h, a = _ra(k, t), _ra(k, t + 0.25); return h is not None and a is not None and a >= h
    return min(f, _bisect(mono, f))
def naive_matrix(a, k, t):
    ct = lambda kk, tt: tt if tt <= 0 else min(tt, naive_limit(kk))
    return XYZ_TO_REC2020 @ adapt(xyz_of(*dng_xy(k, ct(k, t))), xyz_of(*dng_xy(a[0], ct(a[0], a[1])))) @ REC2020_TO_XYZ

if __name__ == '__main__':
    model = {'old': lambda a, k, t: wb_matrix(a, (k, t)), 'naive': naive_matrix}[sys.argv[1] if len(sys.argv) > 1 else 'old']
    worst = (0, None); neg = []
    for a in AS:
        for k in KS:
            peak = -9
            for t in TS:
                o = model(a, k, t) @ np.full(3, 0.18)
                if not np.isfinite(o).all() or o.min() < -1e-6: neg.append((a, round(k), float(t))); break
                A = oklab(o)[1]; peak = max(peak, A)
                if peak - A > worst[0]: worst = (peak - A, (a, round(k), float(t)))
    print(f'lines {len(AS) * len(KS)}: negative-channel lines {len(neg)} {neg[:3]}; max OKLab-a drop {worst[0]:.4f} at {worst[1]}')
    if len(sys.argv) > 1 and sys.argv[1] == 'naive':
        print('naive guard tintLimit(K):', {K: round(naive_limit(K), 1) for K in (2000, 2500, 2850, 3200, 4000, 5000, 5500, 6500)})
