#!/usr/bin/env python3
"""WS-15 Dehaze acceptance check: evaluates every measurable line of SPEC.md on the
renders spec_render.py wrote, and prints one PASS/FAIL row per line with the numbers.

Usage: check_spec.py WORKDIR [--only ID[,ID...]] [--swift] [--json OUT.json]
  WORKDIR   the directory spec_render.py rendered into
  --swift   also run `swift test --filter WS15` (SPEC U-lines) and take the airlight
            numbers for A1-A3 from the corpus test's `WS15AIRLIGHT {json}` lines instead
            of the pre-fix emulation in airlight_probe.py
  --only    evaluate only these line ids (prefix match: --only P,C1)

Exit status 0 iff every evaluated line passes.
"""
import argparse, glob, json, math, os, re, subprocess, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '../../../../..'))
sys.path.insert(0, HERE)
import dehaze_metrics as dm  # noqa: E402

ALL6 = ['983', '1840', '4213', '3437', '2545', '6929']
LAND5 = ['983', '1840', '4213', '3437', '2545']
BLUESKY = ['983', '1840', '2545']
HAZY4 = ['983', '1840', '4213', '3437']
LOWHAZE = ['2545', '6929']
R = json.load(open(os.path.join(HERE, 'regions.json')))

W = None  # work dir
_cache = {}


def full(f, v):
    return os.path.join(W, 'full', f'{f}_L2400_d{v}.png') if v != 'unset' else os.path.join(W, 'full', f'{f}_L2400_unset.png')


def lin(path):
    if path not in _cache:
        _cache[path] = dm.srgb_to_linear(dm.load(path))
    return _cache[path]


def u8(path):
    return np.asarray(Image.open(path).convert('RGB'))


def sgn(v):
    return f'{v:+d}' if v else '0'


# --------------------------------------------------------------------------- lines
LINES = []


def line(lid, claim, threshold):
    def deco(fn):
        LINES.append((lid, claim, threshold, fn)); return fn
    return deco


# I — identity -------------------------------------------------------------------
@line('I1', 'Dehaze 0 renders pixel-identical to a recipe with no dehaze key', 'max |diff| = 0 codes')
def i1():
    rows = []
    for f in ALL6:
        d = int(np.abs(u8(full(f, 0)).astype(int) - u8(full(f, 'unset'))).max())
        rows.append((f, d, d == 0))
    for s in ('colorchecker', 'hard_edge', 'grey_ramp'):
        a = os.path.join(W, 'syn', f'{s}_L1024_d0.png'); b = os.path.join(W, 'syn', f'{s}_L1024_unset.png')
        d = int(np.abs(u8(a).astype(int) - u8(b)).max())
        rows.append((s, d, d == 0))
    return rows


# P — positive: tone ----------------------------------------------------------------
def shadow(f, v):
    k = ('shadow', f, v)
    if k not in _cache:
        b8, o8 = u8(full(f, 0)), u8(full(f, v))
        yb, yo = dm.luminance(lin(full(f, 0))), dm.luminance(lin(full(f, v)))
        new0 = float(((o8 == 0).any(-1) & ~(b8 == 0).any(-1)).mean() * 100)
        _cache[k] = {'new0': new0, 'p1': float(np.percentile(yo, 1) / max(np.percentile(yb, 1), 1e-6)),
                     'dEV': float(np.log2(yo.mean() / yb.mean()))}
    return _cache[k]


@line('P1', 'Positive Dehaze clips no new shadows: pixels newly at code 0 (any channel)', '+50 <= 0.02 %, +100 <= 0.05 %')
def p1():
    return [(f'{f} {sgn(v)}', round(shadow(f, v)['new0'], 3), shadow(f, v)['new0'] <= lim)
            for f in ALL6 for v, lim in ((50, 0.02), (100, 0.05))]


@line('P2', 'Positive Dehaze keeps the deep shadows: p1 linear Y out/base', '+50 >= 0.70, +100 >= 0.50')
def p2():
    return [(f'{f} {sgn(v)}', round(shadow(f, v)['p1'], 3), shadow(f, v)['p1'] >= lim)
            for f in ALL6 for v, lim in ((50, 0.70), (100, 0.50))]


@line('P3', 'Exposure drift bounded (LR-like moderate darkening, estimated): mean linear Y change',
      '+50 in [-0.40, +0.10] EV, +100 in [-0.70, +0.10] EV')
def p3():
    return [(f'{f} {sgn(v)}', round(shadow(f, v)['dEV'], 3), lo <= shadow(f, v)['dEV'] <= 0.10)
            for f in ALL6 for v, lo in ((50, -0.40), (100, -0.70))]


def regions(f, v):
    k = ('reg', f, v)
    if k not in _cache:
        _cache[k] = dm.m_regions(f, full(f, 0), [full(f, v)])[os.path.basename(full(f, v))]
    return _cache[k]


@line('P4', '4213 overcast sky does not turn to storm: sky0 OKLab L change at +100', 'dL >= -0.15')
def p4():
    d = regions('4213', 100)['sky0']['dL']
    return [('4213 +100', d, d >= -0.15)]


@line('P5', 'Haze-region local contrast rises (detail, not darkening): far-box local RMS contrast out/base',
      '4213: +50 >= 1.12, +100 >= 1.30; 983/1840/3437: +100 >= 1.15')
def p5():
    rows = []
    for f, v, lim in (('4213', 50, 1.12), ('4213', 100, 1.30), ('983', 100, 1.15), ('1840', 100, 1.15), ('3437', 100, 1.15)):
        r = dm.local_contrast(lin(full(f, v)), R[f]['far']) / dm.local_contrast(lin(full(f, 0)), R[f]['far'])
        rows.append((f'{f} {sgn(v)}', round(r, 3), r >= lim))
    return rows


def de_full(f, v):
    k = ('de', f, v)
    if k not in _cache:
        de = dm.de2000(dm.cielab(lin(full(f, 0))), dm.cielab(lin(full(f, v))))
        _cache[k] = (float(de.mean()), float(np.percentile(de, 95)))
    return _cache[k]


@line('P6', 'Low-haze frames are not wrecked at +50: dE2000 vs base', 'mean <= 2.5, p95 <= 6.0')
def p6():
    rows = []
    for f in LOWHAZE:
        m, p = de_full(f, 50)
        rows.append((f'{f} +50 mean', round(m, 2), m <= 2.5)); rows.append((f'{f} +50 p95', round(p, 2), p <= 6.0))
    return rows


@line('P7', 'No mottling on flat white surfaces: residual of OKLab L after an affine (exposure+contrast) fit to base, / base L std',
      '+50 <= 0.12, +100 <= 0.20 (6929 wall x2, 983 snow, 2545 house wall)')
def p7():
    rows = []
    for f, name, bx in (('6929', 'wall_upper', R['6929']['mottle']['wall_upper']), ('6929', 'white_wall', R['6929']['neutral']['white_wall']),
                        ('983', 'snow', R['983']['neutral']['snow']), ('2545', 'house_wall', R['2545']['neutral']['house_wall'])):
        for v, lim in ((50, 0.12), (100, 0.20)):
            m, g = dm.mottle_index(lin(full(f, 0)), lin(full(f, v)), bx)
            rows.append((f'{f} {name} {sgn(v)} (gain {g:.2f})', round(m, 3), m <= lim))
    return rows


@line('P8', '[LR-est] A dark object in front of a bright hazy background is deepened, not crushed: mean log2 Y change of the lit trunk minus that of the meadow beside it (3437)',
      '+50 >= -0.35 EV, +100 >= -0.70 EV')
def p8():
    rows = []
    S = R['3437']['surfaces']
    for v, lim in ((50, -0.35), (100, -0.70)):
        d = {}
        for k in ('trunk_lit', 'meadow'):
            yb = dm.luminance(dm.box(lin(full('3437', 0)), S[k])); yo = dm.luminance(dm.box(lin(full('3437', v)), S[k]))
            d[k] = float(np.log2(yo.mean() / yb.mean()))
        x = d['trunk_lit'] - d['meadow']
        rows.append((f'3437 {sgn(v)} (trunk {d["trunk_lit"]:+.2f}, meadow {d["meadow"]:+.2f})', round(x, 3), x >= lim))
    return rows


@line('P9', 'Strength: positive Dehaze is visibly strong (LR +100 is a strong effect), mean dE2000 vs dehaze 0',
      '4213: +50 >= 2.5, +100 >= 5.0; 983, 3437: +100 >= 3.0; 1840 (thin haze): +100 >= 2.0')
def p9():
    rows = []
    for f, v, lim in (('4213', 50, 2.5), ('4213', 100, 5.0), ('983', 100, 3.0), ('1840', 100, 2.0), ('3437', 100, 3.0)):
        m, _ = de_full(f, v); rows.append((f'{f} {sgn(v)}', round(m, 2), m >= lim))
    return rows


@line('P10', 'The existing proof authority floor for detail.dehaze holds (hazySky, peak code separation -100 vs +100; ProofRegistry floor 68, not lowered)',
      'records/detail.dehaze.json authority >= the registry authorityFloor, and the floor is still 68')
def p10():
    rec = json.load(open(os.path.join(ROOT, 'Tests/LumenCoreTests/Proof/records/detail.dehaze.json')))
    reg = src('Tests/LumenCoreTests/Proof/ProofRegistry.swift')
    m = re.search(r'id: "detail\.dehaze".*?authorityFloor:\s*([\d.]+)', reg, re.S)
    floor = float(m.group(1)) if m else float('nan')
    return [('record authority', round(rec['authority'], 2), rec['authority'] >= floor),
            ('registry floor', floor, floor == 68)]


# C — colour ------------------------------------------------------------------------
@line('C1', 'Blue-sky chroma does not fall, rises modestly (LR: "+Dehaze increases saturation"): sky0 C out/base',
      '+50 and +100 in [1.00, 1.40]')
def c1():
    rows = []
    for f in BLUESKY:
        for v in (50, 100):
            s = regions(f, v)['sky0']; r = s['out']['C'] / s['base']['C']
            rows.append((f'{f} {sgn(v)}', round(r, 3), 1.00 <= r <= 1.40))
    return rows


@line('C2', 'Sky mean hue holds (no purple/cyan sky): sky0 OKLab hue shift', '|dh| <= 3.0 deg at +50, +100')
def c2():
    return [(f'{f} {sgn(v)}', regions(f, v)['sky0']['dHue_deg'], abs(regions(f, v)['sky0']['dHue_deg']) <= 3.0)
            for f in BLUESKY for v in (50, 100)]


@line('C3', 'No violet/cyan sky banding: per 2%-height strip of sky pixels in the skyband box, OKLab hue shift',
      'max |dh| <= 3.0 deg and max-min <= 4.0 deg at +50, +100')
def c3():
    rows = []
    for f in BLUESKY:
        for v in (50, 100):
            s = dm.sky_bands(f, full(f, 0), full(f, v))
            rows.append((f'{f} {sgn(v)} max|dh|', round(s['max_abs_dh'], 2), s['max_abs_dh'] <= 3.0))
            rows.append((f'{f} {sgn(v)} spread', round(s['spread_dh'], 2), s['spread_dh'] <= 4.0))
    return rows


NEUTRALS = [('983', 'snow'), ('983', 'cc_white_B1'), ('983', 'cc_grey_E3'), ('983', 'cc_grey_E4'), ('983', 'cc_grey_E5'),
            ('4213', 'tower_wall'), ('4213', 'sky_grey'), ('2545', 'house_wall'), ('6929', 'white_wall')]


@line('C4', 'Neutrals stay neutral: OKLab a/b drift on snow, CC greys, white walls, overcast sky', '|da|,|db| <= 0.003 at +50, +100')
def c4():
    rows = []
    for f, n in NEUTRALS:
        for v in (50, 100):
            s = regions(f, v)[n]; m = max(abs(s['da']), abs(s['db']))
            rows.append((f'{f} {n} {sgn(v)}', round(m, 4), m <= 0.003))
    return rows


@line('C5', 'Snow / white walls are not crushed to grey: OKLab L change at +100',
      'snow, white walls dL >= -0.08; CC white B1 dL >= -0.05')
def c5():
    rows = []
    for f, n, lim in (('983', 'snow', -0.08), ('983', 'cc_white_B1', -0.05), ('4213', 'tower_wall', -0.08),
                      ('2545', 'house_wall', -0.08), ('6929', 'white_wall', -0.08)):
        d = regions(f, 100)[n]['dL']
        rows.append((f'{f} {n}', d, d >= lim))
    return rows


def patches(v):
    k = ('patch', v)
    if k in _cache:
        return _cache[k]
    truth = json.load(open(os.path.join(ROOT, 'corpus/synthetic/colorchecker.json')))['truth']['patches']
    b = lin(os.path.join(W, 'syn', 'colorchecker_L1024_d0.png')); o = lin(os.path.join(W, 'syn', f'colorchecker_L1024_d{v}.png'))
    H, Wd = b.shape[:2]; s = Wd / 1368.0
    ys, xs = np.mgrid[0:H, 0:Wd]; out = []
    for p in truth:
        x, y, w, h = [c * s for c in p['rect']]
        cx, cy = x + w / 2, y + h / 2
        m = np.maximum(np.abs(xs - cx) / (w / 2), np.abs(ys - cy) / (h / 2))
        cen, rim = m < 0.4, (m >= 0.75) & (m < 0.95)
        c0, c1 = dm.oklab(b[cen]).mean(0), dm.oklab(o[cen]).mean(0)
        r0, r1 = dm.oklab(b[rim]).mean(0), dm.oklab(o[rim]).mean(0)
        C0, C1 = math.hypot(c0[1], c0[2]), math.hypot(c1[1], c1[2])
        dh = dm.hue_diff(math.degrees(math.atan2(c0[2], c0[1])), math.degrees(math.atan2(c1[2], c1[1]))) if C0 > 0.02 else None
        out.append({'i': p['index'], 'L0': c0[0], 'L1': c1[0], 'C0': C0, 'C1': C1, 'dh': dh,
                    'split': (r1[0] - c1[0]) - (r0[0] - c0[0]), 'da': c1[1] - c0[1], 'db': c1[2] - c0[2]})
    _cache[k] = out
    return out


@line('C6', 'Synthetic ColorChecker at +50/+100: greys keep lightness and neutrality, no rim/centre split, colours keep chroma and hue',
      'greys 19-24 dL >= -0.05 and |da|,|db| <= 0.003; every patch |rim-centre split| <= 0.02; C>0.02 patches chroma ratio >= 0.90, |dh| <= 3 deg')
def c6():
    rows = []
    for v in (50, 100):
        P = patches(v); greys = [p for p in P if p['i'] >= 19]
        wl = min(greys, key=lambda p: p['L1'] - p['L0'])
        rows.append((f'{sgn(v)} worst grey dL (#{wl["i"]})', round(wl['L1'] - wl['L0'], 3), wl['L1'] - wl['L0'] >= -0.05))
        wt = max(max(abs(p['da']), abs(p['db'])) for p in greys)
        rows.append((f'{sgn(v)} worst grey tint', round(wt, 4), wt <= 0.003))
        ws = max(P, key=lambda p: abs(p['split']))
        rows.append((f'{sgn(v)} worst rim-centre (#{ws["i"]})', round(ws['split'], 3), abs(ws['split']) <= 0.02))
        col = [p for p in P if p['C0'] > 0.02]
        wc = min(col, key=lambda p: p['C1'] / p['C0'])
        rows.append((f'{sgn(v)} worst chroma ratio (#{wc["i"]})', round(wc['C1'] / wc['C0'], 3), wc['C1'] / wc['C0'] >= 0.90))
        wh = max(col, key=lambda p: abs(p['dh']))
        rows.append((f'{sgn(v)} worst |dh| (#{wh["i"]})', round(wh['dh'], 2), abs(wh['dh']) <= 3.0))
    return rows


@line('C7', 'Synthetic hard_edge: flat 0.18 grey band not darkened; no rim around the bright disc',
      'band dL >= -0.05 at +100; |dL(annulus 1.03-1.12 R) - dL(annulus 1.4-1.6 R)| <= 0.02 at +100 and -100')
def c7():
    b = lin(os.path.join(W, 'syn', 'hard_edge_L1024_d0.png')); H, Wd = b.shape[:2]; s = Wd / 1600.0
    Lb = dm.oklab(b.reshape(-1, 3))[:, 0].reshape(H, Wd)
    ys, xs = np.mgrid[0:H, 0:Wd]; rr = np.hypot(xs - 400 * s, ys - 450 * s) / (220 * s)
    near, farr = (rr > 1.03) & (rr < 1.12), (rr > 1.4) & (rr < 1.6)
    band = (ys >= 960 * s) & (ys < 1190 * s)
    rows = []
    for v in (100, -100):
        o = lin(os.path.join(W, 'syn', f'hard_edge_L1024_d{v}.png'))
        dL = dm.oklab(o.reshape(-1, 3))[:, 0].reshape(H, Wd) - Lb
        if v == 100:
            d = float(dL[band].mean()); rows.append(('+100 grey band dL', round(d, 3), d >= -0.05))
        rim = float(dL[near].mean() - dL[farr].mean())
        rows.append((f'{sgn(v)} disc rim dL', round(rim, 3), abs(rim) <= 0.02))
    return rows


@line('C8', 'Synthetic grey_ramp stays monotone (no tone reversal) at +100 and -100',
      'continuous ramp: no column-to-column drop > 1 code; 15-step wedge: no step drops > 0.5 code')
def c8():
    rows = []
    for v in (100, -100):
        o = u8(os.path.join(W, 'syn', f'grey_ramp_L1024_d{v}.png')).astype(float).mean(-1); H = o.shape[0]
        ramp = o[int(0.05 * H):int(0.45 * H)].mean(0)
        drop = float(np.min(np.diff(ramp)))
        rows.append((f'{sgn(v)} ramp worst step (codes)', round(drop, 2), drop >= -1.0))
        steps = o[int(0.6 * H):int(0.9 * H)].mean(0)
        n = len(steps); centres = [steps[int((k + 0.5) * n / 15)] for k in range(15)]
        worst = float(min(centres[k + 1] - centres[k] for k in range(14)))
        rows.append((f'{sgn(v)} wedge worst step (codes)', round(worst, 2), worst >= -0.5))
    return rows


# H — halo ---------------------------------------------------------------------------
HALO_FRAMES = ['4213', '983', '2545', '1840', '3437']


def halo(f, v):
    k = ('halo', f, v)
    if k not in _cache:
        _cache[k] = dm.m_halo(f, full(f, 0), [full(f, v)])[os.path.basename(full(f, v))]
    return _cache[k]


def halo_rows(v, key, lim, fmt):
    rows = []
    for f in HALO_FRAMES:
        for prof, r in halo(f, v).items():
            for side in ('bright_side', 'dark_side'):
                if side in r:
                    x = r[side][key]
                    rows.append((f'{f} {prof} {side.split("_")[0]}', fmt(x), abs(x) <= lim))
    return rows


@line('H1', 'No horizon/canopy halo at +100 (2400 px): |near-edge minus far-plateau| of log2(out/base) along each edge profile',
      '<= 0.30 EV on every side of every profile (4213, 983, 2545, 1840, 3437)')
def h1():
    return halo_rows(100, 'max_near_dev_EV', 0.30, lambda x: x)


@line('H2', 'Halo band width at +100 (2400 px): pixels from the edge where |deviation| > 0.1 EV',
      '<= 48 px (2 % of the long edge) on every side of every profile')
def h2():
    return halo_rows(100, 'band_width_px_gt0.1EV', 48, int)


@line('H3', 'No halo from the negative veil at -100 (2400 px)', '<= 0.30 EV on every side of every profile')
def h3():
    return halo_rows(-100, 'max_near_dev_EV', 0.30, lambda x: x)


# A — airlight ------------------------------------------------------------------------
AIRLIGHT = {}


def airlight():
    if not AIRLIGHT:
        out = subprocess.run([sys.executable, os.path.join(HERE, 'airlight_probe.py'), '--json', *ALL6],
                             capture_output=True, text=True, check=True).stdout
        AIRLIGHT.update(json.loads(out)); AIRLIGHT['_source'] = 'emulated pre-fix rule (airlight_probe.py)'
    return AIRLIGHT


@line('A1', 'Airlight is not picked from white/coloured objects: share of the selection inside forbidden boxes (CC chart, lamp, tank+pink lid, house wall)',
      '<= 0.05 at 512 and 2048 px')
def a1():
    rows = []
    for f in ('983', '3437', '2545'):
        for le in ('L512', 'L2048'):
            fr = max(airlight()[f][le]['forbidden_fraction'].values())
            rows.append((f'{f} {le}', fr, fr <= 0.05))
    return rows


@line('A2', '3437 airlight (and hence its veil) is not magenta: green share g/(r+g+b) of A', '>= 0.315 at 512 and 2048 px')
def a2():
    return [(f'3437 {le}', airlight()['3437'][le]['chroma'][1], airlight()['3437'][le]['chroma'][1] >= 0.315)
            for le in ('L512', 'L2048')]


@line('A3', 'Airlight is resolution-stable: 512 vs 2048 px chromaticity distance and luminance ratio',
      'dist <= 0.010 and ratio in [0.90, 1.10] on all six')
def a3():
    rows = []
    for f in ALL6:
        a = airlight()[f]
        rows.append((f'{f} chroma dist', a['chroma_dist_512_2048'], a['chroma_dist_512_2048'] <= 0.010))
        rows.append((f'{f} luma ratio', a['luma_ratio_512_over_2048'], 0.90 <= a['luma_ratio_512_over_2048'] <= 1.10))
    return rows


# N — negative --------------------------------------------------------------------
def veil(f, v):
    k = ('veil', f, v)
    if k not in _cache:
        _cache[k] = dm.m_veil(f, full(f, 0), [full(f, v)])[os.path.basename(full(f, v))]
    return _cache[k]


@line('N1', 'Negative veil is atmospheric: far-box OKLab L lift / near (bottom 15 %) lift', '>= 1.20 at -50 and -100 on the five landscapes')
def n1():
    rows = []
    for f in LAND5:
        for v in (-50, -100):
            r = veil(f, v)['far_over_near_dL']
            rows.append((f'{f} {sgn(v)}', r, r is not None and r >= 1.20))
    return rows


@line('N2', 'Negative veil is near-neutral (no pink/mauve wash, no blue foreground): mean OKLab shift at -100',
      'near (bottom 15 %): hypot(da,db) <= 0.006 and da <= +0.003; far box: da <= +0.003 and db >= -0.006 (desaturation allowed), all six')
def n2():
    rows = []
    for f in ALL6:
        r = veil(f, -100)['near']; c = math.hypot(r['da'], r['db'])
        rows.append((f'{f} near |dab| (da {r["da"]:+.4f})', round(c, 4), c <= 0.006 and r['da'] <= 0.003))
        r = veil(f, -100)['far']
        rows.append((f'{f} far da (db {r["db"]:+.4f})', r['da'], r['da'] <= 0.003 and r['db'] >= -0.006))
    return rows


@line('N3', 'Negative veil lifts the blacks of the distance (milky, not grey-cast): far-box p1 OKLab L rise at -100',
      '>= +0.02 on the five landscapes')
def n3():
    rows = []
    for f in LAND5:
        b, o = veil(f, -100)['far']['minL']; rows.append((f'{f}', round(o - b, 3), o - b >= 0.02))
    return rows


def tiles(f):
    out = {}
    for p in glob.glob(os.path.join(W, 'sweep', f'{f}_fine_tiles', 'tile_*.png')):
        v = int(float(re.match(r'tile_\d+_([+\-]?\d+)', os.path.basename(p)).group(1))); out[v] = p
    return out


@line('N4', 'Negative contrast drop is monotone: far-box OKLab L std over 0,-10..-100 (512 px sweep)',
      'strictly decreasing and std(-100)/std(0) <= 0.85, all six')
def n4():
    rows = []
    for f in ALL6:
        t = tiles(f); stds = []
        for v in range(0, -101, -10):
            L = dm.oklab(dm.box(lin(t[v]), R[f]['far']).reshape(-1, 3))[:, 0]; stds.append(float(L.std()))
        mono = all(stds[i + 1] < stds[i] for i in range(len(stds) - 1)); r = stds[-1] / stds[0]
        rows.append((f'{f} monotone', int(mono), mono)); rows.append((f'{f} ratio', round(r, 3), r <= 0.85))
    return rows


@line('N5', 'Strength: negative Dehaze is a visible veil (LR -100 is a heavy mist), mean dE2000 vs dehaze 0 at -100',
      '4213 >= 3.0; 983, 3437 >= 2.5')
def n5():
    rows = []
    for f, lim in (('4213', 3.0), ('983', 2.5), ('3437', 2.5)):
        m, _ = de_full(f, -100); rows.append((f'{f} -100', round(m, 2), m >= lim))
    return rows


# S — smoothness ------------------------------------------------------------------
def sweep(f):
    m = json.load(open(os.path.join(W, 'sweep', f'{f}_fine_m.json')))
    return {int(round(t['value'])): t['deltaE2000VsReference']['mean'] for t in m['tiles']}


def sides(f):
    d = sweep(f)
    pos = [d[v] for v in range(0, 101, 10)]; neg = [d[v] for v in range(0, -101, -10)]
    return pos, neg


@line('S1', 'Monotone response: mean dE2000 vs dehaze 0 strictly increases with |value| on each side (512 px, step 10)', 'strict, all six')
def s1():
    rows = []
    for f in ALL6:
        for name, s in zip(('pos', 'neg'), sides(f)):
            st = np.diff(s); ok = bool((st > 0).all())
            rows.append((f'{f} {name} min step', round(float(st.min()), 3), ok))
    return rows


@line('S2', 'Even response: max/min step of mean dE2000 per 10 units on each side', '<= 1.5, all six')
def s2():
    rows = []
    for f in ALL6:
        for name, s in zip(('pos', 'neg'), sides(f)):
            st = np.diff(s); r = float(st.max() / max(st.min(), 1e-9))
            rows.append((f'{f} {name}', round(r, 2), r <= 1.5))
    return rows


@line('S3', 'No jump and no dead zone at 0: first step (0 to +-10) / median step on that side', 'in [0.5, 1.5], all six')
def s3():
    rows = []
    for f in ALL6:
        for name, s in zip(('pos', 'neg'), sides(f)):
            st = np.diff(s); r = float(st[0] / max(np.median(st), 1e-9))
            rows.append((f'{f} {name}', round(r, 2), 0.5 <= r <= 1.5))
    return rows


@line('S4', 'Rough strength balance: mean dE2000 at -100 / at +100 on the hazy frames', 'in [0.50, 1.50] on 983, 1840, 4213, 3437')
def s4():
    rows = []
    for f in HAZY4:
        pos, neg = sides(f); r = neg[-1] / pos[-1]
        rows.append((f, round(r, 2), 0.5 <= r <= 1.5))
    return rows


# R — resolution ------------------------------------------------------------------
def res(f, v):
    k = ('res', f, v)
    if k not in _cache:
        p = lambda e, vv: os.path.join(W, 'res', f'{f}_L{e}_d{vv}.png')
        _cache[k] = dm.m_res(p(512, v), p(2048, v), p(512, 0), p(2048, 0))
    return _cache[k]


@line('R1', 'Preview (512) matches full size (2048 area-averaged to 512): excess mean dE2000 over the dehaze-0 pair', '<= 0.40 at +60 and -60, all six')
def r1():
    return [(f'{f} {sgn(v)}', res(f, v)['excess_dE_mean'], res(f, v)['excess_dE_mean'] <= 0.40) for f in ALL6 for v in (60, -60)]


@line('R2', 'Preview vs full size, worst areas: excess p95 dE2000', '<= 1.20 at +60 and -60, all six')
def r2():
    return [(f'{f} {sgn(v)}', res(f, v)['excess_dE_p95'], res(f, v)['excess_dE_p95'] <= 1.20) for f in ALL6 for v in (60, -60)]


@line('R3', 'Preview vs full size brightness: |mean encoded Y difference - the dehaze-0 difference|', '<= 1.5 codes at +60 and -60, all six')
def r3():
    rows = []
    for f in ALL6:
        for v in (60, -60):
            r = res(f, v); d = r['pair']['meanEncYDiff_codes'] - r['baseline_dehaze0']['meanEncYDiff_codes']
            rows.append((f'{f} {sgn(v)}', round(d, 2), abs(d) <= 1.5))
    return rows


# G — CPU/GPU structural parity (code reading, scripted where a grep can decide) ---
def src(rel, strip=False):
    t = open(os.path.join(ROOT, rel)).read()
    return re.sub(r'//[^\n]*', '', t) if strip else t


def kernel_source():
    s = src('Sources/LumenPipeline/Kernels.swift')
    m = re.search(r'static let dehazeSource = """(.*?)"""', s, re.S)
    return re.sub(r'//[^\n]*', '', m.group(1)) if m else ''


def gpu_apply():
    s = src('Sources/LumenPipeline/RenderGraph.swift')
    i = s.find('static func applyDehaze(')
    j = s.find('\n    // MARK:', i)
    return re.sub(r'//[^\n]*', '', s[i:j]) if i >= 0 else ''


def cpu_apply():
    s = src('Sources/LumenCore/Image/DetailEngine.swift')
    i = s.find('public static func applyDehaze(')
    j = s.find('\n    // MARK:', i)
    return re.sub(r'//[^\n]*', '', s[i:j]) if i >= 0 else ''


@line('G1', 'GPU dehaze kernel carries the sky guard (bright-and-flat transmission floor)', 'kernel source mentions a sky term and takes its inputs')
def g1():
    k = kernel_source(); ok = bool(re.search(r'sky', k, re.I)) and bool(re.search(r'smoothstep', k))
    return [('Kernels.dehazeSource', int(ok), ok)]


@line('G2', 'GPU negative branch uses the same distance as CPU: max(1 - t, skyness)', 'kernel `distant` expression includes the sky term')
def g2():
    m = re.search(r'float\s+distant\s*=\s*([^;]*);', kernel_source()); e = m.group(1) if m else ''
    ok = bool(re.search(r'sky', e, re.I)) and 'max' in e
    return [('distant = ' + (e.strip()[:40] or '?'), int(ok), ok)]


@line('G3', 'Sky-guard constants are named once in DetailEngine and read by both paths', '>= 3 `dehazeSky*` constants; each referenced in RenderGraph.swift or Kernels.swift and in CPU applyDehaze; no bare sky-guard smoothstep(0.5, 2.0)/(0.05, 0.35) literals in CPU applyDehaze')
def g3():
    de = src('Sources/LumenCore/Image/DetailEngine.swift')
    names = sorted(set(re.findall(r'static let (dehazeSky\w*)', de)))
    gpu = src('Sources/LumenPipeline/RenderGraph.swift') + src('Sources/LumenPipeline/Kernels.swift')
    cpu = cpu_apply()
    used = all(n in gpu and n in cpu for n in names)
    literals = len(re.findall(r'smoothstep\(\s*(?:0\.5|0\.05)\s*,\s*(?:2\.0|0\.35)', cpu))
    ok = len(names) >= 3 and used and literals == 0
    return [(f'{len(names)} names, all used both sides={used}, CPU sky literals={literals}', int(ok), ok)]


@line('G4', 'GPU airlight rule is the CPU rule (no separate 0.99 x proxy-max threshold)', 'RenderGraph.applyDehaze has no `* 0.99` threshold and calls the shared estimator / constants')
def g4():
    g = gpu_apply()
    no99 = not re.search(r'\*\s*0\.99', g)
    shared = bool(re.search(r'estimateAirlight|DetailEngine\.dehazeAirlight|airlightEstimate', g))
    ok = no99 and shared
    return [(f'no 0.99={no99}, shared estimator={shared}', int(ok), ok)]


@line('G5', 'GPU transmission guide radius derives from the image it filters (as CPU), not from options.longEdge', 'no `Double(longEdge) * 0.02` in RenderGraph.applyDehaze')
def g5():
    ok = not re.search(r'Double\(longEdge\)\s*\*\s*0\.02', gpu_apply())
    return [('RenderGraph.applyDehaze', int(ok), ok)]


@line('G6', 'BUILDING.md no longer lists the dehaze sky guard as reference-only', 'no "sky guard is still reference-only"')
def g6():
    ok = 'sky guard is still reference-only' not in src('BUILDING.md')
    return [('BUILDING.md', int(ok), ok)]


# U — swift tests -----------------------------------------------------------------
SWIFT = {}
U_TESTS = ['testIdentityAtZero', 'testPositiveRestoresSkyChromaAndGroundContrast', 'testPositiveExposureDriftBounded',
           'testAirlightIgnoresWhiteCard', 'testAirlightIgnoresMagentaObject', 'testNeutralPatchKeepsLightnessAndTint',
           'testNegativeVeilFarExceedsNear', 'testNoHaloAtSkyTreelineStep', 'testScaleStableAirlightAndOutput',
           'testMonotoneBothSides', 'testCorpusAirlight']


@line('U', 'Swift unit tests WS15DehazeSpecTests (+ corpus-gated WS15DehazeAirlightCorpusTests) exist and pass on Linux', 'each named test passed (run with --swift)')
def u():
    if not SWIFT:
        return [('not run (pass --swift)', 0, False)]
    rows = []
    for t in U_TESTS:
        st = SWIFT.get(t, 'missing'); rows.append((t, st, st == 'passed'))
    return rows


def run_swift():
    env = dict(os.environ); env['PATH'] = '/opt/swift/usr/bin:' + env.get('PATH', '')
    r = subprocess.run(['swift', 'test', '--filter', 'WS15'], cwd=ROOT, env=env, capture_output=True, text=True)
    txt = r.stdout + r.stderr
    for m in re.finditer(r"Test Case '[^']*?[.\s-](test\w+)\]?' (passed|failed|skipped)", txt):
        SWIFT[m.group(1)] = m.group(2)
    al = {}
    for m in re.finditer(r'WS15AIRLIGHT (\{.*\})', txt):
        d = json.loads(m.group(1)); al[d['id']] = d
    if len(al) == len(ALL6):
        AIRLIGHT.update(al); AIRLIGHT['_source'] = 'WS15DehazeAirlightCorpusTests (current code)'
    SWIFT['_rc'] = r.returncode


# --------------------------------------------------------------------------- main
def main():
    global W
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('work'); ap.add_argument('--only'); ap.add_argument('--swift', action='store_true'); ap.add_argument('--json')
    a = ap.parse_args(); W = os.path.abspath(a.work)
    if a.swift:
        run_swift()
    sel = [x for x in LINES if not a.only or any(x[0].startswith(p) for p in a.only.split(','))]
    results = {}; npass = 0
    for lid, claim, thr, fn in sel:
        try:
            rows = fn()
        except Exception as e:  # a missing render is a FAIL, not a crash
            rows = [(f'error: {type(e).__name__}: {e}'[:120], None, False)]
        ok = all(r[2] for r in rows); npass += ok
        print(f'{lid:<3} {"PASS" if ok else "FAIL"}  {claim}  [{thr}]')
        for lab, val, good in rows:
            print(f'       {"ok " if good else "BAD"} {lab:<44} {val}')
        results[lid] = {'pass': ok, 'claim': claim, 'threshold': thr, 'rows': [[r[0], r[1], bool(r[2])] for r in rows]}
    if AIRLIGHT:
        print(f'(A-lines source: {AIRLIGHT["_source"]})')
    print(f'\nSUMMARY {npass}/{len(sel)} lines PASS; failing: {" ".join(k for k, v in results.items() if not v["pass"]) or "none"}')
    if a.json:
        json.dump(results, open(a.json, 'w'), indent=1, default=str)
    sys.exit(0 if npass == len(sel) else 1)


if __name__ == '__main__':
    main()
