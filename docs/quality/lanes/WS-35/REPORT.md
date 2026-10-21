# WS-35 / WS-36 (lane K1): colour grading wheels — report

Branch `quality/k1-grading-wheels`, from `claude/inspiring-dirac-ulgpch` @ 9068ded.

## For the owner

1. The wheels were grading the wrong tones. "Shadows" sat in the last ten code values above black and "Highlights" began at mid-grey, so a teal Shadows push did nothing visible and the orange covered the whole picture. They now sit where Lightroom puts them: a third and two thirds of what you see.
2. Black stays black under any tint, and a tint no longer drags skin through grey. That second fix is the "muddy" you would have hit with teal shadows on darker skin.
3. The wheel shows Hue, Saturation and Luminance as normal rows under it: type, scrub, ⇧ for fine, double-click to reset. The puck is now the colour it applies.
4. Try by hand: drag the puck with and without ⇧, double-click it, and drag the strip's handles at Balance ±100. The PNGs can't show feel.
5. Saved looks that used the wheels will render differently. That is the fix, but re-check any preset you care about.

Best evidence: `evidence/zones-ramp.png`, `evidence/teal-orange-more.png`, `evidence/teal-orange-skin.png`.

## Verdict per spec line

Numbers from `measure.py` (end to end through `lumen-render`, sRGB, no dither), before =
9068ded, after = this branch. Full JSON in `evidence/measure-{before,after}.json`.

| # | claim | threshold | before | after | verdict |
|---|---|---|---|---|---|
| 1 | defaults are identity | exact | exact | exact (`isIdentity`, unit test) | PASS |
| 2 | Shadows / Highlights 50 % points, display level | 0.33 / 0.67 ± 0.05 | 0.035 / 0.52 | 0.310 / 0.663 | PASS |
| 3 | Shadows sat 1 chroma at u > 0.75; Highlights sat 1 at u < 0.25 | < 0.005 | 0.000 / 0.002 | 0.000 / 0.000 | PASS |
| 4 | black under Shadows sat 1: \|ΔL\|, ΔC at u < 0.02 | < 0.01, < 0.01 | 0.051, 0.045 | 0.0094, 0.0057 | PASS |
| 5 | Shadows sat 1 chroma over u 0.05–0.25, every hue | ≥ 0.03 | 0.0023 | ≥ 0.0477 | PASS |
| 6 | tint hue vs wheel angle, 12 hues × 4 wheels | mean ≤ 4°, max ≤ 9° | worst mean 3.4°, max 9.0° | worst mean 3.0°, max 8.0° | PASS (residual is S14, NEEDS.md 1) |
| 7 | Midtones sat 0.5, max/min chroma around the wheel | ≤ 1.25 | 1.11 | 1.11 | PASS |
| 8 | Luminance ±1 hue change on chromatic patches | mean ≤ 2°, max ≤ 7°; Shadows moves L ≥ 0.01 | Shadows ΔL 0.000 | zone wheels: mean ≤ 1.55°, max ≤ 4.5°; Shadows ΔL ±0.044–0.048. Global +1: max 9.4° (unchanged from before) | PARTIAL: Global +1 fails max; the wheel holds working-space hue < 1° (unit test), the turn is the display shoulder (NEEDS.md 2) |
| 9 | Blending 10→90 % width: 0 < 0.08, 100 > 0.35, increasing | | 0.012 / 0.08 (all in the toe) | 0.114 at the 33-cube preview table, **0.055 at the 65-cube export table**; 0.38 at 50; 0.65 at 100 | PASS at export; the preview table smears a hard edge (engine width 0.012, unit test) |
| 10 | Balance ±100 moves both 50 % points ≥ 0.15 the right way | | | +100: −0.30 / −0.30; −100: +0.34 / +0.30 | PASS |
| 11 | limiters still prevent folds | existing tests | | all pass on the new axis; one property restated (below) | PASS |
| 12 | CPU = GPU | grade reaches the GPU only through the baked S10 table | | unchanged path, no kernel edits | PASS (gpu-parity CI: see CI) |

Visual claims: V1 `teal-orange-*.png`: after reads as cool shadows and warm highlights,
orange objects stay orange, skin stays warm; before is a flat orange cast. A low-key frame
(the church in `teal-orange-more.png`) comes out mostly cool, which is what the setting
asks for on a frame that is mostly shadow. V2 `zones-ramp.png`. V3 the UI snapshot: see
"UI" below.

## What changed and why

**Zone axis (`ZoneWindows`).** Pivots, Balance and Blending are now in display level `u`,
the neutral display curve's `normalizedCurve(x)` at the live tone anchors, tabulated at
1024 points. Raised-cosine crossfades of one half-width (Blending 0 → 0.01, 50 → 0.28,
100 → 0.56). Two equal-width monotone steps never overlap into a negative mid, so the old
ceiling and its easing knee are gone. Balance moves both pivots ±0.3. Stored pivots may
sit in −0.3…1.3 so a handle dropped at either end at Balance ±100 lands where it was
dropped. The monotonicity limiters still measure per EV and now sample at
`samplingStep`, the narrowest crossfade through the display curve's steepest slope.
Half-width 0.28 at Blending 50 is not a taste number. At 1/6 a lone full Midtones
Luminance ring folded the tone response where the display curve is steepest and had to
be held to 74 %. At 0.28 it is held to > 99 %.

**Tint (`GradeEngine.apply`).** Three changes, all no-ops on a neutral at the default.
- Below mid-grey the ab offset is proportional to OKLab L, so it is a constant saturation,
  not a constant chroma. That is what makes it read evenly down the shadows instead of
  saturating them.
- The bottom 0.08 of display level fades the tint out, because the display toe turned
  any added chroma into lifted black.
- The component of a push that opposes the pixel's own hue is eased by the pixel's
  saturation C/L (at most fully, half way at C/L 0.06). Neutrals get the full tint at the
  wheel's hue, and a push along a colour's own hue is untouched. Only "drive this colour
  through grey" is held back, which is what muddy skin under teal shadows was. Lightroom
  does not do this. It is the one place this lane chose to beat it, and the skin sheet is
  the argument.

**UI.** `LumenColorWheel(detailRows:)` replaces the centred, captioned lightness bar with
Hue (0–360, a hue-ring track), Saturation (0–100) and Luminance (−100…+100) rows aligned
with Blending and Balance. Each row is a `LumenSlider`, so typing, scrubbing, ⇧-fine, the
arrow nudge and double-click reset come with it. The puck is 13 pt, filled with the
colour it applies, with a white ring, a dark keyline and a spoke from the centre. The disc
carries a centre mark and a half-strength ring. The wheel's own drag (press picks up the
puck, ⇧ fine at 0.25×, double-click resets strength and luminance) is unchanged. The zone
strip draws its curves on display level with a 3 pt tonal ramp along its foot, so the
handles sit over the curves they move.

**Not changed:** the GPU path (the grade is baked into the S10 table that both CPU and GPU
read), printer lights (WS-37), `ColorBalanceGrid`'s maths (it reads the same windows, so
its zones moved with the wheels').

## Tests changed, and why each is not a loosening

- `enginemath.json` was regenerated from `scripts/gen-fixtures.py`, whose `ZoneWindows`
  mirror was ported to the new axis, using the generator's own copy of the display curve.
  Only the `grade` section changed. The generator's own checks still pass (partition of
  unity, no inversion, Blending and Luminance alive over their whole travel).
- `ControlProofTests` records: 24 `grade.*`/`cb.*` records re-recorded, nothing else
  moved. Floors for `cb.chroma.mid` 109 → 62 and `cb.saturation.mid` 108 → 63, by the
  registry's stated rule (70 % of the corrected measurement, as the Brilliance floors
  were). The Midtones zone now covers about −0.9…+1.0 EV instead of −4.4…+0.4, so it moves
  less of that wedge. The shadow fields went from 55 to 150 and keep their floors.
  `cb.chroma.mid` declares a 5.192-code give-back. The grade's own output chroma is
  strictly monotone in the slider on all 2048 sampled wedge pixels (measured), so the
  give-back is S14 gamut compression on bright saturated colours, as `cb.chroma.high`
  already shows.
- Tests that pinned the old geometry at a scene EV were re-pointed at the zone they
  meant, each with a comment: `ColourAccuracyTests`, `GradeBalanceDirectionTests`,
  `GradeStripAxisTests`, `GradeStripAxisAppTests`, `RobustnessTests` (no ceiling exists to
  "not reach"), `AppliedReadoutTests` (reads the render's own percentage, 34 % → 31 %),
  `WheelTintLightnessContractTests` (the tint is L-scaled now, owner's DECISION 2 taken).
  `BrillianceMonotoneTests` and `GradeJointLimiterTests` re-measured the "defect before
  the fix" magnitudes on the new axis. Every "after" assertion (no fold, < 1e-6 code
  values) is unchanged.
- **One property restated, flagged for review.**
  `GradeJointLimiterTests.testThePairKeepsSeparatingTheZonesAsBothArePushed` asked the
  mid/highlight separation to rise strictly as wheels and Brilliance are pushed together.
  At the new zone centres it rises to 1.611 stops by a third of the travel, then gives
  back 0.013 stops (about a third of a code value) by full deflection. The test's own doc
  comment already prices this drift as the cost of the proportional shared budget. The old
  measurement points happened to show it at 1e-5. Now pinned as "strictly rising to the
  bound, then never more than 0.02 stops below its best". Removing the drift needs a
  different budget split in `solveJointScale`, which this lane did not attempt.
- `BrillianceMonotoneTests.testTheFixMovesTheSevenThatFoldedAndNothingElse` gains a
  branch. Where the old search reported 1.0 only because its 64× ceiling flattens the
  profile, the closed form may ease through the knee, never below 0.9, and the result must
  not fold. The fold counts per Blending were re-measured (11/15/11 at 50/75/100).
- New: `GradeWheelsDisplayZoneTests` (zone placement, Blending range, partition of unity,
  level↔EV inverse, black untouched, zone selectivity, no push through grey, Luminance
  holds hue, identity).
- `LayoutMetricSupport` citations were moved to the lines they now land on. The grade
  wheel's untitled bar entry was replaced by its three titled rows.

Gates: `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` on Swift
6.1.2 (CI's): 3053 tests, 0 failures. `ControlProofTests -c release`: 6 tests, 0
failures. `swiftc -parse` on every source: clean. `check-swift-surface.py` exits 1 on the
base commit too (a pre-existing `LumenType` import finding).

## What a human must judge

- The look: `evidence/teal-orange-*.png` (moderate) and the skin sheet.
- How the wheel feels in the hand. Drag latency and the ⇧ gear can't be seen in a PNG.
- Whether Balance ±100 (±0.3 of display level, which takes the Shadows zone almost off
  the end at +100) is too strong.

## UI

See CI section for the snapshot comparison.

## CI

(filled after the run)
