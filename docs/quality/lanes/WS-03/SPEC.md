# WS-03 White balance: acceptance spec

Inputs: `AUDIT.md`, `charts.json`, the lane lead's decisions A-D. The builder makes every line PASS and
records the measured number in `REPORT.md`. **Before** values were measured on the pre-WS-03 binary
(commit 84bcd7c, `.build/x86_64-unknown-linux-gnu/release/lumen-render`). Run every command from the repo
root after `export PATH=/opt/swift/usr/bin:$PATH; swift build -c release --product lumen-render`.
`T=docs/quality/lanes/WS-03/tools`. `BASE=claude/inspiring-dirac-ulgpch`.

**Convention used everywhere below.** Temp/Tint means the Adobe/DNG SDK pair: Robertson isotemperature
lines in CIE 1960 uv, tint is the offset along the isotherm, and kTintScale is -3000. This is
`DNGTemperature.chromaticity`, used for both the target and the as-shot pair. "Grey ΔE00" is CIEDE2000
against the neutral of the same L*. The 2400 px chart frames and rectangles are in `charts.json`, and the
whole-chart masks are in `tools/charts.py: CHART_MASK`.

## Measurable lines

| # | Claim | Threshold | Command | Before |
|---|---|---|---|---|
| 1 | **Identity.** Setting Temp/Tint to exactly the sidecar as-shot pair renders byte-identically to leaving them unset, on 8 frames (flat_grey, skin_tones, 6929, 2545, 1346, 983, 3914, 864). `displayed` written back still changes no pixel. | `cmp` identical on 8/8; tests pass | `python3 $T/identity.py`; `swift test --filter testTheTempRowShowsTheNeutralTheRenderAdaptsFrom` | 8/8 identical |
| 2 | **One convention.** Below the magenta guard, `ColorTemperature.chromaticity(kelvin:tint:)` equals `DNGTemperature.chromaticity` for both target and as-shot. Round trip `DNGTemperature.temperatureAndTint(chromaticity(K,t))` returns (K,t). | xy within 1e-9 over 2000-50000 K (5-mired steps) × tint -150…+150; round trip within 0.01 mired and 0.01 tint | new `swift test --filter WhiteBalanceConventionTests` | max xy difference 0.102 (11111 K, +150); Lumen 5500/+10 = Adobe 5309/+17.0 |
| 3 | **Kelvin accuracy.** A 0.18 grey lit by illuminant L and decoded at as-shot A, rendered with Temp/Tint = L's Adobe numbers, comes out neutral. Grid: 10 as-shots (incl. 4708/+48.2, 9365/+16.4, 5500/-15) × K {2500…15000} × tint {-20,-10,0,+10,+21} = 500 pairs. | display grey ΔE00 < 0.5 on every pair | `python3 $T/kelvin_grid.py` | median 2.47, p90 5.40, max 9.29 |
| 4 | **Tint direction.** At as-shot 6504/+9.77, 5500/+10, 3200/0 and 2850/0, a tint move with Temp at as-shot has the display OKLab hue and chroma of the Adobe-model prediction (the predicted pixel rendered through the same pipeline). | \|Δhue\| ≤ 3°, \|C ratio − 1\| ≤ 0.10, all 21 cases | `python3 $T/tint_axis.py` | max \|Δhue\| 38.8°, C ratio up to 2.07. At 6504/+9.77: +75 is 291.0° (Adobe 325.7°) and −75 is 116.4° (Adobe 152.6°) |
| 5 | **Monotone sweeps.** On the 8 frames, whole-frame display OKLab b does not fall as Temp rises over 2500…50000, and a does not fall as Tint rises over −150…+150 (Temp at as-shot). | no step falls by more than 5e-4 | `python3 $T/sweeps.py --out /tmp/ws03_after` | PASS. The excluded 2000 K tile reverses on 3914 by 0.0052 (note N3) |
| 6 | **No new clipping.** Each sweep tile of line 5, *including 2000 K*, is compared with the same value in `tools/baseline_sweeps.json`. | highlightsPct.any ≤ before + 0.5 pp; shadowsPct.any ≤ before + 1.0 pp | same run as line 5 | baseline. Worst cases: 3914 @2000 K crush 68.2 %, 6929 @2000 K crush 58.4 %, 864 @2000 K highlights 3.31 %, 1346 tint +150 highlights 1.81 % |
| 7 | **Eyedropper round trip.** `WhiteBalanceEngine.neutralizing` clicked on that grey returns L's Adobe numbers. 4 as-shots {6504/+9.77, 5000/+5, 3000/0, 4708/+48.2} × 7 illuminants {2856/0, 3800/+21, 4000/0, 5002/+9.6, 6504/+9.8, 7506/+9.6, 9992/+9.3}. | \|Δmired\| ≤ 0.1 (≈ 3 K at 5500 K), \|Δtint\| ≤ 0.3 | new `swift test --filter WhiteBalanceConventionTests/testTheEyedropperReturnsTheIlluminantsAdobeNumbers` | max 39.75 mired, 11.58 tint (`python3 $T/eyedropper_before.py`). CIE A at as-shot D65 gives 2844/+4.0 |
| 8 | **Magenta guard, no inversion.** As-shot {2500/0, 2850/0, 3200/0, 4000/+5, 4708/+48.2, 5000/+8, 5500/+10, 6504/+9.77, 7500/+10, 9365/+16.4, 10000/+10, 12000/+10, 5500/−20} × Temp 2000…50000 (20-mired steps) × Tint −150…+150 (step 2.5). A 0.18 grey through `WhiteBalanceEngine(...).matrix` never goes negative, and its OKLab a never falls more than 0.003 below its running maximum as Tint rises. +150…+300 (hard range) never gives a negative channel. The guard does not clamp ordinary work: with any as-shot from line 3, there is no clamp at Tint ≤ +25 for Temp ≥ 2500 K. With as-shot 5500/+10, there is none at +150 for Temp ≥ 4500 K. | 0 negative lines; max a drop ≤ 0.003; clamp-free bands as stated | `swift test --filter TintGuardTests` (new `testNoInversionAcrossAsShotAndTargetGrid`, same grid as `guard_grid.py`) | old model: 0 negative, max drop 0.0135 (12000/+10 → 2000 K at +5) (`python3 $T/guard_grid.py old`). A naive port fails: 1 negative, drop 0.0145 (`… naive`) |
| 9 | **Presets.** `WhiteBalanceEngine.presets` stays exactly Daylight 5500/+10, Cloudy 6500/+10, Shade 7500/+10, Tungsten 2850/0, Fluorescent 3800/+21, Flash 5500/0, now meaning Adobe light. Each preset neutralises the grey of its own Adobe illuminant from every as-shot of line 3. | values exact; max ΔE00 < 0.5 per preset; preset-name tests pass | `python3 $T/kelvin_grid.py` (presets row); `swift test --filter WhiteBalancePresetNameTests` | max ΔE00: Daylight 4.83, Cloudy 4.87, Shade 4.89, Tungsten 5.84, Fluorescent 4.25, Flash 5.98 |
| 10 | **Temp travel unchanged (decision B).** Mired-linear, K(p) = 1e6/(500 − 480p): 0 % → 2000, 25 % → 2632, 50 % → 3846, 75 % → 7143, 100 % → 50000. That is a constant 4.8 mired per 1 % of travel, so it is monotone and even in mired. | tests pass unchanged; `SliderDrag.swift` diff empty; Temp row still `.reciprocal` | `swift test --filter SliderScaleTests`; `git diff $BASE -- Sources/LumenCore/Interaction/SliderDrag.swift`; `grep -n reciprocal Sources/LumenApp/BasicPanel.swift` | PASS |
| 11 | **GPU parity without kernel change.** WB reaches the GPU only as the CPU-built `plan.linear.matrix` (`RenderGraph.swift:210`) and the `LocalWhiteBalance` matrices. | empty pipeline diff; grep shows no WB maths in LumenPipeline; LumenCoreTests pass | `git diff --stat $BASE -- Sources/LumenPipeline` (empty); `grep -rn "ColorTemperature\|DNGTemperature\|AutoWhiteBalance\|adaptation(" Sources/LumenPipeline` (comments only); `swift test --filter LumenCoreTests`. Paste the output into REPORT. macOS `gpu-parity.yml` must stay green | n/a |
| 12 | **Auto API.** A new file `Sources/LumenCore/Engine/AutoWhiteBalance.swift` defines `public enum AutoWhiteBalance` with `estimate(_ image: ImageBuffer, asShot: WhiteBalanceEngine.Neutral, excluding: [rects] = []) -> (kelvin, tint, confidence)`. Input is the scene-linear Rec.2020 decode at camera-reference WB. Output is in line 2's convention. It combines grey-world, a bright-but-unclipped white patch and a near-neutral (grey-edge / gamut-constrained) estimate. Skin-wedge pixels are down-weighted, and when confidence is low the result falls back toward as-shot. A new `lumen-render autowb` subcommand prints `{"kelvin","tint","confidence","seconds"}` (contract in `tools/auto_eval.py`). The only edit to existing code is the dispatch `case` in `CLI.swift`. | builds; the JSON parses | `swift build --target LumenCore --target LumenRender`; `git diff $BASE -- Sources/LumenRender` | none |
| 13 | **Auto accuracy, chart IN.** Chart-neutral in Adobe numbers (from `charts.py`): 1346 5454/−7.6, 967 4740/+15.5, 983 4947/+13.1, 3914 5456/+32.2, 864 11024/+11.2. | (a) each frame's grey ΔE00 ≤ max(2.0, as-shot + 0.3); (b) mean over 5 ≤ 3.20; (c) \|Δmired\| ≤ 12 and \|Δtint\| ≤ 8 vs chart-neutral on 1346, 967, 983, 864 | `python3 $T/auto_eval.py` | no Auto. As-shot ΔE00 1.21 / 2.10 / 1.26 / 9.68 / 3.57 (mean 3.57). Grey-world 3.91 / 3.92 / 5.29 / 15.65 / 2.88; white-patch 2.77 / 4.18 / 0.82 / 14.62 / 2.57 |
| 14 | **Auto, chart OUT** (`--exclude CHART_MASK`): it must do no harm. | each frame ≤ as-shot + 2.5; mean ≤ as-shot mean + 0.5 (4.06) | `python3 $T/auto_eval.py` | as above |
| 15 | **No wild swings** on ordinary daylight frames 6929 (A7 IV) and 2545 (GX85). | \|Δmired\| ≤ 15 and \|Δtint\| ≤ 10 vs as-shot | `python3 $T/auto_eval.py` | n/a |
| 16 | **Skin-safe.** (a) skin_tones (0.18 grey background) stays at as-shot. (b) skin_only (MST 2-8 + both ColorChecker skins, no neutral, generated by the tool) is not greyed: mean skin OKLab chroma after Auto ≥ 0.80 × as-shot, and the hue of patches with C ≥ 0.03 moves ≤ 8°. | (a) \|Δmired\|, \|Δtint\| ≤ 3; (b) ≤ 12 mired, ≤ 6 tint, chroma ≥ 0.80, hue ≤ 8° | `python3 $T/auto_eval.py` | n/a. A grey-world-weighted prototype gave 24 mired / 0.74 chroma (N4) |
| 17 | **Sane and fast.** (a) A perfectly neutral frame (flat_grey at as-shot 4000/+5) returns the as-shot pair. (b) 5 runs give bit-identical results. (c) Median `seconds` on 6929 (2400×1600, Linux release) is within budget. | (a) ≤ 0.1 mired and ≤ 0.1 tint; (b) 1 distinct result; (c) ≤ 0.25 s | `python3 $T/auto_eval.py` | n/a |
| 18 | **Auto UI.** `BasicPanel.presetRow` gets an "Auto" `LumenMenuItem` under "As Shot", and an Auto button left of the eyedropper with the eyedropper's exact style. The stale "There is no Auto entry" comment goes. One `binder.edit("wb.preset")` writes ordinary temp/tint, so it is one undo step. `presetName` is unchanged: after Auto the title reads "Custom", or a preset name if the pair matches one. There is no "Auto" title and no recipe-schema field (N7). Plumbing is new functions only, e.g. `RenderCoordinator.autoWhiteBalance(url:recipe:)` on the decoded camera-reference frame downsampled to ≤ 1024 px. | grep shows the items; app diff touches only `presetRow` plus new functions | `grep -n "Auto" Sources/LumenApp/BasicPanel.swift`; `git diff $BASE -- Sources/LumenApp Sources/LumenPipeline`; macOS CI build | no Auto |
| 19 | **Tests.** Tests that pinned the old locus or guard are rewritten in the same commit, with the reason in REPORT. Candidates: `ColorScienceTests` locus/round-trip, `TintGuardTests` pinned limits such as +152.22 at 5500 K, `EngineMathFixtureTests`, `AuditWhiteBalancePickerTests`. Nothing is skipped or loosened beyond this spec. | LumenCoreTests pass, or failures are proven pre-existing on `$BASE` | `swift test --filter LumenCoreTests` | not run by spec writer |

## Visual claims (human judges; sheets ≤ 400 KB in `evidence/`)

- **V1** `evidence/after_tint_axis_skin_tones.png` against `before_tint_axis_skin_tones.png`. Made with
  `lumen-render sweep --input corpus/synthetic/skin_tones.lfi --as-shot-kelvin 6503.7072 --as-shot-tint 9.77 --set develop.raw.temp=6503.7072 --key develop.raw.tint --values -150,-75,0,9.77,75,150 --long-edge 256 --columns 6 --out …`.
  −150 reads green, not olive or yellow. +150 reads magenta-pink, not violet. Skin at ±75 still reads as skin.
- **V2** `evidence/after_tint_2545_gx85.png` against `before_tint_2545_gx85.png` (same command on
  `corpus/lfi/2545_panasonic-dmc-gx85.lfi`, as-shot 4711.419/0.4589, values -150,-75,0,0.4589,75,150).
  Across the sweep the sky stays blue, turning greener or pinker but never teal or purple, and the lawn
  is never yellow at −150.
- **V3** `evidence/after_auto_charts.png` (`python3 $T/auto_eval.py --sheet docs/quality/lanes/WS-03/evidence/after_auto_charts.png`).
  Columns are as-shot | Auto | chart-neutral; rows are 3914, 864, 967. On 864 the Auto greys are
  indistinguishable from chart-neutral. On 3914 Auto is no bluer or more magenta than as-shot. Nothing
  in the Auto column looks less natural than as-shot.

## Spec notes (where I adjusted or qualified the lead's decisions, with numbers)

- **N1, the D tolerance as 300 K.** I measure Kelvin in mired, because 300 K is 12 mired at 5000 K but
  only 2.5 mired at 11024 K (frame 864). ±300 K or ±8 tint on its own still leaves grey ΔE00 at about
  2.2-3.3 (`charts.py` sensitivity), so the ΔE00 lines 13a and 13b are the binding ones. 3914 is exempt
  from 13c: its as-shot is already 29 mired / 16 tint off the chart (corpus decode, per the audit).
  For it, 13a only requires "no worse than as-shot".
- **N2, the guard has to know the as-shot.** Porting the current guard onto the DNG axis gives limits of
  +3.3 at 2000 K, +54 at 2850 K and +141 at 4000 K. It still measures against a fixed 5500/0, so line 8
  fails at 0.0145 when the as-shot is cool (≥ 9000 K) and the target is warm. `adaptation` has both pairs,
  so the bound can use them. `neutralizing` (WS-02) reports `clampedTint(kelvin:)`. If an as-shot-aware
  bound makes that report differ from the rendered tint, the builder writes `NEEDS.md` and does not edit
  `neutralizing`.
- **N3, the 2000 K cliff is out of scope for monotonicity.** From 2500 to 2000 K, shadow crush jumps
  0.6 → 68 % on 3914 and 0.02 → 58 % on 6929, and b turns round on 3914. The cause is CAT16's negative
  lobes (off-diagonal −0.40 for 4987 → 2000 K) plus the display clamp. That is present before and after,
  and it is downstream of WS-03's maths. Line 6 still forbids making it worse. It is a NEEDS candidate,
  along with the audit's 4d (lightness moves with WB).
- **N4, feasibility.** I wrote a roughly 60-line Python prototype: grey-world + white-patch + iterative
  near-neutral, skin wedge excluded, confidence = estimator agreement × near-neutral fraction × (1 −
  skin fraction). It passes 13a, 13c and 14-17, and gets mean IN 3.27 against the required 3.20. A
  version without the skin and agreement terms failed 16 (24 mired, 0.74 chroma) and 3914 (11.0). So the
  thresholds are reachable, and they are not trivial.
- **N5.** Masks (`LocalWhiteBalance`, not WS-03's) take on the convention through `WhiteBalanceEngine`.
  `MaskWhiteBalanceTests` must stay green, and `LocalWhiteBalance` is not edited.
- **N6.** Decision A holds. Under the DNG convention, line 3 and line 7 are exact by construction:
  diagonal CAT16 steps compose. The as-shot identity short-circuit is kept.
- **N7, no "Auto" title.** Showing "Auto" in the menu title would need a recipe field, or app-side
  state that goes stale on re-decode and undo. Auto therefore writes ordinary numbers, the same way the
  presets do.
