"""Print the Swift literals pinned by Tests/LumenCoreTests/RawDenoisePackingTests.swift
and RawDenoiseCacheTests.swift.

Packing goes through the REAL `raw.pack` / `raw.unpack` / `prepare.to_rggb` /
`prepare.from_rggb`, so a change to the Python layout breaks the Swift tests instead of
silently drifting. `rawpy` is stubbed only so `raw.py` imports on a machine without it;
none of the functions called here touch it.

Normalization cannot go through `raw.load` (it needs a real RAW file and exiftool), so
`normalize` / `denormalize` below copy the exact numpy expressions from `raw.load` and
`infer.Engine.denoise_file` line for line, dtypes included. Keep them in sync by hand.

Usage (from the repo root): python3 Denoise/scripts/gen_swift_fixtures_packing.py
"""
import hashlib
import struct
import sys
import types
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.modules.setdefault("rawpy", types.ModuleType("rawpy"))
from lumen_denoise import raw  # noqa: E402
from lumen_denoise.prepare import from_rggb, to_rggb  # noqa: E402

PATTERNS = ["RGGB", "BGGR", "GRBG", "GBRG"]
H, W = 5, 7  # both odd: the trailing row and column must be dropped by pack


def swift_floats(a):
    # float32 repr is the shortest string that round-trips, so Swift's Float(literal)
    # parses it back to the identical bit pattern.
    return "[" + ", ".join(repr(float(np.float32(v))) if not float(v).is_integer()
                           else str(int(v)) for v in np.asarray(a, np.float32).ravel()) + "]"


def normalize(raw_dn, bl_tile, white):
    """raw.load, verbatim: per-position black tiled over the frame, one shared scale."""
    cfa = raw_dn.astype(np.float32)
    bl = np.asarray(bl_tile, np.float32)
    black = np.tile(bl.reshape(2, 2), (cfa.shape[0] // 2 + 1, cfa.shape[1] // 2 + 1))[: cfa.shape[0], : cfa.shape[1]]
    return (cfa - black) / (white - bl.mean())


def denormalize(cfa, bl_tile, white):
    """infer.Engine.denoise_file, verbatim (np.mean of a Python list is float64)."""
    bl = np.tile(np.asarray(bl_tile, np.float32).reshape(2, 2),
                 (cfa.shape[0] // 2 + 1, cfa.shape[1] // 2 + 1))[: cfa.shape[0], : cfa.shape[1]]
    scale = white - np.mean(list(bl_tile))
    return np.clip(np.round(cfa * scale + bl), 0, white).astype(np.uint16)


def cache_stable_string(source, model, calib, k, rv):
    def s(name, v):
        return f"{name}={len(v.encode())}:{v}\n"

    def d(name, v):
        v = 0.0 if v == 0 else v  # -0 and +0 share a key, as in Swift
        return f"{name}={struct.pack('>d', v).hex()}\n"

    return ("lumen.raw-denoise.cache/v1\n" + s("source", source) + s("model", model)
            + s("calib", calib) + d("k", k) + d("readVar", rv))


def main():
    cfa = np.arange(H * W, dtype=np.float32).reshape(H, W)
    print(f"// cfa = arange({H * W}).reshape({H}, {W})")
    for pat in PATTERNS:
        p = to_rggb(raw.pack(cfa), pat)
        print(f"{pat.lower()} packed {p.shape}: {swift_floats(p)}")
        back = np.full_like(cfa, -1)
        h2, w2 = p.shape[1] * 2, p.shape[2] * 2
        back[:h2, :w2] = raw.unpack(from_rggb(p, pat))
        assert np.array_equal(back[:h2, :w2], cfa[:h2, :w2])
        print(f"{pat.lower()} unpacked into -1 canvas: {swift_floats(back)}")

    rng = np.random.default_rng(7)
    dn = rng.integers(0, 16383, size=(3, 5)).astype(np.uint16)
    dn[0, 0], dn[0, 1] = 0, 16383  # below black and at white
    bl, white = [512.0, 510.0, 514.0, 511.0], 16383.0
    n = normalize(dn, bl, white)
    print("dn:", "[" + ", ".join(str(int(v)) for v in dn.ravel()) + "]")
    print("normalized:", swift_floats(n))
    # A denoiser output is off the DN grid: +0.62 DN must round UP to dn + 1.
    nudged = (n + np.float32(0.62) / np.float32(white - np.mean(bl))).astype(np.float32)
    nudged[0, 0] = np.float32(-0.2)  # clamps to 0
    nudged[0, 1] = np.float32(1.3)   # clamps to white
    print("nudged:", swift_floats(nudged))
    print("denormalized(nudged):", "[" + ", ".join(str(int(v)) for v in denormalize(nudged, bl, white).ravel()) + "]")
    assert np.array_equal(denormalize(n, bl, white), dn)

    st = cache_stable_string("xxh64:0123456789abcdef", "lumen-denoise-v3", "xxh64:fedcba9876543210",
                             3.25e-4, 1.5e-7)
    print("cache stableString:", repr(st))
    print("cache digest:", hashlib.sha256(st.encode()).hexdigest())
    for msg in [b"", b"abc", b"a" * 1000]:
        print(f"sha256({msg[:8]!r} len {len(msg)}):", hashlib.sha256(msg).hexdigest())


if __name__ == "__main__":
    main()
