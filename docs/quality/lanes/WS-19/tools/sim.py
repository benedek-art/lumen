# Ground-truth sim: decode a clean low-ISO RAW twice through scripts/proof/decode_raw.py,
# the second time with noise (and, in simhot.py, defects/stars/speculars) injected on the
# mosaic before LibRaw demosaics it. Native resolution; centre crop for simhot.
# sim.py RAW out_prefix a b seed : decode clean and with Poisson-Gaussian noise injected on the mosaic
import sys, os
os.environ["OMP_NUM_THREADS"]="1"
sys.path.insert(0,os.path.join(os.path.dirname(os.path.abspath(__file__)),'../../../../../scripts/proof'))
import numpy as np, rawpy, decode_raw as dr, lfi
path,out,a,b=sys.argv[1],sys.argv[2],float(sys.argv[3]),float(sys.argv[4])
rng=np.random.default_rng(int(sys.argv[5]) if len(sys.argv)>5 else 1)
orig=rawpy.imread
def noisy(p):
    r=orig(p); im=r.raw_image
    blk=np.array(r.black_level_per_channel)[r.raw_colors] if r.raw_colors.shape==im.shape else r.black_level_per_channel[0]
    white=float(r.white_level); s=(im.astype(np.float64)-blk)/(white-blk)
    s=np.maximum(s,0)
    n=s+rng.standard_normal(s.shape)*np.sqrt(a*s+b)
    im[...]=np.clip(np.round(n*(white-blk)+blk),0,white).astype(im.dtype)
    return r
rec,_=dr.decode(path,long_edge=0); lfi.write(out+'_clean.lfi',rec)
rawpy.imread=noisy
rec,_=dr.decode(path,long_edge=0); lfi.write(out+'_noisy.lfi',rec)
print(rec.shape)
