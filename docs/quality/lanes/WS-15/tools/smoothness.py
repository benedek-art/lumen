#!/usr/bin/env python3
"""Smoothness of a lumen-render sweep: per value mean dE2000 vs reference, mean encoded/
linear luminance change, step-to-step increments, monotonicity and near-zero dead range.
Usage: smoothness.py SWEEP_METRICS.json [...]"""
import json, sys
for p in sys.argv[1:]:
    m = json.load(open(p)); rows = []
    for t in m['tiles']:
        rows.append((t['value'], t['deltaE2000VsReference']['mean'], t['meanEncodedLuminanceDelta'] * 255,
                     t['meanLinearLuminanceDeltaEV']))
    rows.sort()
    print(p)
    print('  value   dE_mean  dEncY(codes)  dLinEV   step_dE')
    prev = None; steps = []
    for v, de, dy, dev in rows:
        s = '' if prev is None else '%.2f' % abs(de - prev[1]) if (v > 0) == (prev[0] >= 0) or prev[0] == 0 or v == 0 else ''
        print('  %+5.0f  %7.2f  %+9.2f  %+7.3f  %s' % (v, de, dy, dev, s)); prev = (v, de)
    neg = [r for r in rows if r[0] <= 0][::-1]; pos = [r for r in rows if r[0] >= 0]
    for name, side in (('neg', neg), ('pos', pos)):
        d = [side[i + 1][1] - side[i][1] for i in range(len(side) - 1)]
        mono = all(x > 0 for x in d)
        print('  %s: monotone dE=%s, first step %.2f, max step %.2f, min step %.2f, ratio max/min %.2f' %
              (name, mono, d[0], max(d), min(d), max(d) / max(min(d), 1e-9)))
