"""WS-03 WB maths in Python (measurement tooling only, not product code).

- `lumen_*`, `wb_matrix`: port of the PRE-WS-03 Lumen model (ColorTemperature locus + v-offset tint +
  magenta guard, WhiteBalanceEngine.adaptation). Used only to state "before" numbers.
- `dng_xy` / `dng_kt`: port of DNGTemperature.swift (Adobe DNG SDK, Robertson, kTintScale -3000).
- `adobe_matrix`: the TARGET model of the spec: CAT16 from dng_xy(target) to dng_xy(as-shot), in
  Rec.2020 (no guard; every spec use stays inside the guard).
- `decoded_grey`: a 0.18 grey lit by illuminant L, decoded at as-shot A (decode modelled as CAT16 A->D65).
- `de_grey`: CIEDE2000 of a linear Rec.2020 colour vs the neutral of the same Y.
Ported from the WS-03 audit scratch (wbmodel.py, q1b.py)."""
import numpy as np
from functools import lru_cache

def xyz_of(x, y, Y=1.0):
    return np.array([Y*x/y, Y, Y*(1-x-y)/y])
def uv_of(x, y):
    d = -2*x + 12*y + 3
    return 4*x/d, 6*y/d
def xy_from_uv(u, v):
    d = 2*u - 8*v + 4
    return 3*u/d, 2*v/d

def rgb_to_xyz_matrix(prim, white):
    P = np.array([xyz_of(*p) for p in prim]).T
    S = np.linalg.solve(P, xyz_of(*white))
    return P * S
REC2020_TO_XYZ = rgb_to_xyz_matrix([(0.708,0.292),(0.170,0.797),(0.131,0.046)], (0.3127,0.3290))
XYZ_TO_REC2020 = np.linalg.inv(REC2020_TO_XYZ)
SRGB_TO_XYZ = rgb_to_xyz_matrix([(0.64,0.33),(0.30,0.60),(0.15,0.06)], (0.3127,0.3290))

CAT16 = np.array([[0.401288,0.650173,-0.051461],[-0.250268,1.204414,0.045854],[-0.002079,0.048952,0.953127]])
BRADFORD = np.array([[0.8951,0.2664,-0.1614],[-0.7502,1.7135,0.0367],[0.0389,-0.0685,1.0296]])
def adapt(src_xyz, dst_xyz, cone=CAT16):
    s = cone @ src_xyz; d = cone @ dst_xyz
    return np.linalg.inv(cone) @ np.diag(d/s) @ cone

def smoothstep(a, b, x):
    t = min(max((x-a)/(b-a), 0), 1); return t*t*(3-2*t)
def planckX(t):
    if t <= 4000: return -0.2661239e9/t**3 - 0.2343589e6/t**2 + 0.8776956e3/t + 0.179910
    return -3.0258469e9/t**3 + 2.1070379e6/t**2 + 0.2226347e3/t + 0.240390
def planckian(k):
    t = max(k, 1667); x = planckX(t)
    if t <= 2222: y = -1.1063814*x**3 - 1.34811020*x**2 + 2.18555832*x - 0.20219683
    elif t <= 4000: y = -0.9549476*x**3 - 1.37418593*x**2 + 2.09137015*x - 0.16748867
    else: y = 3.0817580*x**3 - 5.87338670*x**2 + 3.75112997*x - 0.37001483
    return x, y
def daylight(k):
    t = max(k, 1000)
    if t <= 7000: x = 0.244063 + 0.09911e3/t + 2.9678e6/t**2 - 4.6070e9/t**3
    else: x = 0.237040 + 0.24748e3/t + 1.9018e6/t**2 - 2.0064e9/t**3
    return x, -3*x*x + 2.87*x - 0.275
def locus(k):
    t = min(max(k, 1000), 100000)
    if t <= 3500: return planckian(t)
    if t >= 4500: return daylight(t)
    w = smoothstep(3500, 4500, t); p = planckian(t); d = daylight(t)
    return p[0]+(d[0]-p[0])*w, p[1]+(d[1]-p[1])*w
TINT_UNIT_V = 0.05/150
def unguarded_xy(k, tint):
    x, y = locus(k)
    if tint == 0: return x, y
    u, v = uv_of(x, y); return xy_from_uv(u, v + tint*TINT_UNIT_V)

def oklab(rgb2020):
    M1 = np.array([[0.8189330101,0.3618667424,-0.1288597137],[0.0329845436,0.9293118715,0.0361456387],[0.0482003018,0.2643662691,0.6338517070]])
    M2 = np.array([[0.2104542553,0.7936177850,-0.0040720468],[1.9779984951,-2.4285922050,0.4505937099],[0.0259040371,0.7827717662,-0.8086757660]])
    lms = M1 @ (REC2020_TO_XYZ @ np.asarray(rgb2020, float))
    return M2 @ np.cbrt(lms)

def _cone_floor_limit(k):
    base = CAT16 @ xyz_of(*unguarded_xy(k, 0))
    if (base <= 0).any(): return 150.0
    def ok(t):
        c = CAT16 @ xyz_of(*unguarded_xy(k, t)); return (c >= 0.15*base).all()
    if ok(300): return 300.0
    lo, hi = 0.0, 300.0
    for _ in range(40):
        m = (lo+hi)/2
        if ok(m): lo = m
        else: hi = m
    return lo
def _rendered_a(k, t):
    src = xyz_of(*unguarded_xy(k, t)); dst = xyz_of(*locus(5500))
    out = XYZ_TO_REC2020 @ adapt(src, dst) @ REC2020_TO_XYZ @ np.full(3, 0.18)
    if not np.isfinite(out).all() or out.min() < 0: return None
    return oklab(out)[1]
def _monotone_limit(k, ceiling):
    if ceiling <= 0: return ceiling
    def ok(t):
        h = _rendered_a(k, t); a = _rendered_a(k, t+0.25)
        return h is not None and a is not None and a >= h
    if ok(ceiling): return ceiling
    lo, hi = 0.0, ceiling
    for _ in range(40):
        m = (lo+hi)/2
        if ok(m): lo = m
        else: hi = m
    return lo
@lru_cache(maxsize=None)
def tint_limit(k):
    p = _cone_floor_limit(k); return min(p, _monotone_limit(k, p))
def clamped_tint(k, t):
    return t if t <= 0 else min(t, tint_limit(k))
def lumen_xy(k, tint):
    k = min(max(k, 2000), 50000); t = clamped_tint(k, min(max(tint, -300), 300))
    return unguarded_xy(k, t)
def wb_matrix(asshot, target, cone=CAT16):
    if asshot[0] == target[0] and asshot[1] == target[1]: return np.eye(3)
    src = xyz_of(*lumen_xy(*target)); dst = xyz_of(*lumen_xy(*asshot))
    return XYZ_TO_REC2020 @ adapt(src, dst, cone) @ REC2020_TO_XYZ

# ---- DNG SDK
TABLE = [(0,0.18006,0.26352,-0.24341),(10,0.18066,0.26589,-0.25479),(20,0.18133,0.26846,-0.26876),(30,0.18208,0.27119,-0.28539),(40,0.18293,0.27407,-0.30470),(50,0.18388,0.27709,-0.32675),(60,0.18494,0.28021,-0.35156),(70,0.18611,0.28342,-0.37915),(80,0.18740,0.28668,-0.40955),(90,0.18880,0.28997,-0.44278),(100,0.19032,0.29326,-0.47888),(125,0.19462,0.30141,-0.58204),(150,0.19962,0.30921,-0.70471),(175,0.20525,0.31647,-0.84901),(200,0.21142,0.32312,-1.0182),(225,0.21807,0.32909,-1.2168),(250,0.22511,0.33439,-1.4512),(275,0.23247,0.33904,-1.7298),(300,0.24010,0.34308,-2.0637),(325,0.24702,0.34655,-2.4681),(350,0.25591,0.34951,-2.9641),(375,0.26400,0.35200,-3.5814),(400,0.27218,0.35407,-4.3633),(425,0.28039,0.35577,-5.3762),(450,0.28863,0.35714,-6.7262),(475,0.29685,0.35823,-8.5955),(500,0.30505,0.35907,-11.324),(525,0.31320,0.35968,-15.628),(550,0.32129,0.36011,-23.325),(575,0.32931,0.36038,-40.770),(600,0.33724,0.36051,-116.45)]
def dng_xy(k, tint):
    r = 1e6/k; off = tint/-3000.0; i = 0
    while i < len(TABLE)-2 and not (r < TABLE[i+1][0]): i += 1
    lo, hi = TABLE[i], TABLE[i+1]; f = (hi[0]-r)/(hi[0]-lo[0])
    u = lo[1]*f + hi[1]*(1-f); v = lo[2]*f + hi[2]*(1-f)
    l1 = np.hypot(1, lo[3]); l2 = np.hypot(1, hi[3])
    uu = (1/l1)*f + (1/l2)*(1-f); vv = (lo[3]/l1)*f + (hi[3]/l2)*(1-f); l3 = np.hypot(uu, vv)
    u += uu/l3*off; v += vv/l3*off
    d = u - 4*v + 2; return 1.5*u/d, v/d
def dng_kt(x, y):
    den = 1.5 - x + 6*y; u = 2*x/den; v = 3*y/den
    lastDt = lastDu = lastDv = 0.0
    for i in range(1, len(TABLE)):
        r, ru, rv, rt = TABLE[i]; ln = np.hypot(1, rt); du = 1/ln; dv = rt/ln
        uu = u-ru; vv = v-rv; dt = -uu*dv + vv*du
        if dt <= 0 or i == len(TABLE)-1:
            if dt > 0: dt = 0
            dt = -dt; f = 0.0 if i == 1 else dt/(lastDt+dt); p = TABLE[i-1]
            k = 1e6/(p[0]*f + r*(1-f))
            uu = u-(p[1]*f+ru*(1-f)); vv = v-(p[2]*f+rv*(1-f))
            iu = du*(1-f)+lastDu*f; iv = dv*(1-f)+lastDv*f; il = np.hypot(iu, iv)
            return k, (uu*iu/il + vv*iv/il)*-3000
        lastDt, lastDu, lastDv = dt, du, dv

def lumen_kt_of_xy(x, y):
    """Lumen's inverse (match u, residual v)."""
    u, v = uv_of(x, y)
    ms = np.arange(20, 500.0001, 0.05)
    us = np.array([uv_of(*locus(1e6/m))[0] for m in ms]); m = ms[np.argmin(abs(us-u))]
    lo, hi = m-0.1, m+0.1
    f = lambda mm: uv_of(*locus(1e6/mm))[0]-u
    if f(lo)*f(hi) < 0:
        for _ in range(60):
            mid = (lo+hi)/2
            if f(lo)*f(mid) <= 0: hi = mid
            else: lo = mid
        m = (lo+hi)/2
    k = 1e6/m; return k, (v - uv_of(*locus(k))[1])/TINT_UNIT_V

def residual(rgb):
    n = rgb/rgb.mean(); return ((n-1)**2).sum()
def neutralizing(decoded, asshot, coarse=True):
    """Same objective as WhiteBalanceEngine.neutralizing (sum sq deviation of normalized RGB)."""
    best = (np.inf, None)
    for m in np.arange(20, 500.01, 8):
        for t in np.arange(-300, 300.01, 10):
            d = residual(wb_matrix(asshot, (1e6/m, t)) @ decoded)
            if d < best[0]: best = (d, (m, t))
    f = lambda m, t: residual(wb_matrix(asshot, (1e6/m, t)) @ decoded)
    (m, t), e, step = best[1], best[0], 8.0
    while step > 1e-5:
        moved = False
        for dm, dt in ((1,0),(-1,0),(0,1),(0,-1),(1,1),(-1,-1),(1,-1),(-1,1)):
            mm, tt = min(max(m+dm*step, 20), 500), min(max(t+dt*step, -300), 300)
            ee = f(mm, tt)
            if ee < e: m, t, e, moved = mm, tt, ee, True
        if not moved: step /= 2
    return 1e6/m, clamped_tint(1e6/m, t), e
def lab(xyz, wp=xyz_of(0.3127,0.3290)):
    f = lambda t: np.where(t > (6/29)**3, np.cbrt(t), t/(3*(6/29)**2)+4/29)
    fx, fy, fz = f(xyz/wp); return np.array([116*fy-16, 500*(fx-fy), 200*(fy-fz)])
def de2000(l1, l2):
    L1,a1,b1 = l1; L2,a2,b2 = l2
    C1=np.hypot(a1,b1); C2=np.hypot(a2,b2); Cb=(C1+C2)/2; G=0.5*(1-np.sqrt(Cb**7/(Cb**7+25**7)))
    a1p=(1+G)*a1; a2p=(1+G)*a2; C1p=np.hypot(a1p,b1); C2p=np.hypot(a2p,b2)
    h1=np.degrees(np.arctan2(b1,a1p))%360; h2=np.degrees(np.arctan2(b2,a2p))%360
    dL=L2-L1; dC=C2p-C1p; dh=h2-h1
    if C1p*C2p==0: dh=0
    elif dh>180: dh-=360
    elif dh<-180: dh+=360
    dH=2*np.sqrt(C1p*C2p)*np.sin(np.radians(dh/2)); Lb=(L1+L2)/2; Cbp=(C1p+C2p)/2
    hb=(h1+h2)/2 if abs(h1-h2)<=180 else (h1+h2+360)/2
    if C1p*C2p==0: hb=h1+h2
    T=1-0.17*np.cos(np.radians(hb-30))+0.24*np.cos(np.radians(2*hb))+0.32*np.cos(np.radians(3*hb+6))-0.2*np.cos(np.radians(4*hb-63))
    dth=30*np.exp(-((hb-275)/25)**2); Rc=2*np.sqrt(Cbp**7/(Cbp**7+25**7))
    Sl=1+0.015*(Lb-50)**2/np.sqrt(20+(Lb-50)**2); Sc=1+0.045*Cbp; Sh=1+0.015*Cbp*T; Rt=-np.sin(np.radians(2*dth))*Rc
    return np.sqrt((dL/Sl)**2+(dC/Sc)**2+(dH/Sh)**2+Rt*(dC/Sc)*(dH/Sh))
def de_grey(rgb):  # dE2000 of a linear rec2020 colour vs neutral of same Y
    xyz = REC2020_TO_XYZ @ rgb; n = xyz_of(0.3127,0.3290, xyz[1]); return de2000(lab(xyz), lab(n))

def adobe_matrix(asshot, target, cone=CAT16):
    if asshot[0] == target[0] and asshot[1] == target[1]: return np.eye(3)
    return XYZ_TO_REC2020 @ adapt(xyz_of(*dng_xy(*target)), xyz_of(*dng_xy(*asshot)), cone) @ REC2020_TO_XYZ

D65 = (0.3127, 0.3290)
def decoded_grey(illum, asshot, Y=0.18):
    """Linear Rec.2020 value of a Y=0.18 neutral lit by `illum` (Adobe K, tint), decoded at `asshot`."""
    return XYZ_TO_REC2020 @ adapt(xyz_of(*dng_xy(*asshot)), xyz_of(*D65)) @ xyz_of(*dng_xy(*illum), Y)

def neutral_target(rgb, asshot):
    """Adobe (K, tint) whose adobe_matrix from `asshot` renders decoded colour `rgb` R=G=B (closed form, von Kries)."""
    c = CAT16 @ (REC2020_TO_XYZ @ np.asarray(rgb, float))
    t = (CAT16 @ xyz_of(*dng_xy(*asshot))) * c / (CAT16 @ xyz_of(*D65))
    xyz = np.linalg.solve(CAT16, t); s = xyz.sum()
    return dng_kt(xyz[0] / s, xyz[1] / s)

def hue_deg(lab): return float(np.degrees(np.arctan2(lab[2], lab[1])) % 360)
