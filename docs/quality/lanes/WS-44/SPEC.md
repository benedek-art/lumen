# WS-44 Brush masks: acceptance spec

Measured with `python3 docs/quality/lanes/WS-44/brushlab.py run OUT` (synthetic, 1024x683,
size 0.08 = 41 px radius) and `bash docs/quality/lanes/WS-44/automask.sh OUT` (corpus
photos), both driving `lumen-render strokes` (Sources/LumenRender/Strokes.swift), which calls
the shipping `MaskRaster.accumulatedBrushPlane`. "Before" numbers are base commit 84bcd7c.

The brush is CPU-rasterized and uploaded as a mask plane; there is no GPU twin of the stamp
kernel (`MaskGPU.alpha` returns nil for any mask with a brush component), so there is no
CPU/GPU parity line here.

## Measurable lines

| # | Claim | Threshold | Before | Measure |
|---|---|---|---|---|
| S1 | A straight stroke's cross-section equals the single dab's radial profile (what the cursor shows), Feather 0/25/50/75/100 | max abs error <= 0.02 | 0.155 / 0.510 / 0.581 / 0.616 / 0.638 | `measure.json` featherNN.maxErrVsDabProfile |
| S2 | Feather 100 stroke reaches 50 % at the dab's 50 % radius | half_r within 0.02 of ref_half_r (0.476) | 0.793 | featherNN.half_r |
| S3 | Single dab profile unchanged | dabNN.maxErrVsProfile <= 0.01 | 0.005 | dabNN |
| S4 | Flow 50: one pass deposits 50 %, two crossing passes 75 % | 0.50 +- 0.01, 0.75 +- 0.01 | 1.00, 1.00 | flow50 |
| S5 | Density 60 is a ceiling over three passes at Flow 100 | max <= 0.602, single = 0.60 +- 0.01 | 0.60 / 0.60 | density60 |
| S6 | One stroke going back over itself does not build up (Flow 50 scribble) | centre 0.50 +- 0.01 | 1.00 | scribble50.centre |
| S7 | Erase: Flow 100 removes fully, Flow 50 removes half | erasedCentre <= 0.005, eraseFlow50 0.50 +- 0.01 | 0.0, 0.0 | erase |
| S8 | Pressure scales the deposit: centre at pressure p is p (Flow 100) | each of x=160..860 within 0.03 of p | 0.84, 1.0, 1.0, 1.0, 1.0 | pressure.centre_at_x |
| S9 | Fast strokes (6 events across the frame) are gap-free and bead-free | peakMin >= 0.99; flick at Flow 30: centreline ripple <= 0.005 | peakMin 1.0; ripple: measured | fast_small, fast_large, flick30 |
| S10 | Auto Mask traced along an object outline (centre ~0.5 r inside) stays on the object | leak <= 3 % of mask mass outside the object; coverage inside >= 0.85 | auditor's numbers | automask.sh (4694 lemon, 4694 apple, 8559 can) |
| S11 | Auto Mask stroke that starts on an object and continues across its edge stays on the object it started on | mass beyond the edge <= 3 % | auditor's numbers | automask.sh crossing |
| S12 | Per-stroke paint cost at 2560 long edge, size 0.08 | >= 5x faster without Auto Mask, >= 10x faster with it | `msPerRadius` before | `lumen-render strokes --metrics`, `--repeat 5` |
| S13 | Painting point by point (the live path) equals painting the stroke whole | max abs difference <= 1e-6 | n/a (no live path) | `BrushRasterTests` |
| S14 | Identity: empty set, Flow 0, Density 0 (paint) leave the plane exactly 0 | exact | exact | `BrushRasterTests` |
| S15 | Resolution independence: the same stroke at 512 and 2048, cross-section in radii | max abs difference <= 0.03 | existing `BrushResolutionTests` | `BrushResolutionTests` |

## Visual claims (a human judges from the named sheet)

- V1 `evidence/feather_before_after.png`: Feather 0 to 100 strokes go from a hard bar to a
  visibly soft one; the after Feather 100 stroke looks like the dab beside it, stretched.
- V2 `evidence/automask_*.png`: an Auto Mask stroke traced round the lemon and the watering
  can covers the object to its edge and leaves the bowl/background clean; a stroke dragged
  off the object stops at the edge.
- V3 `evidence/flow_erase_before_after.png`: Flow 50 crossing shows a darker cross-over;
  the Flow 50 eraser leaves a half-strength band with soft edges.

## Interaction (owner, by hand; cannot be seen in a PNG)

Listed in REPORT.md: drag latency while painting, live overlay matching the committed
mask, cursor rings matching the painted edge, pressure on a tablet.
