"""SPEC 7 BEFORE numbers: the eyedropper (WhiteBalanceEngine.neutralizing, ported) clicked on a 0.18 grey
lit by an illuminant with known Adobe numbers, decoded at as-shot A. Reports the error of the returned
pair against the illuminant's Adobe pair. The AFTER measurement is the Swift test named in SPEC.md.
  python3 docs/quality/lanes/WS-03/tools/eyedropper_before.py"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wbmodel import *
AS = [(6503.7072, 9.77), (5000, 5), (3000, 0), (4708, 48.2)]
ILL = [(2856, 0), (3800, 21), (4000, 0), (5002, 9.6), (6504, 9.8), (7506, 9.6), (9992, 9.3)]
if __name__ == '__main__':
    wm = wt = 0
    for a in AS:
        for L in ILL:
            k, t, _ = neutralizing(decoded_grey(L, a), a)
            dm = 1e6 / k - 1e6 / L[0]; dt = t - L[1]; wm = max(wm, abs(dm)); wt = max(wt, abs(dt))
            print(f'as-shot {a[0]:6.0f}/{a[1]:+5.1f}  illum {L[0]}/{L[1]:+5.1f} -> {k:7.0f}/{t:+6.1f}  dK {k - L[0]:+6.0f}  dMired {dm:+6.2f}  dTint {dt:+6.2f}')
    print(f'max |dMired| {wm:.2f}, max |dTint| {wt:.2f}')
