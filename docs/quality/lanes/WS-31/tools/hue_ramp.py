"""Hue ramp through the engine: monotone hue mapping, magnitude/direction at band centres,
L/C preservation of hue moves, and the seam (steepest edge) of every H/S/L move.

Frame: rows of 8 px for L in {0.4,0.6,0.8} x C in {0.03,0.06,0.12,0.2} (scene OKLCh,
Rec.2020 linear), hue 0..360 at 0.25 deg/px. Rendered WITH the ordered dither so an 8x8
block mean resolves sub-code changes. Columns whose block clips a channel (code 0/255) in
the base or the edited render, or whose input is outside Rec.2020, are masked.

usage: hue_ramp.py --bin lumen-render --out DIR --centres c0,...,c7
  --centres = the band centres the build ships (OKLCh deg, wire order red..magenta)
"""
import argparse, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mixlib import *

ap = argparse.ArgumentParser()
ap.add_argument("--bin", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--centres", required=True)
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)
cent = np.array([float(v) for v in a.centres.split(",")]); assert cent.size == 8

Ls = [0.4, 0.6, 0.8]; Cs = [0.03, 0.06, 0.12, 0.2]
W, BH, SM = 1440, 8, 4          # 0.25 deg/px, 8-row blocks, +/-4 px = 2 deg baseline
hin = (np.arange(W) + 0.5) * 0.25
rows, valid = [], []
for L in Ls:
    for C in Cs:
        rgb = from_lab(lch2lab(np.full(W, L), np.full(W, C), hin))
        valid.append((rgb >= 0).all(1)); rows.append(np.repeat(rgb[None], BH, 0))
lfi = os.path.join(a.out, "ramp.lfi"); write_lfi(lfi, np.concatenate(rows, 0))
names = [f"L{L:.1f}C{C:.2f}" for L in Ls for C in Cs]

def blocks(png):
    codes = png_codes(png); lin = srgb_dec(codes / 255.0)
    out, clip = [], []
    for r in range(len(names)):
        blk = lin[r * BH:(r + 1) * BH].mean(0)                       # W x 3
        k = np.ones(8) / 8
        blk = np.stack([np.convolve(np.pad(blk[:, c], 4, mode="wrap"), k, "same")[4:-4] for c in range(3)], -1)
        cb = codes[r * BH:(r + 1) * BH]
        clip.append(((cb == 0) | (cb == 255)).any(-1).any(0))
        out.append(to_lab(blk, "srgb"))
    return np.array(out), np.array(clip)

base, bclip = blocks(render(a.bin, lfi, os.path.join(a.out, "base.png"), [], 0, dither=True))
Lb, Cb, hb = lch(base)
ub = hin + hd(hin, hb)

res = []; worst = {}
def upd(k, v, fn):
    worst[k] = v if k not in worst else fn(worst[k], v)

for b in range(8):
    for comp in ("hue", "sat", "lum"):
        for v in (100, -100):
            o, oclip = blocks(render(a.bin, lfi, os.path.join(a.out, f"b{b}_{comp}{v:+d}.png"), [f"{key(b,comp)}={v}"], 0, dither=True))
            Lo, Co, ho = lch(o)
            for r, rn in enumerate(names):
                m = valid[r] & ~bclip[r] & ~oclip[r]
                ok = m & np.roll(m, SM) & np.roll(m, -SM)
                ic = int(np.argmin(np.abs(hd(cent[b], hin))))
                rec = dict(band=b, comp=comp, v=v, row=rn, coverage=float(ok.mean()))
                if comp == "hue":
                    uo = hin + hd(hin, ho[r])
                    num = np.roll(uo, -SM) - np.roll(uo, SM); den = np.roll(ub[r], -SM) - np.roll(ub[r], SM)
                    num = (num + 180) % 360 - 180; den = (den + 180) % 360 - 180
                    sl = num / np.where(np.abs(den) < 1e-9, np.nan, den)
                    rec["slope_min"] = float(np.nanmin(sl[ok])) if ok.any() else np.nan
                    rec["slope_max"] = float(np.nanmax(sl[ok])) if ok.any() else np.nan
                    rec["centre_shift"] = float(hd(hb[r, ic], ho[r, ic])) if m[ic] else np.nan
                    # L/C preservation: compare each output pixel with the BASE pixel of the same displayed hue
                    order = np.argsort(ub[r] % 360)
                    hx = (ub[r] % 360)[order]
                    Lx = np.interp(ho[r] % 360, hx, Lb[r][order], period=360)
                    Cx = np.interp(ho[r] % 360, hx, Cb[r][order], period=360)
                    mm = m & (np.abs(hd(hb[r], ho[r])) > 1.0)   # only pixels the move actually rotated
                    rec["dC_rel_max"] = float(np.max(np.abs(Co[r] - Cx)[mm] / Cx[mm])) if mm.any() else 0.0
                    rec["dL_max"] = float(np.max(np.abs(Lo[r] - Lx)[mm])) if mm.any() else 0.0
                # seam: steepest hue-edge of the effect profile, relative to its peak (1/deg)
                eff = np.linalg.norm(o[r] - base[r], axis=-1)
                deff = np.abs(np.roll(eff, -SM) - np.roll(eff, SM)) / (2 * SM * 0.25)
                peak = eff[m].max() if m.any() else 0
                rec["peak"] = float(peak)
                rec["seam"] = float(deff[ok].max() / peak) if ok.any() and peak > 0.01 else np.nan
                res.append(rec)

json.dump(res, open(os.path.join(a.out, "hue_ramp.json"), "w"), indent=0)
import collections
def agg(filt, k, fn):
    vals = [r[k] for r in res if filt(r) and r.get(k) is not None and not np.isnan(r[k])]
    return fn(vals) if vals else np.nan
H = lambda r: r["comp"] == "hue"
print("per band (hue +/-100): slope_min  slope_max  centre_shift(L0.6C0.06 / L0.6C0.12)  dC_rel_max  dL_max")
for b in range(8):
    for v in (100, -100):
        f = lambda r: H(r) and r["band"] == b and r["v"] == v
        cs = [r["centre_shift"] for r in res if f(r) and r["row"] in ("L0.6C0.06", "L0.6C0.12")]
        print(f"  {BANDS[b]:8s} {v:+4d}: {agg(f,'slope_min',min):6.2f} {agg(f,'slope_max',max):6.2f}   {cs[0]:+6.1f} / {cs[1]:+6.1f}   {agg(f,'dC_rel_max',max):.3f}  {agg(f,'dL_max',max):.4f}")

print("min coverage", round(min(r["coverage"] for r in res), 3))
smin = agg(H, "slope_min", min); smax = agg(H, "slope_max", max)
cs = [abs(r["centre_shift"]) for r in res if H(r) and r["row"] == "L0.6C0.06"]
dirs = [np.sign(r["centre_shift"]) == np.sign(r["v"]) for r in res if H(r) and r["row"] == "L0.6C0.06"]
gap_up = (np.roll(cent, -1) - cent) % 360; gap_dn = (cent - np.roll(cent, 1)) % 360
reach = [abs(r["centre_shift"]) <= (gap_up[r["band"]] if r["v"] > 0 else gap_dn[r["band"]]) - 2
         for r in res if H(r) and r["row"] == "L0.6C0.06"]
print(f"{verdict(smin >= 0.1)}  H1 hue slope min >= 0.10 (no fold): {smin:.3f}")
print(f"{verdict(smax <= 3.0)}  H2 hue slope max <= 3.0: {smax:.3f}")
print(f"{verdict(min(cs) >= 25 and max(cs) <= 35)}  H3 |centre shift| in [25,35] at L0.6C0.06: {min(cs):.1f}..{max(cs):.1f}")
print(f"{verdict(all(reach))}  H3 shift <= gap-2 deg (never reaches neighbour centre)")
print(f"{verdict(all(dirs))}  H4 +100 -> next band, -100 -> previous")
H6 = lambda r: H(r) and not r["row"].endswith("C0.03")   # C 0.03: 8-bit noise floor ~1.8%
dc = agg(H6, "dC_rel_max", max); dl = agg(H6, "dL_max", max)
print(f"{verdict(dc < 0.02)}  H5 hue move chroma change < 2% (rows C>=0.06): {dc:.4f}")
print(f"{verdict(dl < 0.005)}  H5 hue move L change < 0.005: {dl:.4f}")
for c, t in (("hue", 0.10), ("sat", 0.10), ("lum", 0.10)):
    s = agg(lambda r: r["comp"] == c and r["coverage"] >= 0.9, "seam", max)
    print(f"{verdict(s <= t)}  X5 seam {c} <= {t}/deg (rows with coverage >= 0.9): {s:.3f}")
