import sys, numpy as np
from PIL import Image
def lin(c):
    c = c/255.0
    return np.where(c<=0.04045, c/12.92, ((c+0.055)/1.055)**2.4)
def load(p): return np.asarray(Image.open(p).convert('RGB')).astype(np.float64)
def stats(a,b):
    A,B=load(a),load(b)
    d=np.abs(A-B); dl=np.abs(lin(A)-lin(B))
    return dict(maxc=d.max(), meanc=d.mean(), p99c=np.percentile(d,99), pct_gt2=(d.max(axis=2)>2).mean()*100,
                maxl=dl.max(), meanl=dl.mean())
if __name__=='__main__':
    s=stats(sys.argv[1],sys.argv[2])
    print(' '.join(f'{k}={v:.4g}' for k,v in s.items()))
