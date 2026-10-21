# Ground-truth sim: decode a clean low-ISO RAW twice through scripts/proof/decode_raw.py,
# the second time with noise (and, in simhot.py, defects/stars/speculars) injected on the
# mosaic before LibRaw demosaics it. Native resolution; centre crop for simhot.
import sys, os
os.environ["OMP_NUM_THREADS"]="1"
sys.path.insert(0,os.path.join(os.path.dirname(os.path.abspath(__file__)),'../../../../../scripts/proof'))
import numpy as np, rawpy, decode_raw as dr, lfi
path,out=sys.argv[1],sys.argv[2]
SIGS=eval(sys.argv[3]) if len(sys.argv)>3 else [0.5,0.7,1.0,1.4]
KINDS=eval(sys.argv[4]) if len(sys.argv)>4 else ['base','hot','star','spec']
orig=rawpy.imread
def make(kind):
    def f(p):
        r=orig(p);im=r.raw_image;H,W=im.shape
        blk=np.array(r.black_level_per_channel)[r.raw_colors];white=float(r.white_level)
        s=np.maximum((im.astype(np.float64)-blk)/(white-blk),0)
        rng=np.random.default_rng(7)
        s=s+rng.standard_normal(s.shape)*np.sqrt(7e-4*s+4e-6)
        rng=np.random.default_rng(11)
        N=3000;ys=rng.integers(40,H-40,N);xs=rng.integers(40,W-40,N)
        if kind=='hot':
            s[ys,xs]+=rng.uniform(0.05,1.0,N)
        elif kind=='star':
            amp=rng.uniform(0.05,1.0,N);sig=rng.choice(SIGS,N)
            yy,xx=np.mgrid[-4:5,-4:5]
            for i in range(N):
                g=np.exp(-(yy**2+xx**2)/(2*sig[i]**2));g/=g.max()
                s[ys[i]-4:ys[i]+5,xs[i]-4:xs[i]+5]+=amp[i]*g
        elif kind=='spec':
            rad=rng.choice([1.0,1.5,2.5],N);yy,xx=np.mgrid[-4:5,-4:5]
            for i in range(N):
                disc=np.clip(rad[i]+0.5-np.sqrt(yy**2+xx**2),0,1)
                s[ys[i]-4:ys[i]+5,xs[i]-4:xs[i]+5]+=1.5*disc
        im[...]=np.clip(np.round(s*(white-blk)+blk),0,white).astype(im.dtype)
        return r
    return f
for kind in KINDS:
    rawpy.imread=make(kind)
    rec,_=dr.decode(path,long_edge=0); h,w,_=rec.shape
    lfi.write(out+'_%s.lfi'%kind,rec[h//2-768:h//2+768,w//2-768:w//2+768])
    print(kind,flush=True)
