"""Generate maskh job files for the M6 audit. usage: cases.py <outroot> <set>"""
import json, sys, copy, os
C = os.environ.get('CORPUS_LFI', os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../../../../corpus/lfi')) + '/'
def comp(kind, op='add', amount=100, invert=False, **kw):
    d = dict(kind=kind, op=op, amount=amount, invert=invert); d.update(kw); return d
def mask(mid, comps, invert=False, refine=None):
    return dict(id=mid, name=mid, enabled=True, invert=invert, amount=100, components=comps,
                refine=refine or {})
RAD = lambda **k: comp('radial', center=[0.42, 0.76], radii=[0.20, 0.26], rotation=0, feather=50, **k)
CAN = lambda **k: comp('colorRange', samples=[[0.3388, 0.1529, 0.1717]], rangeAmount=50, **k)
LIN = lambda **k: comp('linear', line=[0.5, 0.15, 0.5, 0.75], **k)
LUM = lambda **k: comp('lumaRange', lo=0.50, hi=1.0, smooth=50, **k)

def algebra():
    j8 = [
      ('R', mask('R', [RAD()])),
      ('C', mask('C', [CAN()])),
      ('R_add_C', mask('RaC', [RAD(), CAN()])),
      ('R_sub_C', mask('RsC', [RAD(), CAN(op='subtract')])),
      ('R_int_C', mask('RiC', [RAD(), CAN(op='intersect')])),
      ('R_sub_C50', mask('RsC50', [RAD(), CAN(op='subtract', amount=50)])),
      ('R50_sub_C', mask('R50sC', [RAD(amount=50), CAN(op='subtract')])),
      ('R_int_C50', mask('RiC50', [RAD(), CAN(op='intersect', amount=50)])),
      ('R_add_C0', mask('RaC0', [RAD(), CAN(amount=0)])),
      ('R_sub_C0', mask('RsC0', [RAD(), CAN(op='subtract', amount=0)])),
      ('R_int_C0', mask('RiC0', [RAD(), CAN(op='intersect', amount=0)])),
      ('R_add_C50', mask('RaC50', [RAD(amount=50), CAN(amount=50)])),
      ('R_sub_Cinv', mask('RsCi', [RAD(), CAN(op='subtract', invert=True)])),
      ('R_int_Cinv', mask('RiCi', [RAD(), CAN(op='intersect', invert=True)])),
      ('inv_R_sub_C', mask('iRsC', [RAD(), CAN(op='subtract')], invert=True)),
      ('Rinv', mask('Ri', [RAD(invert=True)])),
      # references: X = R − C; Y = ref(X) inverted ∩ C-free radial elsewhere
      ('ref_X', mask('refX', [comp('maskRef', maskRef='RsC')])),
      ('ref_X_inv', mask('refXi', [comp('maskRef', maskRef='RsC', invert=True)])),
      ('inv_ref_Xinv', mask('irefXi', [comp('maskRef', maskRef='RsC', invert=True)], invert=True)),
      ('ref_iX', mask('refiX', [comp('maskRef', maskRef='iRsC')])),
    ]
    j9 = [
      ('L', mask('L', [LIN()])),
      ('U', mask('U', [LUM()])),
      ('L_int_U', mask('LiU', [LIN(), LUM(op='intersect')])),
      ('L_sub_U', mask('LsU', [LIN(), LUM(op='subtract')])),
      ('L_add_U', mask('LaU', [LIN(), LUM()])),
      ('U_int_L', mask('UiL', [LUM(), LIN(op='intersect')])),
      ('L_int_U_inv', mask('LiUi', [LIN(), LUM(op='intersect', invert=True)])),
    ]
    return [(C + '8559_nikon-z-fc.lfi', 'alg8559', j8), (C + '983_canon-eos-5d-mark-iv.lfi', 'alg983', j9)]

SWEEPS = dict(feather=[0, 5, 10, 25, 50, 75, 100], edge=[-50, -25, -10, -3, 0, 3, 10, 25, 50],
              blur=[0, 2, 5, 10, 25, 50, 100], levelsLo=[0, 10, 25, 50, 75, 90],
              levelsHi=[100, 90, 75, 50, 25, 10], levelsGamma=[0.2, 0.5, 0.8, 1, 1.25, 2, 5])

def refine_sets():
    out = []
    bases = [
      (C + '8559_nikon-z-fc.lfi', 'ref8559_RsC', [RAD(), CAN(op='subtract')]),
      (C + '8559_nikon-z-fc.lfi', 'ref8559_C', [CAN()]),
      (C + '983_canon-eos-5d-mark-iv.lfi', 'ref983_LiU', [LIN(), LUM(op='intersect')]),
      (C + '983_canon-eos-5d-mark-iv.lfi', 'ref983_hardR', [comp('radial', center=[0.80, 0.25], radii=[0.10, 0.16], feather=0)]),
    ]
    for path, name, comps in bases:
        jobs = []
        for key, vals in SWEEPS.items():
            for v in vals:
                jobs.append((f'{key}_{v}', mask(f'{name}_{key}_{v}', copy.deepcopy(comps), refine={key: v})))
        out.append((path, name, jobs))
    return out

if __name__ == '__main__':
    root, which = sys.argv[1], sys.argv[2]
    sets = algebra() if which == 'algebra' else refine_sets()
    for path, name, jobs in sets:
        d = dict(input=path, longEdge=int(sys.argv[3]) if len(sys.argv) > 3 else 2400, outDir=f'{root}/{name}',
                 masks=[dict(name=n, mask=m) for n, m in jobs])
        if name == 'alg8559':
            d['refs'] = []
        json.dump(d, open(f'{root}/{name}.json', 'w'))
        print(f'{root}/{name}.json')
