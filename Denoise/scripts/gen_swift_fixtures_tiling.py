"""Golden fixtures for Lumen's Swift port of the tiler (RawDenoiseTiling.swift).

    python3 Denoise/scripts/gen_swift_fixtures_tiling.py           # print the Swift block
    python3 Denoise/scripts/gen_swift_fixtures_tiling.py --write   # splice it into the test

Everything that CAN come from the real code does: tile plans and the seam-blending
parity outputs are produced by calling the actual `Engine.denoise_packed` from
lumen_denoise/infer.py with a fake network (the Engine is built with object.__new__, so
no weights are needed). Only the per-tile feather weights are taken from a verbatim copy
of the lines in that function, because they never leave it; the parity outputs exercise
the real ones anyway.

rawpy and tifffile are stubbed so infer.py imports on a machine without them — the code
paths used here never touch either. Requires numpy and torch (CPU is fine).
"""
import argparse, base64, sys, types
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
TEST = REPO / "Tests" / "LumenCoreTests" / "RawDenoiseTilingTests.swift"
BEGIN, END = "// BEGIN GENERATED FIXTURES", "// END GENERATED FIXTURES"

for m in ("rawpy", "tifffile"):
    sys.modules.setdefault(m, types.ModuleType(m))
sys.path.insert(0, str(ROOT))
import torch  # noqa: E402
from lumen_denoise import infer  # noqa: E402


def engine(net):
    e = object.__new__(infer.Engine)
    e.net, e.table = net, None
    return e


# ---------------------------------------------------------------- tile plans (real code)
class PlanProbe(torch.nn.Module):
    """Recovers each tile's geometry from the pixels it is handed. The input encodes
    every pixel's own coordinates (y%1024, y//1024, x%1024, x//1024 — integers ≤ 1024
    survive the fp16 cast exactly), so the top-left sample gives the origin and the first
    row/column where the coordinate stops increasing (steps back, or
    repeats for a 1-long axis) is where the reflect padding starts."""

    def __init__(self):
        super().__init__(); self.tiles = []

    def forward(self, x, std):
        t = x[0].float().numpy()
        yy = t[0] + 1024 * t[1]; xx = t[2] + 1024 * t[3]
        col, row = yy[:, 0], xx[0, :]
        def unpadded(v):
            d = np.nonzero(np.diff(v) <= 0)[0]
            return int(d[0]) + 1 if len(d) else len(v)
        H, W = t.shape[1:]
        th, tw = unpadded(col), unpadded(row)
        self.tiles.append((int(yy[0, 0]), int(xx[0, 0]), th, tw, H - th, W - tw))
        return x


def plan(w, h, tile=1024, ov=64):
    yy, xx = np.meshgrid(np.arange(h), np.arange(w), indexing="ij")
    p = np.stack([yy % 1024, yy // 1024, xx % 1024, xx // 1024]).astype(np.float32)
    probe = PlanProbe()
    engine(probe).denoise_packed(p, 0.0, 1.0, tile=tile, ov=ov)
    return probe.tiles


# ------------------------------------------- feather weights (verbatim copy of infer.py)
def feather(h, w, y0, x0, th, tw, tile, ov):
    ramp = np.minimum(np.arange(tile) + 1, ov).astype(np.float32) / ov
    wy = np.minimum(ramp[:th], ramp[:th][::-1]) if th == tile else np.ones(th, np.float32)
    wx = np.minimum(ramp[:tw], ramp[:tw][::-1]) if tw == tile else np.ones(tw, np.float32)
    if y0 == 0: wy[: ov] = 1
    if y0 + th >= h: wy[-ov:] = 1
    if x0 == 0: wx[: ov] = 1
    if x0 + tw >= w: wx[-ov:] = 1
    return wy, wx


# ------------------------------------------------------- seam-blending parity (real code)
def fixture_input(c, h, w):
    """k/1024 values: exact in fp16, so infer.py's .half() cast is lossless and the
    Swift side (which feeds Float32 straight through) sees the same numbers."""
    i = np.arange(c * h * w, dtype=np.int64)
    return (((i * 2654435761) % 1021) / 1024.0).astype(np.float32).reshape(c, h, w)


class BlurNet(torch.nn.Module):
    """Deterministic stand-in for the UNet: 3x3 box blur over the PADDED tile with
    clamp-to-edge sampling, plus 0.01·(call+1)·(channel+1) so each tile is distinguishable
    and the visiting order matters. Computed in float32 in a fixed summation order the
    Swift test mirrors."""

    def __init__(self):
        super().__init__(); self.calls = 0

    def forward(self, x, std):
        t = x[0].float().numpy()
        C, H, W = t.shape
        s = np.zeros_like(t)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                ys = np.clip(np.arange(H) + dy, 0, H - 1); xs = np.clip(np.arange(W) + dx, 0, W - 1)
                s = s + t[:, ys][:, :, xs]
        self.calls += 1
        bias = np.array([0.01 * self.calls * (k + 1) for k in range(C)], np.float32)  # in double, then f32
        o = s / np.float32(9) + bias[:, None, None]
        return torch.from_numpy(o.astype(np.float32))[None]


def parity(c, h, w, tile, ov):
    p = fixture_input(c, h, w)
    net = BlurNet()
    out = engine(net).denoise_packed(p, 0.0, 1.0, tile=tile, ov=ov)
    return out.astype("<f4"), net.calls


# ------------------------------------------------------------------------------ emit
PLAN_CASES = [  # (w, h, tile, ov)
    (1, 1, 1024, 64), (5, 3, 1024, 64), (100, 60, 1024, 64), (1000, 17, 1024, 64),
    (1024, 1024, 1024, 64), (1025, 1024, 1024, 64), (1024, 1025, 1024, 64),
    (1025, 1025, 1024, 64), (1793, 897, 1024, 64), (2296, 1724, 1024, 64),  # GX85 packed
    (3000, 2000, 1024, 64), (3504, 2336, 1024, 64), (3520, 2344, 1024, 64),  # A7 IV packed
    (70, 45, 32, 8), (37, 26, 24, 4), (30, 13, 24, 4),
]
REFLECT_CASES = [(2, 3, 4, 2, 1), (1, 3, 2, 13, 15), (1, 1, 5, 15, 11), (2, 2, 1, 7, 3), (1, 4, 4, 0, 0)]
PARITY_CASES = [(1, 45, 70, 32, 8), (4, 26, 37, 24, 4), (4, 13, 30, 24, 4)]  # (c, h, w, tile, ov)


def swift_floats(a):
    return "[" + ", ".join(repr(float(v)) for v in np.asarray(a, np.float32)) + "]"


def emit():
    L = [BEGIN,
         "// Produced by Denoise/scripts/gen_swift_fixtures_tiling.py from the real",
         "// infer.Engine.denoise_packed. Do not edit by hand; rerun with --write.",
         "enum RawDenoiseTilingFixtures {",
         "    struct PlanCase {\n        let width: Int\n        let height: Int\n        let tile: Int\n        let overlap: Int\n        let tiles: [[Int]]\n    }",
         "    static let plans: [PlanCase] = ["]
    plans = {}
    for (w, h, tile, ov) in PLAN_CASES:
        tl = plan(w, h, tile, ov); plans[(w, h, tile, ov)] = tl
        L.append(f"        PlanCase(width: {w}, height: {h}, tile: {tile}, overlap: {ov}, tiles: "
                 + "[" + ", ".join("[" + ", ".join(map(str, t)) + "]" for t in tl) + "]),")
    L.append("    ]")
    L.append("    struct FeatherCase {\n        let width: Int\n        let height: Int\n        let tile: Int\n        let overlap: Int\n        let tile0: [Int]\n        let wy: [Float]\n        let wx: [Float]\n    }")
    L.append("    static let feathers: [FeatherCase] = [")
    for key in [(70, 45, 32, 8), (37, 26, 24, 4), (30, 13, 24, 4), (100, 60, 1024, 64)]:
        w, h, tile, ov = key
        for t in plans[key]:
            wy, wx = feather(h, w, *t[:4], tile, ov)
            L.append(f"        FeatherCase(width: {w}, height: {h}, tile: {tile}, overlap: {ov}, "
                     f"tile0: {list(t)}, wy: {swift_floats(wy)}, wx: {swift_floats(wx)}),")
    L.append("    ]")
    L.append("    struct ReflectCase {\n        let channels: Int\n        let height: Int\n        let width: Int\n        let padBottom: Int\n        let padRight: Int\n        let output: [Float]\n    }")
    L.append("    /// np.pad(a, ((0,0),(0,pb),(0,pr)), mode='reflect') with a = arange(c*h*w).reshape(c,h,w).")
    L.append("    static let reflect: [ReflectCase] = [")
    for (c, h, w, pb, pr) in REFLECT_CASES:
        a = np.arange(c * h * w, dtype=np.float32).reshape(c, h, w)
        o = np.pad(a, ((0, 0), (0, pb), (0, pr)), mode="reflect")
        L.append(f"        ReflectCase(channels: {c}, height: {h}, width: {w}, padBottom: {pb}, padRight: {pr}, "
                 f"output: {swift_floats(o.ravel())}),")
    L.append("    ]")
    L.append("    struct ParityCase {\n        let channels: Int\n        let height: Int\n        let width: Int\n        let tile: Int\n        let overlap: Int\n        let calls: Int\n        let output: String\n    }")
    L.append("    /// Little-endian Float32 output of denoise_packed with BlurNet, base64.")
    L.append("    static let parity: [ParityCase] = [")
    for (c, h, w, tile, ov) in PARITY_CASES:
        out, calls = parity(c, h, w, tile, ov)
        b64 = base64.b64encode(out.tobytes()).decode()
        L.append(f"        ParityCase(channels: {c}, height: {h}, width: {w}, tile: {tile}, overlap: {ov}, "
                 f"calls: {calls}, output: \"{b64}\"),")
    L.append("    ]")
    L.append("}")
    L.append(END)
    return "\n".join(L)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--write", action="store_true")
    a = ap.parse_args()
    block = emit()
    if not a.write:
        print(block); return
    src = TEST.read_text()
    i, j = src.index(BEGIN), src.index(END) + len(END)
    TEST.write_text(src[:i] + block + src[j:])
    print(f"wrote {TEST}")


if __name__ == "__main__":
    main()
