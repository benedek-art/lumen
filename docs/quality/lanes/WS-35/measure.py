# K1 grading-wheel measurements, end to end through lumen-render (sRGB output, no dither).
import sys, subprocess, json, os, numpy as np
from PIL import Image
BIN=os.environ.get("K1BIN","/home/user/lumen/.build/x86_64-unknown-linux-gnu/release/lumen-render")
SYN="/home/user/lumen/corpus/synthetic"
OUT=os.environ.get("K1OUT","/tmp/claude-0/k1/out"); os.makedirs(OUT, exist_ok=True)
M1=np.array([[0.4122214708,0.5363325363,0.0514459929],[0.2119034982,0.6806995451,0.1073969566],[0.0883024619,0.2817188376,0.6299787005]])
M2=np.array([[0.2104542553,0.7936177850,-0.0040720468],[1.9779984951,-2.4285922050,0.4505937099],[0.0259040371,0.7827717662,-0.8086757660]])
def lin(c):
    c=c/255.0; return np.where(c<=0.04045,c/12.92,((c+0.055)/1.055)**2.4)
def oklab(rgb): return np.cbrt(rgb@M1.T)@M2.T
cache={}
def render(inp, sets, le=1400):
    key=(inp,tuple(sets),le)
    if key in cache: return cache[key]
    p=f"{OUT}/m{abs(hash(key))}.png"
    cmd=[BIN,"render","--input",f"{SYN}/{inp}.lfi","--long-edge",str(le),"--no-dither",
         "--as-shot-kelvin","6503.7072","--as-shot-tint","9.77","--out",p]
    for s in sets: cmd+=["--set",s]
    subprocess.run(cmd,check=True,capture_output=True)
    im=np.asarray(Image.open(p).convert("RGB")).astype(float); cache[key]=im; return im
def ramp(sets):
    im=render("grey_ramp",sets); row=im[10:90].mean(axis=0)
    return oklab(lin(row)), row.mean(axis=1)/255.0
def hue(a,b): return np.degrees(np.arctan2(b,a))%360
def herr(x,y): return (x-y+180)%360-180
def main():
    res={}
    base,u=ramp([])
    # zone weight proxy: shadow/high wheel chroma relative to global wheel chroma, at hue 210
    def dC(sets):
        g,_=ramp(sets); d=g-base; return np.hypot(d[:,1],d[:,2]), d
    cg,_=dC(["look.wheels.global.hue=210","look.wheels.global.sat=0.5"])
    def zone(z, extra=[]):
        c,_=dC([f"look.wheels.{z}.hue=210",f"look.wheels.{z}.sat=0.5"]+extra)
        return np.where(cg>0.004, c/np.maximum(cg,1e-9), np.nan)
    def cross(w,u,level=0.5,falling=True):
        ok=~np.isnan(w)
        idx=np.where(ok)[0]
        for i in idx[:-1]:
            a,b=w[i],w[i+1]
            if np.isnan(b): continue
            if (falling and a>=level>b) or (not falling and a<level<=b):
                return float(u[i])
        return None
    for bl in [0,50,100]:
        for ba in [-100,0,100]:
            ex=[f"look.wheels.blending={bl}",f"look.wheels.balance={ba}"]
            ws=zone("shadows",ex); wh=zone("high",ex)
            res[f"zones_bl{bl}_ba{ba}"]=dict(shadow50=cross(ws,u,0.5,True),high50=cross(wh,u,0.5,False),
                shadow10=cross(ws,u,0.1,True),shadow90=cross(ws,u,0.9,True),
                high10=cross(wh,u,0.1,False),high90=cross(wh,u,0.9,False))
    # selectivity + black: shadows full sat teal
    c,d=dC(["look.wheels.shadows.hue=210","look.wheels.shadows.sat=1"])
    res["shadow_tint_in_highlights_maxC"]=float(np.nanmax(np.where(u>0.75,c,np.nan)))
    res["shadow_tint_at_black_C"]=float(np.nanmax(np.where(u<0.02,c,np.nan)))
    res["shadow_tint_at_black_dL"]=float(np.nanmax(np.where(u<0.02,np.abs(d[:,0]),np.nan)))
    c,d=dC(["look.wheels.high.hue=40","look.wheels.high.sat=1"])
    res["high_tint_in_shadows_maxC"]=float(np.nanmax(np.where(u<0.25,c,np.nan)))
    res["high_tint_at_white_C"]=float(np.nanmax(np.where(u>0.985,c,np.nan)))
    # hue accuracy per zone, 12 hues, sat 1: chroma-weighted mean hue of the tint over the zone core
    acc={}
    for z,lo,hi in [("shadows",0.05,0.25),("mid",0.4,0.6),("high",0.75,0.95),("global",0.1,0.9)]:
        errs=[]; chroma=[]
        for h in range(0,360,30):
            c,d=dC([f"look.wheels.{z}.hue={h}",f"look.wheels.{z}.sat=1"])
            m=(u>lo)&(u<hi)
            A=(d[m,1]).mean(); B=(d[m,2]).mean()
            errs.append(round(float(herr(hue(A,B),h)),1)); chroma.append(round(float(np.hypot(A,B)),4))
        acc[z]=dict(err=errs,meanAbs=float(np.mean(np.abs(errs))),maxAbs=float(np.max(np.abs(errs))),
                    chroma=chroma,chromaMaxOverMin=float(max(chroma)/max(min(chroma),1e-9)))
    res["hue_accuracy_sat1"]=acc
    # saturation evenness at sat .5 midtones
    ch=[]
    for h in range(0,360,30):
        c,d=dC([f"look.wheels.mid.hue={h}",f"look.wheels.mid.sat=0.5"]); m=(u>0.4)&(u<0.6)
        ch.append(float(np.hypot(d[m,1].mean(),d[m,2].mean())))
    res["mid_sat05_chroma"]=[round(x,4) for x in ch]; res["mid_sat05_maxOverMin"]=max(ch)/min(ch)
    # luminance hue shift on colorchecker
    cc0=render("colorchecker",[],800)
    def patches(im):
        h,w,_=im.shape; out=[]
        for r in range(4):
            for c in range(6):
                y=int((r+0.5)/4*h); x=int((c+0.5)/6*w)
                out.append(oklab(lin(im[y-5:y+5,x-5:x+5].reshape(-1,3).mean(axis=0))))
        return np.array(out)
    p0=patches(cc0)
    lumres={}
    for z in ["shadows","mid","high","global"]:
        for v in [-1,1]:
            p1=patches(render("colorchecker",[f"look.wheels.{z}.lum={v}"],800))
            C0=np.hypot(p0[:,1],p0[:,2]); C1=np.hypot(p1[:,1],p1[:,2])
            m=(C0>0.04)&(C1>0.04)
            e=np.abs(herr(hue(p1[m,1],p1[m,2]),hue(p0[m,1],p0[m,2])))
            lumres[f"{z}{v:+d}"]=dict(mean=round(float(e.mean()),2),max=round(float(e.max()),2),dL=round(float((p1[:,0]-p0[:,0]).mean()),3))
    res["lum_hue_shift"]=lumres
    json.dump(res,open(sys.argv[1] if len(sys.argv)>1 else f"{OUT}/measure.json","w"),indent=1)
    print(json.dumps(res,indent=1))


if __name__ == "__main__":
    main()
