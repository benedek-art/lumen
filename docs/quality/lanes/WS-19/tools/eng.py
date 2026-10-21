# Python port of the SHIPPED S3 engine (commit 9068ded): ClassicalDenoise.apply with the
# old seed profile, white-noise thresholds and Y0U0V0 basis (DEF below). Verified against
# that Swift engine to 1.6e-7 on the G9 crop. measure.py uses it only for the "shipped"
# comparison columns; every "new" number comes from nrtool, i.e. the Swift engine.
import numpy as np, wav, lfi
from scipy.ndimage import uniform_filter
def box(p,r): return uniform_filter(p,2*r+1,mode='nearest') if r>0 else p
def radii(s):
    n=3.;wi=np.sqrt(12*s*s/n+1);wl=int(np.floor(wi));wl-= (wl%2==0);wl=max(wl,1)
    m=int(round((12*s*s-n*wl*wl-4*n*wl-3*n)/(-4*wl-4)));m=min(max(m,0),3)
    return [((wl if i<m else wl+2)-1)//2 for i in range(3)]
def edgemap(p,sig=1.5,lo=3.,hi=12.):
    s=p
    for r in radii(sig): s=box(s,r)
    sc=1/(2*np.sqrt(np.pi)*sig);e0,e1=lo*sc,hi*sc
    sp=np.pad(s,1,mode='edge');gx=(sp[1:-1,2:]-sp[1:-1,:-2])/2;gy=(sp[2:,1:-1]-sp[:-2,1:-1])/2
    g=np.sqrt(gx*gx+gy*gy);t=np.clip((g-e0)/(e1-e0),0,1);return t*t*(3-2*t)
def b3(p,s):
    from scipy.ndimage import convolve1d
    k=np.zeros(4*s+1);k[::s]=np.array([1,4,6,4,1])/16
    return convolve1d(convolve1d(p,k,axis=0,mode='nearest'),k,axis=1,mode='nearest')
def edgemap2(u,v,sig=1.5,lo=3.,hi=12.):
    su,sv=u,v
    for r in radii(sig): su=box(su,r);sv=box(sv,r)
    sc=1/(2*np.sqrt(np.pi)*sig);e0,e1=lo*sc,hi*sc
    def g(s):
        sp=np.pad(s,1,mode='edge');return (sp[1:-1,2:]-sp[1:-1,:-2])/2,(sp[2:,1:-1]-sp[:-2,1:-1])/2
    ux,uy=g(su);vx,vy=g(sv);gg=np.sqrt(ux*ux+uy*uy+vx*vx+vy*vy)
    t=np.clip((gg-e0)/(e1-e0),0,1);return t*t*(3-2*t)
def soft(d,t,edge,prot):
    T=t*(1-prot*edge) if prot>0 else t
    m=np.abs(d)-T;return np.where(m>0,np.sign(d)*m,0)
def guided(p,I,r=8,eps=1e-4):
    mI=box(I,r);mP=box(p,r);cI=box(I*I,r);cIP=box(I*p,r)
    a=(cIP-mI*mP)/(np.maximum(cI-mI*mI,0)+eps);b=mP-a*mI
    return box(a,r)*I+box(b,r)
def inv_unb(y,a,b):
    d=np.maximum(y,1.2247448713915889);i1=1/d;i2=i1*i1;i3=i2*i1;r=1.224744871391589
    lam=np.maximum(0.25*d*d+0.25*r*i1-1.375*i2+0.625*r*i3-0.125,0);return a*lam-b/a
def inv_alg(y,a,b): return 0.25*a*y*y-0.375*a-b/a
DEF=dict(lumaMaxK=2.5,lumaAnchorK=1.7,lumaAnchorS=60,chromaMaxK=2.5,chromaAnchorK=1.6,chromaAnchorS=25,
  gY=[1]*6,gU=[1]*6,gV=[1]*6,prof=1.0,lumaEdgeProt=0.8,contrastReach=0.9,smoothReach=3.0,blotchMax=0.10,levels=5,
  edgeLo=3.,edgeHi=12.,detailMode='old')
def kmap(s,mx,ak,asl):
    if s<=0: return 0.
    e=np.log(ak/mx)/np.log(asl/100);return mx*(s/100)**e
def apply(img,iso,luma=0,chroma=25,ld=50,lc=0,cd=50,cs=50,P=None):
    P={**DEF,**(P or {})}
    a,b=lfi.seed(iso);a*=P['prof'];b*=P['prof']
    kL=kmap(luma,P['lumaMaxK'],P['lumaAnchorK'],P['lumaAnchorS']);kC=kmap(chroma,P['chromaMaxK'],P['chromaAnchorK'],P['chromaAnchorS'])
    if kL<=0 and kC<=0: return img
    shrink=min(max(kL/P['lumaMaxK'],kC/P['chromaMaxK']),1)
    yuv=wav.to_yuv(img.astype(np.float64),a,b);L=P['levels']
    out=yuv.copy()
    if kL>0:
        e=edgemap(yuv[...,0],lo=P['edgeLo'],hi=P['edgeHi'])
        det,res=wav.atrous(yuv[...,0],L);ds=1.5-ld/100 if P['detailMode']=='old' else P['detailMode'](ld)
        for j in range(L):
            band=max(1-P['contrastReach']*lc/100*(j/(L-1))**P.get('contrastPow',1.0),0)
            if P.get('lumaMode')=='bayes':
                sn=wav.TABLE[j]*P['gY'][j]
                E=b3(det[j]**2,2**j)
                for extra in range(P.get('eSteps',1)-1): E=b3(E,2**(j+1+extra))
                sx=np.sqrt(np.maximum(E-sn*sn,0))
                T=np.minimum(kL*ds*band*sn*sn/(sx+P.get('eps',0.05)*sn),P.get('cap',4.0)*sn*ds*band)
                det[j]=soft(det[j],T,0,0)
            else:
                det[j]=soft(det[j],kL*ds*wav.TABLE[j]*P['gY'][j]*band,e,P['lumaEdgeProt'])
        out[...,0]=res+sum(det)
    if kC>0:
        u,v=yuv[...,1],yuv[...,2];e=edgemap2(u,v,lo=P['edgeLo'],hi=P['edgeHi']) if P.get('joint') else edgemap(np.sqrt(u*u+v*v),lo=P['edgeLo'],hi=P['edgeHi'])
        for c,g in ((1,P['gU']),(2,P['gV'])):
            det,res=wav.atrous(yuv[...,c],L)
            for j in range(L):
                if 'cm' in P:
                    sm=P['smoothF'](cs,j)
                    dF=P['detailF'](cd,j) if 'detailF' in P else 1.0
                    det[j]=soft(det[j],P['cscale'](chroma)*P['cm'][j]*wav.TABLE[j]*g[j]*sm*dF,e,P['cprot'](cd) if 'cprot' in P else cd/100)
                else:
                    det[j]=soft(det[j],kC*wav.TABLE[j]*g[j]*(1+P['smoothReach']*cs/100*j/(L-1)),e,cd/100)
            out[...,c]=res+sum(det)
        bl=cs/100*chroma/100
        if bl>0 and P['blotchMax']>0:
            I=img[...,0]*0.2627+img[...,1]*0.6780+img[...,2]*0.0593
            for c in (1,2): out[...,c]+= (guided(out[...,c],I)-out[...,c])*P['blotchMax']*bl
    v=np.einsum('ij,hwj->hwi',wav.MI if hasattr(wav,'MI') else wav.M.T,out)
    return (1-shrink)*inv_alg(v,a,b)+shrink*inv_unb(v,a,b)
