# WS-51 / WS-52 report: local light, white balance and colour

## For the owner

- Local Temp/Tint used to measure from a fixed 5500 K, so on every real photo a full-mask Tint +100 missed the global look by up to ΔE 8. It now matches global exactly (ΔE 0), and so do Exposure, Kelvin, Sat, Vibrance and Point Colour.
- The mask's Shift/Kelvin switch now converts your white balance into the other unit instead of wiping it, including at Strength up to 200.
- Feathers are smooth with no ring for every control at normal values (sheet 03).
- Still failing, and not this lane's code: a strong move toward the opposite colour (Tint +100 on foliage, Hue +180, a saturated blue or teal Colour tint) shows a lighter or greyer ring in the feather. Asks are in NEEDS.md.
- Try by hand: the mask's Colour tint against Lightroom's mask Colour swatch on a real edit. I could not compare the two from here.

## Verdict per spec line

Measured with `measure.py` (8-bit sRGB, CIEDE2000) and the release lumen-render at
c9eab36. P2 was re-checked on the final commit (2545 at 6200 K: max 0.44). Corpus: 6929 A7 IV, 2545 GX85, 1192 X-T10, 3914 X-T4, 1346 5D and 1840 D850, each
at its as-shot neutral. 6929 and 2545 were run again with the global row at 6200 K / +15.

| line | measured (worst over all runs) | verdict |
|---|---|---|
| P1 Exposure +1 / −1.5 | ΔE max 0.00 | PASS |
| P2 Temp/Tint relative, at as-shot and at 6200 K | mean 0.00, p95 0.00, max 0.90 (one 8-bit code step); was mean up to 1.8 for Temp and 8.5 for Tint | PASS |
| P3 Kelvin 3800 | max 0.00 | PASS |
| P4 Sat +50 / −100, Vibrance +60 | max 0.00 | PASS |
| P5 Point Colour (foliage swatch, global moved ΔE mean 0.5 to 2.7) | max 0.00 | PASS |
| P6 Grading wheels | mean 0.23, p95 0.88 | PASS |
| P7 Contrast / Highlights / Shadows / Whites / Blacks | worst Shadows +80: mean 0.61, p95 1.58 | PASS, with gaps: global Highlights −80 and Whites +50 barely move these frames (ΔE < 0.2), so those two comparisons are near-vacuous |
| P8 Defaults are identity (full mask and feathered) | 0 codes | PASS |
| F1 No L* halo (listed controls; WB Tint at −60) | worst: amber tint 0.65, Hue +60 0.48, others ≤ 0.30 | PASS |
| F1 with WB Tint +100 (verifier) | 1.83 (6929), 2.61 (2545); 2.6 before this change | FAIL, pre-existing, WS-42 (NEEDS) |
| F2 Monotone ramp | true in every case | PASS |
| F3 No colour ring (F1 set) | worst Hue +60 1.68 | PASS |
| F3 with WB Tint +50 / +100 | 6.9 to 13.3 | FAIL, pre-existing, WS-42 (NEEDS) |
| F4 Strong tints, teal / blue at 100 | teal 1.13; blue 5.4 to 6.1 (same before the change) | FAIL, display transform (NEEDS) |
| U1-U3 unit tests | pass | PASS |
| V1 / V2 | ramps smooth with no ring; "after" ΔE maps flat | PASS (verifier agreed) |

Tests: 3064 tests pass on Linux at the final commit (release build with `-enable-testing`), 6 skipped, 0 failures.
Linux `swift test` does not build as-is, and this predates the lane:
`Sources/LumenApp/CompareView.swift:326,569` has trailing commas in call arguments, which
the Swift 6.0.3 parser rejects (from merge #26). For the test run I removed them in a
local copy and did not commit that.

## What changed and why

1. `LocalWhiteBalance.init(temp:tint:balanced:space:)` now measures the relative shift
   from the balanced neutral. It used to measure from 5500 K / 0. CAT16 is a von Kries
   scaling, so the local matrix composes with S6 into exactly the global adaptation to the
   shifted neutral. `resolve` passes `balanced` through. The GPU `LocalPlan` calls the
   same `resolve`, and `balanced` is already in `LocalTableCache`'s key, so the GPU path
   needs no edit of its own.
2. Added `kelvinEquivalent` and `shiftEquivalent`. `MP.whiteBalanceRows` now uses them, so
   the Shift/Kelvin switch converts the edit into the other unit. It used to reset to the
   bare neutral, which dropped any shift the mask had.
3. Strength past 100 now scales both spellings the same way. The Kelvin spelling used
   to stop at amount 1, so the switch jumped ΔE 3.4 at Strength 200. The Shift spelling
   clamped slider × Strength to ±100, so a maxed slider gained nothing past Strength 100.
   Round 2's half-fix turned that into a ΔE 6 jump, which the second verifier caught.
   Now the slider is clamped to ±100 first and then scaled. Measured on 6929 for
   (40,−30), (100,100) and (−100,0) at Strength 30, 100, 150 and 200: switch ΔE 0.00
   in every case. Remaining edge case: a Kelvin Tint past the ±300 hard range is
   clamped, so the switch is not exact there.
4. Tests. `MaskWhiteBalanceTests.testResolveReturnsTheOldMatrixBitForBitWhenNoKelvinIsSet`
   encoded the 5500 K anchor. It was renamed and now passes `balanced`. That is a changed
   expectation, not a loosened one: the anchor is the defect. New tests: two in
   `MaskWhiteBalanceTests` and the `LocalGlobalParityTests` file, which runs full
   `ReferenceRenderer.render` parity at as-shot 4711 K.

## Tried and dropped

I rebuilt the Colour tint to hold OKLab lightness instead of luminance Y. It did not
reduce the blue-tint feather ring (L* 5.9 against 5.4), so I reverted it. The ring comes
from the display transform: a constant-Y chroma ramp moves output L* +2.3 at mid chroma
and then back (NEEDS.md).

## For a human to judge

- The Colour tint against Lightroom's mask Colour swatch. Lumen's tint holds luminance
  and mixes chroma toward the swatch, like a Color blend mode. Lightroom's exact
  behaviour is my guess, not something I measured.
- Local tone is per-pixel and global tone is edge-aware (P7). On a real edit they look the
  same to me (ΔE mean ≤ 0.6), but the difference is by design.

## Evidence

- `evidence/01-wb-parity-gx85.png`: global Temp +20 mired / Tint −45 against local
  +40 / −30, before and after, with ΔE maps.
- `evidence/02-temp-parity-a7iv.png`: local Temp −100 against global, before and after.
- `evidence/03-feather-100pct-a7iv.png`: feather ramps at 100% for Exposure +1, Temp
  +100, Sat −100 and an amber tint at 50.
