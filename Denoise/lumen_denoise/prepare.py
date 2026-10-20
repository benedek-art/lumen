"""Turn clean low-ISO RAWs into ground-truth packed tensors.

Each packed channel is 2x2 box-downsampled: halves residual base-ISO noise std and keeps
a valid Bayer layout. Saved as float16 .npy (4, h, w), normalized black=0 white=1, RGGB order.
Usage: python -m lumen_denoise.prepare <list.txt> <outdir>
"""
import sys
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np
from . import raw

# reorder any 2x2 pattern to RGGB so the net sees one layout
_TO_RGGB = {"RGGB": [0, 1, 2, 3], "BGGR": [3, 1, 2, 0], "GRBG": [1, 0, 3, 2], "GBRG": [2, 0, 3, 1]}


def to_rggb(packed, pattern):
    return packed[_TO_RGGB[pattern]]


def from_rggb(packed, pattern):
    inv = np.argsort(_TO_RGGB[pattern])
    return packed[inv]


def one(args):
    src, outdir = args
    out = Path(outdir) / (Path(src).stem + ".npy")
    if out.exists():
        return str(out)
    r = raw.load(src)
    p = to_rggb(raw.pack(r.cfa), r.pattern)
    c, h, w = p.shape
    p = p[:, : h // 2 * 2, : w // 2 * 2].reshape(c, h // 2, 2, w // 2, 2).mean((2, 4))
    np.save(out, p.astype(np.float16))
    return str(out)


if __name__ == "__main__":
    files = [l.strip() for l in open(sys.argv[1]) if l.strip()]
    Path(sys.argv[2]).mkdir(parents=True, exist_ok=True)
    with ProcessPoolExecutor(6) as ex:
        for i, o in enumerate(ex.map(one, [(f, sys.argv[2]) for f in files])):
            print(i, o, flush=True)
