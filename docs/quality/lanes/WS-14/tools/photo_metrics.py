"""Per-render metrics against the identity render of the same frame (real photos and flat synthetics).

usage: python3 photo_metrics.py DIR PREFIX [name ...]     e.g. photo_metrics.py OUT/photos 6929
  gT     cross-spectral gain of log2 Y in the TEXTURE band, 375-1500 cpi (periods 4-16 px at 6000),
         capped at 0.95 x Nyquist of the render (at 1600 px: 375-760 cpi)
  gC     same in the CLARITY band, 20-160 cpi (periods 37-300 px at 6000)
  dLuma  mean encoded luma change (codes)
  zoneP  pixel zones (synthetic flats / ramps): max over the 10 identity zones (encoded luma
         0-25.5, 25.5-51, ... codes) holding >= 1 % of the pixels of |median of (out - id)| (codes)
  zoneB  block zones (real photos): the frame is cut into blocks of L/10 px; max over the 10
         identity zones of the blocks' mean encoded luma (zones with >= 2 blocks) of |mean block
         change| (codes). A local-contrast control legitimately moves dark pixels inside textured
         areas, so pixel zones are not a brightness measure on photos; block means are.
  chroma mean OKLab chroma change (%)
  hue    systematic hue shift: chroma-weighted mean of SIGNED OKLab hue change on chromatic pixels
         (identity C > 0.03 and identity encoded luma >= 30 codes: darker pixels' 8-bit hue is noise),
         whole frame and worst 30-degree hue sector holding >= 2 % of them (degrees);
         |hue| = chroma-weighted mean of |hue change| (includes 8-bit quantisation noise)
"""
import sys, os
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wslib import load, logY, encY, oklab

d, p = sys.argv[1], sys.argv[2]
names = sys.argv[3:] or [f"{k}{v}" for k in "tc" for v in (-100, -50, -25, 25, 50, 100)]
R = load(f"{d}/{p}_id.png"); r = logY(R); h, w = r.shape; L = max(h, w)
win = np.outer(np.hanning(h), np.hanning(w))
I = np.fft.rfft2((r - r.mean()) * win); pw = np.abs(I) ** 2
cpi = np.hypot(np.fft.rfftfreq(w)[None, :], np.fft.fftfreq(h)[:, None]) * L
nyq = 0.95 * L / 2
bT = (cpi >= 375) & (cpi < min(1500, nyq)); bC = (cpi >= 20) & (cpi < 160)
eR = encY(R)
zones = [(eR >= 25.5 * z) & (eR < 25.5 * (z + 1) + (z == 9)) for z in range(10)]
labR = oklab(R); CR = np.hypot(labR[..., 1], labR[..., 2]); HR = np.degrees(np.arctan2(labR[..., 2], labR[..., 1]))
chrom = (CR > 0.03) & (eR >= 30)
print(f"  {p}: L={L}  chromatic px {100*chrom.mean():.1f}%")
for n in names:
    fn = f"{d}/{p}_{n}.png"
    if not os.path.exists(fn):
        continue
    O = load(fn); o = logY(O)
    F = np.fft.rfft2((o - o.mean()) * win); cr = (F * np.conj(I)).real
    gT = cr[bT].sum() / max(pw[bT].sum(), 1e-12); gC = cr[bC].sum() / max(pw[bC].sum(), 1e-12)
    eO = encY(O)
    zmax = max((abs(np.median(eO[m] - eR[m])) for m in zones if m.mean() >= 0.01), default=0.0)
    bs = max(L // 10, 1); hb, wb = h // bs, w // bs
    if hb and wb:
        bR = eR[:hb * bs, :wb * bs].reshape(hb, bs, wb, bs).mean((1, 3))
        bO = eO[:hb * bs, :wb * bs].reshape(hb, bs, wb, bs).mean((1, 3))
        zb = np.minimum((bR // 25.5).astype(int), 9)
        zbmax = max((abs((bO - bR)[zb == z].mean()) for z in range(10) if (zb == z).sum() >= 2), default=0.0)
    else:
        zbmax = float("nan")
    lab = oklab(O); C = np.hypot(lab[..., 1], lab[..., 2]); H = np.degrees(np.arctan2(lab[..., 2], lab[..., 1]))
    if chrom.sum() > 100:
        dh = ((H - HR + 180) % 360 - 180)[chrom]; wgt = CR[chrom]
        hs = float(np.average(dh, weights=wgt)); ha = float(np.average(np.abs(dh), weights=wgt))
        sect = ((HR[chrom] % 360) // 30).astype(int); worst = 0.0
        for k in range(12):
            m = sect == k
            if m.mean() >= 0.02:
                worst = max(worst, abs(float(np.average(dh[m], weights=wgt[m]))))
        hue = f"hue {hs:+.2f} deg (worst sector {worst:.2f}) |hue| {ha:.2f}"
        chroma = f"chroma {100*(C.mean()/CR.mean()-1):+.2f}%"
    else:
        hue, chroma = "hue n/a (achromatic)", "chroma n/a"
    print(f"  {n:>6}: gT {gT:.3f}  gC {gC:.3f}  dLuma {eO.mean()-eR.mean():+.2f}  zoneP {zmax:.2f}  zoneB {zbmax:.2f}  {chroma}  {hue}")
