#!/usr/bin/env python3
"""Write the fiducial fixture: a grid of flat coloured cells that a screenshot can be
located against (driver/tools/fiducial.py).

Every cell differs from its four neighbours, and every 3x3 block of cells occurs once,
so any view showing two grid lines in each direction identifies where it is.

    make_fiducial.py OUT_DIR [--cols 60 --rows 40 --cell 100]

Writes OUT_DIR/fiducial.png and OUT_DIR/fiducial.json. Standard library only.
"""
import argparse
import json
import random
import struct
import sys
import zlib
from pathlib import Path

LOW, HIGH = 48, 208
PALETTE = {
    "R": (HIGH, LOW, LOW), "G": (LOW, HIGH, LOW), "B": (LOW, LOW, HIGH),
    "C": (LOW, HIGH, HIGH), "M": (HIGH, LOW, HIGH), "Y": (HIGH, HIGH, LOW),
    "W": (HIGH, HIGH, HIGH),
}
LETTERS = "RGBCMYW"


def layout(cols, rows, seed=20261125):
    """A random proper colouring, retried until every 3x3 block is unique."""
    for attempt in range(1000):
        rng = random.Random(seed + attempt)
        grid = [[None] * cols for _ in range(rows)]
        for r in range(rows):
            for c in range(cols):
                options = [x for x in LETTERS
                           if not (c > 0 and grid[r][c - 1] == x)
                           and not (r > 0 and grid[r - 1][c] == x)]
                grid[r][c] = rng.choice(options)
        blocks = set()
        for r in range(rows - 2):
            for c in range(cols - 2):
                blocks.add(tuple(grid[r + i][c + j] for i in range(3) for j in range(3)))
        if len(blocks) == (rows - 2) * (cols - 2):
            return ["".join(row) for row in grid]
    raise SystemExit("no layout found")


def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def write_png(path, grid, cell):
    rows, cols = len(grid), len(grid[0])
    width, height = cols * cell, rows * cell
    compressor = zlib.compressobj(6)
    parts = []
    for row in grid:
        line = b"\x00" + b"".join(bytes(PALETTE[letter]) * cell for letter in row)
        parts.append(compressor.compress(line * cell))
    parts.append(compressor.flush())
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        f.write(chunk(b"sRGB", b"\x00"))
        f.write(chunk(b"IDAT", b"".join(parts)))
        f.write(chunk(b"IEND", b""))
    return width, height


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--cols", type=int, default=60)
    parser.add_argument("--rows", type=int, default=40)
    parser.add_argument("--cell", type=int, default=100)
    parser.add_argument("--map-only", action="store_true")
    args = parser.parse_args()
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    grid = layout(args.cols, args.rows)
    meta = {"cols": args.cols, "rows": args.rows, "cell": args.cell,
            "width": args.cols * args.cell, "height": args.rows * args.cell,
            "low": LOW, "high": HIGH, "grid": grid}
    (out / "fiducial.json").write_text(json.dumps(meta, indent=1) + "\n")
    if not args.map_only:
        write_png(out / "fiducial.png", grid, args.cell)
    print(f"{out}/fiducial.png {meta['width']}x{meta['height']}, {args.cols}x{args.rows} cells")


if __name__ == "__main__":
    sys.exit(main())
