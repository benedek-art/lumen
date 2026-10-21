# WS-04 Exposure: changes needed outside the lane

WS-04 owns `ToneEngine.exposureGain`, `LinearStage`, `RG.applyMatrix`, the RenderPlan `---- S6`
block and the Exposure literal in `BasicPanel.toneRows`. These items need code that another lane
owns. None of them gates WS-04 except that N-1 is how SPEC line 13 reaches the full CPU render.

Numbers come from `AUDIT.md` and the harness outputs in `audit/` (same folder). Codes are
pre-rounding sRGB codes, measured with `audit/harness_main.swift.txt` at as-shot 6503.7072 K /
+9.77, LUT 33, no dither. OKLab hue drifts are measured with its `hue` and `mono` modes.

## N-1 (owner WS-01, stage-chain rule 1): the CPU S6 call must use `LinearStage.apply`

SPEC line 15. `Sources/LumenCore/Engine/ReferenceRenderer.swift`, `RR.render`, lines 66-69:

```swift
        // S6 — the fused linear matrix.
        if !plan.linear.isIdentity {
            let matrix = plan.linear.matrix
            image = image.map { matrix.apply($0) }
        }
```

Requested change: line 68 `image = image.map { matrix.apply($0) }` becomes
`image = image.map { plan.linear.apply($0) }` (and line 67 can go). That is all.

- Why: `LinearStage.apply` now clamps each channel to ±`LinearStage.outputLimit` (65504, the
  half-float maximum). The GPU twin `RG.applyMatrix` adds the same clamp, fused after
  `CIColorMatrix` before the RGBAh store, and `RG.colorStageInput` already calls it at S6 (line
  210), so the GPU side needed no call-line change. Until N-1 lands, the CPU reference applies the
  bare matrix and does not clamp.
- Effect: none for any pixel where `|S6 output| ≤ 65504`, i.e. scene values below
  65504 / 2^EV: below 64 at the +10 hard limit, below 2047 at the slider's soft limit +5. The two
  renderers agree on every such input today. Above it the CPU writes values past 65504 and the GPU
  writes 65504; both then render white at the display (SPEC line 14: (64, 64, 64), (1e4, 1e4, 1e4)
  and (1e4, 50, 20) at EV +10 are finite and neutral code ≥ 254.5 on the CPU), so the visible
  difference is nil, but the parity contract is only exact once N-1 lands.
- Identity: `LinearStage.apply` returns its input unchanged when `isIdentity`, so the guard on
  line 66 can stay or go; the EV 0 default plan stays bit-exact either way.
- Test the owner should keep green: `ExposureQualityTests.testS6OutputClampedToHalfFloatMax` and
  `testReferenceFiniteAtTenStopsOverHalfMax`. After N-1, add an assertion that `RR.render` at EV
  +10 on scene (64, 1e3, 1e4) writes exactly 65504 into the S6 output (observable in a Linear
  render-preset plan, or via a stage probe).

## Out of lane, owner WS-13 (display transform and finish table)

SPEC §5, lines O1-O6. S6 contributes 0° of hue: OKLab hue is invariant under scaling, and
SPEC line 3 proves the render is a pure pre-scale (max |code diff| 0.000 on 11 recipes, re-measured
by `ExposureQualityTests.testExposureIsPureSceneGainAcrossRecipes`). Every degree below comes from
`DisplayTransform`, its finish table or the final encode clamp.

| # | Defect (audited) | Evidence | Suggested WS-13 threshold |
|---|---|---|---|
| O1 | Orange (0.55, 0.22, 0.03), scene h 54.4°, goes yellow by **+8.6° at +1, +21.7° at +2 and +32.9° at +3** OKLab (+46.9° at +4). Unclamped the drift is +10° at +2 and +23° at +3: about half comes from the transform's per-channel shoulder, the other half from the per-channel [0, 1] clamp in the sRGB encode (the finish path calls `apply(_:gamut:)` without a gamut boundary, so R exceeds 1 after the outset matrix and Rec.2020 → sRGB). | `audit/harness_hue.txt`; AUDIT §5a | OKLab hue drift < 5° from EV 0 to +3 |
| O2 | Skin (0.45, 0.30, 0.22), scene h 41.0°, goes yellow by **+19.9° at +3** (61° against 41°); fails from +2.5. Exact unclamped is +4.6°, so most of it is the encode clamp at R = 255 from EV +2 onward. Light patches turn cream/yellow at +3 and +4. | `audit/harness_hue.txt`; `audit/sweep_skin_tones.png`; AUDIT §5b | < 5° from EV 0 to +3 while OKLab C > 0.01 |
| O3 | Deep blue (0.02, 0.03, 0.30), scene h 259.8°, goes purple: **+10.9° at 0, +15.4° at +2, +23.2° at +3 and +33.6° at +4**. Cause: the documented `rotation.b = +0.06` in `DisplayTransformParams`. | `audit/harness_hue.txt`; AUDIT §5c | baseline < 3°; drift < 5° from EV 0 to +3 |
| O4 | Sky blue (0.05, 0.12, 0.35), scene h 244.1°, has a constant purple bias of **+6.9…+8.6°** at every EV from −3 to +3. | `audit/harness_hue.txt`; AUDIT §5 table | < 3° at every EV from −3 to +3 |
| O5 | The LUT33 finish table (`LUT3D.interactiveSize` = 33 over the 24-EV `LumenLog` domain, 0.75 EV per cell) kinks the EV response at grey: slope **0.40 → 0.64 codes per 0.01 EV** across EV 0, against 0.57 exact on both sides (1.6×). Max \|Δ²\| of code against EV is **0.34** for LUT33, 0.16 LUT65, 0.002 exact. Grey misplaced by up to **2.3 codes** (EV −1: 72.72 LUT33 against 70.41 exact; full ladder LUT33 20.32 / 41.29 / 72.72 / 117.65 / 168.74 / 207.17 / 234.51 against exact 20.32 / 39.44 / 70.41 / 117.65 / 168.58 / 207.45 / 234.51). Low-chroma skin hue gets ±3…5° of table noise (EV 0: h 40.9 LUT33 against 43.7 exact; EV −3: 37.9 against 43.4). | `audit/harness_mono.txt`, `audit/harness_s6_grey_roll.txt` §C, `audit/harness_hue.txt`; AUDIT §4, §5d | \|LUT − exact\| ≤ 0.5 code at grey for EV −3…+3; slope ratio across any table node ≤ 1.15 |
| O6 | The hue-wheel shows a radial seam in the blue sector (near 7 o'clock) and a lobe seam in the cyan half-radius, at every EV including 0; brightening makes both more visible (blue bleaches to lavender, cyan stays saturated longer at +3/+4). | `audit/sweep_hue_wheel.png`; AUDIT §5e | no visible seam (human judges the sheet) |

If a WS-13 fix changes the absolute LUT33 codes, WS-04 SPEC lines 6 and 8 must be re-baselined
in the same commit (`ExposureQualityTests.testMidGreyLadderMinus3ToPlus3` audited codes and
`testNoStepLargerThanThresholdPerHundredthEV` limits). The invariants must not move: the
`code(0.18 @ EV k) == code(0.18·2^k @ EV 0)` equality in line 6, and lines 3, 7 and 9.

## Out of lane, owner LumenApp / Tone decode (UI)

| # | Defect (audited) | Evidence | Suggested threshold |
|---|---|---|---|
| O7 | A recipe holding `exposure: 12` (sidecar, API or CLI) keeps 12 but renders byte-identically to +10 (and −12 as −10; `cmp` confirms), and nothing reports the clamp: the readout would show a number the render does not use, and `lumen-render` reports no `effectiveValue` change. Separately, the histogram exposure drag (`HistogramView.setTone`) resolves through `Lumen.ToneRow.resolve`, which clamps to the soft range −5…5, so a typed +7 snaps to +5 on the first drag event while the slider's hard range is ±10. The engine clamp is now one constant, `ToneEngine.exposureLimit = 10`, equal to the slider's `hardRange: -10...10`; the readout or the decode can read it. | AUDIT §8a, §8b; `ExposureQualityTests.testHardClampAtTenStops` (renders at ±12 bit-equal to ±10) | readout = effective value (normalize at decode, or clamp the binder display); slider and histogram drag state the same range rule |
