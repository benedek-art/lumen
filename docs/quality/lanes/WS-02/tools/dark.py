import sys,json,numpy as np,subprocess
import os
# NATIVE: folder of native-resolution decodes (decode_raw.py --long-edge 0); SOLVER: built tools/solver binary
NATIVE=os.environ.get('NATIVE','/tmp/claude-0/-home-user-lumen/570f3fe6-32ea-58a4-833c-55f6084bcf78/scratchpad/native')
SOLVER=os.environ.get('SOLVER','/tmp/claude-0/-home-user-lumen/570f3fe6-32ea-58a4-833c-55f6084bcf78/scratchpad/solver/.build/x86_64-unknown-linux-gnu/release/solve')
def read_lfi(p):
    hdr=open(p,'rb').read(16); w,h,c=np.frombuffer(hdr[4:16],'<u4'); return np.memmap(p,'<f4','r',16,(h,w,3))
rng=np.random.default_rng(2)
lines=[];keys=[]
for f,k in (('1332_canon-eos-77d',19),('4213_nikon-z-7-2',25),('2348_panasonic-dc-g9',17)):
    img=read_lfi(f'{NATIVE}/{f}.lfi'); H,W,_=img.shape; meta=json.load(open(f'{NATIVE}/{f}.json'))
    K,T=meta['as_shot']['kelvin'],meta['as_shot']['tint']
    B=64; g=np.asarray(img[:H//B*B,:W//B*B]); nb=(H//B,W//B)
    blk=g.reshape(nb[0],B,nb[1],B,3); cm=blk.mean(axis=(1,3)); sd=blk.mean(axis=3).std(axis=1)  # rough
    lum=cm@np.array([0.2627,0.678,0.0593])
    rel=blk.reshape(nb[0],B,nb[1],B,3).mean(4).std(axis=(1,3))/np.maximum(lum,1e-6)
    for lo,hi in ((0.0015,0.0025),(0.004,0.006),(0.009,0.012),(0.02,0.03)):
        ok=(lum>lo)&(lum<hi)&(cm.min(axis=2)>0)
        idx=np.argwhere(ok)
        if len(idx)==0: print(f,lo,'none'); continue
        order=np.argsort(rel[ok])[:3]
        for (by,bx) in idx[order]:
            cy,cx=by*B+B//2,bx*B+B//2; r=k//2
            for _ in range(120):
                y,x=cy+rng.integers(-8,9),cx+rng.integers(-8,9)
                m=np.asarray(img[y-r:y+r+1,x-r:x+r+1]).reshape(-1,3).mean(0)
                lines.append('%g %g %g %g %g'%(m[0],m[1],m[2],K,T)); keys.append((f,k,lo,int(cy),int(cx)))
out=subprocess.run([SOLVER],input='\n'.join(lines)+'\n',capture_output=True,text=True).stdout.split('\n')
res={}
for kk,o in zip(keys,out):
    if o: res.setdefault(kk,[]).append(1e6/float(o.split()[0]))
import collections
agg=collections.defaultdict(list)
for kk,v in res.items(): agg[kk[:3]].append(np.std(v))
for kk,v in agg.items(): print(kk,'median sdMired over %d patches %.1f'%(len(v),np.median(v)))
