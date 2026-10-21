# Real-image injection test: rescale R by sR and B by sB about the centre (bilinear),
# measure before/after, compare the change with the injected (s-1)*r*halfdiag.
import sys, math, numpy as np, json
sys.path.insert(0, '/home/user/lumen/docs/quality/lanes/WS-28/tools')
import fringe_metrics as fm
path, sR, sB = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
img = fm.read_lfi(path)
h, w = img.shape[:2]; cy, cx = (h-1)/2, (w-1)/2; hd = math.hypot(w/2, h/2)
out = img.copy()
for c, s in ((0, sR), (2, sB)):
    for y0 in range(0, h, 512):
        yy, xx = np.mgrid[y0:min(y0+512, h), 0:w].astype(np.float64)
        qx = cx + (xx-cx)/s; qy = cy + (yy-cy)/s
        out[y0:y0+512, :, c] = fm.bilinear(img[..., c:c+1], qx, qy)[..., 0]
# also resample G by 1.0 through the same bilinear path? G untouched (identity sampling).
a = fm.measure_lateral(img, rng=np.random.default_rng(5))
b = fm.measure_lateral(out, rng=np.random.default_rng(5))
res = {}
for ch, s in (('R-G', sR), ('B-G', sB)):
    for rv in (0.5, 0.75, 1.0):
        k = 'shift_at_r%.2f_px' % rv
        res[f'{ch} r={rv}'] = dict(before=a['fit'][ch][k], after=b['fit'][ch][k],
            delta=round(b['fit'][ch][k]-a['fit'][ch][k], 4), injected=round((s-1)*rv*hd, 4))
    for z in fm.ZONE_NAMES:
        res[f'{ch} zone {z} median delta'] = round(b['zones'][z][ch]['median_px'] - a['zones'][z][ch]['median_px'], 4)
print(json.dumps(res, indent=1))
