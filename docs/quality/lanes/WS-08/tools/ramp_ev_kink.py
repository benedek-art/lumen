#!/usr/bin/env python3
"""WS-08 companion to ramp_check.py: the rendered zone response IN EV, through the pipeline.

ramp_check.py's maxKink divides each render's slope by the default render's slope at the
SAME input EV. A recipe that moves a tone by e EV lands it on a different part of the
display toe, so that ratio changes with the toe's curvature even for a flat shift:
Exposure +0.95 alone scores maxKink 3.13 there. This script reads the tone the pipeline
actually rendered instead: it inverts the default render (monotone) to turn each output
code back into the input EV that the default would have needed for it, u(t), and reports
the slope du/dt and its change over 0.1 EV. For a pure shift du/dt is 1 everywhere.

Usage: ramp_ev_kink.py <dir with ramp_check.py's PNGs> [recipe ...]
Rows 0-199 averaged, 0.1 EV box smooth, as ramp_check.py. Only codes 12-245 are read
(the default render's slope there is >= 5 codes/EV, so the inversion is well conditioned).
"""
import sys, numpy as np
from PIL import Image
d = sys.argv[1]
names = sys.argv[2:] or ['dark+3', 'dark+1.25', 'mid-3', 'mid+3', 'light-3', 'shadow+3',
                         'bright-3', 'dark+3,mid-3', 'shadow+3,mid-3,light+3']
ev = -10 + (np.arange(2800) + 0.5) / 200
k = np.ones(20) / 20
def load(n):
    p = f'{d}/{n.replace(",", "_")}.png'
    g = np.asarray(Image.open(p).convert('RGB')).astype(float)[0:200].mean(axis=0).mean(axis=1)
    return np.convolve(g, k, 'same')
base = load('default')
m = (ev > -9.8) & (ev < 3.8)
bm = np.maximum.accumulate(np.where(m, base, -1))      # monotone for np.interp
print(f"{'recipe':26s} {'minSlope':>8s} {'maxSlope':>8s} {'maxKinkEV':>9s} {'@EV':>6s}")
for n in names:
    c = load(n)
    ok = m & (c > 12) & (c < 245)
    u = np.interp(c, bm[m], ev[m])
    s = np.gradient(u, ev)
    s = np.where(ok, s, np.nan)
    kk = np.abs(s[20:] - s[:-20])
    i = np.nanargmax(kk)
    print(f"{n:26s} {np.nanmin(s):8.2f} {np.nanmax(s):8.2f} {kk[i]:9.2f} {ev[i]:+6.2f}")
