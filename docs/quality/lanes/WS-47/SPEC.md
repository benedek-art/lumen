# WS-47 Luminance Range: acceptance spec

Same probe as WS-48 (`docs/quality/lanes/WS-48/probe.py`), plus unit tests in
`Tests/LumenCoreTests/RangeMaskQualityTests.swift`. EV is scene-linear luminance on the
fixed -10..+4 axis.

| # | claim | threshold | baseline |
|---|---|---|---|
| L1 | unit: the handles are the edge. A pixel exactly at From/To is half selected; the alpha > 0.5 region is identical at every Smooth; nothing more than half a shoulder (Smooth/100 EV) outside the band is selected at all | 0 violations on a 0.01 EV sweep at Smooth 0..100, analytic and rasterized | fails: Smooth 50 moves the edge 1 EV outward |
| L2 | unit: inside the band, alpha is monotone in EV up to the plateau and Smooth widens the ramp monotonically; Smooth 0 is a step | ramp width at Smooth 0 <= 0.05 EV | — |
| L3 | unit: a handle at the end of the axis is open-ended (To = +4 selects +6 EV; From = -10 selects -14 EV) | alpha = 1 | — |
| L4 | 983 sunlit snow vs sky, From -3.6 EV, To +4: precision at Smooth 0 / 50 / 100 | >= 0.95 at each | 0.918 / 0.433 / 0.254 |
| L5 | 983: Smooth neither grows nor shrinks the selection: precision and recall at Smooth 50 and 100 within 0.02 of Smooth 0 | <= 0.02 | precision falls 0.49, recall rises 0.17 |
| L6 | 2348 ISO 3200 darks, To -4.6 EV, Smooth 50: speckle per MP | <= 500 | 7887 |
| L7 | 2348: matte grain `hf` at Smooth 50 | <= 15 | 44.6 |
| L8 | 2348 Smooth 0 speckle per MP | <= 2000 | 10044 |
| L9 | no lo/hi: zero plane (existing) | exact | pass |
| L10 | cost: 2400 x 1800, release | <= 4x baseline (0.2 s) | 0.2 s |

Visual (human):
- V1 `evidence/lr_983_sweep.png`: snow selected, sky stays black at Smooth 0/50/100, Smooth only softens the edge inside the band.
- V2 `evidence/lr_2348_crop.png`: the jacket band edge is a soft region, not salt-and-pepper.
- V3 panel snapshot `panel-masks-luma-range`: a luminance map strip under From/To shows the band and its falloff on the EV axis.

## Revisions (made before verification, with the reason)

- L1 first said "From and To are hard limits, shoulders inside the band" (Lightroom
  Classic's arrangement). The builder went with the shoulder CENTRED on each handle
  instead: inside-shoulders make Smooth shrink the selection (recall at Smooth 50 fell
  from 0.78 to 0.45 on 983) just as outside-shoulders made it grow; centred, Smooth
  softens the edge and never moves it. The help text now says exactly that.
- L4/L5 first used From -3.2 EV and regions that included shaded snow, which is as dark
  as the sky (median -3.46 vs -4.06 EV, overlapping): no luminance band separates
  them, so those numbers measured the scene, not the mask. Regions were corrected (see
  `WS-48/regions.py`), From moved to -3.6 (just above the sky's p99), and L5 restated as
  the property Smooth is actually responsible for. Baseline numbers for the new From are
  the old formula reproduced in numpy (verified against the old Swift output to 5e-6).
