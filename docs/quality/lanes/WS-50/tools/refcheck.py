import mtool, numpy as np, sys, json, os
from cases import SWEEPS
root = sys.argv[1]; bases = sys.argv[2:] or ['ref8559_RsC', 'ref8559_C', 'ref983_LiU', 'ref983_hardR']
DIR = dict(edge=+1, levelsLo=-1, levelsHi=+1, levelsGamma=+1)   # expected per-pixel direction as list index increases
res = {}
for b in bases:
    base = mtool.read_f32(f'{root}/{b}/feather_0.f32')
    m0 = mtool.edge_metrics(base)
    print(f'== {b}  identity cov {m0["coverage"]:.4f} speck {m0["speckle"]} stair {m0["stair"]:.3f}')
    for key, vals in SWEEPS.items():
        prev = None; rows = []
        for v in vals:
            a = mtool.read_f32(f'{root}/{b}/{key}_{v}.f32'); m = mtool.edge_metrics(a)
            m['dmean'] = float(np.abs(a - base).mean()); m['dmax'] = float(np.abs(a - base).max())
            if prev is not None and key in DIR:
                d = (a - prev) * DIR[key]
                m['wrong_px'] = float((d < -1e-3).mean()); m['wrong_max'] = float(max(0, -d.min()))
            prev = a; rows.append((v, m))
        res[f'{b}/{key}'] = rows
        print(f'  {key}:')
        for v, m in rows:
            print(f'    {v:>6}: cov {m["coverage"]:.4f} |Δ|mean {m["dmean"]:.4f} max {m["dmax"]:.3f} speck {m["speckle"]:4d} '
                  f'stair {m["stair"]:.3f} grad {m["mean_grad"]:.4f} halo {m["halo_hi"]:.3f}'
                  + (f' wrong {m["wrong_px"]*100:.3f}% ({m["wrong_max"]:.3f})' if 'wrong_px' in m else ''))
json.dump(res, open(f'{root}/refine_metrics.json', 'w'))
