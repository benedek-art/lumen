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

## 2. WS-04 / WS-13 — CAT16 negative lobes at the ends of travel (SPEC line 6)

With the tint axis now on the Robertson isotherm (SPEC line 4, matched exactly to the Adobe/CAT16 model),
a −150 tint is a strong *green* adaptation. In Rec.2020 its CAT16 matrix has a −0.27 R←G lobe (as-shot
9365/+16.4: rows `[0.835, −0.273, −0.026] …`), so saturated blue/green pixels get a negative red channel
and the display clamps them to 0. The old axis was mostly blue↔yellow and only touched B, so it crushed
less. Same mechanism as SPEC note N3 at 2000 K. Measured worst tiles (shadows "any", pp): 983 tint −150
19.0 vs 0.7 before; 864 tint −150 16.7 vs 1.5; 864 temp 2000 K 38.0 vs 25.3. See BUILD-NOTES.md, line 6.

This is not fixable inside WS-03 without either breaking SPEC 3/4/7 (they are exact *because* WB is a
CAT16 von Kries step) or changing decision D9. Options for the owners of S6 / the display transform:
gamut-compress negative scene-linear channels after S6 instead of clamping, or decide (D9 owner) to apply
WB as a diagonal in working RGB (`diag(W·1)`), which gives identical greys, so SPEC 3/4/7/8 still pass,
and has no negative lobes.

## 3. WS-01 (LumenPipeline) — stale comment

`Sources/LumenPipeline/AppleRawSource.swift:46-50` says the as-shot numbers are "NOT `ColorTemperature`'s"
and quotes `ColorTemperature.chromaticity` at (0.32745, 0.33752). Since WS-03 they are the same
convention, and `ColorTemperature.chromaticity` reproduces Apple's chromaticity like `DNGTemperature`
does. Comment only; SPEC line 11 requires an empty pipeline diff from this lane.
