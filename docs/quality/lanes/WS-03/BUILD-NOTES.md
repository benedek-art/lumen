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
| 13 | (round 3) IN ΔE00: 1346 1.15, 967 1.83, 983 1.75, 3914 9.72, 864 1.26. Mean **3.14** (≤ 3.20). \|Δmired\| / \|Δtint\| vs chart-neutral: 6.0/1.8, 3.3/4.2, 8.4/2.8, 6.2/0.9. Round 2 was mean 3.03, round 1 3.12. | `python3 $T/auto_eval.py` | pass |
| 14 | (round 3) OUT ΔE00: 3.53, 2.29, 2.02, 9.71, 0.49. Mean **3.61** (allowed 4.07). Each frame ≤ as-shot + 2.5 (1346: 3.53 against a limit of 3.71). | same | pass |
| 15 | (round 3) 6929: −7.8 mired / −1.5 tint. 2545: 0.0 / 0.0. | same | pass |
| 16 | (round 3) skin_tones: 0.00 / 0.00. skin_only: 0.0 / 0.0, chroma kept 1.00, max \|Δhue\| 0.0°. | same | pass |
| 17 | flat_grey at 4000/+5: 0.000 / 0.000. 5 runs give 1 distinct result. Median time **0.137 s** on 6929 (round 3). | same | pass |
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

  Against the V2 wording ("the sky stays blue, turning greener or pinker but never teal or purple, and
  the lawn is never yellow at −150"), the measurements say:
  - The lawn claim holds: 130° at −150 is green, not yellow (before: 104°).
  - The sky claim does **not** hold literally. At −150 the sky is 184°, which is cyan/teal (before: 167°,
    more teal). At +150 it is 296°, which is purple-magenta (before: 304°, more purple). Both ends moved
    toward the claim, but neither end meets it.
  - The cause is the isotherm tint axis itself, which line 4 pins to the Adobe model: a green
    adaptation of a blue sky is cyan, and a magenta one is purple.
  - Round 3 re-exported the sheet without palette quantisation: the same sweep, resized to 1200 px wide
    (337 KB), so the sky no longer posterises.
- **V3** `after_auto_charts.png` (regenerated in round 3; unquantised at 45 % scale to stay under 400 KB.
  The numbers below are round 2's; round 3's are in the round 3 table.)
  - 864: Auto (10379/+12.0) is close to chart-neutral (11024/+11.2). The greys match closely but not
    indistinguishably: Auto is 5.6 mired (about 645 K) warmer than chart-neutral.
  - 3914: Auto ≈ as-shot (confidence 0.12), so it is no bluer than as-shot.
  - 967: Auto is slightly warmer than as-shot, toward neutral.

## Round 3: cast recovery (verifier round 2 finding)

**The defect.** The round-2 estimator searched a window around the camera's as-shot, and its prior
scaled the move down with distance. A frame decoded at a wrong as-shot came back as-shot once the cast
passed about 25 mired. On the synthetic ColorChecker it recovered 67–106 % of a ±20-mired cast and
0–5 % beyond ±30.

**The rewrite (`AutoWhiteBalance.swift`; only `estimate`'s internals and the private helpers changed,
the API is the same):**
- **Cast-invariant features.** Pixels are measured as (ln L/M, ln S/M) in CAT16 cone space, relative to
  the working white. The engine's WB is a von Kries step in that space, so a wrong as-shot translates
  every pixel by one vector. Luminance weights use cone M, so a cast scales them all by one constant and
  their ranking does not change.
- **Search over absolute lights.** Candidates are Adobe/DNG Temp 1667–50000 K (mired 20…600 in 2) ×
  tint −50…+60 (in 2), 16 236 of them. Each is read off a 400×400 luminance histogram of the features,
  box-summed over a 0.02 radius. The 12 strongest local maxima are evaluated in full.
- **What each candidate is scored on**, after correcting by it:
  - near-neutral luminance share (radius 0.02);
  - grey ladder: the luminance span of those pixels, no credit below 0.3 stops, full credit from 1.0;
  - white-patch agreement: the brightest 2 % by cone M should be near neutral (1/e at 0.25);
  - 1 − skin share. **The skin wedge is defined in the corrected space** (Monk 1–10 and ColorChecker
    skins: ln L/M 0…0.2, ln S/M −0.06…−0.75), so a tungsten cast does not turn the scene into "skin".
- **The answer** is the best candidate's blend, near-neutral : white-patch : grey-world = 1 : 0.1 : 0.05
  in the corrected space. Evidence is smoothstep(0.02, 0.06) of the score; below it the frame stays at
  as-shot.
- **Ambiguity band (the one non-invariant term).** If the answer moves the light 20–50 mired from the
  as-shot, the move is cut to 40 %. It ramps in over 8–20 mired and out over 50–80. Below 8 and above
  80 mired the evidence is trusted fully. Why this term exists is explained below.

**Cast recovery.** `python3 $T/cast_recovery.py` runs `lumen-render autowb` on frames re-adapted with the
engine's own matrix (`D' = adapt(A' → A)·D`, the decode at the wrong as-shot A'). The reference is Auto's
uncast answer. 12 frames × 14 casts, 163 valid cells:

| cast band | pass (\|res\| ≤ 15 mired and ≤ 8 tint) | median recovered |
|---|---|---|
| −150, −100 mired (orange: a tungsten frame on Daylight) | 10/19 | 100 % |
| −50, −25 | 7/24 | 42 % |
| −10, +10 | 24/24 | 70 % (residual ≤ 4 mired) |
| +25, +50 | 3/24 | 38 % |
| +100, +150 (blue) | 14/24 | 99 % |
| tint ±20 | 16/24 | — |

Per frame:
- **Full recovery at ±100/±150 and tint ±20:** 1346, 967, 983, 4213, 1332, the synthetic ColorChecker,
  and 864 (+100/+150; its −100/−150 casts fall outside 2000–50000 K and are skipped). The
  `after_auto_cast_recovery.png` sheet shows 1332 at −100, 4213 at +100 and 1346 at −150: Auto lands
  within 0.3 mired of its uncast answer.
- **Partial on 6929** (about 80 %), 3582 (40–95 %) and 7881 (about 15 %). Their best neutral evidence
  sits between the 0.02 and 0.06 quality thresholds, so the confidence blend toward as-shot shows.
- **None on 2545 and the synthetic skin_tones.**
  - 2545 has no neutral that passes. Its candidate cluster is the dry lawn, which falls in the skin wedge.
  - skin_tones' only neutral is a perfectly uniform synthetic grey, which has no luminance span, so the
    ladder gives it no credit. The same rule is what keeps skin_only (uniform skin patches) from being
    greyed. A real grey card has shading and noise; a synthetic one does not.

**Why the 20–50-mired band is cut (an honest conflict).** Within that band, a near-white surface and a
camera error produce the same pixels, and the SPEC line 14 chart-OUT runs are exactly that case:
- 1346 without its chart sees a warm white plate. Fully trusted, Auto moves 26 mired and the chart greys
  go to ΔE 6.47 (the limit is 3.71).
- 864 without its card sees the blue cloth, a 47-mired move. With it, the OUT mean is 5.19 against 4.07.

Measured on the Python mirror of this exact estimator (`scratchpad/proto/awb4.py`, which reproduces the
Swift answers to the printed digit):
- **Without the band:** lines 13 and 15–17 pass and 864 IN reaches −309 K, but line 14 fails, and
  cast misses drop from 78 to 50 of 150 cells (the mirror's harness applies the cast after the proxy, so its
  cell count differs from the Swift run's 163). Every 25–50 mired cast on the chart frames is then recovered.
- **With the band (shipped):** line 14 passes, but 25–50 mired casts are recovered only about 40 %.

Passing the spec's line 14 wins, so the band ships. Removing it is a one-constant change
(`ambiguity.cut = 0`) if the lead prefers recovery over chart-OUT.

**Owner bar (300 K and 8 tint of chart-neutral, chart IN):**

| frame | Auto | chart-neutral | ΔK | Δtint |
|---|---|---|---|---|
| 1346 | 5281/−9.4 | 5454/−7.6 | −173 ✓ | −1.8 ✓ |
| 967 | 4816/+11.3 | 4740/+15.5 | +76 ✓ | −4.2 ✓ |
| 983 | 5161/+15.9 | 4947/+13.1 | +214 ✓ | +2.8 ✓ |
| 864 | 10316/+12.0 | 11024/+11.2 | −708 ✗ | +0.9 ✓ |
| 3914 | 4684/+47.4 | 5456/+32.2 | −772 ✗ | +15.2 ✗ |

- **864:** the ambiguity band is the reason; without it 864 lands at −309 K.
- **3914:** still unreachable for the round 2 reasons. Its chart greys are 3.4 % of the luminance, and the
  bark candidate scores higher.

**All 25 frames** (`scratchpad/build/all25_r3.json` against `all25_r2.json`). Biggest movers from
as-shot:
- 832: +24.2 mired, 3009 → 2804 K;
- 3582: +23.1, 3035 → 2836;
- 6001: −14.4 mired / −10.9 tint;
- 8559: −12.0;
- 2348: +11.1.

Four frames changed by more than 10 mired against round 2: 832, 3582, 6001 and 2348. I rendered the top
three as-shot | Auto and looked at them (`scratchpad/proto/movers.png`), and each move is plausible:
- 832: the beige wallpaper wall goes from warm to near-grey;
- 3582: the white curtain goes from cream to near-white;
- 6001: the garden loses a green-yellow cast, and the white flowers read white.

Eight frames return as-shot (no credible neutral).

**Other round 3 items**
- **Tests:** the new `AutoWhiteBalanceTests.testAWrongAsShotIsRecovered` covers ±100/±150 mired, tint
  ±20 and a diagonal cast on a synthetic grey-ladder scene, each within 15 mired / 8 tint of the uncast
  answer. The comment in the round-1 Auto test about the warm-cast skin limit is removed, because the
  skin wedge is now relative to the candidate.
- **Tool:** new `tools/cast_recovery.py`.
- **Evidence:**
  - new `after_auto_cast_recovery.png` (333 KB);
  - `after_auto_charts.png` regenerated unquantised;
  - `after_tint_2545_gx85.png` re-exported unquantised at 1200 px (337 KB).

  That makes 8 files in `evidence/`.
- **Gates (round 3):**
  - LumenCoreTests, all classes except ControlProofTests (debug): 3060 executed, 0 failures, 6 skipped.
  - ControlProofTests (release test build): 6/6 pass.
  - `swift build --target LumenCore --target LumenRender` is clean.
  - `auto_eval.py` passes every check.

## Round 2: the owner's Auto bar (within 300 K and a small tint of chart-neutral)

Change: the as-shot prior's 1/e distance (`AutoWhiteBalance.priorScale`) goes from 0.15 to 0.25 ln-chroma,
so a well-supported near-neutral cluster is trusted further from the as-shot. Nothing else changed. There
is no frame-specific code and no chart rectangle in the estimator.

Chart IN, autowb vs chart-neutral (Adobe numbers from `charts.py`):

| frame | Auto | chart-neutral | ΔK | Δtint | ΔE00 | round 1 ΔK |
|---|---|---|---|---|---|---|
| 1346 | 5340/−6.0 | 5454/−7.6 | −114 | +1.5 | 1.05 | −113 |
| 967 | 4806/+11.4 | 4740/+15.5 | +66 | −4.2 | 1.76 | +66 |
| 983 | 5135/+15.4 | 4947/+13.1 | +188 | +2.2 | 1.55 | +188 |
| 864 | 10379/+12.0 | 11024/+11.2 | **−645** | +0.8 | 1.15 | −845 |
| 3914 | 4714/+48.1 | 5456/+32.2 | **−742** | **+16.0** | 9.63 | −742 |

**The 300 K bar is met on 1346, 967 and 983, and not on 864 or 3914.** I stopped here because neither of
the remaining two can be reached honestly. Measured reasons:

- **864.** 300 K at 11 000 K is only 2.5 mired, about 0.02 in ln B/G. The near-neutral surfaces of the
  frame are two clusters, luminance-weighted (`scratchpad/proto/ladder.py`):
  - the printed card's paper and white border at ln B/G ≈ 0.075;
  - its grey steps at ≈ 0.10, which is where chart-neutral sits.

  Any near-neutral estimator averages the two. Even at full confidence and with no white-patch or
  grey-world blend, it lands near 10 600 K (about −450 K). Choosing the steps over the paper would mean
  knowing which is the chart. The audit already flags this card's inks as possibly non-neutral.
  Luminance-weight variants (Y, √Y, count) moved 864 by at most ±60 K and made 967 worse.
- **3914.** The chart greys are a real cluster (3.4 % of luminance) at Δ(ln R/G, ln B/G) = (−0.02, +0.32)
  from the as-shot, the decode's B/G of 1.38. A rule that would pick that cluster over the scene also
  picks the dense near-neutral clusters that the chart-OUT runs must ignore:
  - 1346's cool background: 16 % of luminance at (+0.02, −0.16);
  - 864's blue cloth: 30 % at (−0.02, +0.26).

  Each of those is closer to as-shot and holds more luminance than 3914's greys, and taking either
  breaks line 14 (1346 OUT ΔE 6.44 at full trust). A grey-ladder test (one chromaticity spanning many
  luminance levels) does not separate them either: 3914-IN greys span 3.9 stops, 1346-OUT's background
  3.0 and 3914-OUT's bark 3.0. 3914's as-shot is itself the outlier (AUDIT finding 7, SPEC N1).

**All 25 corpus frames, before (round 1) and after.** Data: `scratchpad/build/all25_r1.json` and
`all25_r2.json`. The largest move from as-shot is 10.4 mired (864, was 8.5). The next largest are 4213
(−7.7) and 1332 (−5.5). No frame's answer changed by more than 10 mired between rounds; the largest
change is 864 at −1.9 mired, and every other frame is within 1 mired / 1.3 tint. So there was no changed
frame to re-inspect. Eight frames return as-shot (confidence ≤ 0.01).

Also in round 2:
- `boundedTintCaption`: when the as-shot-aware bound is ≤ 0 (a cool as-shot taken very warm), the caption
  now reads "No magenta is available at N K from this file's as-shot neutral — the render holds tint at
  X and stops there". Before, it said "bounded by physics at −13" with the slider at 0.
- `lumen-render` usage text (`CLI.swift` `usage`) and the `main.swift` manual header now list `autowb`.
  This was requested by the lane lead, so LumenRender's existing code now has two edited spots instead
  of the single dispatch case line 12 describes.
- Gates re-run: build clean; `AutoWhiteBalanceTests` 6/6; `auto_eval.py` all PASS (numbers in the table
  at the top).

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
