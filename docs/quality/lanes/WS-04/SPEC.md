# WS-04 Exposure & S6 fused matrix: acceptance spec

Source: `AUDIT.md` (same folder) and the harness outputs in `audit/`. Owned code:
`ToneEngine.exposureGain`, `LinearStage`, `RG.applyMatrix`, the RP `---- S6` block, and the
Exposure literal in `BasicPanel.toneRows`. No line may need an edit outside those.

**How it is measured.** Every `T-` test lives in **`Tests/LumenCoreTests/ExposureQualityTests.swift`**
(`final class ExposureQualityTests`), unless the line names another file. Run it with:

```
bash /tmp/claude-0/runtests.sh ExposureQualityTests /tmp/claude-0/ws04.log   # builds (transient LumenApp patch)
.build/x86_64-unknown-linux-gnu/debug/LumenPackageTests.xctest LumenCoreTests.ExposureQualityTests
```

**Probe conventions** (copied from `audit/harness_main.swift.txt`):
- `RenderPlan(recipe:, asShotKelvin: 6503.7072, asShotTint: 9.77, lutSize: 33)` followed by
  `ReferenceRenderer.render` on a 1-row `ImageBuffer`.
- A "code" is the pre-rounding sRGB value: Rec.2020 → sRGB matrix, clamp to [0, 1], sRGB
  encode, ×255. There is no dither.
- "exact" means `RenderPlan.exactColor`.

Owner `B` is the WS-04 builder, `V` is the verifier, and `H` is a human.

## 1. Core contract (gating)

| # | Claim | Threshold | Measured by | Owner |
|---|---|---|---|---|
| 1 | The S6 matrix is exactly `2^EV · M(0)` for EV ∈ {±10, ±5, ±3, ±1, 2}, WB as-shot / 3200 K / 9000 K, and Printer Lights r = 0 and r = +3 / b = −3. | max rel err of every element = **0** (≤ 1e-15) | `testS6MatrixIsExactPowerOfTwoGain` | B |
| 2 | `LinearStage.apply` is exactly 2^EV on scene values v ∈ ±{1e-4, 1e-3, 0.18, 1, 5.76, 64, 1000, 6e4}, on 0, and on mixed-sign triplets (v, 0.5v, −0.3v). Applies wherever \|v·2^EV\| ≤ 65504. | rel err ≤ 1e-12; sign kept, so negatives are not clamped | `testS6GainExactAcrossRangeAndSigns` | B |
| 3 | Pure-gain equivalence: `render(R + EV k, x) == render(R, 2^k·x)`. Inputs: the audit's 403-pixel ramp (±10 EV; neutral, blue, warm and red pixels; negatives; (100, 90, 80)). k ∈ {−2, +1, +3}. R ∈ {default, tone stack C40/H−60/S50/W30/B−20, zones, sat 40 / vib 30, grade wheels, Punchy, Linear, vignette −50, clarity 40 + dehaze 30, Film Lab portra400, WB 4200 K / +8}. | max \|code diff\| = **0.000** (≤ 1e-9) on every recipe | `testExposureIsPureSceneGainAcrossRecipes` | B |
| 4 | EV 0 is the identity. `ToneEngine.exposureGain == 1` exactly for 0 and −0, the default plan's `linear.isIdentity` is true, and the rendered PNG with no key, with `exposure=0` and with `exposure=-0.0` is the same file. | bit-equal buffers; `cmp` reports no difference | `testEVZeroIsBitExactIdentity` (buffers); CLI: run `lumen-render render --input corpus/lfi/6929_sony-ilce-7m4.lfi --long-edge 1024` three times (no key, `--set develop.tone.exposure=0`, `=-0.0`), then `cmp` the outputs | B, V |
| 5 | Mid-grey 0.18 at EV 0 renders code **117.65**. | within ±0.5, so 117.15…118.15 | `testMidGreyPlacementAtEVZero` | B |
| 6 | Grey ladder: 0.18 at EV k ∈ −3…+3, through LUT33. Audited codes: 20.32, 41.29, 72.72, 117.65, 168.74, 207.17, 234.51. Also `code(0.18 @ EV k) == code(0.18·2^k @ EV 0)`. | each within ±0.5 of the audited code; equality ≤ 1e-9 | `testMidGreyLadderMinus3ToPlus3` | B |
| 6a | The same ladder through the exact path. Audited codes: 20.32, 39.44, 70.41, 117.65, 168.58, 207.45, 234.51. | each within ±0.5 | `testMidGreyLadderExactPath` | B |
| 7 | Monotonic in EV. Sweep scene levels {0.001, 0.01, 0.05, 0.18, 0.5, 1, 2, 4, 8, 64} over EV −5…+5 in 0.01 steps (1001 values), with LUT33 and exact. | 0 steps where the code falls by more than 1e-9 | `testMonotonicInEVAtHundredthStops` | B |
| 8 | No step bigger than N codes per 0.01 EV in the same sweep. Steps where both ends are ≤ 1.0 code are excluded, because that is the black floor below `blackAnchorEV`. Audited maximum: LUT33 0.636, exact 0.570. | **N = 0.70** (LUT33), **N = 0.62** (exact) | `testNoStepLargerThanThresholdPerHundredthEV` | B |
| 9 | No dead zone at grey. One step of 0.01 EV visibly moves 0.18 (audited +0.636). | \|code(EV 0.01) − code(EV 0)\| ≥ 0.3 | `testSmallestStepMovesGrey` | B |
| 10 | Hard clamp at ±10. `exposureGain` returns 1024 for 10, 11, 12 and 1e6, and 1/1024 for −10, −12 and −1e6. A render at EV 12 matches EV 10 bit for bit, and −12 matches −10. | exact equality | `testHardClampAtTenStops` | B |
| 11 | The slider literal matches the engine. BasicPanel Exposure: range −5…5, hard range −10…10, default 0, step 0.01. The hard range equals the ±10 clamp in `exposureGain`. | source read (LumenApp does not build on Linux) | V reads `Sources/LumenApp/BasicPanel.swift` (Exposure literal) | V |

## 2. Robustness (gating, WS-04-owned)

| # | Claim | Threshold | Measured by | Owner |
|---|---|---|---|---|
| 12 | A non-finite Exposure cannot poison the frame. `tone.exposure = .nan` makes `exposureGain == 1`, so S6 is the identity (use `Num.clampFinite(…, fallback: 0)`). `+inf` → 1024, `−inf` → 1/1024. A render of the 403-pixel ramp with NaN exposure equals the EV 0 render. | gain finite for all 3 inputs; render bit-equal to EV 0; 0 NaN pixels | `testNonFiniteExposureIsIdentityOrClamped` | B |
| 13 | **S6 fp16 headroom rule, the CPU/GPU twin.** When S6 is not the identity, its output is clamped per channel to **±65504** (the fp16 maximum). The constant is defined once, as `public static let LinearStage.outputLimit = 65504`.<br>**CPU:** `LinearStage.apply` clamps.<br>**GPU:** `RG.applyMatrix` adds the same clamp after `CIColorMatrix`, in the same CI graph, so it is fused before the RGBAh store. A `CIColorClamp` with min (−65504 ×3, 0) and max (65504 ×3, 1) does this.<br>The clamp is a no-op for in-range values, including the CreativeLUT `displayToWorking` caller. The identity skip is unchanged on both paths, which keeps line 4. | `LinearStage(EV +10).apply(RGB(64, 1e3, 1e4))` = (65504, 65504, 65504); `apply(RGB(−1e4, …))` = −65504; `apply(RGB(0.18))` = 0.18·1024 exactly; output finite for inputs up to 1e30 | `testS6OutputClampedToHalfFloatMax` | B |
| 14 | End-to-end, the CPU reference stays finite, and white where it should be, at EV +10. Inputs: scene (64, 64, 64), (1e4, 1e4, 1e4), (1e4, 50, 20). | every output channel finite; neutral → code ≥ 254.5 | `testReferenceFiniteAtTenStopsOverHalfMax` | B |
| 15 | The CPU path uses the clamp. `RR.render`'s S6 call line must call `plan.linear.apply` instead of `matrix.apply`. That line is WS-01's (stage-chain rule 1), so B writes the one-line request in `NEEDS.md` (N-1). Until it lands, line 13 is enforced at the stage level, and parity holds for every input < 65504 / 2^EV. | NEEDS.md entry present, naming the exact line | V reads `NEEDS.md` | B |
| 16 | GPU parity. On macOS, `RG.applyMatrix` at EV +10 on an RGBAh image holding 64, 1e3 and −1e3 gives ±65504, not ±inf or NaN. On the audit ramp at EV ∈ {−3, +3} it matches `LinearStage.apply`. | \|GPU − CPU\| ≤ 1 fp16 ulp; 0 non-finite | `Tests/LumenPipelineTests/ExposureGPUParityTests.swift` `testApplyMatrixClampsToHalfMaxLikeCPU`, `testApplyMatrixMatchesLinearStageOnRamp`. macOS CI only; on Linux, V checks the code reading. | B, V (macOS CI) |
| 17 | The existing tests still pass: `PlanTableCacheTests`, `EngineTests`, `AccuracyProbeTests` (the users of `LinearStage`/`exposureGain`), and the pipeline parity suites. | 0 new failures compared with the base commit | `bash /tmp/claude-0/runtests.sh LumenCoreTests` | V |

## 3. Visual claims (a human judges these from the named sheets)

All evidence goes in `docs/quality/lanes/WS-04/evidence/`, with a long edge ≤ 1024 px and each
file < 400 KB. Generate it with the `audit/sweep.sh.txt` command at `--long-edge 1024 --columns 3`,
for both the before and the after build.

| # | Claim | Evidence | Owner |
|---|---|---|---|
| V1 | Over −2…+3, the Sony A7 IV and GX85 frames brighten as a smooth bleach to white. There are no per-channel colour fringes at the clip boundary, no posterisation, no halo at foliage or sky edges, and GX85 sky does not go cyan. | `sweep_6929_a7iv_ev.png`, `sweep_2545_gx85_ev.png`, and `crop100_6929_ev0_2_3.png` (100 % crop, white wall and bricks) | H |
| V2 | The grey ramp over −3…+4 shows no banding and no step between columns. The tonal spacing is the same before and after. | `sweep_grey_ramp_ev.png` | H |
| V3 | After the fix, the before and after sheets look the same at every EV, because lines 12–13 change nothing in range. | `sweep_6929_a7iv_ev_before.png` against `sweep_6929_a7iv_ev.png` | H |

## 4. Lightroom comparison (not gating)

| # | Claim | Status |
|---|---|---|
| L1 | There are no Lightroom exports: `corpus/lightroom/` does not exist. The comparison is therefore against documented PV2012 behaviour only (AUDIT §9), which says midtones move about one stop per EV, highlights soft-clip, and Exposure is the first tonal operation. Lumen measures +1.14 / −1.45 display stops per EV at grey, and scene 0.9 at +2 EV renders 252.3 rather than 255. Lumen is content-independent, while LR is image-adaptive, and Lumen is darker at −EV. | **Human must judge. Pending reference exports.** Re-run lines 5–8 against LR exports of 6929 and 2545 at −2…+3 once `corpus/lightroom/` exists. |

## 5. Out of lane: tracked in NEEDS.md (owner WS-13; NOT gating WS-04)

S6 contributes 0° of hue, which follows from line 3 because OKLab hue does not change under
scaling. B copies these lines into `NEEDS.md` for WS-13. Thresholds are suggested, measured with
the `audit/harness_main.swift.txt` `hue` / `mono` modes.

| # | Defect (audited) | Suggested WS-13 threshold |
|---|---|---|
| O1 | Orange (0.55, 0.22, 0.03) goes yellow by **+8.6° at +1, +21.7° at +2 and +32.9° at +3** OKLab. About half of that comes from the per-channel [0, 1] sRGB encode clamp. | OKLab hue drift < 5° from EV 0 to +3 |
| O2 | Skin (0.45, 0.30, 0.22) goes yellow by **+19.9° at +3** (61° against 41°). It fails from +2.5. | < 5° from EV 0 to +3 while C > 0.01 |
| O3 | Deep blue (0.02, 0.03, 0.30) goes purple: **+10.9° at 0, +15.4° at +2, +23.2° at +3 and +33.6° at +4** (`rotation.b = +0.06`). | baseline < 3°; drift < 5° from EV 0 to +3 |
| O4 | Sky blue (0.05, 0.12, 0.35) has a constant purple bias of **+6.9…+8.6°**. | < 3° at every EV from −3 to +3 |
| O5 | The LUT33 finish table kinks at grey. The slope is **0.40 → 0.64 codes per 0.01 EV** across EV 0, against 0.57 exact, which is 1.6×. Max \|Δ²\| is 0.34 for LUT33 against 0.002 exact. Grey is misplaced by up to **2.3 codes** (EV −1: 72.72 against 70.41). Skin hue has ±3…5° of noise. | \|LUT − exact\| ≤ 0.5 code at grey −3…+3; slope ratio across any node ≤ 1.15 |
| O6 | The hue-wheel shows a blue-sector radial seam and a cyan lobe seam at every EV (`audit/sweep_hue_wheel.png`). | no visible seam (H) |
| O7 | UI/recipe: a recipe holding `exposure: 12` keeps 12 but renders as 10, and nothing reports the clamp. A histogram drag snaps +7 to +5 (`ToneRow.resolve`). Owner: LumenApp / Tone decode. | readout = effective value |

If a WS-13 fix changes the absolute LUT33 codes, lines 6 and 8 are re-baselined in the same
commit that changes them. The invariants (equality in 6, and lines 3, 7 and 9) must not move.
