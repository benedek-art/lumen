#!/usr/bin/env python3
"""Float (no 8-bit rounding) colour of the vignette's corner boxes, SPEC Amendment A1.

Renders a frame (downsampled to 768 px, box-averaged) through `probe`
(scripts/proof/ws41/probe, a LumenCore-only executable built on first use) in
  display  ReferenceRenderer output, display-linear -> sRGB linear, clamped
  scene    DetailEngine.vignette alone, scene-linear Rec.2020
and prints per box OKLab dh (deg, hue of mean a,b), cl = (C/L)/(C0/L0), L, C/C0 for
HP, CP and PO.

  huefloat.py line17            CP vs HP at -2/-4 (display): |dh_CP| <= |dh_HP| + 0.5, cl
  huefloat.py line18            CP lift at +1.5/+2 (display): dh, C/C0, dL vs HP
  huefloat.py line19            PO at -2 vs HP' (HP at the Amount whose corner L matches
                                PO's within 0.03): |dh_PO| <= |dh_HP'| + 1.0
  huefloat.py scene             scene-linear dh of CP and PO (must be <= 0.1 deg)
"""
import json, os, subprocess, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib
from corner import BOXES, C5

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.environ.get('WS41_PROBE_BUILD', '/tmp/ws41-probe')
PROBE = os.path.join(SCRATCH, 'release', 'probe')
T = os.path.join(lib.OUT, 'huefloat'); os.makedirs(T, exist_ok=True)
SEL = {'colour4': ['red_TL', 'blue_TR', 'green_BL', 'skin_BR'],
       'skin_tones': ['tan_TR', 'dark_BL', 'mid_BR'], 'skytest': ['sky_TR'],
       '2545': ['TR'], '983': ['TL']}
LIFT = {'skytest': ['sky_TR'], 'skin_tones': ['mid_BR', 'tan_TR'],
        'colour4': ['blue_TR', 'red_TL', 'skin_BR'], '2545': ['TR']}
STYLES = ['highlightPriority', 'colorPriority', 'paintOverlay']
M = np.array([[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]])


def build():
    if not os.path.exists(PROBE):
        subprocess.run(['swift', 'build', '-c', 'release', '--package-path',
                        os.path.join(HERE, 'probe'), '--scratch-path', SCRATCH], check=True)


def oklab(c):
    r, g, b = c[..., 0], c[..., 1], c[..., 2]
    l = np.cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
    m = np.cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
    s = np.cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
    return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)


def small(name, le=768):
    src = lib.frame(name); p = os.path.join(T, name + '_%d.lfi' % le)
    if not os.path.exists(p):
        a = lib.read_lfi(src); H, W, _ = a.shape; f = max(1, int(np.ceil(max(H, W) / le)))
        a = a[:H // f * f, :W // f * f].reshape(H // f, f, W // f, f, 3).mean((1, 3)).astype(np.float32)
        lib.write_lfi(p, a)
        js = src[:-4] + '.json'
        if os.path.exists(js):
            open(p[:-4] + '.json', 'w').write(open(js).read())
    return p


def probe(lfi, look, mode='display'):
    rp = os.path.join(T, 'r.json'); json.dump({'pipelineVersion': 2, 'look': look}, open(rp, 'w'))
    sa = lib.sidecar_args(lfi); iso = sa[5] if len(sa) > 5 else '0'
    out = os.path.join(T, 'o.raw')
    r = subprocess.run([PROBE, lfi, rp, sa[1], sa[3], iso, out, mode], capture_output=True,
                       text=True, check=True)
    w, h = map(int, r.stdout.split())
    return np.fromfile(out, dtype=np.float32).reshape(h, w, 3)


def stats(img, b, mode):
    H, W, _ = img.shape; x0, y0, x1, y1 = b
    p = img[int(y0 * H):max(int(y1 * H), int(y0 * H) + 1), int(x0 * W):max(int(x1 * W), int(x0 * W) + 1)]
    if mode == 'scene':
        p = p @ M.T
    L, A, B = oklab(p)
    return L.mean(), np.hypot(A, B).mean(), np.degrees(np.arctan2(B.mean(), A.mean()))


def compare(base, img, b, mode):
    L0, C0, h0 = stats(base, b, mode); L, C, h = stats(img, b, mode)
    return dict(dh=(h - h0 + 180) % 360 - 180, cl=(C / L) / (C0 / L0), L=L, cc=C / C0, L0=L0)


def main():
    build()
    what = sys.argv[1] if len(sys.argv) > 1 else 'line17'
    fails = 0
    if what in ('line17', 'scene'):
        mode = 'scene' if what == 'scene' else 'display'
        for f, sel in SEL.items():
            p = small(f); bx = BOXES.get(f, C5)
            base = probe(p, {'vignette': 0}, mode)
            for a in (-2.0, -4.0):
                r = {s: probe(p, {'vignette': a, 'vignetteStyle': s}, mode) for s in STYLES}
                for k in sel:
                    hp, cp, po = (compare(base, r[s], bx[k], mode) for s in STYLES)
                    if mode == 'scene':
                        ok = abs(cp['dh']) <= 0.1 and abs(po['dh']) <= 0.1
                    else:
                        clok = 0.90 <= cp['cl'] <= 1.15 or abs(cp['cl'] - hp['cl']) <= 0.02
                        ok = abs(cp['dh']) <= abs(hp['dh']) + 0.5 and clok
                    fails += not ok
                    print('%-10s %-8s a=%+.0f  HP dh %+6.2f cl %.3f | CP dh %+6.2f cl %.3f | PO dh %+6.2f  %s' % (
                        f, k, a, hp['dh'], hp['cl'], cp['dh'], cp['cl'], po['dh'], 'ok' if ok else 'FAIL'))
    elif what == 'line18':
        for f, sel in LIFT.items():
            p = small(f); bx = BOXES.get(f, C5)
            base = probe(p, {'vignette': 0})
            for a in (1.5, 2.0):
                hp = probe(p, {'vignette': a}); cp = probe(p, {'vignette': a, 'vignetteStyle': 'colorPriority'})
                for k in sel:
                    h, c = compare(base, hp, bx[k], 'display'), compare(base, cp, bx[k], 'display')
                    frac = (c['L'] - c['L0']) / max(h['L'] - h['L0'], 1e-9)
                    print('%-10s %-8s a=%+.1f  HP dh %+6.2f | CP dh %+6.2f C/C0 %.3f dL %.0f%%' % (
                        f, k, a, h['dh'], c['dh'], c['cc'], 100 * frac))
    elif what == 'line19':
        amounts = np.round(np.arange(-1.0, -4.01, -0.05), 2)
        for f, sel in SEL.items():
            p = small(f); bx = BOXES.get(f, C5)
            base = probe(p, {'vignette': 0})
            po = probe(p, {'vignette': -2.0, 'vignetteStyle': 'paintOverlay'})
            hps = {a: probe(p, {'vignette': float(a)}) for a in amounts}
            for k in sel:
                q = compare(base, po, bx[k], 'display')
                best = min(amounts, key=lambda a: abs(compare(base, hps[a], bx[k], 'display')['L'] - q['L']))
                h = compare(base, hps[best], bx[k], 'display')
                ok = abs(h['L'] - q['L']) <= 0.03 and abs(q['dh']) <= abs(h['dh']) + 1.0
                fails += not ok
                print('%-10s %-8s PO dh %+6.2f L %.3f | HP at %+.2f dh %+6.2f L %.3f  %s' % (
                    f, k, q['dh'], q['L'], best, h['dh'], h['L'], 'ok' if ok else 'FAIL'))
    print('FAILS', fails)


if __name__ == '__main__':
    main()
