#!/usr/bin/env python3
"""Crop-relative vignette on the CPU reference (Linux). lumen-render has no geometry stage
(GEO-17), so the output is the UNCROPPED frame; the vignette must nevertheless be laid out
on the crop rectangle, exactly as RenderGraph.applyVignette does. This renders flat32
(768x512, 0.18) with develop.geometry.crop set, cuts the crop rectangle out of the output
(mirrored in x when flipH, because the crop is stated in the flipped frame) and compares
its fraction-of-Amount map with an UNCROPPED flat frame of the crop's own pixel size
rendered with the same look settings.

  crop.py [--crop 0.125,0.125,0.375,0.75] [--flip] [--amount -2] [--set k=v ...]

Prints: frac at the crop's 4 corner pixels and centre, max |diff| against the crop-sized
reference, and the frac at the 4 corners of the FULL frame (they must not be pinned).
"""
import argparse, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--crop', default='0.125,0.125,0.375,0.75')
    ap.add_argument('--flip', action='store_true')
    ap.add_argument('--amount', type=float, default=-2.0)
    ap.add_argument('--set', action='append', default=[])
    a = ap.parse_args()
    cx, cy, cw, ch = map(float, a.crop.split(','))
    W, H = 768, 512
    look = ['look.vignette=%g' % a.amount] + a.set
    geo = ['develop.geometry.crop.x=%g' % cx, 'develop.geometry.crop.y=%g' % cy,
           'develop.geometry.crop.w=%g' % cw, 'develop.geometry.crop.h=%g' % ch]
    if a.flip:
        geo.append('develop.geometry.flipH=true')
    img, _ = lib.render(lib.frame('flat32'), look + geo, long_edge=W)
    f = lib.ev_of(img[..., 1]) / a.amount
    x0 = (1 - cx - cw) if a.flip else cx
    X0, Y0, X1, Y1 = int(round(x0 * W)), int(round(cy * H)), int(round((x0 + cw) * W)), int(round((cy + ch) * H))
    c = f[Y0:Y1, X0:X1]
    if a.flip:
        c = c[:, ::-1]
    p = os.path.join(lib.FRAMES, 'flat_%dx%d.lfi' % (X1 - X0, Y1 - Y0))
    if not os.path.exists(p):
        lib.write_lfi(p, np.full((Y1 - Y0, X1 - X0, 3), 0.18))
    ref, _ = lib.render(p, look, long_edge=max(X1 - X0, Y1 - Y0))
    r = lib.ev_of(ref[..., 1]) / a.amount
    d = np.abs(c - r)
    h, w = c.shape
    print('crop px [%d,%d)x[%d,%d) flip=%s  sets %s' % (X0, X1, Y0, Y1, a.flip, ' '.join(a.set)))
    print('crop corners %.3f %.3f %.3f %.3f  centre %.3f   (reference corners %.3f, centre %.3f)' % (
        c[0, 0], c[0, -1], c[-1, 0], c[-1, -1], c[h // 2, w // 2], r[0, 0], r[r.shape[0] // 2, r.shape[1] // 2]))
    print('full-frame corners %.3f %.3f %.3f %.3f' % (f[0, 0], f[0, -1], f[-1, 0], f[-1, -1]))
    print('max |crop - reference| %.3f   mean %.4f' % (d.max(), d.mean()))
    print('CROP_MAXDIFF %.3f' % d.max())


if __name__ == '__main__':
    main()
