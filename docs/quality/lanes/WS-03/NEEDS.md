# WS-03 NEEDS: changes in functions WS-03 does not own

## 1. WS-02 — `WhiteBalanceEngine.neutralizing` should report the as-shot-aware tint

The magenta guard now depends on the as-shot neutral (SPEC note N2): `WhiteBalanceEngine.adaptation`
clamps the target tint with `ColorTemperature.clampedTint(kelvin:tint:asShot:)`. `neutralizing` still
reports `ColorTemperature.clampedTint(kelvin:tint:)`, the as-shot-free illuminant bound, which is never
tighter than the one the render applies.

Consequence: **no pixel difference** (every tint at or above the as-shot-aware bound renders the same, and
the reported value is ≥ that bound), but when a click lands past the picture bound the Tint row can show
a number above the one the render uses, and the panel's "bounded by physics" caption then appears on the
user's own click. Never observed on the SPEC 7 grid (all solutions are inside the bound; max error
0.002 mired / 0.005 tint).

Requested one-line change, last statement of `neutralizing`:

```swift
let kelvin = Num.clamp(bestK, ColorTemperature.minKelvin, ColorTemperature.maxKelvin)
return (kelvin,
        ColorTemperature.clampedTint(kelvin: kelvin, tint: Num.clamp(bestT, -300, 300),
                                     asShot: (shot.kelvin, shot.tint)))
```

## 2. WS-12/WS-13 (output gamut) and the D9 owner — line 6 at the ends of travel

With the tint axis now on the Robertson isotherm (SPEC line 4, matched exactly to the Adobe/CAT16 model),
a −150 tint is a strong *green* adaptation. Its CAT16 matrix has off-diagonal terms (R←G −0.27 in
Rec.2020) that carry saturated colours outside **sRGB**. The output encode then clamps R to 0, and the
clipping metric counts that as crush. Share of pixels with a negative sRGB channel: 983 tint −150
24.4 % (old model 1.1 %); 864 tint −150 22.6 % (3.7 %). Scene-linear Rec.2020 negatives are ~0 % on these
tiles. At 2000 K (N3) there are true Rec.2020 negatives as well (864: 18.6 %).

Options, none inside WS-03 without failing SPEC line 4. The numbers are in BUILD-NOTES, "Line 6".
- Compress the output gamut instead of clipping it, in the display transform or output encode.
- D9 decision: apply WB as a diagonal in working RGB. Greys stay exact (lines 3/7/9) and the matrix has
  no negative lobes, so 983 −150 drops to 2.5 % out-of-gamut. But line 4 then misses the Adobe/CAT16
  grey by 5.9° / C ratio 0.19, and non-neutral hues move 1.3–3.9° (mean) differently from CAT16.

## 3. WS-01 (LumenPipeline) — stale comment

`Sources/LumenPipeline/AppleRawSource.swift:46-50` says the as-shot numbers are "NOT `ColorTemperature`'s"
and quotes `ColorTemperature.chromaticity` at (0.32745, 0.33752). Since WS-03 they are the same
convention, and `ColorTemperature.chromaticity` reproduces Apple's chromaticity like `DNGTemperature`
does. Comment only; SPEC line 11 requires an empty pipeline diff from this lane.
