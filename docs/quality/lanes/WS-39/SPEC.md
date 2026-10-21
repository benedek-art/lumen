# WS-39 Halation: acceptance spec

Derived from `AUDIT.md`. Measurements come from `measure.py` (renders through the release
`lumen-render`, `--no-dither`, Portra 400 unless stated) and from `HalationControlTests`.

```
swift build -c release --product lumen-render
python3 -I docs/quality/lanes/WS-39/measure.py OUTDIR --corpus      # M1-M11 numbers
swift test --filter LumenCoreTests.HalationControlTests              # unit lines
```

Synthetic frames written by `measure.py`: flat fields, and a disk (radius 1% of the long
edge) at a given level on a 0.01 field, rendered at 2400 px. "dR" is the added sRGB red
code against the same stock at Amount 0. `r2` is the farthest ring outside the disk whose
mean dR is at least 2 codes, as a percentage of the long edge.

## Measurable lines

| # | claim | threshold | measured by |
|---|---|---|---|
| M1 | Amount 0 is an exact identity, at any Size and Redness | byte-identical pixels | `testAmountIsALinearGain` |
| M2 | A flat field gets no halation (no cast, no fog), clipped or not | flat 0.18 / 0.9 / 1.0 / 4.0 at A100 S2 R0: max \|d\| <= 1 code; unit: <= 1e-5 relative at 0.05…16 | `measure.py` M2, `testAFlatFieldGetsNoHalationAtAnyLevel` |
| M3 | Midtones never feed the glow | disks at 0.18 and 0.25 (clip −2 EV) on 0.01, A100 S2: max dR outside <= 1 code; energy exactly 0 at <= 0.25 | `measure.py` M3, `testNothingTwoStopsUnderTheClipFeedsTheGlow` |
| M4 | A clipped light source glows, visibly and well beyond an outline | clipped disk: default r2 >= 1.0%, A100 r2 >= 1.5%, A100 S2 R80 r2 >= 2.5%; clipped energy >= 3× a diffuse 0.8 white; energy monotone in exposure | `measure.py` M4, `testAClippedSampleOutGlowsADiffuseWhite` |
| M5 | Colour: red-orange at the source, redder further out, never green or blue dominant | layer-space G/R at ring 40 < 0.6 × G/R at ring 1; G/R near >= 0.15; R >= G >= B on every ring; neutral stock (Tri-X) R = G = B | `testTheHaloIsOrangeNearTheSourceAndRedderFurtherOut` |
| M6 | Size scales with resolution (same fraction of the frame) | 10%-of-peak reach at 1200 vs 3600 px within 15%; `measure.py` r2% at 800 vs 2400 within 0.5 points | `testTheHaloScalesWithTheRender`, `measure.py` M6 |
| M7 | Size is meaningful and monotone | r2(S2) / r2(S0.5) between 2.5 and 5; r2(0.5) < r2(1) < r2(2) | `measure.py` M7 |
| M8 | Redness is meaningful and monotone | display G/R near the source strictly decreasing over Redness 0, 50, 100 | `measure.py` M8 |
| M9 | Amount is linear, no dead range | glow(A50) = 0.5 glow(A100) (unit, 1e-5); each 25-step adds 20–30% of the A100 ring sum | `testAmountIsALinearGain`, `measure.py` M9 |
| M10 | Stock defaults are ordered believably | Velvia 0 < Ektar < Portra < Gold; cine250D (Vision3, rem-jet) <= Ektar; Tri-X neutral | `measure.py` M10 |
| M11 | Real frames: no cast on ordinary bright surfaces | A100 mean dR in the audit's six flat regions (983 snow, 983 chart white, 2545 lawn, 2545 sky, 3582 wall, 6929 wall) <= 1.0 code each | `measure.py --corpus` M11 |
| M12 | GPU computes the CPU's formula | `RG.applyHalation` + `lumenHalationEnergy` term-for-term equal to `RR.applyHalation` + `HalationProfile` (verifier reads both); macOS `KernelGoldenTests` halation goldens green in CI | code review + CI |

Before numbers (base `9068ded`): M2 4 / 5 / 4 / 2 codes; M3 4 and 8 codes; M4 r2 default
0.42%, A100 0.50%, A100 S2 R80 1.04%; M5 G/R near 0.047 vs far 0.23 (redder at the
source: inverted); M7 r2 0.25 / 0.5 / 1.0%; M10 cine250D 0.077 > Portra 0.052;
M11 dR +2.5 / +7.0 / +5.9 / +4.9 / +5.5 / +4.1 codes.

## Visual lines (judged from named sheets in `evidence/`)

- V1 `1192` stained glass, Portra A0 / A35 / A100: the brightest glass (the gold halo)
  bleeds warm into the lead lines and the dark wall; the wall and the blue glass do not
  turn pink.
- V2 `983` snow and lantern, A0 / A100: snow, sky and chart whites keep their colour;
  only near-clipped edges against dark get a warm fringe.
- V3 clipped disk, A0 / A35 / A100 / A100 S2 R80: orange core grading to a red tail; the
  last reads as a CineStill-like red bloom, the default as a subtle warm glow.
