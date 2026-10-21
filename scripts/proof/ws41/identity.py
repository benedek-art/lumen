#!/usr/bin/env python3
"""Byte identity of legacy vignette renders (spec lines 1-3).

  identity.py --record            hash today's renders -> identity_before.json (done once,
                                  on the base commit; the file is committed)
  identity.py                     re-render, compare with identity_before.json
  identity.py --explicit          same, but every case also sets the new keys to their
                                  defaults (midpoint 50, roundness 0, highlights 0,
                                  style highlightPriority) -- must still match
  identity.py --amount-zero       Amount 0 with each non-default combination of the other
                                  controls must equal the plain default render

Hashes are SHA-256 of the decoded RGB pixels (not the PNG bytes). Cases: 7 frames x 7
Amounts at feather 50, long edge 512, export dither on; plus 3 legacy-sidecar recipes
loaded with --recipe.
"""
import argparse, hashlib, json, os, subprocess, sys
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lib

HERE = os.path.dirname(os.path.abspath(__file__))
STORE = os.path.join(HERE, 'identity_before.json')
FRAMES = ['flat_grey', 'skin_tones', 'colorchecker', 'skytest', '6929', '2545', '983']
AMOUNTS = ['-4', '-2.5', '-1', '-0.37', '0.6', '2', '0']
DEFAULTS = ['look.vignetteMidpoint=50', 'look.vignetteRoundness=0',
            'look.vignetteHighlights=0', 'look.vignetteStyle=highlightPriority']
LEGACY = {'legacy_no_feather': {'pipelineVersion': 2, 'look': {'vignette': -1.3}},
          'legacy_feather50': {'pipelineVersion': 2, 'look': {'vignette': -1.3, 'vignetteFeather': 50}},
          'legacy_plus': {'pipelineVersion': 2, 'look': {'vignette': 1.7}}}
ZERO_COMBOS = [
    ['look.vignetteMidpoint=0', 'look.vignetteFeather=0', 'look.vignetteRoundness=-100'],
    ['look.vignetteMidpoint=100', 'look.vignetteFeather=100', 'look.vignetteRoundness=100'],
    ['look.vignetteHighlights=100', 'look.vignetteStyle=colorPriority'],
    ['look.vignetteStyle=paintOverlay', 'look.vignetteMidpoint=17', 'look.vignetteRoundness=63'],
]


def h(img):
    return hashlib.sha256(np.ascontiguousarray(img).tobytes()).hexdigest()[:20]


def render_recipe(lfi, recipe, tag):
    rp = os.path.join(lib.OUT, tag + '.json')
    json.dump(recipe, open(rp, 'w'))
    png = os.path.join(lib.OUT, tag + '.png')
    cmd = [lib.binary(), 'render', '--input', lfi, '--recipe', rp, '--long-edge', '512',
           '--out', png] + lib.sidecar_args(lfi)
    subprocess.run(cmd, check=True, capture_output=True)
    return np.asarray(Image.open(png).convert('RGB'))


def cases(extra):
    for f in FRAMES:
        lfi = lib.frame(f)
        for a in AMOUNTS:
            img, _ = lib.render(lfi, ['look.vignette=' + a] + extra, long_edge=512, dither=True)
            yield '%s@%s' % (f, a), h(img)
    for name, rec in LEGACY.items():
        if extra:
            rec = json.loads(json.dumps(rec))
            for s in extra:
                k, v = s.split('=')
                rec['look'][k.split('.')[-1]] = v if not v.lstrip('-').replace('.', '').isdigit() else float(v)
        yield name, h(render_recipe(lib.frame('skin_tones'), rec, 'id_' + name))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--record', action='store_true')
    ap.add_argument('--explicit', action='store_true')
    ap.add_argument('--amount-zero', action='store_true')
    a = ap.parse_args()
    if a.amount_zero:
        bad = 0
        for f in ['skin_tones', '6929']:
            lfi = lib.frame(f)
            base = h(lib.render(lfi, [], long_edge=512, dither=True)[0])
            for combo in ZERO_COMBOS:
                got = h(lib.render(lfi, ['look.vignette=0'] + combo, long_edge=512, dither=True)[0])
                ok = got == base
                bad += not ok
                print('%-4s %-10s %s' % ('ok' if ok else 'DIFF', f, ' '.join(combo)))
        print('AMOUNT_ZERO_MISMATCHES', bad)
        return
    got = dict(cases(DEFAULTS if a.explicit else []))
    if a.record:
        json.dump(got, open(STORE, 'w'), indent=1, sort_keys=True)
        print('recorded %d cases -> %s' % (len(got), STORE))
        return
    want = json.load(open(STORE))
    bad = [k for k in want if got.get(k) != want[k]]
    for k in want:
        print('%-4s %s' % ('ok' if k not in bad else 'DIFF', k))
    print('IDENTITY_MISMATCHES %d of %d' % (len(bad), len(want)))


if __name__ == '__main__':
    main()
