"""Chart ground truth for WS-03 Auto WB (tooling). Reads ../charts.json (auditor's patch rects and
mid-grey means, which are convention-free decoded RGB) and re-derives everything in the ADOBE/DNG
convention the spec adopts.

  python3 docs/quality/lanes/WS-03/tools/charts.py            # table: as-shot, chart-neutral (Adobe), residuals
  python3 docs/quality/lanes/WS-03/tools/charts.py K T FRAME  # residual of one pair on one frame

Residual = CIEDE2000 of the chart's mid-grey mean (scene-linear Rec.2020, scaled to Y=0.18) after the
Adobe-convention WB matrix (wbmodel.adobe_matrix), vs the neutral of the same Y. Same definition as
charts.json `asShotResidual.deltaE00`.

CHART_MASK: one rectangle per frame, [x, y, w, h] at the delivered 2400 px size, covering the whole
target (both Passport pages, the whole SpyderCheckr, the whole Kosmos card) with margin. "Chart OUT"
runs of Auto exclude it."""
import sys, os, json
import numpy as np
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from wbmodel import adobe_matrix, neutral_target, de_grey

CHARTS = json.load(open(os.path.join(HERE, '..', 'charts.json')))
FRAMES = ['1346_canon-eos-5d', '967_sony-ilce-7m2', '983_canon-eos-5d-mark-iv', '3914_fujifilm-x-t4', '864_fujifilm-x-t2']
CHART_MASK = {
    '1346_canon-eos-5d': [300, 110, 1680, 1260],
    '967_sony-ilce-7m2': [840, 140, 860, 920],
    '983_canon-eos-5d-mark-iv': [1200, 690, 1100, 800],
    '3914_fujifilm-x-t4': [1110, 380, 520, 860],
    '864_fujifilm-x-t2': [340, 90, 1980, 1450],
}

def short(frame): return frame.split('_')[0]
def find(frame):
    for f in FRAMES:
        if f == frame or short(f) == str(frame): return f
    raise KeyError(frame)
def as_shot(frame):
    a = CHARTS[find(frame)]['asShot']; return (a['kelvin'], a['tint'])
def grey(frame): return np.array(CHARTS[find(frame)]['midGreyMeanNormRGB'], float)
def chart_neutral(frame):
    k, t = neutral_target(grey(frame), as_shot(frame)); return float(k), float(t)
def residual(frame, kelvin, tint):
    g = adobe_matrix(as_shot(frame), (kelvin, tint)) @ grey(frame)
    return float(de_grey(g / g.mean() * 0.18))

if __name__ == '__main__':
    if len(sys.argv) == 4:
        k, t, f = float(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
        print(json.dumps(dict(frame=find(f), kelvin=k, tint=t, deltaE00=round(residual(f, k, t), 3))))
        sys.exit()
    print(f"{'frame':28s} {'as-shot':>16s} {'chart-neutral (Adobe)':>22s} {'dMired':>7s} {'dTint':>6s} {'asShot dE00':>11s} {'neutral dE00':>12s}")
    for f in FRAMES:
        ak, at = as_shot(f); k, t = chart_neutral(f)
        print(f"{f:28s} {ak:8.0f}/{at:+6.1f} {k:13.0f}/{t:+6.1f} {1e6/ak-1e6/k:+7.1f} {at-t:+6.1f} {residual(f, ak, at):11.2f} {residual(f, k, t):12.4f}")
