# WS-41 Vignette: acceptance spec

Source: `AUDIT.md` (F1-F10), lane-lead decisions D1-D9. The feature is Lightroom's post-crop vignette: Style, Amount, Midpoint, Roundness, Feather, Highlights, laid out on the crop. "Before" is today's code on branch `quality/ws-41-vignette`, measured on this container. Numbers marked **DT** are design targets: there are no LR reference exports (`corpus/lightroom/` is absent), so they are what a photographer would accept and why is given.

## Setup (builder and verifier)

```
export PATH=/opt/swift/usr/bin:$PATH
swift build -c release --product lumen-render
python3 scripts/proof/ws41/frames.py            # flat32, skytest, colour4, checker -> $WS41_OUT/frames (default /tmp/ws41)
S=scripts/proof/ws41                            # all scripts: python3 + numpy + PIL, read lumen-render PNG/metrics
```

Each script prints its own definitions (`--help` / module docstring). `profile.py`, `crop.py` and `tone.py` work in fractions of Amount and in EV. They invert the output code through `lib.calibration()`, which reads a 0.18·2^ev ramp rendered by the default pipeline. `profile.py --selftest` proves the inversion: today's r50 measures 0.6875 against the analytic 0.6875, and w 0.381 against 0.380. Unless stated otherwise, every measurement is undithered.

Glossary:
- **r** is measured in half-diagonal units. The diagonal runs from centre to corner, where r is the same for every roundness.
- **r50** is where 50 % of Amount lands. **w** is r90 − r10.
- **side_mid** is the middle of the left/right edges. **top_mid** is the middle of the top/bottom edges.
- **frac** is the fraction of Amount delivered at a pixel.
- **cl** is (C/L)/(C0/L0) in OKLab of the displayed sRGB output. **dh** is the change in OKLab hue.
- **HP**, **CP** and **PO** are the three styles: Highlight Priority, Color Priority and Paint Overlay.

## Model (normative)

- **Profile.** `frac(r) = smoothstep(c − s/2, c + s/2, ρ(x,y))`.
  - Centre `c = r50(midpoint)`, width `s = s(feather)`.
  - ρ is the roundness-dependent radius. It equals today's `sqrt((u²+v²)/2)` at roundness 0 and is 1 at the four crop corners for every roundness.
  - At (midpoint 50, feather 50, roundness 0): c = 0.6875 and s = 0.625. That is exactly today's `smoothstep(0.375, 1, r)`.
  - Feather 0 is a hard edge, anti-aliased over about 1-2 output pixels. The width therefore depends on the pixel size, so the CPU function receives the frame's pixel dimensions.
- **Beyond the corner.** When `c + s/2 > 1`, the profile is NOT renormalised. The corner receives `Amount · frac(1)`.
  - frac(1) is ≥ 0.5 because r50 ≤ 1, and it is continuous and non-increasing in midpoint and feather.
  - Renormalising would move r50 with feather, which D4 forbids.
- **Shared code.** There is one LumenCore function for the coordinate field, (geometry, source size) → ρ per source pixel, built on `CropGeometry.resolve` with flipH and angle. There is one LumenCore profile function and one per-style transfer function. The CPU `DetailEngine.vignette` calls them, and `RG.applyVignette` derives every uniform it passes to the kernel from them. No constant is restated on the GPU side.
- **Highlights.** Protection `p(Y, H)` multiplies the burn exponent as today (`stops = a·frac·(1−p)`).
  - It is nondecreasing in Y and H, and acts only for a < 0 in HP and CP.
  - At H = 0 it is exactly the legacy `0.5·smoothstep(2.88, 5.76, Y)`, for every Amount.
  - For H > 0 it must contain the legacy term so that it is continuous at H = 0. For example `1 − (1−legacy)(1−new)`.
- **Recipe.** `look.vignetteMidpoint` (0…100, default 50), `look.vignetteRoundness` (−100…100, 0), `look.vignetteHighlights` (0…100, 0), and `look.vignetteStyle` (`"highlightPriority"`, the default, `"colorPriority"` or `"paintOverlay"`).
  - All four are non-optional, decoded with `decodeIfPresent ?? default`. An unknown style string decodes to `highlightPriority`.
  - No `pipelineVersion` bump.

## Measurable lines

Fill in the "after" column in REPORT.md. A sweep means `profile.py --key K --values …` with `--amount -2` on flat32 (3:2) unless stated.

| # | Claim | Threshold | Command | Before |
|---|---|---|---|---|
| 1 | **Legacy identity.** Recipes with no new keys render byte-identically. Covers 7 frames × Amounts {−4, −2.5, −1, −0.37, 0.6, 2, 0} at feather 50, plus 3 legacy sidecars via `--recipe` | 0 mismatches of 52 (pixel SHA-256) | `python3 $S/identity.py` | 0/52 (recorded in `identity_before.json` on this container; if the verifier's machine differs, re-record on the base commit first) |
| 2 | **Explicit defaults are identity.** Same 52 cases with `vignetteMidpoint=50, Roundness=0, Highlights=0, Style=highlightPriority` set explicitly | 0 mismatches | `python3 $S/identity.py --explicit` | fails today (keys absent) |
| 3 | **Amount 0 is identity for every combination.** Includes midpoint 0/100, feather 0/100, roundness ±100, highlights 100 and each style | 0 mismatches on skin_tones, 6929 | `python3 $S/identity.py --amount-zero` | fails today (keys absent) |
| 4 | **CPU unit identity.** A frozen copy of today's `DetailEngine.vignette` lives in the test file and is compared against the new function at random Amounts in [−4, 2] (≥ 50 draws, including the clamp ends and ±1e-3), feather 50, other fields default, on a frame with Y from 0.01 to 8 including Y > 2.88 | every pixel `==` (bitwise) | `swift test --filter VignetteLegacyIdentityTests` (new) | n/a |
| 5 | **Decode and canonical form.** (a) `{"look":{"vignette":-1.3}}` and the feather-only sidecar decode to the four defaults. (b) `canonicalRecipeJSON(Recipe()) == {"pipelineVersion":N}`, unchanged, because the new keys are sparse-pruned at their defaults. (c) The fingerprint of every existing recipe is unchanged. (d) `default-recipe.json` gains exactly 4 keys, regenerated through `scripts/gen-fixtures.py` (DEFAULT_RECIPE) so that `python3 scripts/gen-fixtures.py --check` passes. (e) An unknown style string decodes to HP. (f) Each non-default value round-trips | all hold; `CanonicalJSONTests`, `CanonicalDefaultsBaselineTests`, `VignetteFeatherTests.testTheFingerprintOfUntouchedRecipesDoesNotMove` pass unmodified | `swift test --filter 'CanonicalJSON\|VignetteRecipeTests\|VignetteFeatherTests'`; `python3 scripts/gen-fixtures.py --check` | n/a |
| 6 | **Midpoint sets r50 (feather 50, roundness 0).** r50(50) is today's value. r50(0) ≤ 0.30 and 0.90 ≤ r50(100) ≤ 1.00 (**DT**: 0 reaches about the middle third of the frame, 100 confines the effect to the corners, and the corner always gets ≥ half). Strictly increasing | r50(50) = 0.6875 ± 0.005; worst reversal 0; every step of 10 moves r50 ≥ 0.02 | `profile.py --key look.vignetteMidpoint --values 0,10,…,100` | r50 fixed at 0.687 (no key) |
| 7 | **Feather does not move r50.** At midpoint 25, 50 and 75, the spread of r50 across feather 0…100 (step 10) is small | ≤ 0.02 | `profile.py --key look.vignetteFeather --values 0,10,…,100 --set look.vignetteMidpoint=M` | 0.373 (r50 goes 0.875→0.502 over feather) |
| 8 | **Feather sets the width (midpoint 50).** w(50) is today's value. w(100) ≥ 0.60 (**DT**: at least today's widest). Strictly increasing, and every step of 10 adds ≥ 0.02 (above feather 0) | w(50) = 0.381 ± 0.006 | same sweep at midpoint 50 | w 0.153…0.609, but coupled to r50 (F1) |
| 9 | **Feather 0 is a hard, anti-aliased edge.** At midpoint 50 on flat32 at 768 px and at 1536 px. The stair-step statistic of an aliased edge is 0.27 and of a 4×-supersampled edge 0.07 (synthetic check) | w_px ≤ 3; 1 ≤ edge_px ≤ 3; aa_rms ≤ 0.15 px | `profile.py --set look.vignetteFeather=0 [--long-edge 1536]` | w_px 70.5, edge_px 0 (not hard) |
| 10 | **Corner gets the Amount.** corner = 1 whenever c + s/2 ≤ 1. When it is larger, corner = frac(1) per the model: ≥ 0.5, continuous and non-increasing in midpoint and feather. Unit test on the analytic function plus a rendered check at (m50, f50), (m100, f100) and (m0, f0). Centre untouched whenever c − s/2 > 0 | corner 1.00 ± 0.015 rendered (1e-9 analytic); centre bitwise untouched | `profile.py …`; `swift test --filter VignetteGeometryTests` (new) | 1.005 at every feather |
| 11 | **Roundness shapes the vignette (m50, f50, 3:2).** −100 (rounded rectangle): side_mid and top_mid ≥ 0.80, top_var and side_var ≤ 0.10. 0: side_mid = top_mid = today. +100 (circle in pixels): circ ≤ 1.02, side_mid ≥ 0.75, top_mid ≤ 0.25. Corner 1.00 ± 0.015 at all three. **DT**: −100 numbers assume a superellipse exponent ≥ 4 | as listed; ρ0 side_mid 0.540 ± 0.01 | `profile.py --key look.vignetteRoundness --values -100,0,100` | only ρ0 exists: 0.540/0.540, circ 1.273, top_var 0.261 |
| 12 | **Roundness is monotone and has no dead travel on 3:2.** top_mid strictly decreases from −100 to +100. circ strictly decreases from 0 to +100. Every step of 20 moves top_mid or top_var by ≥ 0.02. On 1:1 (flat_grey), 0…+100 is the same circle by definition, so it must change nothing there (Δ ≤ 0.01) | worst reversal 0 | `profile.py --key look.vignetteRoundness --values -100,-80,…,100` (`--frame flat_grey` for 1:1) | n/a |
| 13 | **Amount is monotone and live in every style.** Corner code on flat_grey across Amount −4…+2 step 0.5, per style. CP on neutral grey equals HP, because CP is a luminance-only operation on neutrals. PO on mid-grey matches HP so that Amount means the same corner in every style (**DT**) | no reversal; each step changes the corner by ≥ 2 codes; CP = HP ± 1 code; PO = HP ± 4 codes at −4, −2, −1, +1, +2 | `profile.py --frame flat_grey --amount A --set look.vignetteStyle=S` (corner), or `corner.py --frame flat_grey` | HP corner codes: −4→10, −2→41, 0→118, +2→207 |
| 14 | **Highlights protects bright areas (HP and CP, Amount −4, H 100).** Measured L/L0 per box. skytest snow (Y 0.6) ≥ 0.80. White patch (Y 1.5) ≥ 0.90. Sky (Y 0.52) ≥ 0.70. 6929 TL (Y≈0.47) ≥ 0.65. The mid-grey corner of flat32 keeps ≥ 75 % of the burn (≤ −3.0 EV). A Y 0.09 corner keeps ≥ 95 %. **DT**: LR's Highlights 100 keeps bright areas "punchy" while dark corners still burn | as listed; CP within ±0.05 of HP | `corner.py --frame skytest --set look.vignette=-4 --set look.vignetteHighlights=100 [--set look.vignetteStyle=colorPriority]`; `corner.py --frame 6929 …`; `profile.py --amount -4 --set look.vignetteHighlights=100` (corner frac ≥ 0.75) | H0 today: snow ×0.33, white ×0.49, sky ×0.37, 6929 TL ×0.31, grey −4.0 EV |
| 15 | **Highlights is monotone, continuous and gated.** (a) The snow and white L rise monotonically over H = 0…100 step 10, by ≥ 0.01 per step. (b) Between H 0 and H 1 at −4, no box's L moves by more than 0.02 (no jump at the legacy switch-over). (c) H has no effect at Amount > 0 in any style, or in PO at any Amount | (c) is pixel-identical | `corner.py` per value; (c) via sha256 of `lib.render` output (H 0 vs 100 at +1.5 for all styles, and at −2 in PO) | n/a |
| 16 | **No tone inversion.** Output is nondecreasing in input Y at fixed positions (corner, side_mid, r 0.85), 28 levels Y 0.005…8, for HP/CP × H {0, 50, 100} × Amount {−4, −1}, plus every style at +2. Scene-linear unit test of `stops`/gain over Y ∈ [0.001, 16] at 2000 levels for every style × H × a ∈ {−4, −1, +1, +2}. The single exemption is HP + H 0 + a > 0 + Y > 2.88: the legacy curve is kept bytewise (D3) and only the display check applies there (see notes) | WORST_REVERSAL 0 (8-bit); unit test d(out)/dY ≥ 0 | `python3 $S/tone.py --set look.vignette=-4 --set look.vignetteHighlights=100 [--set look.vignetteStyle=…]`; `swift test --filter VignetteToneTests` (new) | HP today: 0 at +2 and −4 (8-bit) |
| 17 | **CP holds colour when burning.** At −2 and −4, on colour4 (4 corners), skin_tones tan_TR / dark_BL / mid_BR, skytest sky_TR, 2545 TR, 983 TL, for boxes with C0 ≥ 0.03. Corner L within ±0.03 of HP's at the same Amount (same strength). **DT** for the hue number: HP today reaches −9.0° on skin | \|dh\| ≤ 3.0° at −2 and ≤ 4.0° at −4; cl in [0.90, 1.15]; never worse than HP + 0.5° in any box | `corner.py --frame F --set look.vignette=A --set look.vignetteStyle=colorPriority` vs the same without style | HP −2: tan_TR dh −9.0, dark_BL −4.1, 2545 TR +3.2; HP −4: tan_TR −5.5, blue +4.0, 983 TL +6.1, sky cl 1.15 |
| 18 | **CP lifts without pastel.** At +2 and +1.5 on skytest sky_TR, skin mid_BR / tan_TR, colour4 blue/red/skin, 2545 TR: chroma kept, L still rises by at least 60 % of HP's ΔL, and the box clips ≤ 1 % at 255. **DT**: LR's CP "minimizes color shifts", and corners must not go milky | C/C0 ≥ 0.80; \|dh\| ≤ 3°; as listed | `corner.py … --set look.vignette=2 --set look.vignetteStyle=colorPriority` | HP +2: sky C ×0.43 (cl 0.35), mid_BR cl 0.73 dh +4.6, 2545 TR C ×0.82 (cl 0.63) |
| 19 | **PO is opaque paint with less contrast.** On the checker frame, corner sdL ratio below HP's at the same Amount, with the corner mean L within ±0.08 of HP's. Hue held on chromatic boxes. **DT**: LR/ACR document PO as blending toward black or white with reduced contrast; HP keeps contrast in stops | PO sdL ≤ HP − 0.08 at −2 and ≤ HP − 0.15 at +1.5; \|dh\| ≤ 3° at −2 on colour4 and skin boxes | `corner.py --frame checker --set look.vignette=-2 --set look.vignetteStyle=paintOverlay` (and +1.5) | HP checker: −2 sdL ×0.66 (L ×0.55); +1.5 sdL ×0.77 (L ×1.34) |
| 20 | **No new shadow clipping.** Frame shadowsPct (lumen-render metrics) at Amount −4, defaults otherwise, per style | each style ≤ HP-today + 0.05 | `corner.py --frame {1569,983,2545} --set look.vignette=-4 [--set look.vignetteStyle=…]` ("frame set shadowsPct") | HP: 1569 5.340 %, 983 1.226 %, 2545 0.571 % |
| 21 | **No banding (8-bit, flat_grey 1024², full resolution).** For each style at Amount −4 and +2, crossed with {defaults, midpoint 0, midpoint 100, feather 100, roundness −100, roundness +100, feather 25}. Feather < 25 is excluded from maxstep because the hard edge is intended; line 9 covers it. Dithered local-mean reversal must stay 0 | undithered: maxstep ≤ 1, reversal 0, flat ≤ 1.5 × before at defaults; dithered local-mean reversal ≤ 0.25 code | `python3 $S/banding.py --set look.vignette=-4 --set …` | −4: row maxstep 1, flat 15 px, diag flat 30 px; +2: row flat 11; −1: flat 30; dithered reversal 0.00 everywhere |
| 22 | **Crop-relative on the CPU reference (Linux).** The crop rectangle of the uncropped CPU output equals a flat frame of the crop's own size. Crop corners get the corner frac and the full-frame corners are not pinned. Cases: crop 0.125, 0.125, 0.375, 0.75; the same with `--flip`; the centred 1:1 crop 0.1666667, 0, 0.6666667, 1; and with `--set look.vignetteMidpoint=30 --set look.vignetteRoundness=60 --set look.vignetteFeather=20` | CROP_MAXDIFF ≤ 0.04 | `python3 $S/crop.py [--flip] [--crop …] [--set …]` | 0.928 / 0.928 / 0.497; crop corners 0.15-0.85 |
| 23 | **Crop with straighten (unit, Linux).** The shared LumenCore coordinate field, evaluated on a source pixel grid for angle ±13°, 90° and flipH, matches the delivered-frame formula of `VignetteGeometryContractTests.check` (its u, v from the delivered extent) after mapping through the same orientation | max \|Δρ\| ≤ 1e-9; ReferenceRenderer passes `plan.recipe.develop.geometry` | `swift test --filter VignetteCropFieldTests` (new) | CPU ignores crop (F7) |
| 24 | **CPU/GPU parity (macOS CI, `gpu-parity.yml`).** New `VignetteStyleParityTests` in LumenPipelineTests. Source: 64×32 with Y 0.02…2 and saturated hues. Cases: geometry crop 0.1, 0.2, 0.6, 0.55, angle −7, flipH; each style × {midpoint 30, roundness −60, feather 20, H 70} and {midpoint 80, roundness +80, feather 90, H 0} × Amount {−3, +1.5}. Plus feather 0. The existing parity tests stay green; `VignetteGeometryContractTests` changes only its expected-falloff call to the shared profile function | \|gpu − ref\| ≤ 0.005·max(1, ref) dithered (the existing golden bar); ≤ 0.002 undithered (the geometry-contract bar). Feather 0 edge pixels within 1 px of the edge use the same bar | `swift test --filter LumenPipelineTests` on macOS (workflow green) | parity at crop: 1.98 EV off (F7) |
| 25 | **Unit tests exist for lines 4-18 and 23** in `Tests/LumenCoreTests` (Vignette*Tests). `swift build --target LumenCore --target LumenRender` is clean and `swift test --filter LumenCoreTests` passes on Linux | all green | as stated | n/a |
| 26 | **Existing tests are untouched except the ones listed under Tests that change, each with a reason in the commit message.** No test is skipped, disabled or loosened | diff review | `git diff --stat Tests/` | n/a |
| 27 | **UI (D9).** `EffectsPanel.vignetteSection` order: Style, Amount, Midpoint, Roundness, Feather, Highlights (LR's order). Details below this table | `ci.yml` macOS build, `ui-layout.yml` and `python3 scripts/check-swift-surface.py` green | grep, plus CI | 2 rows |
| 28 | **Wiring.** `RenderPlan` carries all four fields. `LookSubset` blends midpoint, roundness and highlights with `Num.mix` like feather, and style lands whole at amount > 0 (like a stock name). `SettingsSubset` copies them with the vignette. `lumen-render keys` lists the 3 numeric keys with their ranges, and `--set look.vignetteStyle=paintOverlay` works. `ControlIndex` aliases include midpoint, roundness, "highlight priority", "color priority", "paint overlay" | tests for each, plus `LookAmountTests` and `SettingsSubsetTests` pass | `swift test --filter 'LookAmount\|SettingsSubset\|SavedLook\|ControlIndex'`; `$BIN keys \| grep vignette` | n/a |

Line 27 in detail:
- **Style row.** A `LumenMenuPicker(title: "Style")` with the labels "Highlight Priority", "Color Priority" and "Paint Overlay". This is the Soft Proof "Destination" pattern; segmented would overflow the panel.
- **Slider rows.** The four new sliders are `LumenSlider` with the same arguments shape as Feather: `step: 1, decimals: 0`. Roundness is `bipolar: true` with range −100…100; the others are `bipolar: false`.
- **Highlights row.** `.disabled(style == .paintOverlay)`, which is LR's behaviour and follows the `DetailPanel:688` precedent. Its help says it acts only when Amount is negative.
- **Help text.** The Amount and Feather help no longer says "Feather is the strength control".
- **Modified dot and Reset.** `isVignetteModified`, `WorkspaceSection.nonDefault(.effects)`, the section Reset and `WorkspaceSection.effects.reset` cover all 6 fields, with one test per field (each one alone at Amount 0 lights the dot, and Reset clears it).
- **Registries.** Add entries in `SliderEvidenceTests` (new keys, and the feather entry renamed to its new test) and in `LayoutMetricSupport.SliderSpec`, with the file:line refs of the Effects rows updated.

## Tests that change (line 26), and why

All of them encode the old **feather = size/strength** semantics (D4 makes feather a width only):
- **`VignetteFeatherTests`**
  - `testInnerRadiusIsMonotoneAndBounded`: the old inner(0)=0.75 and inner(100)=0 mapping.
  - `testFeatherShapesTheFalloffWithoutMovingItsEnds`: "more feather darkens r≈0.74 more", and a full corner at feather 100.
- **`VignetteResponseTests`**
  - `testTheCornerReceivesExactlyTheStatedStops`: now restricted to `c + s/2 ≤ 1`, per line 10.
  - `testTheFalloffStatisticsTheTooltipsQuote`: re-pinned to the new profile.
  - `testTheFeatherTooltipQuotesTheMeasuredFractions`: the tooltip changes.
  - `testBothEndsOfTheFalloffAreFlatAndThisIsByHowMuch`: re-pinned per feather.
  - `testFeatherMovesTheDeliveredStrengthTwelvefold`: replaced by "feather keeps r50, changes w".
- **`SliderEvidenceTests`**: the feather entry points at the replacement test.
- **`VignetteGeometryContractTests`** (macOS): its expected falloff call uses feather 75 under the old meaning.
- **Fixture and registries**: `default-recipe.json` (4 keys, regenerated), `LayoutMetricSupport` (line refs and new rows).
- **Additions only**: `RecipeCodecToleranceTests` and `ResetSemanticsTests` gain the new fields in their "every field off default" samples.

Must pass **unmodified**:
- Everything at the default feather, for example `VignetteResponseTests` range, monotone and increment tests, `SliderContractTests.testVignetteCornerIsTheStatedStops` and `EngineIntegrationTests.testVignetteDarkensTheCornersAndLeavesTheCentre`.
- `KernelGoldenTests` vignette clamp, feather and fp16-banding goldens. The signature may change; the assertions and bars may not.

## Visual claims (human judges; the files are written by the builder, each < 400 KB, dithered)

Each command is prefixed `python3 $S/sheet.py`.

- **V1. Shape control on a real photo (6929).**
  - Sheet: `--frame 6929 --set look.vignette=-2 --rows look.vignetteRoundness=-100,0,100 --cols look.vignetteMidpoint=0,25,50,75,100 --long-edge 768 --tile 160 --out docs/quality/lanes/WS-41/evidence/after_6929_midpoint_roundness_grid.png`.
  - Claim: midpoint changes the vignette's size without changing its softness. −100 hugs the frame edges, +100 is a circle. No grey haze at −2, and the TL sky corner stays bright with Highlights.
  - Companion sheet: `--frame flat32 --set look.vignette=-3 --cols look.vignetteFeather=0,25,50,75,100 --tile 200 --out …/after_flat32_feather_sweep_ev-3.png`. Compare it with `before_flat32_feather_sweep_ev-3.png`: same size, only the softness changes, and feather 0 is crisp.
  - 100 % crop: `--frame flat32 --set look.vignette=-3 --set look.vignetteFeather=0 --long-edge 1536 --crop 0.9,0.4,1,0.6 --tile 154 --out …/after_feather0_edge_crop.png`. It must show no stair-steps.
- **V2. Bright corners stop going muddy (983 snow, 6929 walls).**
  - Sheet: `--frame 983 --set develop.tone.exposure=1.5 --set look.vignette=-3 --cols look.vignetteHighlights=0,50,100 --long-edge 768 --tile 250 --out …/after_983_highlights.png`. Exposure +1.5 is needed because the raw is dark: the snow sits at scene Y ≈ 0.1 and displays below mid-grey at exposure 0.
  - The same command on `--frame 6929` writes `after_6929_highlights.png`.
  - Claim: at H 100 the snow, sky and white walls in the corners stay white or bright, while the foliage and dark ground still burn, with no halo or tone flip at the boundaries between the two.
- **V3. Styles (2545, skin_tones).**
  - Sheet: `--frame 2545 --rows look.vignetteStyle=highlightPriority,colorPriority,paintOverlay --cols look.vignette=0,-2,1.5 --long-edge 768 --tile 220 --out …/after_2545_styles.png`.
  - The same for `--frame skin_tones --cols look.vignette=-4,-2,2 --tile 260` writes `after_skin_tones_styles.png`.
  - Claim:
    - CP's sky stays blue at +1.5 instead of HP's pastel, and skin keeps its hue at −2.
    - PO reads as flat paint: lower corner contrast, toward black or white.
    - No banding in the grey surround.

## Spec notes (decisions flagged to the lane lead)

1. **D3 versus D5 conflict.** The legacy protection kept bytewise at Highlights 0 inverts tone for a > 0 at scene Y 2.88-5.76 (F4: slope −0.60).
   - Exact identity (D3) and "monotone at every pixel" (D5) cannot both hold there. Line 16 exempts only that corner of the space, and only the 8-bit display check applies to it; that check passes today because the region saturates at 255.
   - Recommendation: accept the exemption, since the corpus has 0 pixels above 2.88. Alternatively, allow dropping legacy protection for a > 0, which moves bytes only on synthetic hlbars-type frames and would make line 1 skytest@0.6/@2 the only cases to re-record.
2. **Highlights keyed on scene Y.** Real raws place display-bright content at different scene levels: 983's snow is Y ≈ 0.1 and displays at L 0.43, while 6929's sky is Y ≈ 0.47 and displays at L 0.76. A protection keyed on scene Y (as D5 says) therefore follows Exposure. Lines 14/V2 are written for content that displays bright. If the builder keys protection on the plan's display mapping instead, the numbers above still apply.
3. **Feather beyond the corner** is not renormalised, so that r50 stays fixed (D4). At midpoint 100 / feather 100 the corner gets roughly 55-60 % of Amount, which is accepted and stated in the help.
4. **Roundness > 0 on a 1:1 crop is a dead range by geometry**, because the crop-aspect ellipse is already a circle. Line 12 tests for a no-op there instead of liveness.
5. **CP thresholds (lines 17-18) are design targets** to be met at S13 in scene-linear before the DRT. If the DRT's own hue behaviour at dark levels makes ≤ 3°/4° unreachable, REPORT.md must give the measured worst value, and the floor is "never worse than HP + 0.5°", not silence.
6. `lumen-render` gains no geometry stage (GEO-17 owns it). Line 22 measures the crop on the uncropped CPU output, which is exactly what the reference renders.

## Amendment A1 (lane lead, after verifier round 1; reason and evidence in VERIFY.md)

Round 1 measured, in float with no 8-bit rounding, that CP and PO change the SCENE hue by 0.00° and that the remaining display hue shift on skin (tan_TR −8.5° at −2) is the finish/display transform responding to a lower lightness. That transform belongs to another lane, and a stage that changes only lightness cannot get under it. The absolute display-hue thresholds in 17 and 19 measured that transform, not the vignette. They are replaced. Nothing else in 17-19 changes, and line 18 keeps all its thresholds because its misses were implementation faults.

- **17 (hue part), replaced:** (a) scene-linear hue change for CP is ≤ 0.1° in every box (unit test); (b) in FLOAT display (no 8-bit rounding), |dh_CP| ≤ |dh_HP| + 0.5° in every listed box; (c) cl inside [0.90, 1.15], or within ±0.02 of HP's cl in the same box where HP itself is outside that range. The 8-bit |dh| numbers are reported, not gated.
- **19 (hue part), replaced:** (a) scene-linear hue change for PO is ≤ 0.1°; (b) in FLOAT display, |dh_PO| ≤ |dh_HP'| + 1.0°, where HP' is HP at the Amount that gives the same corner L within ±0.03 (a lightness-matched comparison, because PO lands at a different L by design).
- **New 29:** feather 0 is anti-aliased on every crop aspect: the 10-90 % edge is ≥ 1.0 output px measured along the gradient on crops of 1:1, 3:2, 6:1 and 1:6, with no stair-steps (aa_rms ≤ 0.15 px).
- **New 30:** Feather has no jump at the low end: the transition-width step per unit of feather over 0…10 is ≤ 3× the median step over 10…100.

## Amendment A2 (lane lead, after verifier round 2; evidence in VERIFY-R2.md)

- **18 (hue part), replaced** on the same evidence and rule as A1: VERIFY-R2 measured HP at matched lightness on skin mid_BR at +5.0° (L 0.830) against CP's +4.9° (L 0.832), at about a quarter of a JND on a chroma-0.06 patch. That is the display transform, not CP. New bar: in FLOAT display, |dh_CP| ≤ |dh_HP'| + 1.0°, where HP' is HP at the Amount giving the same corner L within ±0.03. The 8-bit |dh| is reported. C/C0, lift ≥ 60 % of HP and clip ≤ 1 % keep their thresholds.
- **New 31 (CP lift on bright saturated colour):** for saturated patches (red, green, blue, skin at OKLab C ≥ 0.10) at scene Y 0.5, 1, 2, 4, sweeping Amount 0→+2 in steps of 0.125: display L is non-decreasing (worst reversal ≤ 0.002), the hue step between adjacent Amounts is ≤ 1.5°, and |dh| over the whole range is ≤ that of HP at matched L + 1.0°.
- **New 32 (byte identity at every frame size):** line 1's identity holds for frames as small as 1×1, 2×3, 5×5 and 7×4 px, at defaults with legacy amounts.
- **New 33 (no hot pixels from lift):** in every style at +2, no output pixel's display value exceeds that of the same input pixel at HP +2 by more than 8 codes in any channel, and pixels with input luminance ≤ 0.001 (including negative) gain at most 2^Amount. Checked on 1569, 983 and a synthetic with negative and zero pixels.
- **New 34 (feather has no kink):** the per-unit change in transition width just below and just above any feather value differs by at most 3× everywhere on 2…100. Feathers 0–2 may render alike where the anti-aliasing floor dominates, which is pixel-limited.
