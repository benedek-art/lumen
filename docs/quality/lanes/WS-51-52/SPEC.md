# WS-51 / WS-52 acceptance spec: local light, white balance and colour

Contract: an adjustment inside a mask behaves like its global counterpart, scaled by the
mask alpha. Measured on the reference renderer (CPU definition; the GPU `LocalPlan`
calls the same `LocalWhiteBalance.resolve`, `applyColorTint`, `ColorEngine` and
`GradeEngine`, so it inherits every line below).

Commands (from the repo root, after `swift build -c release --product lumen-render`):

```
H=docs/quality/lanes/WS-51-52/measure.py
BIN=.build/release/lumen-render python3 $H suite   corpus/lfi/<id>.lfi                    # P-lines
BIN=.build/release/lumen-render python3 $H suite   corpus/lfi/<id>.lfi --global-temp 6200 15
BIN=.build/release/lumen-render python3 $H feather corpus/lfi/<id>.lfi FULL '<local-set>'  # F-lines
swift test --filter "LocalGlobalParityTests|MaskWhiteBalanceTests"                     # U-lines
```

`suite` renders the global control and the same control inside a full-frame radial mask
(radii 5, feather 0) and reports CIEDE2000 between the two 8-bit sRGB outputs (no dither,
long edge 768). One 8-bit code step is worth ΔE 0.3-0.9, so "max < 1" means "identical
up to one rounding step". Corpus set: 6929 (A7 IV), 2545 (GX85), 1192 (X-T10), 3914
(X-T4), 1346 (5D), 1840 (D850), each at its sidecar as-shot neutral; 6929 and 2545 again
with the global row moved to 6200 K / +15. Every case first checks the global control
moved the picture (ΔE global vs untouched > 0.5 mean), otherwise parity is vacuous.

Local slider meaning: local Temp ±100 = ±50 mired from the balanced neutral, local Tint
±100 = ±150 global Tint units from the balanced tint. Kelvin mode is absolute.

## Parity (full-frame mask = global control)

| # | claim | threshold |
|---|---|---|
| P1 | Exposure +1 and −1.5 | ΔE max < 0.5 on all 8 runs |
| P2 | Temp ±100, Tint +100 / −60, Temp+40 Tint−30, at as-shot AND with global 6200 K | ΔE mean < 0.05, p95 < 0.5, max < 1.0 |
| P3 | Kelvin 3800 (absolute spelling) | ΔE max < 0.5 |
| P4 | Saturation +50 / −100, Vibrance +60 | ΔE max < 0.5 |
| P5 | Point Colour swatch (same swatch globally and locally) | ΔE max < 0.5 |
| P6 | Grading wheels (local wheels = global wheels) | ΔE mean < 0.5, p95 < 1.0 |
| P7 | Contrast +50, Highlights −80, Shadows +80, Whites +50, Blacks −50 | ΔE mean < 1.0, p95 < 2.0 (see note) |
| P8 | Every local slider at default, full mask and feathered radial | output bit-identical to no mask |

P7 note: global tone (S7) evaluates its gain on an edge-aware guided luminance, the local
tone stage per pixel. That difference is by design of the stage order (the local stage
runs after S9/S10 on the GPU as a 3D table, which cannot hold a spatial filter), so the
bar here is "visually the same edit", not ΔE 0.

## Feather and partial alpha (radial r 0.3, feather 60, on 6929 and 2545)

`feather` compares the feathered render with the full-mask render of the same local set.

| # | claim | threshold |
|---|---|---|
| F1 | No halo: L* of the feathered render never leaves [untouched, full] | p99.9 ≤ 1.0 L* for exposure ±, temp, tint, sat ±, vibrance, hue +60, contrast, shadows, amber tint 50 |
| F2 | Partial alpha is smooth: median fraction of the full move, binned by radius, is non-increasing outward | `monotone: true` for every F1 case |
| F3 | No colour ring: chroma never dips below both sides | C* dip p99 < 2.0 for every F1 case (hue +180 is reported, not gated: see REPORT) |
| F4 | Strong tints: teal (sRGB 0,.5,.5) and blue (sRGB 0,0,1) at Strength 100 | L* p99.9 ≤ 1.0 |

## Unit tests (Tests/LumenCoreTests)

| # | claim | test |
|---|---|---|
| U1 | Relative Temp/Tint composed with S6 equals the one global adaptation to the shifted neutral, three as-shot/global pairs, 1e-9 | `MaskWhiteBalanceTests.testARelativeShiftInsideAFullMaskIsTheGlobalRowAtTheShiftedNeutral` |
| U2 | Shift and Kelvin spellings render the same matrix at amount 0, 0.3, 1 and convert both ways exactly (the panel switch moves no pixel) | `MaskWhiteBalanceTests.testTheShiftAndKelvinSpellingsAreOneEditAtEveryAmount` |
| U3 | End to end through `ReferenceRenderer.render`, as-shot 4711 K / +6: Exposure, Temp/Tint (as-shot and global 6200 K), Kelvin, Saturation, Vibrance in a full mask = global, < 2e-5 display-linear | `LocalGlobalParityTests` |

## Visual claims

- V1 `evidence/03-feather-100pct-a7iv.png`: four feather ramps at 100%, no visible ring,
  edge or step; the transition reads as one gradual blend.
- V2 `evidence/01-wb-parity-gx85.png`, `02-temp-parity-a7iv.png`: the "after" ΔE map is
  flat at zero; the "before" map shows the full-frame offset the old anchor produced.
- V3 (human): the local Colour tint against Lightroom's mask Colour swatch on a real edit.
