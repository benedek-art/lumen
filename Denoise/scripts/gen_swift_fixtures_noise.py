"""Golden values for the Swift port of NoiseTable and std_map (LumenCore RawDenoise).

    python Denoise/scripts/gen_swift_fixtures_noise.py

Calls the REAL `lumen_denoise.train.NoiseTable` / `std_map` (and the ISO clamp from
`infer.Engine.noise_params`) so the Swift tests pin the Python that trained the
network, not a re-reading of it. Prints Swift literals to paste into
Tests/LumenCoreTests/RawDenoiseNoiseTableTests.swift and RawDenoiseStdMapTests.swift.
Re-run and re-paste whenever train.py's noise conditioning changes: the network only
works if Lumen feeds it the std map it was trained on.
"""
import sys
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from lumen_denoise.train import NoiseTable, std_map  # noqa: E402

CALIB = ROOT / "weights" / "calib.json"


def clamped_params(table, model, iso):
    # Same clamp as infer.Engine.noise_params (np.clip to the table's ISO range).
    lo, hi = table.iso_range(model)
    return table.params(model, float(np.clip(iso, lo, hi)))


def table_cases():
    t = NoiseTable(CALIB)
    out = []
    probes = {
        # exact points (first, interior, last), between points, and outside the range
        "ILCE-7M4": [50, 100, 3200, 51200, 75, 140, 2300, 12801, 30000, 25, 1, 102400, 204800],
        "DMC-GX85": [100, 200, 1600, 25600, 150, 333, 4500, 9000, 20000, 50, 80, 51200],
    }
    for model, isos in probes.items():
        for iso in isos:
            k, r = clamped_params(t, model, float(iso))
            out.append((model, float(iso), k, r))
    print("    // (model, iso, k, readVar) from train.NoiseTable.params after infer.py's ISO clamp")
    print("    static let golden: [(String, Double, Double, Double)] = [")
    for m, iso, k, r in out:
        print(f'        ("{m}", {iso!r}, {k!r}, {r!r}),')
    print("    ]")
    for m in probes:
        lo, hi = t.iso_range(m)
        print(f'    // isoRange("{m}") = {float(lo)!r}...{float(hi)!r}')


def fmt(a):
    return ", ".join(repr(float(v)) for v in np.asarray(a, np.float32).ravel())


def std_case(name, packed, k, r):
    x = torch.from_numpy(packed)[None]
    s = std_map(x, k, r)[0, 0].numpy()
    h, w = packed.shape[1:]
    print(f"    // {name}: 4x{h}x{w}, K={k!r}, r={r!r}")
    print(f"    static let {name}K: Double = {k!r}")
    print(f"    static let {name}R: Double = {r!r}")
    print(f"    static let {name}H = {h}, {name}W = {w}")
    print(f"    static let {name}Input: [Float] = [{fmt(packed)}]")
    print(f"    static let {name}Expected: [Float] = [{fmt(s)}]")


def std_cases():
    rng = np.random.default_rng(20261020)
    # Values in [-0.05, 0.9] so some channel means go negative and hit the clamp,
    # quantised to 1/4096 so the Swift literals are exact in Float.
    a = np.round(rng.uniform(-0.05, 0.9, (4, 6, 7)) * 4096) / 4096
    a[:, 0, 0] = -0.02  # a fully negative corner pixel: clamped to 0 before the pool
    a[:, 2:4, 3] = -0.04  # interior negatives
    a = a.astype(np.float32)
    t = NoiseTable(CALIB)
    k, r = clamped_params(t, "ILCE-7M4", 3200.0)
    std_case("a", a, k, r)
    # A deliberately large K so the shot term dominates and pool errors would show.
    b = (np.round(rng.uniform(-0.1, 1.0, (4, 3, 2)) * 1024) / 1024).astype(np.float32)
    std_case("b", b, 0.01, 1e-4)
    # 1x1: the 3x3 window holds one real pixel and eight zero pads -> mean/9.
    c = np.array([0.5, 0.25, 0.75, 1.0], np.float32).reshape(4, 1, 1)
    k, r = clamped_params(t, "DMC-GX85", 6400.0)
    std_case("c", c, k, r)


if __name__ == "__main__":
    table_cases()
    print()
    std_cases()
