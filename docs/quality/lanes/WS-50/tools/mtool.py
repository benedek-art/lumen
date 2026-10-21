"""Mask alpha tooling: read maskh .f32 planes, write PNGs/crops/sheets, edge metrics."""
import json, sys, os, struct, numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage as ndi

def read_f32(p):
    b = open(p, 'rb').read(); w, h = struct.unpack('<II', b[:8])
    return np.frombuffer(b[8:], dtype=np.float32).reshape(h, w).astype(np.float64)

def read_lfi(p):
    b = open(p, 'rb').read(); w, h, c = struct.unpack('<III', b[4:16])
    return np.frombuffer(b[16:], dtype=np.float32).reshape(h, w, 3)

def srgb_preview(rgb):
    # crude display: Rec2020 linear -> luminance-ish gamma preview, auto exposure to mid grey
    y = 0.2627*rgb[...,0] + 0.678*rgb[...,1] + 0.0593*rgb[...,2]
    k = 0.18 / max(np.median(y), 1e-4)
    v = np.clip(rgb * k, 0, 1) ** (1/2.2)
    return (v * 255).astype(np.uint8)

def to_png(a, path):
    Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), 'L').save(path)

def overlay(rgb8, a, path):
    base = rgb8.astype(np.float64)
    red = np.array([255, 40, 40.0])
    o = base * (1 - 0.6 * a[..., None]) + red * 0.6 * a[..., None]
    Image.fromarray(o.astype(np.uint8)).save(path)

def sheet(tiles, labels, path, cols=4, scale=1.0):
    ims = [Image.fromarray(t) if isinstance(t, np.ndarray) else t for t in tiles]
    if scale != 1.0:
        ims = [im.resize((int(im.width*scale), int(im.height*scale)), Image.NEAREST) for im in ims]
    tw = max(i.width for i in ims); th = max(i.height for i in ims)
    rows = (len(ims) + cols - 1) // cols
    S = Image.new('RGB', (cols * tw, rows * (th + 16)), (30, 30, 30))
    d = ImageDraw.Draw(S)
    for k, (im, lab) in enumerate(zip(ims, labels)):
        x = (k % cols) * tw; y = (k // cols) * (th + 16)
        S.paste(im.convert('RGB'), (x, y + 16)); d.text((x + 3, y + 2), lab, fill=(255, 255, 0))
    S.save(path)

def coverage(a): return float(a.mean())

def edge_metrics(a):
    """Edge-quality numbers on an alpha plane.
    speckle: connected components of (a>0.5) and of (a<=0.5) smaller than 16 px, count
    halo: pixels whose alpha exceeds the max of the 3x3-median-smoothed neighbourhood over a 9 px window by >0.02
          (a local maximum ring / dip next to a plateau)
    stair: mean |second difference| along x and y restricted to the transition band (0.05..0.95),
           normalised by mean |first difference| there  (0 = perfectly linear ramp; steps raise it)
    gradTV: total variation of |grad| inside the band (roughness of the ramp)
    """
    fg = a > 0.5
    lab, n = ndi.label(fg); sizes = ndi.sum(np.ones_like(a), lab, range(1, n + 1)) if n else np.array([])
    labb, nb = ndi.label(~fg); sizesb = ndi.sum(np.ones_like(a), labb, range(1, nb + 1)) if nb else np.array([])
    speck = int((sizes < 16).sum() + (sizesb < 16).sum())
    band = (a > 0.05) & (a < 0.95)
    gx = np.diff(a, axis=1); gy = np.diff(a, axis=0)
    d2x = np.abs(np.diff(a, 2, axis=1)); d2y = np.abs(np.diff(a, 2, axis=0))
    bx = band[:, 1:-1]; by = band[1:-1, :]
    d1 = (np.abs(gx[:, :-1])[bx].sum() + np.abs(gy[:-1, :])[by].sum()) / max(bx.sum() + by.sum(), 1)
    d2 = (d2x[bx].sum() + d2y[by].sum()) / max(bx.sum() + by.sum(), 1)
    stair = float(d2 / max(d1, 1e-9))
    # overshoot: alpha above the max over a 15px window of a heavily smoothed copy (ringing/halo)
    sm = ndi.uniform_filter(a, 15)
    halo_hi = float(np.clip(a - ndi.maximum_filter(sm, 15), 0, None).max())
    return dict(coverage=coverage(a), speckle=speck, band_px=int(band.sum()), stair=stair,
                halo_hi=halo_hi, mean_grad=float(d1))

def profile(a, y0, x0, x1):
    return a[y0, x0:x1]

if __name__ == '__main__':
    pass
