import numpy as np, math
CAT16=np.array([[0.401288,0.650173,-0.051461],[-0.250268,1.204414,0.045854],[-0.002079,0.048952,0.953127]])
def prim_to_xyz(xr,yr,xg,yg,xb,yb,xw,yw):
    def col(x,y): return np.array([x/y,1,(1-x-y)/y])
    P=np.stack([col(xr,yr),col(xg,yg),col(xb,yb)],1)
    W=col(xw,yw); S=np.linalg.solve(P,W); return P*S
R2X=prim_to_xyz(0.708,0.292,0.170,0.797,0.131,0.046,0.3127,0.3290); X2R=np.linalg.inv(R2X)
M1=np.array([[0.8189330101,0.3618667424,-0.1288597137],[0.0329845436,0.9293118715,0.0361456387],[0.0482003018,0.2643662691,0.6338517070]])
M2=np.array([[0.2104542553,0.7936177850,-0.0040720468],[1.9779984951,-2.4285922050,0.4505937099],[0.0259040371,0.7827717662,-0.8086757660]])
def oklab_xyz(x):
    l=np.cbrt(M1@x); return M2@l
def xyz(xy): x,y=xy; return np.array([x/y,1,(1-x-y)/y])
def uv(xy): x,y=xy; d=-2*x+12*y+3; return 4*x/d,6*y/d
def fromuv(u,v): d=2*u-8*v+4; return 3*u/d,2*v/d
def daylight(t):
    x=(0.244063+0.09911e3/t+2.9678e6/t**2-4.6070e9/t**3) if t<=7000 else (0.237040+0.24748e3/t+1.9018e6/t**2-2.0064e9/t**3)
    return x,-3*x*x+2.87*x-0.275
def planckX(t):
    if t<=4000: return -0.2661239e9/t**3-0.2343589e6/t**2+0.8776956e3/t+0.179910
    return -3.0258469e9/t**3+2.1070379e6/t**2+0.2226347e3/t+0.240390
def planck(t):
    t=max(t,1667); x=planckX(t)
    if t<=2222: y=-1.1063814*x**3-1.34811020*x**2+2.18555832*x-0.20219683
    elif t<=4000: y=-0.9549476*x**3-1.37418593*x**2+2.09137015*x-0.16748867
    else: y=3.0817580*x**3-5.87338670*x**2+3.75112997*x-0.37001483
    return x,y
def smooth(a,b,x):
    t=min(max((x-a)/(b-a),0),1); return t*t*(3-2*t)
def locus(t):
    if t<=3500: return planck(t)
    if t>=4500: return daylight(t)
    w=smooth(3500,4500,t); p=planck(t); d=daylight(t); return (p[0]+(d[0]-p[0])*w,p[1]+(d[1]-p[1])*w)
UNIT=0.05/150
def lumen_chroma(k,tint):
    u,v=uv(locus(k)); return fromuv(u,v+tint*UNIT)
TABLE=[(0,0.18006,0.26352,-0.24341),(10,0.18066,0.26589,-0.25479),(20,0.18133,0.26846,-0.26876),(30,0.18208,0.27119,-0.28539),(40,0.18293,0.27407,-0.30470),(50,0.18388,0.27709,-0.32675),(60,0.18494,0.28021,-0.35156),(70,0.18611,0.28342,-0.37915),(80,0.18740,0.28668,-0.40955),(90,0.18880,0.28997,-0.44278),(100,0.19032,0.29326,-0.47888),(125,0.19462,0.30141,-0.58204),(150,0.19962,0.30921,-0.70471),(175,0.20525,0.31647,-0.84901),(200,0.21142,0.32312,-1.0182),(225,0.21807,0.32909,-1.2168),(250,0.22511,0.33439,-1.4512),(275,0.23247,0.33904,-1.7298),(300,0.24010,0.34308,-2.0637),(325,0.24702,0.34655,-2.4681),(350,0.25591,0.34951,-2.9641),(375,0.26400,0.35200,-3.5814),(400,0.27218,0.35407,-4.3633),(425,0.28039,0.35577,-5.3762),(450,0.28863,0.35714,-6.7262),(475,0.29685,0.35823,-8.5955),(500,0.30505,0.35907,-11.324),(525,0.31320,0.35968,-15.628),(550,0.32129,0.36011,-23.325),(575,0.32931,0.36038,-40.770),(600,0.33724,0.36051,-116.45)]
def dng_chroma(k,tint):
    r=1e6/k; off=tint/-3000; i=0
    while i<len(TABLE)-2 and not (r<TABLE[i+1][0]): i+=1
    lo,hi=TABLE[i],TABLE[i+1]; f=(hi[0]-r)/(hi[0]-lo[0])
    u=lo[1]*f+hi[1]*(1-f); v=lo[2]*f+hi[2]*(1-f)
    l1=math.sqrt(1+lo[3]**2); l2=math.sqrt(1+hi[3]**2)
    uu=(1/l1)*f+(1/l2)*(1-f); vv=(lo[3]/l1)*f+(hi[3]/l2)*(1-f); l3=math.hypot(uu,vv)
    return fromuv(u+uu/l3*off, v+vv/l3*off)
def render(model, asshot, target, rgb=(0.18,0.18,0.18)):
    s=CAT16@xyz(model(*target)); d=CAT16@xyz(model(*asshot))
    A=np.linalg.inv(CAT16)@np.diag(d/s)@CAT16
    M=X2R@A@R2X
    out=M@np.array(rgb)
    lab=oklab_xyz(R2X@out)
    return out,lab
def hc(lab): return math.degrees(math.atan2(lab[2],lab[1]))%360, math.hypot(lab[1],lab[2])
if __name__=='__main__':
    for name,model in [('lumen',lumen_chroma),('dng',dng_chroma)]:
        print('==',name)
        for k0 in [5500,3000]:
            for tgt in [(k0,-150),(k0,-50),(k0,50),(k0,150),(k0-1000,0),(k0+1500,0)]:
                out,lab=render(model,(k0,0),tgt); h,c=hc(lab)
                print(f' asShot {k0}/0 target {tgt}: rgb {np.round(out/0.18,3)} hue {h:6.1f} C {c:.4f}')
