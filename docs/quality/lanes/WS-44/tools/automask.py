#!/usr/bin/env python3
# WS-44 Auto Mask edge test (auditor, adapted): python3 automask.py OUTDIR [lumen-render]
# Ground-truth objects from colour thresholds (gt.py); leak = mask mass outside the object.
import json, math, subprocess, os, numpy as np
sys_path_hack=None
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common import *
from PIL import Image
import sys
A=sys.argv[1] if len(sys.argv)>1 else 'automask-out'
os.makedirs(A, exist_ok=True)
BIN=sys.argv[2] if len(sys.argv)>2 else '.build/release/lumen-render'
W,H=1024,683
SIZE=0.06; R=SIZE/2*W   # 30.7 px
def march(gt, cx, cy, dx, dy):
    x,y=cx,cy
    while 0<=int(round(y))<gt.shape[0] and 0<=int(round(x))<gt.shape[1] and gt[int(round(y)),int(round(x))]:
        x+=dx*0.5; y+=dy*0.5
    return x,y
def loop(gt, cx, cy, a0=0, a1=360, n=None, inset=0.5):
    pts=[]
    steps=int(abs(a1-a0)/2)+1
    for i in range(steps):
        th=math.radians(a0+(a1-a0)*i/(steps-1))
        dx,dy=math.cos(th),math.sin(th)
        bx,by=march(gt,cx,cy,dx,dy)
        pts.append((bx-dx*inset*R, by-dy*inset*R))
    # resample to ~4px spacing (mouse events)
    out=[pts[0]]
    for p in pts[1:]:
        if math.hypot(p[0]-out[-1][0],p[1]-out[-1][1])>=4: out.append(p)
    return out
def line(x0,y0,x1,y1,step=4):
    n=max(2,int(math.hypot(x1-x0,y1-y0)/step)+1)
    return [(x0+(x1-x0)*i/(n-1), y0+(y1-y0)*i/(n-1)) for i in range(n)]
def stroke_json(pts, automask, feather=50):
    return {"version":1,"strokes":[{"points":[[x/W,y/H,1.0,i*8] for i,(x,y) in enumerate(pts)],
            "size":SIZE,"feather":feather,"flow":100,"density":100, **({"automask":True} if automask else {})}]}
def dist_to_poly(pts, shape, bbox):
    y0,y1,x0,x1=bbox
    yy,xx=np.mgrid[y0:y1,x0:x1]; px=xx+0.5; py=yy+0.5
    d=np.full(px.shape,1e9)
    P=np.array(pts)
    for (ax,ay),(bx,by) in zip(P[:-1],P[1:]):
        vx,vy=bx-ax,by-ay; L2=vx*vx+vy*vy or 1e-9
        t=np.clip(((px-ax)*vx+(py-ay)*vy)/L2,0,1)
        d=np.minimum(d,np.hypot(px-ax-t*vx,py-ay-t*vy))
    full=np.full(shape,1e9); full[y0:y1,x0:x1]=d; return full
cases={}
from gt import gt_4694, gt_8559
os.makedirs(A, exist_ok=True)
_, _g = gt_4694(); lemon, apple = _g['lemon'], _g['apple']
can = gt_8559()[1]['can']
cases['lemon_a']=('4694_canon-eos-r5',lemon,loop(lemon,563,303))
cases['lemon_b']=('4694_canon-eos-r5',lemon,line(563,300,720,300))
cases['apple_a']=('4694_canon-eos-r5',apple,loop(apple,181,337))
cases['apple_b']=('4694_canon-eos-r5',apple,line(180,335,10,335))
# can: trace the bottom edge, x 400..545, centre 0.5R above the GT boundary
cpts=[]
for x in range(400,546,4):
    bx,by=march(can,x,540,0,1); cpts.append((x,by-0.5*R))
cases['can_a']=('8559_nikon-z-fc',can,cpts)
cases['can_b']=('8559_nikon-z-fc',can,line(440,540,440,675))
res={}
for name,(pid,gt,pts) in cases.items():
    d=dist_to_poly(pts,gt.shape,(0,H,0,W))
    for am in (False,True):
        tag=f"{name}_{'am' if am else 'off'}"
        j=f'{A}/{tag}.json'; json.dump(stroke_json(pts,am),open(j,'w'))
        subprocess.run([BIN,'strokes','--strokes',j,'--input',os.path.join(ROOT,'corpus','lfi',pid+'.lfi'),'--long-edge','1024',
            '--out',f'{A}/{tag}.png','--pfm-out',f'{A}/{tag}.pfm','--metrics',f'{A}/{tag}.metrics.json','--repeat','3'],check=True,stdout=subprocess.DEVNULL)
        a=read_pfm(f'{A}/{tag}.pfm')
        tot=a.sum(); out=a[~gt].sum()
        band=gt&(d<=0.8*R)
        m=json.load(open(f'{A}/{tag}.metrics.json'))
        # leak beyond the object counted only for pixels within 1R of an object pixel stamp centred inside
        res[tag]={'leak_pct':round(100*out/tot,1),'coverage':round(float(a[band].mean()),3),
                  'cov_min_p5':round(float(np.percentile(a[band],5)),3),
                  'mass_px':round(float(tot)),'ms':round(m['perStroke'][0]['ms'],1),
                  'msPerRadius':round(m['perStroke'][0]['msPerRadius'],3),'points':len(pts)}
        print(tag,res[tag])
json.dump(res,open(f'{A}/automask.json','w'),indent=1)
