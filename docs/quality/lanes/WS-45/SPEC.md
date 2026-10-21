# WS-45 / WS-46 acceptance spec: linear and radial gradients (lane M3)

Owner's complaint: masks are "slow, glitchy… horrific". Bar: Lightroom Classic's Linear
and Radial Gradient, or better. Units: view points (pt) for handles, source pixels (px)
for rasters. `swift test --filter <Test>` runs on Linux unless marked (macOS CI).

## Measurable

| # | Claim | Threshold | Measured by |
|---|---|---|---|
| S1 | A drawn linear gradient applies its FULL effect where the drag started (Lightroom's convention) and none where it ended | alpha at press pixel ≥ 0.999, at release pixel ≤ 0.001 | `GradientLaneTests.testDrawnGradientIsFullWhereTheDragStarted` |
| S2 | Linear has three lines: the centre line (away from the pin) rotates, the pin moves, each outer line feathers, the strip between moves | grab table over a 500 pt gradient: centre line ±11 pt → `.rotate`; pin ±11 pt → `.move`; outer lines ±11 pt → `.startBand`/`.endBand`; rest of strip → `.move` | `GradientLaneTests.testThreeLineGrammar` |
| S3 | Dragging an outer line feathers SYMMETRICALLY about the centre line (centre fixed), ⌥ moves that line alone | midpoint moves < 1e-9 pt; span changes by exactly 2× the slide; ⌥: far line moves < 1e-9 pt; span never below 11 pt | `GradientLaneTests.testOuterLineFeathersAboutTheCentre` |
| S4 | A short gradient (< 66 pt, where the centre line is not offered) still has a move target across its whole strip, and its centre line does not swallow it | existing `testShortGradientKeepsAMoveTarget` passes unchanged | MaskHandlesTests |
| S5 | A radial is drawn from its centre by default (Lightroom), ⌥ draws corner to corner | centre = press within 1e-9; radii = |drag| per axis | `GradientLaneTests.testRadialDrawsFromItsCentre` |
| S6 | Radial at Feather 0 is anti-aliased, not a stair-step, and stays hard in EVERY direction | partial pixels (0.02…0.98) ≥ 0.5 × rim perimeter in px (a hard step has 0); on a 1000 × 20 px ellipse the ramp at each end of BOTH axes is ≤ 3 px | `GradientLaneTests.testFeatherZeroRadialIsAntialiased`; GPU uses the same `rin` (MaskGPU) |
| S7 | A linear gradient shorter than 1.5 px is a 1.5 px anti-aliased edge, not a hard step | ≥ 1 intermediate sample across the edge | `GradientLaneTests.testSubPixelLinearIsOnePixelRamp` (CPU) + same widening in `maskLinearSource` |
| S8 | Alignment: on a 3:2 frame with the axis at 30°, the rendered alpha is 0 / 0.5 / 1 exactly on the start / centre / end lines the handles draw | |alpha − expected| ≤ 0.01 at the pixel nearest each line, along 5 points of each line | `GradientLaneTests.testLinearAlphaSitsOnItsThreeLines` |
| S9 | Alignment: radial rim and inner ring where the handles draw them, rotated 30° on 3:2 | alpha ≤ 0.01 just outside the rim (+1.5 px), ≥ 0.99 just inside the ring (−1.5 px) on 32 rays | `GradientLaneTests.testRadialAlphaSitsOnItsDrawnRimAndRing` |
| S10 | Source↔display mapping is a similarity under a rotated crop, so lines drawn perpendicular on screen are perpendicular in pixels (the rasterizer's frame) | round trip < 1e-9; angle between mapped perpendicular vectors 90° ± 0.01° | `GradientDisplayMappingTests` (LumenPipelineTests, macOS CI) |
| S11 | The drawn ellipse is the rendered ellipse at every zoom | polyline sagitta ≤ 0.25 pt for any on-screen radius up to 20 000 pt | `GradientLaneTests.testEllipseStepsKeepTheOutlineWithinAQuarterPoint` |
| S12 | Falloff is monotone and C1: no visible band edge | max |Δcode| per px ≤ ceil(total/span·1.5)+1; monotone; on flat grey −2/+2 EV linear and radial F25/50/100 | auditor profile (audit/AUDIT.md) |
| S13 | Perceptually even: the 50 % L* point of a ±2 EV gradient lies within 8 % of span from the centre line | |t50 − 0.5| ≤ 0.08 | auditor profile |
| S14 | No banding in 8-bit sky gradients with the shipped dither (983, 1840 at −1.5 EV) | longest constant-code run in the masked sky ≤ 1.5× the same crop unmasked | auditor banding |

## Visual (human-judged)

- V1 `window-1512x982-masking-linear.png` (new snapshot): three lines across the photo, clipped to it, pin on the centre line, no axis stub.
- V2 `window-1512x982-masking-overlay.png`: the unselected Sky gradient draws a faint centre line across the photo instead of the stray vertical axis segment the baseline shows.
- V3 `evidence/radial-feather0-before-after.png`: the Feather 0 edge is clean. (Feather 50/100 are untouched by this lane: the per-pixel floor only binds when the feather ramp is under 1.5 px; their profiles are `audit/falloff_profiles_Lstar.png`.)
