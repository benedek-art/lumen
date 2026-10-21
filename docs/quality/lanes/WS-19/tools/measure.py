#!/usr/bin/env python3
"""Every number in docs/quality/lanes/WS-19/SPEC.md.

    python3 measure.py crops                  # (prepare.sh calls this)
    python3 measure.py profile|colour|luma|hot|defaults|all

"new" numbers come from nrtool (the Swift engine in this checkout); "shipped" numbers
from eng.py (the python port of the engine at 9068ded). Inputs: prepare.sh.
"""
import os, sys, subprocess, tempfile, json
import numpy as np
from scipy.ndimage import gaussian_filter, uniform_filter, maximum_filter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lfi, eng  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, '../../../../..'))
OUT = os.path.join(ROOT, 'corpus/ws19')
NRTOOL = os.path.join(HERE, 'nrtool/.build/release/nrtool')
TMP = tempfile.mkdtemp(prefix='ws19-')

# ---------------------------------------------------------------- engines

def nr(img, iso, **kw):
    """The Swift engine. kw: luma chroma hot ld lc cd cs (unset = ISO default)."""
    i, o = os.path.join(TMP, 'i.lfi'), os.path.join(TMP, 'o.lfi')
    lfi.write(i, img)
    args = [NRTOOL, i, o, str(iso)] + ['%s=%g' % (k, v) for k, v in kw.items()]
    r = subprocess.run(args, capture_output=True, text=True, check=True)
    return lfi.read(o).astype(np.float64)

def nr_sigma(iso):
    i, o = os.path.join(TMP, 'i.lfi'), os.path.join(TMP, 'o.lfi')
    lfi.write(i, np.full((8, 8, 3), 0.18, np.float32))
    r = subprocess.run([NRTOOL, i, o, str(iso), 'mode=off'], capture_output=True,
                       text=True, check=True)
    return float(r.stderr.split('sigma(0.18)=')[1].split()[0])

def shipped(img, iso, **kw):
    """The engine at 9068ded, with its ISO default unless kw overrides."""
    lo = float(np.interp(np.log2(iso), np.log2([400, 6400, 25600]), [0, 25, 40]))
    co = float(np.interp(np.log2(iso), np.log2([100, 1600, 6400, 25600]), [10, 20, 25, 30]))
    a, b = lfi.seed(iso)
    n = np.clip((np.log2(max(np.sqrt(a * .18 + b), 1e-9)) - np.log2(0.004))
                / (np.log2(0.03) - np.log2(0.004)), 0, 1)
    p = dict(luma=lo, chroma=co, ld=50 - 10 * n, lc=0, cd=50, cs=50 + 40 * n)
    p.update(kw)
    return eng.apply(img, iso, **p)

# ---------------------------------------------------------------- display + metrics

R2S = np.array([[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]])
S2X = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])

def lab(x, ev):
    s = np.clip(np.einsum('ij,hwj->hwi', R2S, x * 2 ** ev), 0, 1)
    t = np.einsum('ij,hwj->hwi', S2X, s) / np.array([0.95047, 1, 1.08883])
    f = np.where(t > 0.008856, np.cbrt(t), 7.787 * t + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]),
                     200 * (f[..., 1] - f[..., 2])], -1)

SIMS = {'a7iv': ('6929', 1400, 2700, 768, 1.0), 'r5': ('4694', 3000, 2500, 1024, 1.0),
        'r5bg': ('4694', 1400, 300, 512, 2.0), 'gx85': ('2545', 2400, 900, 768, 0.5)}
_sim = {}

def sim(name):
    if name not in _sim:
        k, x, y, s, ev = SIMS[name]
        n = lfi.read('%s/sim/%s_noisy.lfi' % (OUT, k))[y:y + s, x:x + s].astype(np.float64)
        c = lfi.read('%s/sim/%s_clean.lfi' % (OUT, k))[y:y + s, x:x + s].astype(np.float64)
        Lc = lab(c, ev)
        hp = Lc[..., 0] - gaussian_filter(Lc[..., 0], 2); en = uniform_filter(hp * hp, 16)
        ab = Lc[..., 1:]
        g = np.hypot(*np.gradient(gaussian_filter(ab[..., 0], 1))) \
            + np.hypot(*np.gradient(gaussian_filter(ab[..., 1], 1)))
        _sim[name] = dict(n=n, c=c, ev=ev, Lc=Lc, flat=en < np.percentile(en, 25),
                          tex=en > np.percentile(en, 75), edge=g > np.percentile(g, 97))
    return _sim[name]

def score(name, out):
    d = sim(name); Lo = lab(out, d['ev']); Lc = d['Lc']; e = Lo - Lc
    f, t, ed = d['flat'], d['tex'], d['edge']
    hf = e - np.stack([gaussian_filter(e[..., i], 16) for i in range(3)], -1)
    r = dict(flatL=hf[..., 0][f].std(),
             flatC=np.sqrt((hf[..., 1][f] ** 2 + hf[..., 2][f] ** 2).mean() / 2))
    hc = Lc[..., 0] - gaussian_filter(Lc[..., 0], 2); ho = Lo[..., 0] - gaussian_filter(Lo[..., 0], 2)
    r['texRet'] = (ho[t] * hc[t]).sum() / (hc[t] ** 2).sum()
    bc = gaussian_filter(Lc[..., 0], 2) - gaussian_filter(Lc[..., 0], 6)
    bo = gaussian_filter(Lo[..., 0], 2) - gaussian_filter(Lo[..., 0], 6)
    r['midRet'] = (bo[t] * bc[t]).sum() / (bc[t] ** 2).sum()
    r['edgeC'] = np.sqrt((e[..., 1][ed] ** 2 + e[..., 2][ed] ** 2).mean() / 2)
    dark = Lc[..., 0] < 30
    r['darkShift'] = (Lo[..., 0] - Lc[..., 0])[dark].mean() if dark.any() else 0.0
    return r

REAL = {'2348': ('2348_panasonic-dc-g9', 1950, 1650, 3200, 1.5),
        '2062': ('2062_canon-eos-kiss-x9', 600, 2400, 6400, 1.0),
        '1192': ('1192_fujifilm-x-t10', 730, 1250, 4000, 2.0),
        '2242': ('2242_panasonic-dc-gx850', 2000, 1500, 2000, 1.0),
        '4144': ('4144_sony-ilce-7c', 1750, 950, 2000, 1.0)}
_real = {}

def real(k):
    if k not in _real:
        x = lfi.read('%s/crops/%s.lfi' % (OUT, k)).astype(np.float64); ev = REAL[k][4]
        L = lab(x, ev); s = gaussian_filter(L[..., 0], 2.0)
        v = uniform_filter(s * s, 16) - uniform_filter(s, 16) ** 2
        _real[k] = dict(x=x, ev=ev, flat=v < np.percentile(v, 15))
    return _real[k]

def rscore(k, out):
    d = real(k); Lo = lab(out, d['ev'])
    hp = Lo - np.stack([gaussian_filter(Lo[..., i], 8) for i in range(3)], -1); f = d['flat']
    return dict(noiseL=hp[..., 0][f].std(),
                noiseC=np.sqrt((hp[..., 1][f] ** 2 + hp[..., 2][f] ** 2).mean() / 2))

# ---------------------------------------------------------------- report

RESULTS = []

def line(num, ok, text):
    RESULTS.append((num, ok, text))
    print('%-6s %-4s %s' % (num, 'PASS' if ok else 'FAIL', text), flush=True)

def fmt(xs): return ' '.join('%.3f' % x for x in xs)

# ---------------------------------------------------------------- commands

def cmd_crops():
    os.makedirs(OUT + '/crops', exist_ok=True)
    for k, (f, x, y, iso, ev) in REAL.items():
        a = lfi.read('%s/native/%s.lfi' % (OUT, f))
        lfi.write('%s/crops/%s.lfi' % (OUT, k), a[y:y + 640, x:x + 640])

def cmd_profile():
    frames = [('2348_panasonic-dc-g9', 3200), ('2062_canon-eos-kiss-x9', 6400),
              ('2242_panasonic-dc-gx850', 2000), ('1192_fujifilm-x-t10', 4000),
              ('4144_sony-ilce-7c', 2000), ('1332_canon-eos-77d', 3200),
              ('832_nikon-d7200', 1600), ('6933_sony-ilce-7m4', 640)]
    good = 0; rows = []
    for f, iso in frames:
        img = lfi.read('%s/native/%s.lfi' % (OUT, f))
        V = []
        for ch in range(3):
            pr = lfi.profile(img[..., ch], bins=20)
            V.append(np.interp(0.18, pr[:, 0], pr[:, 1]))
        meas = np.sqrt(np.mean(V)); model = nr_sigma(iso); ratio = model / meas
        good += 0.7 <= ratio <= 1.4
        rows.append('%s %.2f' % (f.split('_')[0], ratio))
    line('19.1', good >= 7, 'model/measured sigma(0.18): %s -> %d of 8 in [0.7,1.4]'
         % (', '.join(rows), good))

def cmd_colour():
    # 19.2 real frames at Colour 25 / Luminance 0
    ok = True; rows = []
    for k, (f, x, y, iso, ev) in REAL.items():
        d = real(k); a = rscore(k, d['x'])['noiseC']
        b = rscore(k, nr(d['x'], iso, luma=0, chroma=25, ld=50, lc=0, cd=50, cs=50))['noiseC']
        s = rscore(k, shipped(d['x'], iso, luma=0))['noiseC']
        ok &= b <= 2.2 and b <= 0.3 * a
        rows.append('%s %.2f->%.2f (%.0f%%; shipped %.2f)' % (k, a, b, 100 * (1 - b / a), s))
    line('19.2a', ok, 'real flat chroma noise dE*ab: ' + '; '.join(rows))
    ok = True; rows = []
    for name in ['a7iv', 'r5', 'r5bg']:
        d = sim(name); a = score(name, d['n'])['flatC']; b = score(name, nr(d['n'], 3200, luma=0, chroma=25))['flatC']
        ok &= b <= 0.3 * a; rows.append('%s %.2f->%.2f (%.0f%%)' % (name, a, b, 100 * (1 - b / a)))
    line('19.2b', ok, 'sim flat chroma noise: ' + '; '.join(rows))
    # 19.3c, 19.4
    ok3 = ok4 = True; r3 = []; r4 = []
    for name in ['a7iv', 'r5', 'r5bg']:
        d = sim(name); a = score(name, d['n']); b = score(name, nr(d['n'], 3200, luma=0, chroma=25))
        ok3 &= b['edgeC'] <= 0.75 * a['edgeC']; r3.append('%s %.2f->%.2f' % (name, a['edgeC'], b['edgeC']))
        if name in ('a7iv', 'r5'):
            ok4 &= abs(b['texRet'] - a['texRet']) <= 0.01 and b['flatL'] <= 1.03 * a['flatL']
            r4.append('%s texRet %.3f->%.3f flatL %.2f->%.2f' % (name, a['texRet'], b['texRet'], a['flatL'], b['flatL']))
    d = sim('gx85'); g0 = score('gx85', d['n'])['edgeC']; g1 = score('gx85', nr(d['n'], 3200, luma=0, chroma=25))['edgeC']
    line('19.3c', ok3, 'colour-edge error input->default: %s (gx85 grass, not gated: %.2f->%.2f)'
         % ('; '.join(r3), g0, g1))
    line('19.4', ok4, 'Colour 25 alone: ' + '; '.join(r4))
    # 19.9 Colour Detail, 19.10 Smoothness
    ge = [score('gx85', nr(sim('gx85')['n'], 3200, luma=0, chroma=25, cd=c))['edgeC'] for c in (0, 50, 100)]
    af = [score('a7iv', nr(sim('a7iv')['n'], 3200, luma=0, chroma=25, cd=c))['flatC'] for c in (0, 50, 100)]
    line('19.9', ge[0] > ge[1] > ge[2] and ge[0] - ge[2] >= 0.8 and af[2] - af[0] <= 0.5,
         'Colour Detail 0/50/100: gx85 edgeC %s; a7iv flatC %s' % (fmt(ge), fmt(af)))
    sf = [score('r5bg', nr(sim('r5bg')['n'], 3200, luma=0, chroma=25, cs=c))['flatC'] for c in (0, 50, 100)]
    line('19.10', sf[0] > sf[1] > sf[2] and sf[0] - sf[2] >= 0.15,
         'Colour Smoothness 0/50/100: r5bg flatC %s' % fmt(sf))

def matched(curve, target):
    """curve: [(flatL, texRet, midRet)] by rising slider; interpolate at flatL = target."""
    c = np.array(curve); o = np.argsort(-c[:, 0])
    if target < c[:, 0].min(): return None
    return [float(np.interp(-target, -c[o, 0], c[o, i])) for i in (1, 2)]

def cmd_luma():
    ok5 = True; rows = []
    for name in ['a7iv', 'r5']:
        d = sim(name); base = score(name, d['n'])['flatL']
        newc = []; oldc = []
        for L in range(0, 101, 10):
            r = score(name, nr(d['n'], 3200, luma=L, chroma=25)); newc.append((r['flatL'], r['texRet'], r['midRet']))
            r = score(name, shipped(d['n'], 3200, luma=L, chroma=25)); oldc.append((r['flatL'], r['texRet'], r['midRet']))
        t = 0.65 * base; nw = matched(newc, t); od = matched(oldc, t)
        reach = 1 - min(c[0] for c in newc) / base; oreach = 1 - min(c[0] for c in oldc) / base
        if od is None:
            okk = nw is not None and reach >= 0.55
            rows.append('%s at -35%%: new tex %.3f mid %.3f, shipped cannot reach it (max -%.0f%%); new max -%.0f%%'
                        % (name, nw[0], nw[1], 100 * oreach, 100 * reach))
        else:
            okk = nw[0] >= od[0] - 1e-3 and nw[1] >= od[1] - 1e-3 and reach >= 0.55
            rows.append('%s at -35%%: tex %.3f vs shipped %.3f, mid %.3f vs %.3f; max -%.0f%% vs -%.0f%%'
                        % (name, nw[0], od[0], nw[1], od[1], 100 * reach, 100 * oreach))
        ok5 &= okk
        if name == 'a7iv':
            tex = [c[1] for c in newc]
            steps = np.diff(tex)
            line('19.6a', all(steps <= -0.01), 'a7iv texRet 0..100/10: %s' % fmt(tex))
    line('19.5', ok5, '; '.join(rows))
    d = sim('r5bg'); fl = [score('r5bg', nr(d['n'], 3200, luma=L, chroma=25))['flatL'] for L in range(0, 61, 10)]
    line('19.6b', all(np.diff(fl) <= 1e-6), 'r5bg flatL 0..60/10: %s' % fmt(fl))
    tr = [score('a7iv', nr(sim('a7iv')['n'], 3200, luma=50, chroma=25, ld=v))['texRet'] for v in (0, 50, 100)]
    line('19.7', tr[0] < tr[1] < tr[2] and tr[2] - tr[0] >= 0.10, 'Luminance 50, Detail 0/50/100: a7iv texRet %s' % fmt(tr))
    mr = [score('r5', nr(sim('r5')['n'], 3200, luma=50, chroma=25, lc=v))['midRet'] for v in (0, 50, 100)]
    line('19.8', mr[0] < mr[1] < mr[2] and mr[2] - mr[0] >= 0.04, 'Luminance 50, Contrast 0/50/100: r5 midRet %s' % fmt(mr))
    ds = score('r5bg', nr(sim('r5bg')['n'], 3200, luma=100, chroma=100))['darkShift'] \
        - score('r5bg', sim('r5bg')['c'])['darkShift']
    line('19.13', abs(ds) <= 1.0, 'Luminance 100 + Colour 100, r5bg mean dL* in L*<30: %+.2f' % ds)

def cmd_hot():
    imgs = {k: lfi.read('%s/sim/hot_%s.lfi' % (OUT, k)).astype(np.float64)
            for k in ['base', 'hot', 'star07', 'spec']}
    feats = {}
    for k in ['hot', 'star07', 'spec']:
        ds = (imgs[k] - imgs['base']).max(-1)
        feats[k] = (np.nonzero((ds == maximum_filter(ds, 7)) & (ds > 0.1)), ds)
    res = {}
    for h in (25, 50, 100):
        hb = nr(imgs['base'], 3200, luma=0, chroma=0, hot=h)
        touched = (np.abs(hb - imgs['base']) > 0).any(-1).mean()
        row = {'touched': touched}
        for k in feats:
            (ys, xs), ds = feats[k]; ho = nr(imgs[k], 3200, luma=0, chroma=0, hot=h)
            row[k] = maximum_filter((ho - hb).max(-1), 5)[ys, xs] / ds[ys, xs]
        res[h] = row
    hot50 = res[50]['hot']
    line('20.1', (hot50 <= 0.3).mean() >= 0.9, 'Hot Pixels 50: %.1f%% of %d hot pixels at <=30%% of peak (median %.3f)'
         % (100 * (hot50 <= 0.3).mean(), hot50.size, np.median(hot50)))
    st = [(res[h]['star07'] >= 0.9).mean() for h in (25, 50, 100)]
    line('20.2', min(st) >= 0.95, 'stars sigma>=0.7 keeping >=90%% of peak at 25/50/100: %s' % fmt(st))
    sp = [(res[h]['spec'] >= 0.9).mean() for h in (25, 50, 100)]
    line('20.3', min(sp) >= 1.0, 'speculars keeping >=90%% at 25/50/100: %s' % fmt(sp))
    line('20.4', res[50]['touched'] <= 0.001 and res[100]['touched'] <= 0.01,
         'noise pixels changed: %.4f%% at 50, %.4f%% at 100' % (100 * res[50]['touched'], 100 * res[100]['touched']))

def cmd_defaults():
    ok2 = ok4 = True; rows = []
    for k, (f, x, y, iso, ev) in REAL.items():
        d = real(k); a = rscore(k, d['x']); b = rscore(k, nr(d['x'], iso)); s = rscore(k, shipped(d['x'], iso))
        cut = 1 - b['noiseL'] / a['noiseL']
        ok2 &= 0.10 <= cut <= 0.45; ok4 &= b['noiseC'] <= 2.2 and b['noiseC'] <= 0.3 * a['noiseC']
        rows.append('%s ISO %d: L %.2f->%.2f (-%.0f%%), C %.2f->%.2f | shipped L %.2f C %.2f'
                    % (k, iso, a['noiseL'], b['noiseL'], 100 * cut, a['noiseC'], b['noiseC'], s['noiseL'], s['noiseC']))
    line('21.2', ok2, 'ISO default flat L noise cut 10-45%: ' + '; '.join(rows))
    line('21.4', ok4, 'ISO default meets 19.2 on every frame (chroma column above)')

if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'all'
    if cmd == 'crops': cmd_crops(); sys.exit(0)
    for c in (['profile', 'colour', 'luma', 'hot', 'defaults'] if cmd == 'all' else [cmd]):
        globals()['cmd_' + c]()
    fails = [r for r in RESULTS if not r[1]]
    print('\n%d lines, %d FAIL' % (len(RESULTS), len(fails)))
