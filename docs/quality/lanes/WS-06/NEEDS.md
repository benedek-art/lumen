# WS-06 needs from other lanes

WS-06 owns `ToneEngine.contrastMapped`, the contrast constants above it, and the Contrast and
Pivot `LumenSlider` literals in `BasicPanel.toneRows`. These requests are for functions
outside that set. SPEC.md gives the numbers.

## N1. Contrast chroma coupling: WS-07 (S7 application), SPEC S20

**What and why.** Lightroom's Contrast raises saturation along with tonal contrast. The audit
measured +16% chroma at +50 and +29% at +100 with a hue-locked curve. Lumen's Contrast is a
single scalar gain per pixel, so OKLab C/L stays flat (−1.6% at +100), and +100 looks
darker and duller: whole-frame chroma falls 19% on 6929. WS-06 has decided on a milder
coupling than Lightroom's:

| Contrast | OKLab C/L target |
|---|---|
| +100 | +6…+15% |
| +50 | +3…+8% |
| −100 | −8…−20% |

Hue drift must stay within S18 (mean ≤ 0.75°, max ≤ 2.5°). This cannot be done inside
`contrastMapped`.

**Interface WS-06 will provide.** It is a pure function, placed next to `contrastMapped` in
WS-06's region and unit-tested there. WS-06 adds it only when WS-07 accepts this request.

```swift
/// Chroma factor Contrast asks for at zonal coordinate t (EV from mid-grey, the same
/// coordinate `stops(at:)` takes). Exactly 1 when contrast is 0, at and beyond both live
/// anchors, and wherever the curve's local log-slope is 1. Above 1 where the curve
/// steepens, below 1 where it flattens. Defined as
///     pow(contrastMapped'(t), contrastChromaExponent)
/// with the exponent a WS-06 constant, tuned so S20's band is met.
public func contrastChromaGain(at t: Double) -> Double
```

**What WS-07 is asked to do.**

1. Bake `contrastChromaGain` on the same shaper domain and at the same size as
   `bakeGainLUT`, for example as `RenderPlan.toneChromaLUT`. Skip it (nil) when
   `tone.contrast == 0`, so the identity stays byte-exact (S1, S2).
2. In `RR.applyTone` and `RG.applyTone`, plus the guided kernel or gain cube, look the factor
   up through the same guided mask as the gain. Apply it about the pixel's own
   working-space luminance:

   ```
   rgb' = gain · (Y + k · (rgb − Y))
   ```

   - Clamp k per pixel so that no channel goes below 0: k ≤ Y / (Y − min(rgb)) when
     min < Y.
   - Do this on CPU and GPU in the same commit.
3. Extend the tone key (`RP` 505-560) so that the new table is cached and invalidated
   together with the gain cube.

**How it will be verified.** `run_all.sh` lines S20 (`C2_sat_CL_pct_c±…`) report OPEN
until this lands, then PASS or FAIL. When it lands, S19 is retired. S19 pins C/L at ±3%,
which is today's ratio-preserving behaviour. S18 (hue) still applies.

**Alternative, if WS-07 declines.** WS-16's finish saturation pass could take the factor as
an extra scale, evaluated on the pre-tone luminance. That is worse, because it runs after
the display transform and cannot see the guided mask.

## N2. Pivot travel in the proof registry: WS-58, SPEC S21/S22

If the Pivot drag range narrows to −3…+3 EV (SPEC S22), change the `tone.contrastPivot`
`ControlSpec` (`low: -4, high: 4` in `Tests/LumenCoreTests/Proof/ProofRegistry.swift`) to
`-3…3`. Then re-record `records/tone.contrastPivot.json`.

- Authority at −3…+3, contrast 50, measured now: 84.09 against a floor of 20.
- `lumen-render keys` reads the range from this entry.

Recipe decoding is NOT asked to change. Stored pivots of ±4 must keep decoding and keep
rendering. The engine clamp in `contrastMapped` stays at ±4.

## N3. Nothing in the `toneRows` builder: WS-05

The change is confined to the two `LumenSlider(...)` literals: range, hardRange and
`help:` strings. No reordering, no new disclosure, no helper signature.
