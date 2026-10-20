"""Identity round-trip: unmodified CFA -> DNG -> rawpy gives back the same raw values.
Run: .venv/bin/python tests/test_dng.py"""
import os
import sys
import tempfile

import numpy as np
import rawpy

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from lumen_denoise.dng import write_cfa_dng  # noqa: E402

SAMPLES = ["A7404922-2.ARW", "P1100829.RW2"]

for name in SAMPLES:
    src = os.path.join(ROOT, "data", "samples", name)
    with rawpy.imread(src) as r:
        cfa = r.raw_image_visible.copy()
        black, white = list(r.black_level_per_channel), r.white_level
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "out.dng")
        write_cfa_dng(src, cfa, out)
        with rawpy.imread(out) as d:
            back = d.raw_image_visible
            assert list(d.black_level_per_channel) == black, (name, d.black_level_per_channel, black)
            assert d.white_level == white, (name, d.white_level, white)
    # Adobe's raw area can differ from LibRaw's by a few edge rows/cols (outside the crop).
    h, w = min(back.shape[0], cfa.shape[0]), min(back.shape[1], cfa.shape[1])
    assert h > cfa.shape[0] - 8 and w > cfa.shape[1] - 16, (name, back.shape, cfa.shape)
    diff = back[:h, :w] != cfa[:h, :w]
    # Only defect pixels the source stores as 0 (Panasonic) may differ: Adobe repairs them.
    assert (cfa[:h, :w][diff] == 0).all(), (name, int(diff.sum()))
    assert diff.mean() < 1e-4, (name, int(diff.sum()))
    print(f"PASS {name}: {h}x{w} identical ({int(diff.sum())} repaired defect px)")
