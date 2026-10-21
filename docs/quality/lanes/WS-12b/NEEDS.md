# T2 tone curves: changes needed outside this lane

## N1 (blocker, WS-01): run the curve as its own stage after the finish cube

The curve is baked into `RenderPlan.finishLUT` with picture formation (`RenderPlan.init`,
the `display` closure, ~line 338: `curve.apply(formed, white:, space:) / scale`). The cube's
LumenLog lattice puts about 11 nodes across visible tones at 33, so on grey_ramp the
rendered curve is off the drawn one by 9 codes (S-curve), 33 (steep), 101 (a dip) at the
preview size, and 1 / 19 / 81 at export. A steep curve turns a blue sky 244°→272° in the
preview while the exact curve holds 258°→253°. Preview and export differ by up to 37
codes. Evidence: `evidence/before-steep-curve-drawn-vs-applied.png`,
`before-sky-d850-steep-none-lut33-lut65.png`, `before-steep-curve-ramp-lut33-vs-65.png`.

The stage is ready in this lane: `CurveStage` (`Sources/LumenCore/Engine/CurveStage.swift`)
holds the five curves as 8192-sample 1-D tables, and `CurveStage.apply` runs
`CurveStack.run`, the same body as `CurveStack.apply`. Measured against the exact curve:
≤ 0.003 code on every audited curve, 0.19 on the steepest curve the editor can make
(`CurveStageTests`). What is needed:

1. `RenderPlan.init`: bake `display` WITHOUT the curve (drop `CurveStack` from the closure
   and from the finish key's `inputs`), and publish `plan.curveStage = CurveStage(CurveStack(develop.curve))`
   with its own key (the curve alone), so a curve drag no longer re-bakes the 33³/65³ cube
   either. `finishedColor` (~line 667) applies it the same way.
2. `ReferenceRenderer.render`: after the finish cube, `curveStage.apply(c, white: finishScale, space:)`
   on the formed, display-linear pixel; before the gamut flag, local curves and grain, i.e.
   exactly where the curve sits today inside the table.
3. `RenderGraph` (GPU): one Core Image kernel after `ColorCube.filter(plan.finishLUT…)` and
   the `finishScale` matrix. It needs the five tables as a 8192×5 float texture (one row per
   curve, identity rows for nil curves) sampled linearly at `x·(N−1)+0.5`, and the
   uniforms `preserveLuminance`, `masterBlack`, `lumaBlack`, the luminance weights and the
   encoded top. The arithmetic is `CurveStack.run`, line for line: encode sRGB, the master
   stage (ratio form, `liftedLuma` below the lift), the luma stage, the three channel
   lookups with the unit-slope extension above 1, decode. Skip the kernel when
   `curveStage.isIdentity`. `gpu-parity.yml` should then compare it with `CurveStage.apply`.
4. Soft proof: the proofed table (`finishLUTBeforeProof`) is derived from the unproofed one;
   the proof must move after the curve stage to keep its order (curve, then proof).

## N2 (major, WS-13 display transform / output encode): gamut-map after the curve

Preserve Luminance keeps saturation by scaling chroma with lightness (D10). On a
brightening curve that pushes colours that were inside sRGB out of it. They stay inside
Rec.2020, so the curve itself does nothing wrong, but the per-channel clamp at the sRGB
encode then turns their hue: orange +11°, hue wheel up to 19.8°, clipped-channel pixels
34% → 70% (`evidence/before-huewheel-brighten-clip-hue.png`). The display transform's gamut
boundary runs before the curve; the curve output needs the same hue-keeping compression
before the output clamp (or the curve stage of N1 placed before it).

## N3 (minor, scopes owner): the curve's histogram depends on the histogram panel

`AppState.scheduleScopeRefresh` and `measureScopes` return early unless `showHistogram ||
showScopes`, so pressing H to hide the histogram panel also removes the histogram behind
the tone curve. The curve editor should keep its backdrop whatever the panel's visibility.

## N4 (minor, WS-12b decision recorded for the integrator): RGB curves act on Rec.2020 channels

The R/G/B curves act on the working space's channels. A red lift is 1.65× stronger in
chroma than the same lift on sRGB red and lowers sRGB G by ~3 codes. The editor's R/G/B
backdrops are binned in sRGB primaries, so for saturated colours the backdrop is
approximate (neutrals are exact). Changing the curve's channel space is a picture change for
every existing recipe with an RGB curve and was not made here.
