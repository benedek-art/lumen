import numpy as np, struct
def read(p):
    with open(p,'rb') as f:
        b=f.read()
    w,h,c=struct.unpack('<III',b[4:16])
    return np.frombuffer(b,dtype='<f4',offset=16).reshape(h,w,3).copy()
def write(p,a):
    a=np.ascontiguousarray(a,dtype='<f4'); h,w,_=a.shape
    with open(p,'wb') as f:
        f.write(b'LFI1'+struct.pack('<III',w,h,3)); f.write(a.tobytes())
def seed(iso):
    import math
    sx=[100,400,1600,6400,25600,102400]; sa=[1e-5,4e-5,1.6e-4,6.4e-4,2.56e-3,1.024e-2]; sb=[1e-8,6e-8,4e-7,3e-6,2.4e-5,2e-4]
    l=math.log2(iso); xs=[math.log2(x) for x in sx]
    a=2**np.interp(l,xs,np.log2(sa)); b=2**np.interp(l,xs,np.log2(sb)); return a,b
def block_stats(ch,B=8):
    h,w=ch.shape; h-=h%B; w-=w%B
    x=ch[:h,:w].reshape(h//B,B,w//B,B).transpose(0,2,1,3).reshape(-1,B,B).astype(np.float64)
    c=(B-1)/2; d=np.arange(B)-c
    m=x.mean((1,2)); sx=(x*d[None,None,:]).sum((1,2)); sy=(x*d[None,:,None]).sum((1,2))
    sdx2=(d*d).sum()*B
    res=((x-m[:,None,None])**2).sum((1,2))-(sx*sx+sy*sy)/sdx2
    return m, np.maximum(res/(B*B-3),0)
def profile(ch, bins=16):
    m,v=block_stats(ch)
    lo,hi=np.percentile(m,[1,99]); out=[]
    edges=np.geomspace(max(lo,1e-4),hi,bins+1)
    for i in range(bins):
        s=(m>=edges[i])&(m<edges[i+1])
        if s.sum()<30: continue
        out.append((m[s].mean(), np.percentile(v[s],10)/0.776, s.sum()))
    return np.array(out)
