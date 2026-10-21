# WS-35 / WS-36 (lane K1): colour grading wheels — acceptance spec

Written after the audit, before any code change. Every measurable line names its command.
`M` = `python3 docs/quality/lanes/WS-35/measure.py out.json` (end-to-end through
`lumen-render`, sRGB output, no dither, `corpus/synthetic/grey_ramp.lfi` and
`colorchecker.lfi`). "Display level" `u` = the sRGB-encoded output value of the ungraded
ramp (0 = display black, 1 = display white), which is what a photographer means by
"shadows" and what Lightroom's zones are defined on.

## Audit (before, base commit 9068ded)

| measure | before | Lightroom / target |
|---|---|---|
| Shadows zone 50 % point (Blending 50, Balance 0), display level | **0.035** | ≈ 0.33 |
| Highlights zone 50 % point | 0.52 | ≈ 0.67 |
| Shadows sat 1 tint chroma over the visible shadows (u 0.05–0.25) | **0.0025** (invisible) | clearly visible |
| Shadows sat 1 at display black (u < 0.02): ΔL / ΔC | **+0.051 / 0.045** (lifts and colours black) | black stays black |
| Shadows Luminance ±1 on the colour checker | 0.000 (does nothing) | moves the dark patches |
| Tint hue error vs wheel angle, mid zone, 12 hues | mean 2.8°, max 7.5° | a few degrees |

Root cause: the zone axis is scene EV normalised over the tone anchors (−9…+5 EV), but
the display curve maps the bottom 40 % of that axis into the toe, so pivots at 0.33/0.67
put "Shadows" at sRGB code ≈ 10 and "Highlights" from mid-grey up. And a constant OKLab
ab offset has unbounded relative chroma as L → 0, so the little the Shadows wheel did,
it did to black.

## Measurable lines

1. **Identity.** All wheels at default → output byte-identical to no grade
   (`GradeEngine.isIdentity`; existing tests stay green).
2. **Zone placement.** Blending 50, Balance 0: Shadows 50 % point at u = 0.33 ± 0.05,
   Highlights 50 % point at u = 0.67 ± 0.05 (M `zones_bl50_ba0`).
3. **Selectivity.** Shadows sat 1: tint chroma at u > 0.75 < 0.005. Highlights sat 1:
   tint chroma at u < 0.25 < 0.005 (M).
4. **Black stays black.** Shadows sat 1: at u < 0.02, |ΔL| < 0.01 and ΔC < 0.01 (M).
5. **The Shadows wheel works.** Shadows sat 1 tint chroma over u 0.05–0.25 ≥ 0.03 (M
   `hue_accuracy_sat1.shadows.chroma`, every hue).
6. **Hue accuracy.** Full saturation, 12 hues, each of Shadows/Midtones/Highlights/Global:
   mean |output tint hue − wheel angle| ≤ 4°, max ≤ 9° (M `hue_accuracy_sat1`).
7. **Even saturation.** Midtones sat 0.5, 12 hues: max/min tint chroma ≤ 1.25
   (M `mid_sat05_maxOverMin`).
8. **Luminance does not turn hue.** Every wheel's Luminance ±1 on the colour checker,
   chromatic patches: mean hue change ≤ 2°, max ≤ 7° (M `lum_hue_shift`); Shadows ±1 moves
   the patches' mean L by ≥ 0.01 (it currently does nothing).
9. **Blending.** Balance 0: the Shadows 10→90 % transition width (in u) at Blending 0 <
   0.08, at Blending 100 > 0.35, and strictly increasing 0 → 50 → 100 (M).
10. **Balance.** Blending 50: Balance +100 moves both 50 % points down by ≥ 0.15 u,
    −100 up by ≥ 0.15 u (Lightroom's direction: + favours Highlights) (M).
11. **No fold.** The existing monotonicity limiters (`GradeLuminanceInversionTests`,
    `GradeJointLimiterTests`, `BrillianceMonotoneTests`) pass on the new axis.
12. **CPU = GPU.** The grade is still only `GradeEngine.apply` baked into the S10 table,
    so the GPU reads the same function (no kernel change; `gpu-parity.yml` green).

## Visual claims (human judges)

- V1 `evidence/teal-orange-6929.png`, `-2545.png`, `-skin.png`: the classic look
  (Shadows 205°/0.45, Highlights 55°/0.35, Midtones 60°/0.08) reads as cool shadows and
  warm highlights with clean skin, not as an orange cast over the whole frame and not
  muddy.
- V2 `evidence/zones-strip.png`: the zone strip's three curves sit on the display level a
  photographer sees, with handles at about a third and two thirds.
- V3 the UI snapshot `panel-grade-grading.png`: the wheel shows its hue and strength as
  numbers, the puck is legible, the luminance bar no longer floats in an odd box.
