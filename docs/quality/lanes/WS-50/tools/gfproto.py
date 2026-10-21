import numpy as np
from scipy import ndimage as ndi
def box(x, r): return ndi.uniform_filter(x, 2*r+1, mode='nearest')
M_2020_XYZ = np.array([[0.636958, 0.144617, 0.168881],[0.262700, 0.677998, 0.059302],[0.0, 0.028073, 1.060985]])
M1 = np.array([[0.8189330101,0.3618667424,-0.1288597137],[0.0329845436,0.9293118715,0.0361456387],[0.0482003018,0.2643662691,0.6338517070]])
M2 = np.array([[0.2104542553,0.7936177850,-0.0040720468],[1.9779984951,-2.4285922050,0.4505937099],[0.0259040371,0.7827717662,-0.8086757660]])
def luma_guide(rgb):
    y = 0.2627*rgb[...,0]+0.6780*rgb[...,1]+0.0593*rgb[...,2]
    ev = np.log2(np.maximum(y, 2**-16)); lo, hi = np.percentile(ev, [2, 98])
    return np.clip((ev - lo) / max(hi - lo, 1e-6), 0, 1)
def lab(rgb):
    lms = np.clip(rgb, 0, None) @ (M1 @ M_2020_XYZ).T; return np.cbrt(lms) @ M2.T
def colour_guide(rgb, k=2.0):
    L = luma_guide(rgb); l = lab(rgb); return np.stack([L, k*l[...,1], k*l[...,2]], -1)
def gf_gray(p, I, r, eps=1e-4):
    mI, mp = box(I, r), box(p, r); vI = np.maximum(box(I*I, r) - mI*mI, 0); cov = box(I*p, r) - mI*mp
    a = cov/(vI+eps); b = mp - a*mI; return box(a, r)*I + box(b, r)
def gf_colour(p, I, r, eps=1e-4):
    m = np.stack([box(I[...,i], r) for i in range(3)], -1); mp = box(p, r)
    S = np.empty(p.shape + (3, 3))
    for i in range(3):
        for j in range(i, 3):
            S[..., i, j] = S[..., j, i] = box(I[...,i]*I[...,j], r) - m[...,i]*m[...,j]
    S += eps*np.eye(3)
    cov = np.stack([box(I[...,i]*p, r) - m[...,i]*mp for i in range(3)], -1)
    a = np.linalg.solve(S, cov[..., None])[..., 0]
    b = mp - (a*m).sum(-1)
    q = sum(box(a[...,i], r)*I[...,i] for i in range(3)) + box(b, r)
    return q, (S[...,0,0]+S[...,1,1]+S[...,2,2] - 3*eps)
def follow(p, I, r, eps=1e-4, conf_eps=None):
    if I.ndim == 2: q = gf_gray(p, I, r, eps); tr = None
    else: q, tr = gf_colour(p, I, r, eps)
    q = np.clip(q, 0, 1)
    if conf_eps is None: return q
    if tr is None:
        mI = box(I, r); tr = np.maximum(box(I*I, r) - mI*mI, 0)
    w = tr/(tr+conf_eps)
    return p + w*(q-p)
