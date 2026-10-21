#!/usr/bin/env python3
"""Synthetic frames for the WS-06 measurements (scene-linear Rec.2020, LFI1).

  mkframes.py OUTDIR

writes
  OUTDIR/ramp.lfi    3200 x 64 continuous grey ramp, EV = -10 + 16*(x+0.5)/3200
                     (-10 ... +6 EV around 0.18), 200 px per stop. Rows are identical,
                     so the guided tone mask is the pixel's own value away from the ends.
  OUTDIR/midedge.lfi 1600 x 600, three bands with a vertical edge at x = 800:
                     (-2 | +2), (-0.5 | +0.5), (-4 | +1) EV  (audit finding 6)
"""
import struct, sys, os
import numpy as np

def write_lfi(path, img):
    h, w, _ = img.shape
    with open(path, "wb") as f:
        f.write(b"LFI1"); f.write(struct.pack("<III", w, h, 3))
        f.write(img.astype("<f4").tobytes())

RAMP_W, RAMP_H, RAMP_LO, RAMP_SPAN = 3200, 64, -10.0, 16.0

def ramp_ev(x):
    return RAMP_LO + RAMP_SPAN * (np.asarray(x) + 0.5) / RAMP_W

def main(out):
    os.makedirs(out, exist_ok=True)
    ev = ramp_ev(np.arange(RAMP_W))
    row = (0.18 * 2.0 ** ev).astype(np.float32)
    img = np.repeat(np.repeat(row[None, :, None], RAMP_H, 0), 3, 2)
    write_lfi(os.path.join(out, "ramp.lfi"), img)
    W, H = 1600, 600
    e = np.zeros((H, W, 3), np.float32)
    for i, (a, b) in enumerate([(-2, 2), (-0.5, 0.5), (-4, 1)]):
        e[i * 200:(i + 1) * 200, :800] = 0.18 * 2 ** a
        e[i * 200:(i + 1) * 200, 800:] = 0.18 * 2 ** b
    write_lfi(os.path.join(out, "midedge.lfi"), e)

if __name__ == "__main__":
    main(sys.argv[1])
