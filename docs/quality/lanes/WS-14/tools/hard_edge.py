"""Artefacts on corpus/synthetic/hard_edge.lfi (9.6 EV disk/square edges, 1/2/4 px lines of 4.0 and
0.005 on 0.18, i.e. very high contrast edges, line ends and T-junctions).

usage: python3 hard_edge.py DIR PREFIX [name ...]     e.g. hard_edge.py OUT/he he t100 t-100 c100 c-100
prints per render: max |delta encoded luma| (codes), 99.9th percentile, and % of pixels > 8 codes."""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, encY

d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or ["t-100", "t100", "c-100", "c100"]
ref = encY(load(f"{d}/{p}_id.png"))
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    dl = np.abs(encY(load(fn)) - ref)
    print(f"  {n:>6}: max {dl.max():6.1f} codes  p99.9 {np.percentile(dl, 99.9):6.2f}  >8 codes {100*(dl>8).mean():.3f}%")
