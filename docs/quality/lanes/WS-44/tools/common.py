import os
import sys, numpy as np
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(ROOT, 'scripts', 'proof'))
from decode_raw import read_lfi, area_downsample
# linear Rec.2020 -> OKLab (via LMS; Rec2020->XYZ->LMS)
M2020_XYZ = np.array([[0.636958,0.144617,0.168881],[0.262700,0.677998,0.059302],[0.0,0.028073,1.060985]])
XYZ_LMS = np.array([[0.8189330101,0.3618667424,-0.1288597137],[0.0329845436,0.9293118715,0.0361456387],[0.0482003018,0.2643662691,0.6338517070]])
LMS_LAB = np.array([[0.2104542553,0.7936177850,-0.0040720468],[1.9779984951,-2.4285922050,0.4505937099],[0.0259040371,0.7827717662,-0.8086757660]])
def load(id, le=1024):
    img = read_lfi(os.path.join(ROOT, 'corpus', 'lfi', f'{id}.lfi'))
    return area_downsample(img, le).astype(np.float64)
def oklab(rgb):
    lms = rgb @ (XYZ_LMS @ M2020_XYZ).T
    lms = np.cbrt(np.maximum(lms, 0))
    return lms @ LMS_LAB.T
def read_pfm(path):
    with open(path, "rb") as fh:
        assert fh.readline().strip() == b"Pf"
        w, h = map(int, fh.readline().split()); scale = float(fh.readline())
        a = np.frombuffer(fh.read(), dtype="<f4" if scale < 0 else ">f4").reshape(h, w)
    return np.flipud(a).astype(np.float64)
def largest_cc_containing(mask, seed):
    from collections import deque
    h, w = mask.shape; out = np.zeros_like(mask, bool)
    sy, sx = seed
    if not mask[sy, sx]: raise SystemExit('seed not in mask')
    q = deque([(sy, sx)]); out[sy, sx] = True
    while q:
        y, x = q.popleft()
        for ny, nx in ((y+1,x),(y-1,x),(y,x+1),(y,x-1)):
            if 0<=ny<h and 0<=nx<w and mask[ny,nx] and not out[ny,nx]:
                out[ny,nx]=True; q.append((ny,nx))
    return out
def fill_holes(m):
    # background = cc of ~m touching border
    from collections import deque
    h,w=m.shape; bg=np.zeros_like(m,bool); q=deque()
    for y in range(h):
        for x in (0,w-1):
            if not m[y,x] and not bg[y,x]: bg[y,x]=True; q.append((y,x))
    for x in range(w):
        for y in (0,h-1):
            if not m[y,x] and not bg[y,x]: bg[y,x]=True; q.append((y,x))
    while q:
        y,x=q.popleft()
        for ny,nx in ((y+1,x),(y-1,x),(y,x+1),(y,x-1)):
            if 0<=ny<h and 0<=nx<w and not m[ny,nx] and not bg[ny,nx]:
                bg[ny,nx]=True; q.append((ny,nx))
    return ~bg
