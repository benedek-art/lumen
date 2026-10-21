import numpy as np, sys; sys.path.insert(0, '.')
from curvelib import *
from plot import plot
from PIL import Image
def hist(v): h = np.bincount(np.clip((v * 256).astype(int), 0, 255).ravel(), minlength=256).astype(float); return h
def emd(a, b): a=a/a.sum(); b=b/b.sum(); return np.abs(np.cumsum(a) - np.cumsum(b)).sum() / 256
def input_counts(out, f, per=8):
    n=len(out); m=n*per
    y=np.clip(f(np.arange(m+1)/m),0,1)*n
    cover=np.zeros(n); res=np.zeros(n); spans=[]
    for j in range(m):
        lo,hi=min(y[j],y[j+1]),max(y[j],y[j+1])
        if hi<=lo: spans.append([]); continue
        k=min(int(lo),n-1); s=[]
        while k<n and k<hi:
            o=min(hi,k+1)-max(lo,k)
            if o>0: s.append((k,o)); cover[k]+=o
            k+=1
        spans.append(s)
    for j,s in enumerate(spans):
        for k,o in s: res[j//per]+=out[k]*o/cover[k]
    for k in range(n):
        if cover[k]==0 and out[k]>0:
            j=int(np.argmin(np.abs(y-(k+.5)))); res[min(j//per,n-1)]+=out[k]
    return res
S=MonotoneCubic([[0,0],[.25,.15],[.75,.85],[1,1]])
A = np.asarray(Image.open('r8/6929_none.png').convert('RGB')).astype(float)
B = np.asarray(Image.open('r8/6929_S.png').convert('RGB')).astype(float)
linA = png_to_rec2020_linear(A); linB = png_to_rec2020_linear(B)
drawn_old = hist(srgb_enc(np.clip(linB @ W2020, 0, 1)))
truth = hist(np.clip(srgb_enc(np.clip(linA, 0, 1)) @ W2020, 0, 1))
new = input_counts(drawn_old, S)
print('EMD old', round(emd(drawn_old,truth),4), 'new', round(emd(new,truth),4))
xs=(np.arange(256)+.5)/256; mx=max((truth/truth.sum()).max(),(drawn_old/drawn_old.sum()).max())
plot([(xs,truth/truth.sum()/mx,(0,0,200)),(xs,drawn_old/drawn_old.sum()/mx,(200,0,0)),(xs,new/new.sum()/mx,(0,150,0)),(xs,S(xs),(0,0,0))],
     'after-histogram-backdrop-on-input-axis.png', yr=(0,1),
     title=f'6929 A7 IV, S-curve: true curve input (blue), old backdrop = output (red, EMD {emd(drawn_old,truth):.3f}), new backdrop (green, EMD {emd(new,truth):.4f})',
     labels=['true curve input','old: post-curve histogram','new: pulled back through the curve','the S curve'])
