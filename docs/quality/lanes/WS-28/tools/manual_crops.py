import sys, json, numpy as np, math
sys.path.insert(0, '/home/user/lumen/docs/quality/lanes/WS-28/tools')
import fringe_metrics as fm
from PIL import Image
Image.MAX_IMAGE_PIXELS = None
exec(open('crops.py').read().split('def lab_to_srgb8')[1].join(['def lab_to_srgb8','']) if False else '')
def lab_to_srgb8(lab):
    Minv_lab = np.linalg.inv(fm.M_LMS_LAB); Minv_lms = np.linalg.inv(fm.M_XYZ_LMS); Minv_rgb = np.linalg.inv(fm.M_SRGB_XYZ)
    rgb = ((lab @ Minv_lab.T) ** 3) @ Minv_lms.T @ Minv_rgb.T
    v = np.clip(rgb, 0, 1); enc = np.where(v <= 0.0031308, v*12.92, 1.055*v**(1/2.4)-0.055)
    return (enc*255+0.5).astype(np.uint8)
name = sys.argv[1]; tag = name.split('_')[0]
im = Image.open(f'render_{name}.png').convert('RGB'); W, H = im.size
hd = math.hypot(W/2, H/2)
out = []
for spec in sys.argv[2:]:
    x0, y0, zx, zy = map(int, spec.split(','))
    crop = im.crop((x0, y0, x0+400, y0+300)); p = f'crop_{tag}_m_x{x0}_y{y0}.png'; crop.save(p)
    c = fm.srgb_to_linear(np.asarray(crop).astype(np.float32)/255)
    g = 0.85/max(float(np.percentile(fm.luminance(c, fm.M_SRGB_XYZ), 99.5)), 1e-4)
    v = np.clip(c*g, 0, 1); enc = np.where(v <= 0.0031308, v*12.92, 1.055*v**(1/2.4)-0.055)
    b8 = Image.fromarray((enc*255+0.5).astype(np.uint8)); pb = p.replace('.png', f'_gain{g:.1f}.png'); b8.save(pb)
    z = b8.crop((zx, zy, zx+200, zy+150)).resize((800, 600), Image.NEAREST); pz = pb.replace('.png', f'_zoom4_at{x0+zx}_{y0+zy}.png'); z.save(pz)
    L = fm.to_oklab(fm.srgb_to_linear(np.asarray(z).astype(np.float32)/255), fm.M_SRGB_XYZ); L[..., 1:] *= 4
    pc = pz.replace('.png', '_chroma4.png'); Image.fromarray(lab_to_srgb8(L)).save(pc)
    r = math.hypot(x0+zx+100-(W-1)/2, y0+zy+75-(H-1)/2)/hd
    out.append(dict(crop=p, boosted=pb, zoom=pz, chroma4=pc, r=round(r, 3)))
print(json.dumps(out, indent=1))
