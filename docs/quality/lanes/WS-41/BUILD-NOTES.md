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

## Round 2 (after VERIFY.md round 1 and SPEC Amendment A1)

This section supersedes the round-1 rows it names. Everything not named here was re-measured on the round-2 build and is unchanged.

### What changed

- **Feather 0 is anti-aliased along the gradient (line 29, VERIFY D4).**
  - The transition is never narrower than 2.5 output pixels measured along the local gradient of ρ. That gradient is the analytic derivative `DetailEngine.vignetteRadiusGradient`; the floor is applied by `vignetteEffectiveWidth`.
  - The previous rule used 2.5 px of the half-diagonal, which is 0.27 px on the short axis of a 6:1 crop.
  - The kernel computes the same derivative line for line.
  - At the default feather the width is still exactly 0.625, so identity holds.
- **Feather's low end is smooth (line 30).** The width is `0.535·(f/25)²` up to feather 25, replacing the square root. It is unchanged from 25 to 100, so the feather-25 width (0.535) that keeps the −4 EV ramp at 1 code per pixel is kept.
- **The Color Priority lift no longer clips (line 18, VERIFY D2).** The roll-off key is now `vignetteLiftKey`: luminance, raised toward the brightest sRGB channel for pixels below +0.8…+1.5 EV over mid-grey. A saturated red near the sRGB gamut wall gets less lift; a bright sky keeps the luminance key.
  - Chroma below the shoulder is held by 2^(−0.08·stops), so the display transform's chroma rise is not overshot.
  - The shoulder restoration is 2^(1.0·stops), faded in over +1.5…+4.5 EV of lifted luminance.
  - The kernel takes the sRGB rows and the new constants as arguments; it now has 26 arguments, all from `vignetteUniforms`.
- **New tools.**
  - `scripts/proof/ws41/edge.py`: the line-29 measurement.
  - `scripts/proof/ws41/huefloat.py` with `scripts/proof/ws41/probe/`: the verifier's float probe, kept so the Amendment A1 float measurements reproduce.
- **Tests.**
  - Added `VignetteGeometryTests`: `testFeatherZeroIsAntiAliasedAlongTheGradientOnEveryAspect` (rendered on 1:1, 3:2, 6:1 and 1:6), `testTheHardEdgeWidthIsConstantInPixelsAlongTheGradient` (analytic derivative against a numerical one, 4 roundness values × 3 aspects), and `testTheLowEndOfFeatherHasNoJump`.
  - Updated to the per-pixel width: the corner/profile checks in `VignetteResponseTests`, `VignetteCropFieldTests` and `VignetteFeatherTests`. The neutral CP=HP tolerance went to 1e-8 relative, because the hold now round-trips a neutral through OKLab.
  - `VignetteStyleParityTests` (macOS) gains a 6:1 crop at feather 0 for all styles, and CP at +2 for three roundness values, on that crop and the straightened one.
- **Evidence.**
  - Regenerated: the feather sweep, the feather-0 edge crop, both style sheets and the 2545 corner crop.
  - New: `after_feather0_6x1_crop_edge.png`.
  - The folder has 12 files, all under 400 KB.

### Per line (round 2)

| # | Status | Measured |
|---|---|---|
| 1-3 | PASS | identity 0/52, explicit 0/52, amount-zero 0 |
| 4-5 | PASS | unit tests green |
| 6-8 | PASS | r50 spread over feather 0.0019 / 0.0020 / 0.0015 (M25/50/75). w(50) 0.381, w(100) 0.609. Smallest step of 10 above feather 0: 0.0219 |
| 9 | PASS | 768 px: w_px 2.0, edge_px 1, aa_rms 0.015. 1536 px: 2.2, 1, 0.015 |
| 11-12 | PASS | unchanged: −100 0.949/0.949; 0 0.540/0.540; +100 circ 1.002, side 0.824, top 0.199 |
| 16 | PASS | WORST_REVERSAL 0: HP/CP × H{0, 100} × {−4, −1}; all styles at +2 |
| 17 (A1) | PASS | `huefloat.py line17`: 0 fails. Scene dh of CP and PO is 0.00° in every box. Float \|dh_CP\| ≤ \|dh_HP\| + 0.5° everywhere; worst excess green_BL −4, +0.75° vs +0.26°. cl: sky −2 is 1.155, within 0.02 of HP's 1.168; elsewhere inside 0.96–1.15 |
| 18 | PARTIAL | 8-bit, CP: clip255 0 % in every box at +1.5 and +2 (was 100 % on red_TL and skin_BR). C/C0 ≥ 0.85 (sky 0.85 / 0.89). dL ≥ 60 % of HP's (sky 61 % / 60 %, others 64–86 %). \|dh\| ≤ 3° in 13 of 14 box×amount cases. Remaining miss: skin_tones mid_BR +4.9° at +2 and +3.2° at +1.5 (HP +4.6° / +4.7°). In float that box is +3.65° at +2 (HP +3.36°) and +1.90° at +1.5 (HP +3.41°). It sits at L 0.87, near display white, where the display transform's path to white turns skin hue; HP misses too, and the 8-bit reading moves about ±3° per code on its C ≈ 0.06 |
| 19 (A1) | PASS | `huefloat.py line19`: 0 fails. PO vs lightness-matched HP′ is within 0.6° in every box (mid_BR +4.07° vs +4.01° at HP −2.20; tan_TR −9.14° vs −9.11°). sdL: PO 0.53 vs HP 0.66 at −2; 0.56 vs 0.77 at +1.5 |
| 21 | PASS | 42 cases: max step 1, reversal 0, dithered reversal 0.00; defaults flat 15/30 px |
| 22 | PASS | CROP_MAXDIFF 0.020 / 0.017 (crop, plain / m30 r60 f20), 0.020 / 0.017 (flip), 0.023 / 0.023 (1:1) |
| 25 | PASS | 3080 LumenCoreTests (parallel, ControlProofTests skipped): 0 failures after the two fixes listed above. `gen-fixtures.py --check` OK. Build clean. `check-swift-surface.py` reports the same findings as base |
| 29 | PASS | `edge.py`: w_min along the gradient 1.55 / 1.52 / 1.53 / 1.55 px (1:1 / 3:2 / 6:1 / 1:6); aa_rms 0.014 / 0.015 / 0.013 / 0.015 px. Before: 6:1 and 1:6 were 0.79 px |
| 30 | PASS | `profile.py` at feather 0…100 step 1: largest step over 0…10 is 0.0097, against a median over 10…100 of 0.0042 (2.32×, bar 3×). Before: 14× |
| 24, 27 | macOS CI | parity test extended; macOS files pass `swiftc -parse` |

Reproduce:
- line 29: `python3 scripts/proof/ws41/edge.py`
- lines 17-19 and scene: `python3 scripts/proof/ws41/huefloat.py line17|line18|line19|scene` (builds the probe into `/tmp/ws41-probe` on first use)
- line 18 in 8-bit: `corner.py --frame F --set look.vignette=A --set look.vignetteStyle=colorPriority`, against the same command without the style
