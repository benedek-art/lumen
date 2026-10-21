"""SPEC 1: rendering with develop.raw.temp/tint set to exactly the sidecar as-shot pair is byte-identical
to rendering with them unset, on the 8 sweep frames (--long-edge 768).
  python3 docs/quality/lanes/WS-03/tools/identity.py"""
import sys, os, filecmp
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lr import ROOT, TMP, render, sidecar_asshot
from sweeps import FRAMES
bad = []
for f in FRAMES:
    lfi = os.path.join(ROOT, 'corpus', f + '.lfi'); a = sidecar_asshot(lfi)
    p0 = render(lfi, a, out=os.path.join(TMP, 'id0.png'), long_edge=768)
    p1 = render(lfi, a, a[0], a[1], out=os.path.join(TMP, 'id1.png'), long_edge=768)
    same = filecmp.cmp(p0, p1, shallow=False); print(f, a, 'BIT-IDENTICAL' if same else 'DIFFERS')
    if not same: bad.append(f)
print('SPEC-1', 'PASS' if not bad else f'FAIL {bad}')
