import sys
sys.path.insert(0, '/tmp/claude-0/-home-user-lumen/7b419a8a-9f16-5bc3-bbad-d84e24161d81/scratchpad/tonefix')
from wbmodel import *
def cone(k,t): return CAT16@xyz(dng_chroma(k,t))
def ra(k,t):
    s=CAT16@xyz(dng_chroma(k,t)); d=CAT16@xyz(dng_chroma(5500,0))
    M=X2R@np.linalg.inv(CAT16)@np.diag(d/s)@CAT16@R2X
    out=M@np.array([.18,.18,.18])
    if not np.all(np.isfinite(out)) or out.min()<0: return None
    return oklab_xyz(R2X@out)[1]
def limit(k,sign):
    b=cone(k,0)
    def ok(a):
        c=cone(k,sign*a)
        if np.any(c<0.15*b): return False
        h=ra(k,sign*a); n=ra(k,sign*(a+.25))
        if h is None or n is None: return False
        return sign*(n-h)>=0
    if ok(300): return 300
    lo,hi=0,300
    for _ in range(40):
        m=(lo+hi)/2
        if ok(m): lo=m
        else: hi=m
    return lo
for k in [2000,2500,2800,3200,4000,4500,5000,5500,6500,10000,50000]:
    print(k, round(limit(k,1),2), round(limit(k,-1),2))
