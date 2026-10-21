import numpy as np
from scipy.ndimage import convolve1d
TABLE=[0.8907,0.2007,0.0856,0.0413,0.0205,0.0103]
M=np.array([[0.5773502691896258]*3,[0.7071067811865475,0,-0.7071067811865475],[0.4082482904638631,-0.8164965809277261,0.4082482904638631]])
def atrous(p,L=5):
    det=[];c=p
    for j in range(L):
        s=2**j; k=np.zeros(4*s+1); k[::s]=np.array([1,4,6,4,1])/16
        n=convolve1d(convolve1d(c,k,axis=0,mode='nearest'),k,axis=1,mode='nearest')
        det.append(c-n); c=n
    return det,c
def vst(x,a,b):
    return (2/a)*np.sqrt(np.maximum(a*x+0.375*a*a+b,0))
def to_yuv(img,a,b):
    v=vst(img,a,b); return np.einsum('ij,hwj->hwi',M,v)
def block_sigma(p,B=32,pct=10,mask=None):
    h,w=p.shape;h-=h%B;w-=w%B
    x=p[:h,:w].reshape(h//B,B,w//B,B).transpose(0,2,1,3).reshape(-1,B*B)
    s=1.4826*np.median(np.abs(x-np.median(x,1,keepdims=True)),1)
    if mask is not None: s=s[mask]
    return np.percentile(s,pct)
