# WS-41 Vignette: build notes (builder, round 1)

This is the builder's own measurement. It is not the verdict; the independent verifier gives that.

## What changed

- **Model** (`DetailEngine` vignette section).
  - ρ comes from the shared crop field and a roundness shape: a superellipse with n going 2 → 8 for −100…0, the crop-aspect ellipse at 0, and an ellipse relaxing to a pixel circle for 0…+100. ρ is 1 at the corners for every roundness.
  - The share delivered is `smoothstep(c − s/2, c + s/2, ρ)`.
    - c comes from Midpoint (0.25 / 0.6875 / 0.95).
    - s comes from Feather. At 0 it is a hard edge 2.5 px of the crop's half-diagonal wide. It follows a square root up to 0.535 at feather 25, is exactly 0.625 at 50, and reaches 1.0 at 100.
    - The profile is not renormalised beyond the corner.
  - At the defaults (50/50/0) the edges are exactly the historical 0.375 and 1.
- **Styles** (`vignetteStops`, `vignetteChromaScale`, `vignetteHoldColour`). All styles work at S13 in scene-linear.
  - **HP** keeps the legacy formula. Highlights adds `1 − (1−legacy)(1−H·knee(log2 Y))`, with the knee running from −0.5 to +2 EV around mid-grey, for Amount < 0 only.
  - **CP** uses HP's luminance stops for a burn. For a lift it applies all of Amount up to mid-grey, then rolls off to 25 % over 3 stops above it. Chroma is scaled about the OKLab lightness axis, so scene hue is held exactly:
    - burn: 2^(0.01·stops), which offsets the toe's C/L lift;
    - lift: 2^(0.4·stops), faded in by where the lifted pixel lands on the display shoulder.
  - **PO** is a log-space mix toward the black anchor (burn) or white anchor (lift). It lands mid-grey exactly where HP does and cuts corner contrast in stops by Amount/9 (burn) or Amount/5 (lift).
- **Crop on the CPU.** `VignetteField` (new, `LumenCore/Image/VignetteGeometry.swift`) is `geometryRects` in Doubles: the orientation, the usable frame, the crop, and `.integral`. `DetailEngine.vignette` and `RenderGraph.applyVignette` both build their coordinates from it. `ReferenceRenderer` passes `plan.recipe.develop.geometry`.
- **GPU.** `RG.applyVignette` passes `DetailEngine.vignetteUniforms` and the OKLab matrices to `lumenVignette`, which now takes 21 arguments, one branch per `vignetteStops` case, and keeps its dither. No constant is retyped.
- **Recipe.** `look.vignetteMidpoint`, `vignetteRoundness`, `vignetteHighlights`, and `vignetteStyle` (string-coded, unknown → HP). All are sparse-pruned, the plan carries them as `RenderPlan.vignette`, and they are wired into look blending, copy settings, the Effects dot and Reset, the search aliases and `lumen-render keys`. The cross-lane hunks are in `NEEDS.md`.
- **UI** (`EffectsPanel.vignetteSection`). Rows in this order: Style (`LumenMenuPicker`), Amount, Midpoint, Roundness, Feather, Highlights.
  - Highlights is disabled in Paint Overlay.
  - The Amount and Feather help no longer call Feather the strength control.
  - Reset and `isVignetteModified` cover all six fields.

## Tests

- **New**: `VignetteLegacyIdentityTests`, `VignetteRecipeTests`, `VignetteGeometryTests`, `VignetteToneTests`, `VignetteCropFieldTests` (LumenCoreTests); `VignetteStyleParityTests` (LumenPipelineTests, macOS).
- **Changed, per spec line 26**: these encoded "feather = size/strength".
  - `VignetteFeatherTests`: `testInnerRadiusIsMonotoneAndBounded`, `testFeatherShapesTheFalloffWithoutMovingItsEnds`.
  - `VignetteResponseTests`:
    - corner test restricted to c + s/2 ≤ 1;
    - falloff statistics, tooltip and flat-ends tests re-pinned;
    - `testFeatherMovesTheDeliveredStrengthTwelvefold` replaced by `testFeatherKeepsTheMidpointAndSetsTheWidth`.
  - `SliderEvidenceTests`, `LayoutMetricSupport`: registries updated.
  - `VignetteGeometryContractTests`: only the expected-falloff call changed.
- **Other edits** (additions and pins, with reasons in `NEEDS.md`):
  - `RecipeCodecToleranceTests` and `ResetSemanticsTests`: additions only.
  - `SavedLookTests`: fixture additions.
  - `SettingsSubsetTests`: field count.
  - `RawDenoiseRecipeTests`: the full-default-tree digest, which moves with `default-recipe.json`.
- **Unchanged and passing**: every KernelGolden vignette assertion, `CanonicalJSON*`, `testTheFingerprintOfUntouchedRecipesDoesNotMove`, `SliderContractTests`, and `EngineIntegrationTests`.

## Per spec line (measured on this container, Linux, CPU reference)

| # | Status | Measured |
|---|---|---|
| 1 | PASS | `identity.py`: 0 mismatches of 52 |
| 2 | PASS | `--explicit`: 0 of 52 |
| 3 | PASS | `--amount-zero`: 0 |
| 4 | PASS | `VignetteLegacyIdentityTests`: 64 Amounts × 3 sizes, Y 0.01…8, bitwise `==` (direct, via settings, via plan) |
| 5 | PASS | `VignetteRecipeTests` (a, b, c, e, f); `gen-fixtures.py --check` OK; `CanonicalJSONTests`, `CanonicalDefaultsBaselineTests` and `testTheFingerprintOfUntouchedRecipesDoesNotMove` pass unmodified |
| 6 | PASS | r50: 0.250 (m0), 0.687 (m50), 0.950 (m100); no reversal; min step 0.051 |
| 7 | PASS | r50 spread over feather 0…100: 0.0022 (m25), 0.0022 (m50), 0.0015 (m75) |
| 8 | PASS | w(50) 0.381, w(100) 0.609; min step above feather 0 is 0.0219 |
| 9 | PASS | 768 px: w_px 1.8, edge_px 2, aa_rms 0.013. 1536 px: 2.2, 2, 0.012 |
| 10 | PASS | Corner 1.005 at (m50, f50) and (m0, f0). At (m100, f100) 0.569, with frac(1) analytic 0.575 ≥ 0.5. Centre bitwise untouched (unit test) |
| 11 | PASS | −100: side/top 0.949/0.949, var 0.000. 0: 0.540/0.540. +100: circ 1.002, side 0.824, top 0.199. Corner 1.005 at all three |
| 12 | PASS | top_mid strictly decreasing from −100 to +100, min step 0.040 (negative side) and 0.059 (positive side); circ strictly decreasing over 0…+100; 1:1 Δ 0.000 |
| 13 | PASS | flat_grey corner, −4…+2 step 0.5: 10 15 20 30 41 53 73 95 118 145 169 189 207, min step 5 codes; CP − HP = 0; PO − HP = 0 codes |
| 14 | PASS | skytest −4, H100 (HP, and CP the same): snow ×0.98, white ×1.00, sky ×0.95. 6929 TL ×0.88. flat32 corner frac 0.892 (−3.57 EV). Y 0.09 keeps 100 % (unit) |
| 15 | PASS | (a) snow L 0.269 → 0.814 with min step 0.040, white min step 0.028, HP = CP. (b) max \|ΔL\| for H 0 → 1 is 0.007. (c) 0 hash mismatches |
| 16 | PASS | `tone.py` WORST_REVERSAL 0 for HP and CP × H{0, 50, 100} × {−4, −1}, all styles at +2, and PO at −4; `VignetteToneTests` monotone at 2000 levels (the D3 exemption only) |
| 17 | PARTIAL | cl within [0.91, 1.15] in every box (sky −4: HP 1.15 → CP 1.12). Corner L within 0.002 of HP. \|dh\| over the bar where HP is over it too (8-bit/DRT, see note): tan_TR −8.9° (HP −9.0) and dark_BL −4.1° (HP −4.1) at −2; 2545 TR +3.3° (HP +3.2) at −2; 983 TL +6.2° (HP +6.1) at −4. The HP+0.5° floor misses in two boxes that are inside the absolute bar: skin_BR at −4 is −2.4° (HP −1.3°), green at −2 is +1.1° (HP +0.4°) |
| 18 | PARTIAL | sky +2: C/C0 0.80 (HP 0.43), ΔL 62 % of HP's; sky +1.5: 0.86; 2545 TR 0.87 / 0.97. \|dh\| over 3° on skin_tones mid_BR (+3.8° at +2, HP +4.6°; +4.9° at +1.5, HP +4.7°) and on colour4 skin_BR at +2 (+3.5°, HP +2.8°). colour4 red_TL and skin_BR read clip255 100 % at +2 for HP and CP alike, and red_TL already does at +1.5: a lifted, saturated red at that lightness sits on the sRGB gamut boundary, so one channel is 255 by construction |
| 19 | PARTIAL | checker sdL: PO ×0.53 against HP ×0.66 at −2 (bar ≤ 0.58), PO ×0.56 against HP ×0.77 at +1.5 (bar ≤ 0.62); mean L within 0.01. Hue at −2: colour4 within ±0.5°, but skin_tones tan_TR −9.6° (HP −9.0°) and mid_BR +5.3° (HP +2.3°). PO is a pure scalar gain on scene RGB, so this is the display transform at a different L, not a hue the stage introduces |
| 20 | PASS | shadowsPct at −4, HP / CP / PO: 1569 5.340 / 5.247 / 0.991; 983 1.226 / 1.208 / 0.002; 2545 0.571 / 0.560 / 0.002 |
| 21 | PASS | 42 cases (3 styles × {−4, +2} × 7 variants): max undithered step 1, reversal 0, dithered local-mean reversal 0.00; defaults flat 15/30 px (before: 15/30) |
| 22 | PASS | CROP_MAXDIFF 0.020 (crop), 0.020 (flip), 0.023 (1:1), 0.020 (m30 r60 f20, with and without flip) |
| 23 | PASS | `VignetteCropFieldTests`: max \|Δρ\| ≤ 1e-9 for ±13°, ±90°, −7°, 0 × flipH and two more crops; the reference passes the plan's geometry |
| 24 | NOT RUN | macOS only. `VignetteStyleParityTests` written (3 styles × 2 shapes × {−3, +1.5}, feather 0, and field = `geometryRects` to 1e-9) for gpu-parity.yml |
| 25 | PASS | `swift build --target LumenCore --target LumenRender` clean. `swift test --parallel --filter LumenCoreTests --skip ControlProofTests`: 3077 tests, 0 failures. ControlProofTests (skipped by CI's engine lane, run in proof-linux) was NOT completed locally: in a debug build each of its tests ran over 55 minutes and was stopped. Its sweeps set Amount only, and line 1 shows those renders are byte-identical |
| 26 | PASS | `git diff --stat Tests/`: only the tests listed above changed; nothing skipped or loosened |
| 27 | PENDING CI | Rows and order as specified; `check-swift-surface.py` reports nothing new against base (identical findings); macOS files pass `swiftc -parse` |
| 28 | PASS | Tests for plan, look blend, copy settings and search pass; `lumen-render keys` lists the three keys with ranges; `--set look.vignetteStyle=paintOverlay` works |

**Note on hue (lines 17-19).** The hue errors come from the display transform and from 8-bit quantization of low-chroma patches (C 0.03-0.06). They do not come from the stage:
- With dither on, global Exposure −1…−4 alone wanders tan_TR's hue by ±6°.
- CP and PO hold OKLab hue exactly in scene-linear; the unit test holds it to 0.01°.
- Spec note 5 asks for the measured worst values, which are listed above.

## Reproduce

Build and set up:

```
export PATH=/opt/swift/usr/bin:$PATH
swift build -c release --product lumen-render
python3 scripts/proof/ws41/frames.py
S=scripts/proof/ws41
```

Lines 1-3: `python3 $S/identity.py`, then `python3 $S/identity.py --explicit` and `python3 $S/identity.py --amount-zero`.

Lines 6-12:
- `python3 $S/profile.py --key look.vignetteMidpoint --values 0,10,…,100`
- `python3 $S/profile.py --key look.vignetteFeather --values 0,…,100 --set look.vignetteMidpoint=M`
- `python3 $S/profile.py --key look.vignetteRoundness --values=-100,-80,…,100`

Other lines: `corner.py`, `tone.py`, `banding.py` and `crop.py` as in SPEC. The evidence sheets are `sheet.py` with the SPEC's commands, plus `after_2545_tr_corner_styles_crop.png`.

Unit tests:

```
swift test --parallel --filter LumenCoreTests --skip ControlProofTests
```

Swift 6.0.3 here cannot parse `CompareView.swift`'s trailing commas (CI uses 6.1.2). The local test runs had those two commas removed in the working tree only; the change is not committed.
