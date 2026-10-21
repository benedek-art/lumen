# WS-03 White balance: verification report (verifier, round 1)

Branch `quality/ws-03-white-balance` at a0786d9. Base code: 8e2f3b7 (the spec commit). I formed every
number below myself before reading BUILD-NOTES.md and NEEDS.md. Where they disagree with me, the
"Builder's claims" section says so.

## Verdict: **FAIL**

- **Line 6 fails.** It is the only measurable line that fails outright. It cannot be fixed inside
  WS-03 without failing line 4. The builder's diagonal-adaptation experiment shows this, and nothing
  I measured contradicts it.
- **V2 fails as worded.** At −150 tint the sky reads teal.
- **Line 2 meets its threshold only through a substitute function.** It is accepted with a deviation.
- **Line 18 is not compiled.** The macOS CI build is needed. On Linux every called symbol checks out.

Every other line passes.

## Environment and how the tests were run

- `swift build --target LumenCore --target LumenRender` is clean, and so is
  `swift build -c release --product lumen-render`. I also built from scratch in a fresh worktree.
- `swift test` does not build on Linux with Swift 6.0.3. `LumenApp/CompareView.swift:326` and `:569` use
  trailing-comma argument lists. The base commit has the same problem, so it is pre-existing and not
  caused by this lane.
- To run the tests anyway, I used scratch worktrees (never committed) whose `Package.swift` drops
  LumenApp, LumenAppTests and LumenPipelineTests.
  - `swift test --filter LumenCoreTests` then fails to spawn ("Argument list too long"). So I ran the
    xctest bundle directly with every class named.
- Results:

  | Run | Tests executed | Skipped | Failures |
  |---|---|---|---|
  | HEAD, LumenCoreTests without ControlProofTests (debug) | 3059 | 6 | 0 |
  | Base 8e2f3b7, the same set | 3044 | 6 | 0 |
  | HEAD, ControlProofTests (release, `-enable-testing`) | 6 | 0 | 0 |

  - ControlProofTests runs for more than 15 minutes in a debug build, which is why I built it in release.
  - The new tests all pass: WhiteBalanceConventionTests (8), TintGuardTests (15), AutoWhiteBalanceTests (7).
  - So do the neighbouring suites: MaskWhiteBalanceTests (16), WhiteBalancePresetNameTests (8),
    SliderScaleTests (16), EngineMathFixtureTests (14) and `testTheTempRowShowsTheNeutralTheRenderAdaptsFrom`.
- For "before" numbers I built lumen-render at 8e2f3b7 and ran the same tools with `LUMEN_RENDER` pointing
  at it. It reproduces the spec's Before column and `baseline_sweeps.json` exactly: line 6 measures
  +0.00/+0.00, and lines 3, 4 and 9 give the spec's numbers.

## Per spec line

| # | Measured (after) | Before | Threshold | Result |
|---|---|---|---|---|
| 1 | 8/8 frames bit-identical. The `displayed` test passes. | 8/8 | 8/8; tests pass | **PASS** |
| 2 | Largest xy difference between `ColorTemperature.chromaticity` and `DNGTemperature.chromaticity` below the guard: **0.0** (1-tint grid, 2000-50000 K). Round trip through `ColorTemperature.temperatureAndTint`: 4e-12 mired, 4e-12 tint. Round trip through the spec's literally named `DNGTemperature.temperatureAndTint`: **0.0326 mired**, 0.0016 tint. | 0.102 | 1e-9; 0.01 mired / 0.01 tint | **PASS with deviation.** The SDK inverse is inexact by design (it is a faithful port, pinned by DNGTemperatureTests), so the slider's exact inverse is the right function to hold to the threshold. This is outside WS-03's control and was documented. |
| 3 | 500 pairs: ΔE00 median 0.000, p90 0.000, max 0.010 | median 2.47, max 8.65-9.29 | < 0.5 | **PASS** |
| 4 | 21 cases: largest \|Δhue\| 0.0°, largest \|C ratio−1\| 0.000. At 6504/+9.77, +75 gives 325.7° and −75 gives 152.6°. | 38.8°, 1.07 | 3°, 0.10 | **PASS** |
| 5 | All 16 sweeps monotone (2000 K excluded per N3) | PASS | 5e-4 | **PASS** |
| 6 | Worst **+5.92 pp highlights** (skin_tones 2000 K) and **+18.32 pp shadows** (983 tint −150). The table below lists all 10 failing tiles. | baseline | +0.5 / +1.0 pp | **FAIL** |
| 7 | 28 cases: largest \|Δmired\| 0.0019, \|Δtint\| 0.0047 | 39.75 / 11.58 | 0.1 / 0.3 | **PASS** |
| 8 | Test grid: 0 negative lines (+150…+300 included). Largest a drop **0.0020** (10000/+10 → 3846 K, +120). The clamp-free bands hold (`testTheGuardLeavesOrdinaryWorkUnclamped`). | drop 0.0135 | 0; ≤ 0.003; bands | **PASS** |
| 9 | Preset values exact. Largest ΔE00: Daylight 0.00, Cloudy 0.00, Shade 0.00, Tungsten 0.01, Fluorescent 0.00, Flash 0.00. PresetName tests pass. | 4.25-5.98 | < 0.5 | **PASS** |
| 10 | SliderScaleTests pass. The `SliderDrag.swift` diff against `$BASE` is 0 lines. `BasicPanel.swift:227 scale: .reciprocal`. | — | as stated | **PASS** |
| 11 | `git diff --stat $BASE -- Sources/LumenPipeline` is empty. The grep finds comments only (`AppleRawSource.swift:46-50`, now stale; NEEDS §3). No Kelvin, mired or tint maths in the pipeline or kernels. Every WB number reaches the GPU as the CPU `RenderPlan` matrix. LumenCoreTests pass. | — | empty, comments only | **PASS**. The macOS `gpu-parity.yml` run was not observable here. |
| 12 | Builds. `autowb` prints `{"confidence","kelvin","seconds","tint"}`, and the JSON parses on all 25 corpus frames. The LumenRender diff is the new `AutoWB.swift` plus a 1-line `CLI.swift` case. `estimate` returns an `Estimate` struct rather than a tuple, which is equivalent. The `usage` text does not list `autowb` (minor). | — | builds; parses | **PASS** |
| 13 | IN ΔE00: 1346 1.05, 967 1.77, 983 1.55, 3914 9.63, 864 1.59. **Mean 3.12.** Δmired/Δtint from chart-neutral: 3.9/1.6, 2.9/4.2, 7.4/2.2, 7.5/1.5. | as-shot mean 3.57 | (a), (b) 3.20, (c) | **PASS** (13b margin 0.08) |
| 14 | OUT: 1.68, 2.18, 1.86, 9.59, 3.16. Mean 3.69. | — | each ≤ as-shot+2.5; mean ≤ 4.06 | **PASS** |
| 15 | 6929: −4.4 mired / −1.1 tint. 2545: +0.6 / −0.5. | — | 15 / 10 | **PASS** |
| 16 | skin_tones: +0.38 / +0.04. skin_only: 0.0 / 0.0, chroma kept 1.00, hue 0.0°. | — | as stated | **PASS** |
| 17 | flat_grey: 0.000 / 0.000. 5 runs give 1 distinct result. Median 0.080 s. | — | 0.1; 1; 0.25 s | **PASS** |
| 18 | The grep shows the "Auto" `LumenMenuItem` under As Shot and an Auto button left of the eyedropper with identical modifiers. The stale comment is gone. `presetName` is unchanged, with no Auto title and no recipe field. Every called symbol exists with a matching signature (see "Code review"). | — | grep; diff scope; macOS CI | **PASS on review. Compile unverified** (macOS CI) |
| 19 | All LumenCoreTests pass, as in the table above. Rewritten tests each have a convention-change reason (see "Tests"). | — | pass | **PASS** |

### Line 6 failing tiles (after − baseline, pp highlights / pp shadows)

| Tile | Highlights | Shadows | Note |
|---|---|---|---|
| skin_tones 2000 K | +5.92 | 0 | |
| 6929 2000 K | +0.97 | −11.8 | |
| 3914 2000 K | +0.54 | −3.23 | |
| 3914 2500 K | +0.70 | −0.25 | |
| 864 2000 K | −2.09 | +12.65 | |
| 864 tint −150 | 0 | +15.18 | |
| 864 tint −100 | 0 | +4.97 | |
| 864 tint −50 | 0 | +1.29 | |
| 983 tint −150 | 0 | +18.32 | |
| 2545 tint −150 | 0 | +1.43 | |

- I looked at `983_tint` before and after. At −150 the frame is now a deep green; before it was olive.
  The dark chart and trees crush.
- This follows directly from line 4. The tint axis now has Adobe's strength and direction: whole-frame
  OKLab a at −150 is −0.0725 on 864, against −0.019 before.
- **Inside WS-03's control?** Not without breaking line 4, and the spec writer has to choose. The
  builder's diagonal-adaptation table shows no candidate passes both lines.
- NEEDS §2 points at the downstream sRGB gamut clip. That is consistent with what I see: scene-linear
  negatives are near zero at −150, and the crush comes from output clamping.

## Visual claims

- **V1, PASS.** I regenerated the sheet with the spec command. It is byte-identical to the committed one.
  - −150 reads clearly green, not olive or yellow.
  - +150 reads magenta-pink, not violet. Before, it was blue-violet.
  - +75 skin reads as skin with a pink cast.
  - −75 skin reads olive-khaki. That is still recognisably skin under a green light, but it is the
    borderline case.
- **V2, FAIL as worded.** I regenerated the sheet unquantised at 512 px.
  - The lawn is green, not yellow, at −150. That part passes; it was yellow-olive before.
  - The sky is **teal** at −150 and blue-teal at −75. At +150 it reads violet-purple.
  - The claim "never teal or purple" is not met. The builder measured 184° sky hue at −150.
  - This is very likely unreachable for any WB that matches Adobe's tint strength (line 4), because a
    strong green cast on blue makes cyan. The spec writer should restate this claim.
  - The committed evidence sheet is 256-colour palette-quantised, and the sky posterises. A human
    judging from it sees banding that is not in the render.
- **V3, PASS.**
  - **864:** I cropped the greys at 100 %. Auto is a hair cooler than chart-neutral and nearly
    indistinguishable from it; as-shot is visibly blue.
  - **3914:** Auto ≈ as-shot (confidence 0.11), so it is no bluer or more magenta.
  - **967:** a slight move toward neutral.
  - Nothing in the Auto column looks less natural than as-shot.

## Break attempts

| Attempt | Result |
|---|---|
| CLI extremes on a 0.18 grey: 2000 K, 50000 K, tint ±300, ±1e9 and K = 1 typed (from 5500/+10) | All finite, no crash. Values are clamped to range: 1e9 K renders like 50000, K = 1 like 2000, tint 1e9 like +300. |
| +300 typed at 5500 K | Strongly violet (OKLab a +0.16, b −0.22), no negative channel. |
| As-shot files at 2000 K and 15000 K (synthetic and GX85) | Identity is exact. Retargeting to 5500/+10 works. |
| NaN as-shot (engine level; the CLI rejects "nan") | `WhiteBalanceEngine` falls back to the 5500/0 reference and stays finite. `displayed` shows 5500/0, as-shot. `AutoWhiteBalance.estimate` returns 5500/0 with confidence 0. NaN or ±inf pixels and a 1×1 frame are handled. |
| NaN or inf target | A NaN target is treated as as-shot. An inf target Kelvin clamps to 50000. |
| **Guard for a cool as-shot to a warm target.** `tintLimit(kelvin:asShot:)` goes **negative**: 15000/0 → 2000 K = −13.3, 12000/+10 → 2000 K = −9.3. | By design: everything above the turn renders as the turn. But at 2000 K from a 15000 as-shot, tint +150 renders the same as tint 0, so the whole magenta half is inert. The BasicPanel caption then reads "Magenta is bounded by physics at −13 for 2000 K" even while the slider sits at 0 or slightly green. That wording is odd for a green value (minor UX). This is outside the spec grid (Temp < 2500 K). |
| Real lights the guard makes unreachable | The eyedropper from as-shot 12000/+10 cannot neutralise a 2500/+30, 3000/+60 or 2200/+40 light: residual spread 0.12-0.74. From 9365/+16.4 (frame 864's as-shot), the limit at 2500 K is +25.0. Lights with more than about +25 tint at 2500 K are therefore not reachable from cool as-shots. Line 3's grid stops at +21, so the spec is met. This limitation should be known. |
| Green-side extremes, typed −300 | A negative R channel (down to −0.04 on a 0.18 grey) appears for as-shot 15000/0 or 50000/0 → ≤ 2900 K at tint −300, and as-shot 2000/+150 → any Temp at −300. The guard only bounds magenta. This is outside spec line 8 (which is −150…+300 on its as-shot list), and these are pathological combinations. Minor. |
| OKLab a drop beyond the spec grid (as-shots 15000, 50000, 2000/+150, 5500/−150; tint −300…+300) | At most 0.0020. |
| Eyedropper (`neutralizing`) against the convention | Exact (spread 0) for every light inside the guard. When the solution lies past the as-shot-aware bound, the reported tint exceeds the rendered tint by a small amount (24.50 against 24.40, 16.88 against 16.60). This is NEEDS §1, owned by WS-02; there is no pixel effect. Time per click is 0.26-0.35 s in debug. |
| `presetName` / `displayed` | 5500/+10 gives "Daylight", nil gives "As Shot", 5500/0 gives "Flash", 2850/0 gives "Tungsten", and an Auto-like 5099/+20 gives "Custom". This is correct and unchanged in behaviour. |
| Auto on all 25 corpus frames | No wild answers. Largest moves from as-shot: 864 −8.5 mired, 4213 −7.1 mired, 7301 −6.7 tint. 7 frames return as-shot (confidence 0). 0.075-0.094 s per frame. I rendered as-shot against Auto for 7301, 4213, 3582 and 1332: all natural, small corrections. Auto is conservative; it rarely does harm and rarely does much. |
| Exposure and local mask WB | MaskWhiteBalanceTests 16/16 pass. `LocalWhiteBalance` is not edited. Exposure (`LinearStage`) is not edited, and the S6 fused-matrix and exposure tests pass. |
| Performance of the as-shot-aware bound | 368 uncached `tintLimit(kelvin:asShot:)` calls take 0.31 s in debug, and the result is memoised per (K, as-shot). Acceptable. |
| GPU | No WB maths in `Sources/LumenPipeline` or the kernels. `RenderGraph` and `PipelineRenderer` only pass the as-shot pair into `RenderPlan`/`LocalWhiteBalance` (CPU). There is no CPU/GPU divergence path. |

## Code review (LumenApp, not compilable here)

Every symbol the new code calls was checked against the repo:

| Symbol | Location |
|---|---|
| `primarySelection`, `recipe(for:)`, `statusMessage` | AppState |
| `renderCoordinator` | AppState:1669 |
| `updateRecipe(coalescingKey:label:targets:_:)` | AppState:4204 |
| `PhotoItem.id: URL` | AppState |
| `source(for:)` (private, called on the actor) | RenderCoordinator |
| `ImageSource.nativeLongEdge: Double`, `decode(recipe:draft:scaleFactor:)`, `asShotTemperature`/`asShotTint` | ImageSource protocol |
| `PipelineRenderer.buffer(from:context:)` | public static |
| `CIFormat.RGBAh` as the `.workingFormat` value | same idiom as PipelineRenderer:79 |
| `CGColorSpace.extendedLinearITUR_2020` | CoreGraphics |
| `WhiteBalanceEngine.Neutral(kelvin:tint:)` | WhiteBalanceEngine |
| `.lumenGlyphBody`, `Lumen.controlBackground`, `Lumen.primaryText`, `Lumen.radiusChip` | Lumen style constants |
| `LumenMenuItem(title:symbol:isSelected:action)` (detail defaults to nil) | LumenMenu |
| `state.applyAutoWhiteBalance()` | the new function |

- The Auto button's modifiers are identical to the eyedropper's.
- Deviations from line 18's wording:
  - Auto writes through `state.updateRecipe(label:targets:[primary])`, not `binder.edit("wb.preset")`.
    It is still one undo step, and it deliberately writes only the primary photo, not the selection.
  - The plumbing function is named `solveAutoWhiteBalance`; the spec gave a name only as an example.
  - `boundedTintCaption` (owned by WS-03) is edited too. That is reasonable.

## Ownership

- Edits stay inside the functions WS-03 owns: `ColorTemperature`, the `WhiteBalanceEngine`
  `adaptation`/`effectiveTint`/`presets` docs, and BasicPanel `presetRow`/`boundedTintCaption`.
- The rest is new code: AutoWhiteBalance.swift, AutoWB.swift, the `CLI.swift` dispatch case, and new
  functions in AppState and RenderCoordinator.
- Not touched: `neutralizing` (WS-02), `LinearStage` (WS-04), `LocalWhiteBalance`, LumenPipeline,
  `SliderDrag`, `DNGTemperature`.
- The AppState function is inserted directly after WS-02's `resolvePick` region, but it does not edit it.
- Proof records `raw.temp.json`/`raw.tint.json` were re-recorded. These are data under WS-58's registry,
  and they change because the convention changed.
- `ProofRegistry`'s stale "+156 at 5500 K" comment was correctly left alone.

## Tests changed

All rewritten tests carry a convention-change reason in the diff:

- AccuracyProbe: D65/D50 are now at their Adobe pairs, with the same tolerance.
- ColorScience: the locus check is tightened to 1e-5/1e-4, plus a blackbody cross-check.
- TintGuard `effectiveTint`: now compares against the as-shot-aware clamp, plus a never-looser assert.
- HuePreservation:
  - The pinned +152.22 margin is restated as the spec band.
  - 4000 K and 5000 K are dropped from the "still bounded" list, with 3800 K added. On the DNG axis their
    illuminant bounds are +153 and +229.
- **One loosening:** HuePreservation's tint-monotone assertion moves from strict (1e-9) to "running
  maximum − 0.002". That is within SPEC 8's 0.003 and justified there, so I accept it.
- Nothing was skipped or disabled. The 6 skips are the same on the base.

## Builder's claims compared with mine

- Every number in BUILD-NOTES matches mine to the printed precision: lines 1-17 and 19, the line 6 tile
  list, the 3059/3044 test counts and ControlProofTests 6/6.
- **V2:** the builder leaves the −150 sky to human judgement ("cyan-blue, 184°"). I judge it teal, so V2
  fails as written. The builder's claim that the sky is less teal and less purple than before holds.
- **Process:** the spec and lane brief ask the builder to record numbers in `REPORT.md`. The builder
  wrote `BUILD-NOTES.md` instead, and no REPORT.md exists.
- **Not stated by the builder:** the negative-limit and "unreachable light" behaviour of the as-shot-aware
  guard (above), and the negative channels at −300 typed with extreme as-shots.

## What a FAIL needs

- **Line 6:** the spec owner or D9 decides line 4 against line 6. One option is to exempt −150…−50 tint
  and 2000 K from line 6. The other is to route NEEDS §2 (gamut compression) to WS-12/13. A WS-03 build
  round cannot fix it under the current spec.
- **V2:** restate the claim ("sky turns cyan at −150, as Adobe's model does"), or accept it as failed.
  Separately, re-export the evidence sheet without palette quantisation, for example as a crop under
  400 KB.
- **Optional for the builder:** make the caption wording sign-aware for negative bounds.
