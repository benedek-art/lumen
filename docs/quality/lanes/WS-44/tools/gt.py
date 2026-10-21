from common import *
import numpy as np
from PIL import Image
def gt_4694():
    img=load('4694_canon-eos-r5'); L=oklab(img)
    C=np.hypot(L[...,1],L[...,2]); H=np.degrees(np.arctan2(L[...,2],L[...,1]))
    yy,xx=np.mgrid[0:img.shape[0],0:img.shape[1]]
    def ell(cx,cy,rx,ry): return ((xx-cx)/rx)**2+((yy-cy)/ry)**2<=1
    lemon = (C>0.03)&(H>60)&(H<115)&(L[...,0]>0.17)&ell(563,303,95,125)
    lemon = fill_holes(largest_cc_containing(lemon,(300,562)))
    apple = (C>0.03)&(H>20)&(H<115)&(L[...,0]>0.2)&ell(181,337,118,106)&~lemon
    apple = fill_holes(largest_cc_containing(apple,(335,180)))
    return img, {'lemon':lemon,'apple':apple}
if __name__=='__main__':
    img,g=gt_4694()
    out=np.array(Image.open('../photo_4694_canon-eos-r5.png').convert('RGB')).astype(float)
    for k,c in zip(g,[(0,0,255),(255,0,255)]):
        m=g[k]; out[m]=out[m]*0.5+np.array(c)*0.5
        np.save(f'../gt_4694_{k}.npy', m); print(k, m.sum(), np.argwhere(m).min(0), np.argwhere(m).max(0))
    Image.fromarray(out.astype(np.uint8)).save('../gt_4694.png')

def gt_8559():
    img=load('8559_nikon-z-fc'); L=oklab(img)
    C=np.hypot(L[...,1],L[...,2]); H=np.degrees(np.arctan2(L[...,2],L[...,1]))
    can=(C>0.05)&(H>-15)&(H<35)
    can=fill_holes(largest_cc_containing(can,(540,440)))
    return img, {'can':can}
if __name__=='__main__':
    img,g=gt_8559()
    out=np.array(Image.open('../photo_8559_nikon-z-fc.png').convert('RGB')).astype(float)
    m=g['can']; out[m]=out[m]*0.5+np.array((0,0,255))*0.5
    np.save('../gt_8559_can.npy', m); print('can', m.sum(), np.argwhere(m).min(0), np.argwhere(m).max(0))
    Image.fromarray(out.astype(np.uint8)).crop((280,400,800,683)).save('../gt_8559.png')
