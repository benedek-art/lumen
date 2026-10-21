# WS-10 Match Total Exposures: report

Lane T5 (with WS-09). The summary for the owner is in `../WS-09/REPORT.md`.

## Finding

On the owner's A7 IV pair the EXIF says 6933 (1/80, f/5.6, ISO 640) was captured 0.68 EV brighter
than 6929 (1/50, f/5.6, ISO 250). The pixels say 0.39 EV. That figure comes from 6933's footprint,
located inside 6929 at full resolution by normalized cross-correlation (NCC 0.90), compared on the
shared content. The likely causes are overcast light changing between frames, the sensor's real gain
differing from its ISO label, or both.

Two methods fail on this pair:

- **EXIF only** (Lightroom's rule and the old code) leaves the pair **0.30 EV apart the other way**,
  which is worse than not matching (0.38 EV).
- **Whole-frame measurement** reads the two frames as equal (−1.156 vs −1.159 EV). 6929 holds more
  white wall and 6933 more foliage, so the frame average measures composition, not exposure.

## Change

`ExposureMatch.measureOverlap` places one frame inside the other on a 64-column scene-EV grid read
from the same proxy Auto uses (tone at zero). It searches zoom ratios 1.25-2 at every translation,
in both directions, plus a pan at the same focal length (the central 70 % placed anywhere). It then
takes the median frame − reference difference over the shared cells.

The acceptance score is the gradient correlation, taken as the lowest of the window's textured
quadrants. Two attempts before it were too loose:

- Level NCC scored unrelated sky-over-ground frames up to 0.87.
- Whole-window gradient NCC let one shared horizon carry the score (0.77 on a synthetic pair).

Over all 600 ordered corpus pairs the score is 0.79 for 6929/6933 and at most 0.19 for anything
else. The threshold is 0.5.

`Frame.measuredStopsBrighter` replaces the EXIF difference when present; EXIF stays the fallback. The
status line says "by measured brightness". In the app the command now renders a 512-px proxy per
selected frame (status "Measuring exposures…"). That is slower than reading EXIF alone and will
show on bursts of hundreds of frames.

## Verdict per spec line

| Line | Result | Measured |
|---|---|---|
| M1 pair residual on the registered overlap ≤ 0.10 EV | PASS | median +0.021, log-mean +0.029 (EXIF-only: −0.299 / −0.291) |
| M2 pair found, score ≥ 0.7, offset within 0.05 EV of full-res | PASS | score 0.794; +0.360 vs +0.389 |
| M3 no shared view, so EXIF | PASS | all 600 corpus pairs: only 6929↔6933 measured; synthetic shared-horizon and noise pairs nil |
| M4 1.5× crop, re-aimed, both directions | PASS | within 0.05 EV |
| M5 existing EXIF contract | PASS | `ExposureMatchTests` 11/11, unchanged |
| M6 summary names the basis | PASS | "Matched 1 photo to 6929.ARW by measured brightness" |
| M7 same-focal-length pan | PASS | within 0.05 EV |

M2's threshold changed from 0.9 (level NCC, round 1) to 0.7. The score itself changed to the stricter
quadrant gradient correlation, which reads lower on every pair.

## Limits

- Only one overlapping pair exists in the corpus. The pan and crop cases are proven on synthetic
  grids, not on photographs.
- A sequence that crosses from shade to sun, framed the same way, will be evened out. That is the
  command's job; a frame the photographer wants left alone should stay out of the selection.
- Rotation is not searched.
