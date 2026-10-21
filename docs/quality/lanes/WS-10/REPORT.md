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
from the same proxy Auto uses (tone at zero). It searches zoom ratios 1.05-2 in 0.05-0.1 steps,
each with the whole frame and with central windows of 70 %, 55 % and 40 %, at every translation,
in both directions; that covers pans and zoom-plus-re-aim. It then takes the median
frame − reference difference over the shared cells of the winning placement only.

The acceptance score is the gradient correlation, taken as the lowest of the window's textured
quadrants. Two attempts before it were too loose:

- Level NCC scored unrelated sky-over-ground frames up to 0.87.
- Whole-window gradient NCC let one shared horizon carry the score (0.77 on a synthetic pair).

Windows under 22 × 14 cells are never scored, because a 13-column window matched 4213 to 832 at
0.83. Over all 600 ordered corpus pairs with the full search, the score is 0.79 for 6929/6933 and
at most 0.55 for anything else (1840/832). The threshold is 0.65; the margin is on the side of
staying unmeasured.

Real crops of 6929 (−0.5 EV applied, round 3):

| case | measured | score |
|---|---|---|
| pan 8 % / 17 % / 25 % of the crop width | −0.498 / −0.487 / −0.496 | 0.97 / 0.81 / 0.99 |
| pan 33 % | not measured, so EXIF | |
| zoom 1.05 / 1.15 / 1.38 / 1.56 + re-aim | −0.495 / −0.509 / −0.504 / −0.514 | 0.81 / 0.74 / 0.70 / 0.80 |
| zoom 1.1 | not measured (0.57), so EXIF | |

Speed: `lumen-render match` on the pair, two 512-px renders included, takes 1.7 s in a release build.
In round 2 the search sorted a median at every placement, which cost about 0.5 s per frame.

`Frame.measuredStopsBrighter` replaces the EXIF difference when present; EXIF stays the fallback. The
status line says "by measured brightness". In the app the command now renders a 512-px proxy per
selected frame (status "Measuring exposures…"). That is slower than reading EXIF alone and will
show on bursts of hundreds of frames.

## Verdict per spec line

| Line | Result | Measured |
|---|---|---|
| M1 pair residual on the registered overlap ≤ 0.10 EV | PASS | median +0.021, log-mean +0.029 (EXIF-only: −0.299 / −0.291) |
| M2 pair found, score ≥ 0.7, offset within 0.05 EV of full-res, under 3 s | PASS | score 0.794; +0.360 vs +0.389; 1.7 s |
| M3 no shared view, so EXIF | PASS | all 600 corpus pairs: only 6929↔6933 measured (best unrelated 0.55 < 0.65); synthetic shared-horizon and noise pairs nil |
| M4 1.5× crop, re-aimed, both directions | PASS | within 0.05 EV |
| M5 existing EXIF contract | PASS | `ExposureMatchTests` 11/11, unchanged |
| M6 summary names the basis | PASS | "Matched 1 photo to 6929.ARW by measured brightness" |
| M7 pans and in-between zooms | **FAIL, BLOCKED after 3 rounds** | Synthetic tests pass, and every real crop that is measured is within 0.027 EV, so no wrong value was produced. Recall is spotty, though. The round-3 verifier's own 6929 crops: pans 12/14 measured (missed: 18 % with a 4 % vertical shift). Zooms: 1.05 off-centre, 1.1 centred, 1.15 centred, 1.2 off-centre and 1.7 missed; the rest measured. Scores sit at 0.65-0.70, just over the threshold, so which crops get measured is fragile. A miss falls back to EXIF |

M2's threshold changed from 0.9 (level NCC, round 1) to 0.7. The score itself changed to the stricter
quadrant gradient correlation, which reads lower on every pair.

## Limits

- Only one naturally overlapping pair exists in the corpus. Pans and zooms are proven on synthetic
  grids and on crops cut from 6929, not on separately shot photographs.
- Pans of a third of the frame or more, and some zoom ratios (1.1x on the 6929 crop), fall back to
  EXIF.
- A sequence that crosses from shade to sun, framed the same way, will be evened out. That is the
  command's job; a frame the photographer wants left alone should stay out of the selection.
- Rotation is not searched; the round-2 verifier measured 0.5-2° rotations within 0.02 EV anyway.

## Verification

- **Round 1: FAIL.** Unrelated corpus pairs got measured offsets (up to 1.8 EV).
- **Round 2: FAIL.** Pans over about 15 % and in-between zooms were missed; the search took 0.5 s per
  frame; `match` ignored `--set`.
- **Round 3: FAIL on M7 only.** Every other line passed, with no false positives over 600 pairs and
  1.7 s per pair. M7 is left **BLOCKED**, with the numbers above.

What would fix M7: sub-cell placement (bilinear resampling with fractional offsets instead of integer
box bins) and a finer zoom step. Both raise the true-overlap score without raising the unrelated
score, which the integer grid currently caps. That is the next step, not a threshold change: lowering
0.65 toward the 0.55 an unrelated pair reaches trades a missed measurement (safe, EXIF) for a wrong
one.
