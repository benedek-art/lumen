# WS-33 Primaries: acceptance spec (lane K3)

Owner functions: the WS-33 row in `docs/quality/workstreams.md`. Measurement script and
commands as in `../WS-32/SPEC.md` (`M primaries`). "Primary's own colour" in the unit
tests is a saturated red, green or blue inside every gamut in play; on the chart it is
the red, green and blue patches.

| # | claim | threshold | measured by |
|---|---|---|---|
| P1 | Greys stay grey at every corner of the six matrix sliders (3⁶ = 729 settings), from 0.002 to 2.9 linear | relative error < 1e-9 (engine), < 2e-5 (Float32 twin) | `T PrimariesQualityTests/testGreysStayGreyAtEveryCornerOfTheSixRemapSliders` |
| P2 | Chart neutrals (six patches) do not take a cast under any single slider at any setting | OKLab a/b shift ≤ 0.004 (one 8-bit code; the chart's `neutral 3.5` is not exactly neutral in the input and base measures 0.0034) | `M primaries` → `worst_neutral_ab_shift` |
| P3 | No dead range: every slider moves its primary's colour strictly monotonically across −100…+100 in steps of 10, no step < 0.2 × the mean step | test (no step < 0.2× mean); chart: 0 reversals and no step < 0.1× mean per row (the chart is read after the display transform, whose gamut map compresses the last 20 of Red Hue's travel to 0.15×) | `T …/testEverySliderRunsItsWholeTravelSmoothly`; `M primaries` → `dead_steps`, `reversals` |
| P4 | Hue turns each primary the way Lightroom's Calibration does (red → orange, green → cyan, blue → purple for +) by 10°…40° each way, never more than 2× lopsided | test | `T …/testHueTurnsEachPrimaryTheWayCalibrationDoesAndByARealAmount` |
| P5 | Saturation changes colourfulness, not hue | +100 ≥ ×1.09, −100 ≤ ×0.88 chroma; hue drift < 6° | `T …/testSaturationChangesColourfulnessWithoutTurningTheHue` |
| P6 | No slider is a tonal move in disguise | abs(ΔL) < 0.04 OKLab at ±100 | `T …/testNoSliderIsSecretlyATonalMove` |
| P7 | The proof registry's declared plateau on `primaries.rPurity` (PROOF-03) is gone | `declaredPlateauSteps` 0 and the sweep agrees | `ControlProofTests` (`LUMEN_RECORD_PROOFS=1` re-records) |

Visual claims:

- V1 `evidence/ws33-chart-red-saturation.png`: Red Saturation −100…+100 on the chart,
  base vs new. Base: the right half of the sheet is five identical frames. New: the reds,
  oranges and skin deepen across the whole travel; the grey row does not change.
- V2 UI snapshot `panel-grade-grading-primaries-open.png`: rows are named
  Hue / Saturation per primary, and each track shows its colour axis.
