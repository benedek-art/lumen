import sys, json, numpy as np
def read_lfi(p):
    with open(p,'rb') as f: hdr=f.read(16)
    assert hdr[:4]==b'LFI1'
    w,h,c=np.frombuffer(hdr[4:16],'<u4')
    return np.memmap(p,'<f4','r',16,(h,w,3))
rng=np.random.default_rng(1)
KS=(5,15,17,19,25)
out=[]
for path in sys.argv[1:]:
    img=read_lfi(path); H,W,_=img.shape
    meta=json.load(open(path[:-4]+'.json'))
    B=64
    nb_y,nb_x=H//B,W//B
    g=np.asarray(img[:nb_y*B,:nb_x*B],dtype=np.float32)
    # 8x8 sub-block means
    sub=g.reshape(nb_y,8,8,nb_x,8,8,3).mean(axis=(2,5))  # (nby,8,nbx,8,3)
    lum=sub.mean(axis=4)
    bm=lum.mean(axis=(1,3)); bs=lum.std(axis=(1,3))
    cm=sub.mean(axis=(1,3))  # nby,nbx,3
    mx=g.reshape(nb_y,B,nb_x,B,3).max(axis=(1,3,4))
    rel=bs/np.maximum(bm,1e-6)
    lr=np.log(np.maximum(cm[...,0],1e-6)/np.maximum(cm[...,1],1e-6)); lb=np.log(np.maximum(cm[...,2],1e-6)/np.maximum(cm[...,1],1e-6))
    ok=(bm>0.02)&(bm<0.5)&(mx<0.95)&(np.abs(lr)<0.5)&(np.abs(lb)<0.5)
    if ok.sum()<3: ok=(bm>0.02)&(bm<0.5)&(mx<0.95)
    idx=np.argwhere(ok); order=np.argsort(rel[ok])[:3]
    for (by,bx) in idx[order]:
        cy,cx=by*B+B//2,bx*B+B//2
        res={'file':path.split('/')[-1],'iso':meta['camera']['iso'],'mp':round(W*H/1e6,1),'patch':[int(cx),int(cy)],'level':float(bm[by,bx]),'texture_rel':float(rel[by,bx])}
        clicks=[(cy+rng.integers(-8,9),cx+rng.integers(-8,9)) for _ in range(300)]
        for k in KS:
            r=k//2
            m=np.array([np.asarray(img[y-r:y+r+1,x-r:x+r+1]).reshape(-1,3).mean(0) for y,x in clicks])
            res[k]={'cvG':float(m[:,1].std()/m[:,1].mean()),'sd_lnRG':float(np.log(m[:,0]/m[:,1]).std()) if (m>0).all() else None,'sd_lnBG':float(np.log(m[:,2]/m[:,1]).std()) if (m>0).all() else None,'means':m.tolist()}
        res['asShot']=(meta['as_shot']['kelvin'],meta['as_shot']['tint'])
        out.append(res)
json.dump(out,open('noise_fit.json','w'))
for r in out:
    print(r['file'],'iso',r['iso'],'lvl %.3f tex %.3f'%(r['level'],r['texture_rel']), ' '.join('k%d cvG %.3f sdRG %s'%(k,r[k]['cvG'],'%.3f'%r[k]['sd_lnRG'] if r[k]['sd_lnRG'] is not None else 'neg') for k in KS))
