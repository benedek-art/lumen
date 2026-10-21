import sys,os,numpy as np
from PIL import Image
def load(p): return np.asarray(Image.open(p).convert('RGB')).astype(np.int32)
def alpha(w,h,cx=.5,cy=.5,rx=.25,ry=.3,f=.5):
    long=max(w,h); sx,sy=w/long,h/long
    y,x=np.mgrid[0:h,0:w]
    du=(x+.5)/long-cx*sx; dv=(y+.5)/long-cy*sy
    r=np.sqrt((du/(rx*sx))**2+(dv/(ry*sy))**2)
    rin=max(1-f,1/max(min(rx*w,ry*h),1))
    t=np.clip((r-rin)/(1-rin),0,1); a=1-t*t*(3-2*t)
    a[r<=rin]=1; a[r>=1]=0; return a
d='r/rad'
ims=sys.argv[1:]
for im in ims:
    N=load(f'{d}/{im}_none.png'); h,w,_=N.shape; A=alpha(w,h)
    out=A==0; core=A==1; tr=(A>0)&(A<1)
    for c in ['texture_-100','texture_100','clarity_-100','clarity_100','dehaze_-100','dehaze_100','sharpness_-100','sharpness_100','curve']:
        R=load(f'{d}/{im}_R_{c}.png'); F=load(f'{d}/{im}_F_{c}.png')
        dout=np.abs(R-N)[out].max() if out.any() else 0
        dcore=np.abs(R-F)[core].max()
        lo=np.minimum(N,F)[tr]; hi=np.maximum(N,F)[tr]; rv=R[tr]
        viol=((rv<lo-1)|(rv>hi+1)).any(axis=1).mean()*100
        over=np.maximum(lo-rv,rv-hi).max()
        print(f"{im:26s} {c:15s} outside max|R-N|={dout:3d}  core max|R-F|={dcore:3d}  transition: %px outside[N,F]±1={viol:5.2f} worst={over}")
