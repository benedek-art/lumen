import sys, math, numpy as np, json
sys.path.insert(0, '/home/user/lumen/docs/quality/lanes/WS-28/tools')
import fringe_metrics as fm
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
name = sys.argv[1]
src = f'/tmp/claude-0/audit/render_{name}.png'
im = Image.open(src).convert('RGB'); a8 = np.asarray(im)
lin = fm.srgb_to_linear(a8.astype(np.float32)/255)
h, w = lin.shape[:2]
lab = fm.to_oklab(lin, fm.M_SRGB_XYZ)
Y = fm.luminance(lin, fm.M_SRGB_XYZ)
LY = fm.binomial_smooth(np.log2(np.maximum(Y, 1e-4)))
gx, gy = fm.sobel(LY); edge = np.hypot(gx, gy) > 0.35
def boxblur(x, r):
    c = np.cumsum(np.cumsum(np.pad(x, ((r+1, r), (r+1, r)), mode='edge'), 0), 1)
    k = 2*r+1
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k*k)
hp = np.hypot(lab[..., 1] - boxblur(lab[..., 1], 8), lab[..., 2] - boxblur(lab[..., 2], 8))
# dilate edge by 3 px
e = edge.copy()
for _ in range(3):
    e = e | np.roll(e, 1, 0) | np.roll(e, -1, 0) | np.roll(e, 1, 1) | np.roll(e, -1, 1)
score_px = np.where(e, hp, 0)
TW, TH = 400, 300
cy, cx = (h-1)/2, (w-1)/2; hd = math.hypot(w/2, h/2)
best = {}
Yhi = float(np.percentile(Y, 85)); Ymid = float(np.percentile(Y, 50))
for y0 in range(0, h-TH+1, 150):
    for x0 in range(0, w-TW+1, 200):
        r = math.hypot(x0+TW/2-cx, y0+TH/2-cy)/hd
        if r < 0.72: continue
        q = ('T' if y0+TH/2 < cy else 'B') + ('L' if x0+TW/2 < cx else 'R')
        Yt = Y[y0:y0+TH, x0:x0+TW]
        if (Yt > Yhi).mean() < 0.15 or (Yt < Ymid).mean() < 0.15: continue
        s = float(score_px[y0:y0+TH, x0:x0+TW].sum())
        if q not in best or s > best[q][0]: best[q] = (s, x0, y0, r)
out = []
for q, (s, x0, y0, r) in sorted(best.items()):
    crop = im.crop((x0, y0, x0+TW, y0+TH))
    p = f'/tmp/claude-0/audit/crop_{name.split("_")[0]}_{q}_x{x0}_y{y0}.png'
    crop.save(p)
    crop.resize((TW*2, TH*2), Image.NEAREST).save(p.replace('.png', '_x2.png'))
    out.append(dict(quadrant=q, x=x0, y=y0, r=round(r, 3), score=round(s, 1), path=p))
print(json.dumps(out, indent=1))
# boosted views: linear gain so the crop's p99.5 luminance -> 0.85, and 4x zoom of the
# 200x150 sub-window with the highest score
for o in out:
    x0, y0 = o['x'], o['y']
    sub = score_px[y0:y0+TH, x0:x0+TW]
    best_s, bx, by = -1, 0, 0
    for yy in range(0, TH-150+1, 25):
        for xx in range(0, TW-200+1, 25):
            s = sub[yy:yy+150, xx:xx+200].sum()
            if s > best_s: best_s, bx, by = s, xx, yy
    c = lin[y0:y0+TH, x0:x0+TW]
    Yc = fm.luminance(c, fm.M_SRGB_XYZ)
    g = 0.85/max(float(np.percentile(Yc, 99.5)), 1e-4)
    v = np.clip(c*g, 0, 1)
    enc = np.where(v <= 0.0031308, v*12.92, 1.055*v**(1/2.4)-0.055)
    b8 = Image.fromarray((enc*255+0.5).astype(np.uint8))
    p = o['path'].replace('.png', f'_gain{g:.1f}.png'); b8.save(p); o['boosted'] = p
    z = b8.crop((bx, by, bx+200, by+150)).resize((800, 600), Image.NEAREST)
    p2 = o['path'].replace('.png', f'_gain{g:.1f}_zoom4_at{x0+bx}_{y0+by}.png'); z.save(p2); o['zoom'] = p2
print(json.dumps(out, indent=1))
# chroma x4 view of each zoom (OKLab a,b scaled by 4 about the pixel, L kept), to make the fringe colour and side legible
def lab_to_srgb8(lab):
    Minv_lab = np.linalg.inv(fm.M_LMS_LAB); Minv_lms = np.linalg.inv(fm.M_XYZ_LMS); Minv_rgb = np.linalg.inv(fm.M_SRGB_XYZ)
    lms = (lab @ Minv_lab.T) ** 3
    rgb = lms @ Minv_lms.T @ Minv_rgb.T
    v = np.clip(rgb, 0, 1)
    enc = np.where(v <= 0.0031308, v*12.92, 1.055*v**(1/2.4)-0.055)
    return (enc*255+0.5).astype(np.uint8)
for o in out:
    zimg = np.asarray(Image.open(o['zoom']).convert('RGB')).astype(np.float32)/255
    L = fm.to_oklab(fm.srgb_to_linear(zimg), fm.M_SRGB_XYZ)
    L[..., 1:] *= 4
    p = o['zoom'].replace('.png', '_chroma4.png'); Image.fromarray(lab_to_srgb8(L)).save(p); o['chroma4'] = p
print(json.dumps(out, indent=1))
