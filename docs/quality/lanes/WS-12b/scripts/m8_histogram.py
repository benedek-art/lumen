"""Finding 8: histogram the editor draws (HEAD: post-curve luma = sRGB-encode(Rec.2020 Y)) vs the curve's input."""
import numpy as np, sys; sys.path.insert(0, '.')
from curvelib import *
from plot import plot
from PIL import Image
def hist(v): h = np.bincount(np.clip((v * 256).astype(int), 0, 255).ravel(), minlength=256).astype(float); return h / h.sum()
def emd(a, b): return np.abs(np.cumsum(a) - np.cumsum(b)).sum() / 256  # in units of the 0..1 axis
for p in ('6929', '2545'):
    for c in ('S', 'steep'):
        A = np.asarray(Image.open(f'r8/{p}_none.png').convert('RGB')).astype(float)
        B = np.asarray(Image.open(f'r8/{p}_{c}.png').convert('RGB')).astype(float)
        linA = png_to_rec2020_linear(A); linB = png_to_rec2020_linear(B)
        drawn = srgb_enc(np.clip(linB @ W2020, 0, 1))                  # what HEAD draws (post-curve, encode(Y))
        inp_luma = np.clip(srgb_enc(np.clip(linA, 0, 1)) @ W2020, 0, 1)  # curve's actual input under preserveLuminance (luma of encoded)
        inp_Y = srgb_enc(np.clip(linA @ W2020, 0, 1))                    # pre-curve on the histogram's own definition
        hd, hl, hy = hist(drawn), hist(inp_luma), hist(inp_Y)
        q = lambda v: [round(float(np.percentile(v, k)), 3) for k in (5, 25, 50, 75, 95)]
        print(f'{p} {c}: drawn(post) p5/25/50/75/95 {q(drawn)} | curve input (luma\') {q(inp_luma)} | pre-curve encode(Y) {q(inp_Y)}')
        print(f'      EMD drawn vs input {emd(hd, hl):.3f} (= {emd(hd, hl)*292:.0f} pt on a 292 pt plot); axis-definition only (encode(Y) vs luma\'): {emd(hy, hl):.3f}; '
              f'max |encode(Y)-luma\'| per px {np.abs(inp_Y-inp_luma).max():.3f} p99 {np.percentile(np.abs(inp_Y-inp_luma),99):.3f}')
        if p == '6929' and c == 'S':
            xs = (np.arange(256) + .5) / 256
            mx = max(hd.max(), hl.max())
            plot([(xs, hl / mx, (0, 0, 200)), (xs, hd / mx, (200, 0, 0)), (xs, MonotoneCubic([[0,0],[.25,.15],[.75,.85],[1,1]])(xs), (0, 0, 0))],
                 'm8_hist_6929_S.png', yr=(0, 1), title='6929 A7IV, S-curve: curve input histogram (blue) vs what the editor draws (red, post-curve)',
                 labels=['curve input (luma of encoded Rec.2020)', 'drawn: post-curve encode(Y)', 'the S curve'])
