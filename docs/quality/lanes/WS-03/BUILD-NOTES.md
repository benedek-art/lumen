# WS-03 White balance: build notes (builder, round 1)

These are the builder's own measurements. The verdict is the verifier's. Every command runs from the repo
root after `export PATH=/opt/swift/usr/bin:$PATH; swift build -c release --product lumen-render`, with
`T=docs/quality/lanes/WS-03/tools`.

**Linux test harness note.** `swift test` cannot build on this Linux toolchain (Swift 6.0.3) because
`LumenApp/CompareView.swift` uses trailing commas in argument lists (a Swift 6.1 feature), and
`LumenAppTests` depends on `LumenApp`. This is the same on the base commit. To run `LumenCoreTests`, I
temporarily dropped the `LumenApp` executable, its product and `LumenAppTests` from `Package.swift`
(not committed), built with `swift build --build-tests`, and ran the xctest binary with every
`LumenCoreTests` class named (`swift test --filter` expands to an argument list too long to spawn).
The script is `scratchpad/build/runcore2.sh`. `ControlProofTests` takes more than an hour in debug, so it
ran from a release test build (`swift build -c release --build-tests -Xswiftc -enable-testing`).

## Per spec line

| # | Measured | Command | Builder's reading |
|---|---|---|---|
| 1 | 8/8 frames BIT-IDENTICAL; `testTheTempRowShowsTheNeutralTheRenderAdaptsFrom` passes | `python3 $T/identity.py`; EngineTests | pass |
| 2 | Below the guard, `ColorTemperature.chromaticity` and `DNGTemperature.chromaticity` give the same xy to ≤ 1e-9, because it is the same call, over 20–500 mired in 5-mired steps × tint ±150 in 2.5 (11 000+ pairs). The round trip through `ColorTemperature.temperatureAndTint` is within 0.01 mired and 0.01 tint (Newton-polished, about 1e-9). **Deviation:** the spec names `DNGTemperature.temperatureAndTint`. The SDK's own inverse is not an exact inverse of its forward map (DNGTemperature.swift header; `DNGTemperatureTests` pins this), and its round trip moves up to **0.0326 mired** (3226 K, −150) and 0.0016 tint. That breaks the 0.01-mired threshold by construction of the SDK. Making the SDK port exact would break the SDK cross-check tests (D65 → 6503.70718479529 ± 1e-6, A → 2855.7553 ± 1e-6), so `ColorTemperature.temperatureAndTint` is the exact inverse instead, and the SDK inverse is held to its measured 0.035 mired bound in the test. | `WhiteBalanceConventionTests/testChromaticityIsTheDNGConventionBelowTheGuard`, `testTheAsShotPairIsReadInTheSameConvention`, `testTheRoundTripReturnsThePair` | pass, with the 0.0326-mired SDK round trip noted for the verifier |
| 3 | 500 pairs: ΔE00 median 0.000, p90 0.000, max 0.010 (rounding of the 8-bit output). In the engine itself the channel spread is < 1e-9. | `python3 $T/kelvin_grid.py`; `WhiteBalanceConventionTests/testTypingTheLightsAdobeNumbersNeutralisesItsGrey` | pass |
| 4 | All 21 cases: max \|Δhue\| 0.0°, max \|C ratio − 1\| 0.000. At 6504/+9.77, +75 → 325.7°, −75 → 152.6°. | `python3 $T/tint_axis.py` | pass |
| 5 | Monotone on all 16 sweeps (2000 K tile excluded per N3). | `python3 $T/sweeps.py --out …/ws03_after` | pass |
| 6 | **FAIL as specified** (diagonal-adaptation experiment below: no option passes 6 without failing 4). Worst: +5.92 pp highlights (skin_tones @2000 K: 23.69 vs 17.77), +18.32 pp shadows (983 tint −150: 19.01 vs 0.70). Failing tiles: skin 2000 K hi +5.92; 6929 2000 K hi +0.97 (shadows −11.8); 3914 2000 K hi +0.54, 2500 K hi +0.70; 864 2000 K lo +12.65; 2545 tint −150 lo +1.43; 983 tint −150 lo +18.32; 864 tint −150/−100/−50 lo +15.18/+4.97/+1.29. Every other tile is within threshold, and several improve (1346 tint +150 highlights 1.81 → 0.00, 6929 2000 K crush 58.4 → 46.6). | same run | see "Line 6" below |
| 7 | 28 cases: max \|Δmired\| **0.0019**, max \|Δtint\| **0.0047**. Before: 39.75 mired / 11.58 tint. | `swift test --filter WhiteBalanceConventionTests/testTheEyedropperReturnsTheIlluminantsAdobeNumbers` | pass |
| 8 | 325 lines: 0 negative lines (tint −150…+300), max OKLab-a drop **0.0020** (as-shot 10000/+10 → 3846 K at +120). Clamp-free bands: no as-shot from line 3 clamps at ≤ +25 for any Temp ≥ 2500 K (2.5-mired grid); from 5500/+10, +150 is unclamped for every Temp ≥ 4500 K (1-mired grid). | `swift test --filter TintGuardTests` (`testNoInversionAcrossAsShotAndTargetGrid`, `testTheGuardLeavesOrdinaryWorkUnclamped`) | pass |
| 9 | Presets unchanged. Max ΔE00 over the as-shot set: Daylight 0.00, Cloudy 0.00, Shade 0.00, Tungsten 0.01, Fluorescent 0.00, Flash 0.00. | `python3 $T/kelvin_grid.py`; `WhiteBalanceConventionTests/testEachPresetNeutralisesItsOwnAdobeLight`; `WhiteBalancePresetNameTests` | pass |
| 10 | `SliderScaleTests` passes. The `SliderDrag.swift` diff is empty. `BasicPanel.swift:227 scale: .reciprocal`. | as spec | pass |
| 11 | `git diff --stat claude/inspiring-dirac-ulgpch -- Sources/LumenPipeline` is empty. The grep finds only comments (`AppleRawSource.swift:46-50`, now stale; see NEEDS §3). No kernel computes Kelvin or tint: WB reaches the GPU only as the CPU-built matrix. | as spec | pass |
| 12 | `AutoWhiteBalance.estimate(_:asShot:excluding:) -> Estimate{kelvin,tint,confidence}` in the new file. `lumen-render autowb` prints `{"confidence","kelvin","seconds","tint"}`. The only edit to existing LumenRender code is `CLI.swift` +1 (the dispatch `case`); the command lives in the new file `AutoWB.swift`. | `swift build --target LumenCore --target LumenRender`; `git diff … -- Sources/LumenRender` | pass |
| 13 | IN ΔE00: 1346 1.05, 967 1.77, 983 1.55, 3914 9.63, 864 1.59. Mean **3.12** (≤ 3.20). \|Δmired\| / \|Δtint\| vs chart-neutral: 3.9/1.6, 2.9/4.2, 7.4/2.2, 7.5/1.5. | `python3 $T/auto_eval.py` | pass (13b margin 0.08) |
| 14 | OUT ΔE00: 1.68, 2.18, 1.86, 9.59, 3.16. Mean **3.69** (allowed 4.07). Each frame ≤ as-shot + 2.5. | same | pass |
| 15 | 6929: −4.4 mired / −1.1 tint. 2545: +0.6 / −0.5. | same | pass |
| 16 | skin_tones: +0.38 mired / +0.04 tint. skin_only: 0.0 / 0.0, chroma kept 1.00, max \|Δhue\| 0.0°. | same | pass |
| 17 | flat_grey at 4000/+5: 0.000 / 0.000. 5 runs give 1 distinct result. Median time **0.082 s** on 6929. | same | pass |
| 18 | The `presetRow` LumenMenu has `LumenMenuItem(title: "Auto", symbol: "wand.and.stars", …)` under As Shot. An "Auto" button sits left of the eyedropper with the same modifiers (font `.lumenGlyphBody`, padding 5/3, `controlBackground`, `primaryText`, `radiusChip` clip, `.plain` style). The stale comment is gone. `presetName` is unchanged, with no Auto title and no recipe field. Not compiled (macOS-only target); `swiftc -parse` is clean on all three edited app files. | `grep -n "Auto" Sources/LumenApp/BasicPanel.swift` | needs the macOS CI build |
| 19 | Rewritten tests are listed below. LumenCoreTests, all classes except ControlProofTests, in debug: **3059 executed, 0 failures, 6 skipped**. The base commit gives 3044 / 0 / 6. ControlProofTests in a release test build: **6/6 pass** after re-recording `raw.temp` and `raw.tint`. The drift test flagged exactly those two and no other record. | runcore2.sh; release xctest `LumenCoreTests.ControlProofTests` | pass |

V1–V3 (human judgement, sheets in `evidence/`):
- **V1** `after_tint_axis_skin_tones.png` against `before_…`: −150 reads green, +150 magenta-pink, and skin at ±75 is still skin.
- **V2** `after_tint_2545_gx85.png` against `before_…`. Measured on unquantised tiles (sky = top-right
  12 %, lawn = lower-middle block, display OKLab):

  | tint | sky hue before → after | lawn hue before → after |
  |---|---|---|
  | −150 | 167° → 184° | 104° (yellow-green) → 130° (green) |
  | −75 | 206° → 212° | 98° → 115° |
  | +75 | 279° → 282° | 318° → 356° |
  | +150 | 304° → 296° | 299° → 321° |

  The lawn is no longer yellow at −150, and the sky is less teal and less purple than before. At −150
  the sky still reads cyan-blue (184°): green tint on a blue sky is cyan, and the Adobe model gives
  the same. That part is for the human to judge. The sheet is 256-colour quantised to fit 400 KB, so
  the flat (clipped) sky posterises. Unquantised: `scratchpad/build/v2_after.png`.
- **V3** `after_auto_charts.png` (3/4 size, quantised). On 864, Auto is visibly closer to chart-neutral
  than as-shot. On 3914, Auto ≈ as-shot (confidence 0.11), so it is no bluer. On 967 it is slightly warmer
  than as-shot, toward neutral.

## Line 6: why it does not pass, and the diagonal-adaptation experiment (lane lead's request)

**Mechanism, measured (corrected from round 1).** At tint −150 the WB matrix creates almost no negative
*scene-linear* channels. On 983 the share of pixels with a channel ≤ 0 is 0.00 % for CAT16, the old model
and every alternative. The crush comes from the **sRGB output gamut**. CAT16's green adaptation has
off-diagonal terms (R←G −0.27 in Rec.2020) that push saturated colours outside sRGB. The encoder then
clamps R to 0, which the clipping metric counts as crush. That clamp is downstream of WS-03 (display
transform / output gamut). Share of pixels with a negative sRGB channel after WB, by tile and adaptation:

| tile | old model | CAT16 (shipped) | diagonal in Rec.2020 | 50/50 blend |
|---|---|---|---|---|
| 983 tint −150 | 1.05 % | 24.35 % | 2.51 % | 21.26 % |
| 864 tint −150 | 3.72 % | 22.57 % | 13.79 % | 17.79 % |
| 864 tint −100 | 3.51 % | 14.61 % | 7.27 % | 11.58 % |
| 2545 tint −150 | 0.39 % | 3.50 % | 0.55 % | 2.15 % |

At 2000 K (864, −3.7) the matrix does create Rec.2020 negatives (N3): CAT16 18.6 %, old 17.6 %, diagonal
0.05 % of pixels have a channel ≤ 0.

**The alternatives, against the other lines.** Each one is constructed to map the decoded white of the
target light to neutral, so lines 3/7/9 stay exact. Its matrix is `diag` in space P, set so that
`M · (W⁻¹·𝟙) = 𝟙`. Line 4 compares the grey of a tint-only move with the Adobe/CAT16 prediction, and
there every non-CAT16 space disagrees. Scene-linear, worst over the 21 line-4 cases
(`scratchpad/proto/spaces.py`):

| adaptation space | line 4 max \|Δhue\| | max \|C ratio − 1\| | min off-diagonal at −150 (9365/+16.4) | at 2000 K |
|---|---|---|---|---|
| CAT16 (shipped) | 0.0° | 0.000 | −0.273 | −0.557 |
| Rec.2020 RGB (diagonal) | **5.9°** | **0.192** | 0.000 | 0.000 |
| Bradford | 8.0° | 0.189 | −0.241 | −0.319 |
| HPE | 10.9° | 0.146 | −0.263 | −1.026 |
| XYZ | 10.6° | 0.154 | −0.064 | −2.305 |
| OKLab LMS | 12.1° | 0.100 | −0.130 | −0.280 |

Line 4's thresholds are 3° and 0.10. A 50/50 CAT16/Rec.2020 blend still reproduces greys exactly and
lands at about 3° / 0.10 on line 4, but it leaves 983 at 21 % out-of-gamut, so line 6 still fails.

**What a diagonal trades on non-neutral colours.** I used the 18 chromatic synthetic ColorChecker patches
(C ≥ 0.03). `charts.json` holds only the greys of the real charts, so the patch truth comes from the
synthetic chart, balanced at the 1346 and 967 chart-neutrals and taken to 2850/0 and 7500/+10. Mean
|Δhue| between the Rec.2020 diagonal and CAT16:

| base | target | mean (max) Δhue diag vs CAT16 | mean hue move from base: CAT16 / diag |
|---|---|---|---|
| 1346 5454/−7.6 | 2850/0 | 3.9° (7.9°) | 37.7° / 39.4° |
| 1346 | 7500/+10 | 1.3° (2.6°) | 9.4° / 9.6° |
| 967 4740/+15.5 | 2850/0 | 3.5° (6.6°) | 32.1° / 33.2° |
| 967 | 7500/+10 | 1.5° (3.5°) | 18.3° / 18.3° |

The diagonal is a modest hue trade, slightly larger moves at warm targets. It would remove the
2000 K negatives and most of the −150 out-of-gamut share. It would also let the magenta guard simplify:
gains `1/(W⁻¹·𝟙)` stay positive whenever the target's decoded white is positive, so there is no
inversion pole.

**Decision: CAT16 kept.** No candidate passes line 6 without failing line 4. Line 4's reference *is*
CAT16, and the diagonal misses it by 5.9° / 0.19 against a 3° / 0.10 threshold. Choosing between a
CAT16-exact tint axis (line 4) and fewer out-of-gamut pixels at the extremes (line 6) is a decision for
the spec owner or D9, not the builder. Alternatively, the downstream sRGB gamut clamp could compress
instead of clip (NEEDS §2). Line 6 stays **FAIL** with the tile numbers in the table at the top. Every tile
inside 2500 K…50000 K and tint −100…+150 passes, except 864 tint −100/−50 (+4.97/+1.29 pp shadows) and
3914 at 2500 K (+0.70 pp highlights; the file's +48.2 tint is now honoured instead of being clamped to +29.7).

## Line 2: which inverse round-trips, and why the SDK's cannot

- **`ColorTemperature.temperatureAndTint(for:)` round-trips within 0.01 mired and 0.01 tint** over the whole
  line-2 grid (in fact to about 1e-9). It seeds with the SDK inverse and polishes with Newton steps on
  `DNGTemperature.chromaticity`, so it is the exact inverse of the forward map white balance renders with.
  Test: `WhiteBalanceConventionTests/testTheRoundTripReturnsThePair`.
- **`DNGTemperature.temperatureAndTint` (the SDK's `Set_xy_coord`) cannot meet 0.01 mired.** The forward
  direction interpolates linearly in reciprocal temperature between table rows. The inverse instead
  weights two neighbouring rows by perpendicular distance to their two non-parallel isotherms. The two
  agree only on the table rows. Measured on the line-2 grid, the SDK round trip moves up to **0.0326
  mired** (3226 K, tint −150) and 0.0016 tint. The test holds it to < 0.035 / < 0.002.
- Making the SDK port exact would change its outputs off the rows (A: 2855.7553 K, D65: 6503.70718 K
  are pinned to 1e-6 in `DNGTemperatureTests`). Those numbers are what ACR/Apple report, so the port
  stays faithful and the exact inverse lives in `ColorTemperature`.

## Files and functions touched

- `Sources/LumenCore/Color/ColorSpaces.swift`, `ColorTemperature` (rewritten):
  - `chromaticity(kelvin:tint:)` is now `DNGTemperature.chromaticity`, with the illuminant guard (signature kept).
  - `temperatureAndTint(for:)` is the SDK inverse plus Newton polish, an exact inverse.
  - `locus(kelvin:)` is the Robertson tint-0 point. `planckianLocus`/`daylightLocus` are kept as reference curves.
  - `tintConeFloor`, `tintLimit(kelvin:)` and `clampedTint(kelvin:tint:)` keep the illuminant bound on the DNG axis.
  - New: `tintLimit(kelvin:asShot:)`, `clampedTint(kelvin:tint:asShot:)` and `magentaSlack` (0.002). This is
    the picture bound against the real as-shot neutral. It scans tint upward and stops where the rendered
    grey's OKLab a falls more than 0.002 below its running maximum or a channel goes negative. It can
    be negative, and it is memoised per (K, as-shot).
  - Removed: `tintUnitInV`, `magentaReferenceKelvin`, `magentaMonotoneLimit`, `renderedMagenta` (the
    fixed-5500 K bound).
- `Sources/LumenCore/Engine/WhiteBalanceEngine.swift`:
  - `adaptation` clamps the target tint with the as-shot-aware bound.
  - `effectiveTint` uses the same bound and returns the target tint on identity.
  - Doc comments only on `presets`.
  - `neutralizing` and `LinearStage` are untouched.
- `Sources/LumenCore/Engine/AutoWhiteBalance.swift` (new): `AutoWhiteBalance.estimate`, `neutralTarget`
  (closed-form CAT16 neutral → Adobe K/tint), `Region`, `Estimate`.
- `Sources/LumenRender/AutoWB.swift` (new): `LumenRenderCLI.autowb`. `Sources/LumenRender/CLI.swift`:
  one dispatch line.
- `Sources/LumenApp/BasicPanel.swift`:
  - `presetRow`: Auto menu item, Auto button, and the stale comment removed.
  - `boundedTintCaption`: reads `WhiteBalanceEngine(...).effectiveTint` (the as-shot-aware bound) instead of
    `ColorTemperature.clampedTint(kelvin:tint:)`, so the caption keeps telling the truth. This is outside
    "presetRow only" in line 18, but it is a WS-03-owned function, and without it the caption would
    disagree with the render.
- `Sources/LumenApp/AppState.swift`: new `applyAutoWhiteBalance()` only, inserted after `resolvePick`.
  It writes the primary photo through `updateRecipe(label:targets:)`, which is one history step, uses
  the same selection-still-on-photo guard as `resolvePick`, and sets a status message.
- `Sources/LumenApp/RenderCoordinator.swift`: new `solveAutoWhiteBalance(url:recipe:)` only, after
  `solveNeutral`. It decodes at `min(1, 1024 / nativeLongEdge)`, copies into an `ImageBuffer` with
  `PipelineRenderer.buffer(from:context:)` using its own CIContext configured like the renderer's
  (extended linear Rec.2020, RGBAh), and calls `AutoWhiteBalance.estimate`. No existing function body was edited.
- `scripts/gen-fixtures.py`: the Python mirror of `ColorTemperature` (its header says "change BOTH sides
  together") is now the DNG table, the cone floor on the DNG axis, and the exact inverse.
  Re-running it changed only `enginemath.json`'s `whiteBalance` rows (checked key by key against the old file).
- Not touched: `Sources/LumenPipeline` (empty diff), `SliderDrag.swift`, `neutralizing`, `LinearStage`,
  `LocalWhiteBalance`, `DNGTemperature.swift`.

## Tests

New:
- `WhiteBalanceConventionTests`: lines 2, 3, 4, 7 and 9.
- `AutoWhiteBalanceTests`: neutral frame → as-shot exactly, moves toward the light, exclusion, skin-only
  not greyed, determinism, and closed form agreeing with the eyedropper.
- `TintGuardTests`: `testNoInversionAcrossAsShotAndTargetGrid` and `testTheGuardLeavesOrdinaryWorkUnclamped`.

Changed, each because it encoded the old convention or the old fixed-reference guard:
- `Tests/LumenCoreTests/Proof/records/raw.temp.json` and `raw.tint.json`, re-recorded with
  `LUMEN_RECORD_PROOFS=1` because this is a deliberate fix, not a regression.
  - raw.temp: authority 82.42 → 83.83.
  - raw.tint: authority 145.94 → 83.65, mean 57.2 → 41.8. The old magenta end was about 2.4× Adobe's strength
    and bluer (AUDIT finding 3). The authority floor of 25 is still met.
  - No other record moved. The ProofRegistry comment at the raw.tint spec still quotes the old "+156 at
    5500 K" bound. That file is owned by WS-58, so the comment is left alone.
- `AccuracyProbeTests.testTheKelvinSliderLandsOnThePublishedDIlluminants`: D65/D50 are now asked for at their
  Adobe pairs (6503.7/+9.77, 5000.7/+9.56) instead of tint 0. Tolerance unchanged.
- `ColorScienceTests.testTheLocusPassesThroughTheStandardIlluminants`: the same, at 1e-5/1e-4, and tint 0 is
  checked against Kim's independent Planckian fit (1e-3).
- `EngineMathFixtureTests.testWhiteBalanceMatchesTheReference`: the test is unchanged; the fixture rows were
  regenerated from the updated mirror.
- `HuePreservationTests.testBothWhiteBalanceAxesAreMonotoneInTheirOwnParameter`: the tint half now checks
  against the running maximum with `magentaSlack` (0.002) instead of strict 1e-9. SPEC 8 allows 0.003, and
  a strict bound clamps ordinary tungsten edits of cool frames (+22 at 2500 K from 7500/+10, against
  the spec's +25 clamp-free band). The temperature half is unchanged.
- `HuePreservationTests.testTheMagentaBoundKeepsItsDaylightMarginOnBothSides`: the pinned +152.22 at 5500 K was
  the old fixed-reference number. It now asserts the spec's band (from 5500/+10, +150 is free for every
  Temp ≥ 4500 K) and that the bound still engages at 3200 K and below +25 at 2000 K.
- `HuePreservationTests.testTheMagentaBoundLeavesDaylightAlone`: 4000 K and 5000 K are dropped from the
  "should still be bounded below 150" list (their DNG-axis illuminant bounds are +153 and +229). 3800 K is
  added. The other assertions are unchanged.
- `TintGuardTests.testEffectiveTintReportsTheBoundedMagentaAndOnlyThat`: `effectiveTint` is compared with the
  as-shot-aware clamp, which is what the render uses, and it is asserted never looser than the illuminant clamp.

## Pre-existing failures

None. The base commit 8e2f3b7, run the same way in a worktree, gives 3044 executed and 0 failures
(`scratchpad/build/base_xctest.log`). Its ControlProofTests (release) pass 6/6
(`scratchpad/build/base_proof.log`). `swift test` itself fails to build on
Linux on the base too (CompareView.swift trailing commas). This is pre-existing and unrelated.

## Left / for the verifier

- Line 6 is unmet as written (above, and NEEDS §2).
- Line 2's round trip is met through `ColorTemperature`'s exact inverse, not through the SDK's inexact
  inverse, which is off by 0.0326 mired by design.
- Line 18 needs the macOS CI build. LumenApp cannot be compiled here.
- Auto's skin wedge also covers greys under a *warm* cast of more than about 20 mired relative to
  as-shot. Auto then stays near as-shot. That is the skin-safe trade (`AutoWhiteBalanceTests` documents it).
- NEEDS.md: WS-02 `neutralizing` should report the as-shot-aware tint (cosmetic, no pixel change), the
  line 6 / D9 note, and a stale pipeline comment.
