# WS-06 build notes

Builder round 1. Branch `quality/ws-06-contrast-pivot`, on top of `3b71523` (spec).
Not committed; the orchestrator commits.

## What changed and why

### `ToneEngine.contrastMapped` (Sources/LumenCore/Engine/ToneEngine.swift)

This follows SPEC D1. The curve is now built from a slope profile, integrated in closed form.

- On each side of the pivot, with x = |t − pivot| and R the reach to the live anchor:
  `s(x) = σ + (β − σ)·r₁(x) + (1 − β)·r₂(x)`.
  - r₁ is a smoothstep that eases σ into β.
  - r₂ is a smoothstep that starts where r₁ ends and returns β to exactly 1 at the anchor.
  - The two never overlap, so s is a sum of terms and its integral is closed-form
    (`smoothstepIntegral`). The cost is a few multiplies per call. There is no table and
    no numeric integration, which matters for the limiter sweep, LUT bakes and masks.
- β is solved per side so that ∫₀ᴿ s = R, which makes the anchor a fixed point:
  `β = (R + a₂ − σ(a₁+b₁)) / (R + a₂ − a₁ − b₁)`.
- Monotone by construction:
  - s is a convex combination of σ, β and 1.
  - β > 0 whenever σ < (R+a₂)/(a₁+b₁), and that ratio is at least 2.58 at every reach.
- Beyond the anchor the code returns `t`. `guard c != 0` is kept, and so is the ±4 /
  live-anchor pivot clamp.
- Side shapes, as fractions of R, the same as the spec witness:
  - highlight (0, 0.4, 0.8)
  - shadow (0.05, 0.45, 0.6)
  - The ease is at least min(1, R/2) EV wide and the return at least min(1.5, R/2) EV.
- Slope law: `log2 σ = 0.96u − 0.17u² + 0.12u³`, which gives σ(±100) = 1.879 / 0.420 and
  σ(±50) = 1.368 / 0.689. The witness law (a = 1.1, b = 0.2) was tried first. It passed
  every line except S13 frontLoading (0.589 > 0.58).
  - The cubic term moves slope from the middle of the slider to its ends, which fixes
    frontLoading.
  - σ(+100) is capped near 1.9 by the S14 four-way corner (0.622 at 1.892, 0.627 at
    1.879).
  - σ(−100) = 0.42 keeps authority at 58.5 (≥ 57) and the −100 midtone slope at 23
    (≤ 26).
- New constants: `contrastSlopeLinear/Quadratic/Cubic`, `contrastPivotSlope(_:)`,
  `ContrastSide`, `contrastHighlightSide/ShadowSide`, `contrastTransitions`,
  `smoothstepIntegral`. `contrastShoulderStart` is removed; nothing referenced it except
  comments.
- All comments are rewritten with the new measured numbers: slope law, monotonicity
  bound, and the limiter trade table.

### `BasicPanel.toneRows` (Sources/LumenApp/BasicPanel.swift)

- The Contrast tooltip is now the SPEC D4 text.
- Pivot: `range: -3...3, hardRange: -4...4`, step 0.01. The tooltip gains the
  darkening/brightening sentence. The engine clamp stays at ±4.

## Final run_all.sh output

Run with a 6.0.3 release build. `run_all.sh` prepends `/opt/swift` (6.0.3) to PATH to
compile `probe.swift`, so a 6.1.2-built LumenCore module cannot be imported. Build it with
`swift build -c release --product lumen-render --scratch-path <dir>` under /opt/swift, then
pass `<dir>/release/lumen-render`.

```
id   key                                            measured  rule            baseline  verdict
S1   S1_identity_mismatches                                0  == 0                   0  PASS
S2   P5_identity_png_mismatches                            0  == 0                   0  PASS
S3   S2_min_derivative                              0.420448  >= 0.40            0.400  PASS
S3   S2_min_derivative_positive_c                   0.560477  >= 0.50           0.4105  PASS
S3   S2_full_scale_inversions                              0  == 0                   0  PASS
S4   S3_fixed_point_error                                  0  <= 1e-12               0  PASS
S5   S4_slope_plus100                                1.87905  in 1.60 2.00       1.600  PASS
S5   S4_slope_minus100                              0.420448  in 0.40 0.50       0.400  PASS
S5   S4_slope_nonincreasing_steps                          0  == 0                   0  PASS
S5   S4_slope_plus50                                 1.36841  info               1.300  INFO  
S5   S4_slope_minus50                               0.688964  info               0.700  INFO  
S5   S4_log2_asymmetry_100                             -0.34  info              -0.644  INFO  log2 s(+100) + log2 s(-100); 0 = reciprocal ends
S6   S4_limiter_touches_contrast                           0  <= 1e-9                0  PASS
S7   S5_shift_minus6EV_c100                        -0.485584  abs<= 0.55        -1.354  PASS
S7   S5_shift_minus7EV_c100                        -0.178133  abs<= 0.30        -0.792  PASS
S8   R3_top_span_ratio_c+100                        0.604651  >= 0.55            0.419  PASS
S8   R3_top_span_ratio_c+50                         0.802326  >= 0.75            0.686  PASS
S8   S5_log_span_2to4_c100                           1.47157  info               1.363  INFO  EV of output spanned by +2..+4 EV input (2.0 = identity)
S9   P1_code0_pct_c+100_1346                         2.33938  <= 7.0             8.968  PASS
S9   P1_code0_pct_c+100_4694                        0.516401  <= 3.6             4.379  PASS
S9   P1_code0_pct_c+100_2348                         1.03927  <= 2.0             3.144  PASS
S10  P2_code255_pct_983_exp+1.5_c+100               0.179717  <= 0.45            0.439  PASS
S11  R2_grey_clipped_or_reversed_columns                   0  == 0                   0  PASS
S11  R1_pivot_code_drift                                 0.5  <= 1.0               0.5  PASS
S12  R4_mid_slope_c+100                                   98  >= 80                 85  PASS
S12  R4_mid_slope_c-100                                   23  <= 26                 21  PASS
S13  S8_authority_tone.contrast                      58.5076  >= 57             68.382  PASS
S13  S8_frontLoading_tone.contrast                  0.575647  in 0.42 0.58       0.635  PASS
S13  S8_deadSteps_tone.contrast                            0  == 0                   0  PASS
S13  S8_step_peak_ratio                              1.13966  info               2.304  INFO  max/min per-10-unit peak step on the proof ramp
S14  S6_hl-100_at_c+100                             0.998204  >= 0.845          0.8460  PASS
S14  S6_sh+100_at_c-100                             0.908657  >= 0.619          0.6192  PASS
S14  S6_worst_paired_scale                          0.884347  >= 0.619          0.6192  PASS
S14  S6_four_way_corner_scale                       0.626721  >= 0.620          0.6468  PASS
S14  S6_moderate_band_scale                                1  >= 0.990          0.9939  PASS
S14  S6_composed_min_derivative                     0.000661  >= -0.001       -0.00084  PASS
S15  S7_lut_vs_stops_max_err_EV                            0  <= 1e-9                0  PASS
S15  S7_cube32_interp_err_EV                          0.0665  <= 0.105          0.1013  PASS
S15  S7_cube65_interp_err_EV                         0.03336  <= 0.035          0.0249  PASS
S15  S7_golden_c60_cube32_interp_err_EV             0.027628  <= 0.036          0.0341  PASS
S15  S7_golden_c60_cube65_interp_err_EV             0.007345  <= 0.0090         0.0084  PASS
S16  P3_step_ratio_6929                              1.13587  <= 1.6             2.279  PASS
S16  P3_step_ratio_2545                              1.25314  <= 1.6             2.153  PASS
S16  P3_adjacent_step_ratio_6929                     1.02738  <= 1.15            1.050  PASS
S16  P3_adjacent_step_ratio_2545                     1.04311  <= 1.15            1.044  PASS
S16  P3_rms_nonincreasing_6929                             0  == 0                   0  PASS
S16  P3_rms_nonincreasing_2545                             0  == 0                   0  PASS
S17  P4_sym_100_6929                                 1.02075  in 0.75 1.33       0.558  PASS
S17  P4_sym_100_2545                                 1.18986  in 0.75 1.33       0.653  PASS
S17  P4_sym_50_6929                                 0.986483  in 0.80 1.25       0.750  PASS
S17  P4_sym_50_2545                                  1.05556  in 0.80 1.25       0.806  PASS
S18  C1_hue_mean_abs_deg                            0.599855  <= 0.75            0.492  PASS
S18  C1_hue_max_abs_deg                              1.99592  <= 2.5             1.984  PASS
S19  C2_sat_CL_pct_c+100                            -1.64952  abs<= 3           -1.562  PASS
S19  C2_sat_CL_pct_c-100                            0.429392  abs<= 3            0.250  PASS
S19  C2_photo_CL_change_pct_6929                    0.143908  <= 1               0.159  PASS
S19  C2_photo_CL_change_pct_2545                    0.265218  <= 1               0.341  PASS
S20  C2_sat_CL_pct_c+100                            -1.64952  in 6 15           -1.562  OPEN
S20  C2_sat_CL_pct_c+50                            -0.547175  in 3 8            -0.614  OPEN
S20  C2_sat_CL_pct_c-100                            0.429392  in -20 -8          0.250  OPEN
S21  S8_authority_pivot_-3_3                         66.0073  >= 20             84.094  PASS
S21  S9_min_move_per_quarter_EV_pivot_in_pm3        0.092102  >= 0.05            0.075  PASS
S21  S8_authority_pivot_-4_4                         70.4843  info             100.288  INFO  (contrast 50; floor 20)
S21  S9_info_pivot3.5_vs_4_at_whites100                    0  info                   0  INFO  EV (dead, typed-only range, accepted)
S21  R5_info_pivot_codes                                   0  info                      INFO  p-4:10 p-3:20 p-2:40 p0:118 p2:207 p3:234 p4:250
S22  U1_pivot_range_ok                                     1  == 1                   0  PASS
S22  U1_contrast_range_ok                                  1  == 1                   1  PASS
S23  T1_contrast_tooltip_truthful                          1  == 1                   0  PASS
S23  T2_pivot_tooltip_truthful                             1  == 1                   0  PASS

0 lane line(s) FAIL
```

Every lane line passes, and S20 stays OPEN (it needs WS-07, NEEDS N1). Three lines pass
with thin margins:

| Line | Measured | Bound |
|---|---|---|
| S14 four-way corner | 0.627 | ≥ 0.620 |
| S13 frontLoading | 0.576 | ≤ 0.58 |
| S15 cube65 worst | 0.0334 | ≤ 0.035 |

The cube65 worst case (0.0334) is above the baseline's 0.0249. It occurs at c +100,
pivot 3, where the reach is 2 EV and the transitions are 1 EV wide. The golden +60 case
improved: 0.0084 → 0.0073.

## Tests

- `swift build --target LumenCore --target LumenRender` (6.1.2): clean.
- `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` (6.1.2): 3055
  tests, 0 failures. That is the baseline's 3044 plus the 11 new tests.
- `LUMEN_RECORD_PROOFS=1 swift test -c release --filter ControlProofTests` re-recorded the
  proof records. Only `tone.contrast.json` and `tone.contrastPivot.json` changed:
  - tone.contrast: authority 68.38 → 58.51, frontLoading 0.635 → 0.576.
  - tone.contrastPivot: authority 100.29 → 70.48.
  - meanSeparation fell for both (30.4 → 20.8 and 29.2 → 20.7), because the softer toe
    and shoulder move less of the frame.
  - A plain re-run without recording: 6 tests, 0 failures.
- `python3 scripts/gen-fixtures.py --check`: passes.
- `scripts/check-swift-surface.py` exits 1 on one item, `Font ... LumenType.swift:30`.
  It fails identically on the base commit, in a file this lane does not touch.

New file `Tests/LumenCoreTests/ContrastCurveTests.swift` adds the 11 tests SPEC lists:

- S1 identity
- S3 monotone with margin
- S4 fixed points
- S5 slope law
- S6 limiter never scales Contrast
- S7 deep shadows
- S8 top two stops on a ReferenceRenderer ramp
- S14 trade table, pinned at ±0.002
- S15 LUT is stops
- S15 cube follows the curve
- S13 proof travel, via `ProofRunner.measured`

## Existing tests and fixtures changed, and why

- **`scripts/gen-fixtures.py`**
  - `contrast_mapped` is ported to the new curve. `CONTRAST_SHOULDER_START` is replaced
    by the slope-law and side constants.
  - The pivot slope check is updated to 1.879 / 1.368 / 0.420.
  - The binding-pair comment is updated.
  - Two coverage cases changed, each with a comment, because their premise (that the
    case binds the limiter) no longer holds on the better curve:
    - The Whites-is-never-eased sweep adds pivot +1, where Highlights −100 still binds.
    - The "limiter takes as little as it can" list swaps Blacks +100 / c −100 (which no
      longer binds) for Shadows +100 / c −100 (0.909).
  - The floors are unchanged: 0.60, 0.62, 0.93, `bound > 0`, `worst_scale < 1`.
- **`Fixtures/enginemath.json`** is regenerated. Only the `contrast` and `tone` blocks
  changed, both because of the curve.
- **`EngineTests.testContrastHitsItsSlopeAtThePivot`**: expected values are now the new
  law's 1.879 / 1.368 / 0.420, still at ±0.01, with a comment.
- **`RobustnessTests.testHighlightsAndShadowsKeepDoingMoreAndLeaveEachOtherAlone`**
  - Mirrors the two generator coverage changes above: pivot sweep {0, +1} in the
    Whites-helper block, and the Shadows +100 / c −100 case in the 2% probe list.
  - The comment that cited 0.846 / 0.619 is updated. Floors are unchanged.
  - The 2% "stops rising above the solved limit" probes still pass.
- **`AppliedReadoutTests.testAnEasedSliderIsNamedWithTheAmountTheRenderApplies`**
  - Its two recipes no longer ease, so it is re-pointed at the four-way corner (c +100,
    H −100, S +100, W −100, B +100). It asserts the engine's own applied values
    ("Highlights −75 of −100", "Blacks (tone shelf) +63 of +100").
  - It also now asserts that the two old recipes are silent.
  - `testUntouchedAndSingleSliderAtContrastZeroAreNeverCaptioned` and the grid test pass
    unchanged.
- **Proof records**: only `tone.contrast.json` and `tone.contrastPivot.json` changed (see
  above). `authorityFloor` is unchanged.
- **Unchanged and passing**, as the spec requires:
  - the property tests in `EngineTests`
  - `RobustnessTests` monotone tests
  - `ColourAccuracyTests`
  - `AccuracyProbeTests.testContrastLeavesMidGreyExactlyAlone`
  - `MaskingTests`
  - `ZoneFlatteningTests`

## Not done here

- S20 chroma coupling: NEEDS N1, WS-07.
- Proof-registry pivot travel −3…3: NEEDS N2, WS-58. The `tone.contrastPivot` record is
  still measured over ±4.
- Visual sheets V1-V4 and `evidence/` were not rendered in this round. They are for the
  verifier or the report step.
