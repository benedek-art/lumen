# WS-06 Contrast & Pivot: verifier report (round 1)

**Verdict: PASS.** All 23 spec lines pass except S20, which is OPEN by design (it needs WS-07, NEEDS N1). One trade-off needs a human to judge it (H1 below). It is not a failure of any spec line.

I verified commit `7e7b13b` against the spec commit `3b71523`. I formed the verdict from SPEC.md, LANE-BRIEF.md, the diff and my own runs. I read BUILD-NOTES.md only afterwards: its numbers match mine.

## Gates (rebuilt from clean scratch paths)

| Gate | Result |
|---|---|
| `swift build --target LumenCore --target LumenRender` (6.1.2, fresh scratch) | clean, 0 errors. None of the warnings are in ToneEngine.swift or BasicPanel.swift. |
| `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` | **3055 tests, 0 failures**, exit 0. The base has 3044; the 11 extra tests are the new ContrastCurveTests. |
| `swift test -c release --filter ControlProofTests` | 6 tests, 0 failures. `tone.contrast` measures 58.51 and `tone.contrastPivot` 70.48, the same as the committed records. No other record moved, and the tree is clean after the run. |
| `python3 scripts/gen-fixtures.py --check` | passes. In the fixture diff only `contrast[*].mapped` and the tone cases that contain contrast changed. |
| Release `lumen-render`, Swift 6.0.3, base and new, separate scratch paths | both built |

## Spec lines (my run of `run_all.sh`; the base binary reproduces the spec's baseline numbers)

For each line: new value, then base value, then threshold, then verdict.

- **S1:** 0 (base 0), threshold = 0. PASS
- **S2:** 0 (base 0), threshold = 0. PASS
- **S3:** three keys.
  - Minimum derivative: 0.4204 (base 0.400), threshold ≥ 0.40. PASS
  - Minimum derivative for c > 0: 0.5605 (base 0.4105), threshold ≥ 0.50. PASS
  - Inversions: 0 (base 0), threshold = 0. PASS
- **S4:** 0 (base 0), threshold ≤ 1e-12. PASS
- **S5:** three keys.
  - Slope at +100: 1.879 (base 1.600), threshold in [1.60, 2.00]. PASS
  - Slope at −100: 0.4204 (base 0.400), threshold in [0.40, 0.50]. PASS
  - Non-increasing steps: 0 (base 0), threshold = 0. PASS
- **S6:** 0 (base 0), threshold ≤ 1e-9. PASS
- **S7:** two keys.
  - Shift at −6 EV: −0.486 (base −1.354), threshold \|x\| ≤ 0.55. PASS
  - Shift at −7 EV: −0.178 (base −0.792), threshold \|x\| ≤ 0.30. PASS
- **S8:** two keys.
  - Top-span ratio at +100: 0.605 (base 0.419), threshold ≥ 0.55. PASS
  - Top-span ratio at +50: 0.802 (base 0.686), threshold ≥ 0.75. PASS
- **S9:** three photos.
  - 1346: 2.34 (base 8.97), threshold ≤ 7.0. PASS
  - 4694: 0.52 (base 4.38), threshold ≤ 3.6. PASS
  - 2348: 1.04 (base 3.14), threshold ≤ 2.0. PASS
- **S10:** 0.180 (base 0.439), threshold ≤ 0.45. PASS
- **S11:** two keys.
  - Clipped or reversed columns: 0 (base 0), threshold = 0. PASS
  - Pivot code drift: 0.5 (base 0.5), threshold ≤ 1.0. PASS
- **S12:** two keys.
  - Mid slope at +100: 98 (base 85), threshold ≥ 80. PASS
  - Mid slope at −100: 23 (base 21), threshold ≤ 26. PASS
- **S13:** three keys.
  - Authority: 58.51 (base 68.38), threshold ≥ 57. PASS, with a margin of only 1.5.
  - frontLoading: 0.5756 (base 0.635), threshold in [0.42, 0.58]. PASS, near the edge.
  - deadSteps: 0, threshold = 0. PASS
- **S14:** six keys.
  - Highlights −100 at +100: 0.9982 (base 0.846), threshold ≥ 0.845. PASS
  - Shadows +100 at −100: 0.9087 (base 0.619), threshold ≥ 0.619. PASS
  - Worst paired case: 0.8843 (base 0.619), threshold ≥ 0.619. PASS
  - Four-way corner: 0.6267 (base 0.6468), threshold ≥ 0.620. PASS. This is the one fall the spec allows.
  - Moderate band: 1.000 (base 0.994), threshold ≥ 0.990. PASS
  - Composed minimum derivative: +0.00066 (base −0.00084), threshold ≥ −0.001. PASS
- **S15:** five keys.
  - LUT against stops: 0 (base 0), threshold ≤ 1e-9. PASS
  - Cube error, 32 knots: 0.0665 (base 0.1013), threshold ≤ 0.105. PASS
  - Cube error, 65 knots: 0.0334 (base 0.0249), threshold ≤ 0.035. PASS, but worse than base, at c +100, pivot 3, t ≈ 3.55.
  - Golden case, contrast +60, 32 knots: 0.0276 (base 0.0341), threshold ≤ 0.036. PASS
  - Golden case, contrast +60, 65 knots: 0.0073 (base 0.0084), threshold ≤ 0.0090. PASS
- **S16:** two photos, values for 6929 / 2545.
  - Step ratio: 1.136 / 1.253 (base 2.28 / 2.15), threshold ≤ 1.6. PASS
  - Adjacent-step ratio: 1.027 / 1.043, threshold ≤ 1.15. PASS
  - RMS non-increasing steps: 0 / 0, threshold = 0. PASS
- **S17:** two photos, values for 6929 / 2545.
  - Symmetry at ±100: 1.021 / 1.190 (base 0.56 / 0.65), threshold in [0.75, 1.33]. PASS
  - Symmetry at ±50: 0.986 / 1.056 (base 0.75 / 0.81), threshold in [0.80, 1.25]. PASS
- **S18:** two keys.
  - Mean \|Δh\|: 0.600° (base 0.492°), threshold ≤ 0.75. PASS, slightly worse than base.
  - Maximum \|Δh\|: 1.996° (base 1.984°), threshold ≤ 2.5. PASS
- **S19:** four keys.
  - Chart C/L at +100: −1.65% (base −1.56%), threshold \|x\| ≤ 3. PASS
  - Chart C/L at −100: +0.43% (base +0.25%), threshold \|x\| ≤ 3. PASS
  - Photo C/L change, 6929 / 2545: 0.14 / 0.27, threshold ≤ 1. PASS
- **S20:** −1.65 / −0.55 / +0.43, against the target bands. OPEN (NEEDS N1, WS-07). This is correct: it is printed as OPEN, never as PASS.
- **S21:** two keys.
  - Pivot authority, −3 to +3: 66.0 (base 84.1), threshold ≥ 20. PASS
  - Minimum move per 0.25 EV of pivot: 0.092 (base 0.075), threshold ≥ 0.05. PASS
- **S22:** range −3…3, hardRange −4…4, step 0.01. Contrast range unchanged. PASS
- **S23:** both tooltips are true; the words were read in the diff. PASS

**The measurement scripts.** The builder did not change anything under `measure/`. The base binary reproduces the spec's baseline exactly, with 14 FAIL lines. The other 3 baseline FAILs are the UI lines, which read the source of the current tree. So the lines tell the two curves apart.

I checked where the scripts could pass trivially:

- The ramp uses identical rows, so the guided mask is the pixel itself, and the ramp measures the curve.
- S15's model of the cube matches how the GPU actually reads it. `toneGainCube` samples `toneGainLUT.evaluate(encoded.r)` on uniform knots of the log shaper, and the probe does the same.
- S9 is taken before the dither.

I found no line that measures the wrong thing.

## Changes to existing tests: none of them weaken coverage

- **`EngineTests.testContrastHitsItsSlopeAtThePivot`.** The pinned numbers moved to the new law (1.879 / 1.368 / 0.420) at the same ±0.01. Justified, as the spec requires.
- **`AppliedReadoutTests`.** The test is re-pointed at the four-way corner, which still binds. It checks the caption against the engine's own applied values and against the literals −75 and +63. It also asserts that the two old recipes are no longer captioned, and I confirmed that they no longer bind. Coverage is stronger than before.
- **`RobustnessTests`, the 2% probe.** The case "Blacks +100 at c −100" is swapped for "Shadows +100 at c −100".
  - The old case no longer binds: zonalScale is 1, and the readout's nil caption confirms it. Kept, it would have made the `XCTAssertLessThan(zonalScale, 1)` precondition fail rather than skip.
  - The new case binds at 0.909 and runs the same property: monotone at the limit and inverting 2% above it, on the lower half.
  - Blacks is still pushed in that half by the first case, the four-way corner at c −100.
  - The 0.60 / 0.62 / 0.93 floors are unchanged. Acceptable.
- **`RobustnessTests` and `gen-fixtures`, the Whites-helper sweep.** It adds pivot +1. It does not replace pivot 0. At pivot 0 nothing binds any more, so the `helperBound > 0` guard would otherwise fail. This adds coverage and removes none.
- **`gen-fixtures.py`.** The curve is ported line for line. The input clamp it adds matches the Swift. The monotonicity sweep, the pivot-slope check (new values) and every limiter floor and binding assertion are kept.

## Attempts to break it (my probe linked against the release objects: `/tmp/claude-0/ws06/verify/stress.swift`)

- **Dense grid.** The grid covered:
  - c ∈ {±150 hand-edited, ±100, ±99 … ±0.01}
  - pivot ∈ {±7, ±4.5, ±4, ±3.75, 3.49, 3.5 …}
  - Whites ∈ {±150 … }, Blacks ∈ {±150 … }
  - Exposure ∈ {−5, 0, +5}
  - t from −12 to +12 EV in steps of 0.002

  Results: 0 inversions, 0 non-finite outputs, anchor and beyond-anchor error exactly 0. The minimum secant derivative inside the anchors is 0.4204; for c > 0 it is 0.5605. Base: 0.400 / 0.410.
- **Tiny reach.** Pivot 3.45–3.5 at Whites +100, and pivot 4 at Whites 67, with 1e-5 steps: minimum derivative 0.4204, and no division blow-up.
- **NaN and inf.** The behaviour is the same as base:
  - A NaN input t returns NaN.
  - ±inf passes through.
  - A NaN contrast returns NaN, as before.
  - A NaN pivot gives the identity.

  This is not a regression.
- **Neighbouring controls.** I composed `t + stops(t)` with contrast ±50/±100, pivot {−4, −3, 0, 3, 4, 7} and H/S/W/B ∈ {−100, 0, 100}: the minimum derivative is +0.00054 (base −0.00166). I also baked the gain LUT with Zones panel offsets: no rendered inversions.
- **Masked local contrast.** Global anchors {5/−9, 3.5/−9, 5/−6.5, 3.5/−6.5, 6/−10}, strength 0.3 and 1: monotone (minimum 0.420) and the anchors stay exact.
- **Performance.**
  - `contrastMapped`: 18.8 ns per call (base 7.2), because of one `pow` per call.
  - `bakeGainLUT`: 0.073 ms (base 0.071).
  - `ToneEngine.init`: 9 µs (base 5).
  - Per-pixel `gain(at:)` on the CPU local-adjust path: 48–55 ns (base 39–46), about 20% more.

  The GPU reads the baked cube, so preview cost is unchanged. Acceptable.

## GPU path

`grep contrast` over Kernels.swift and RenderGraph.swift finds no separate implementation of contrast. `RG.applyTone` multiplies by `plan.toneGainCubeBaked`, which is baked from `toneGainLUT`, which is `bakeGainLUTAndFloor`, which is `stops()`. The masked local GPU path (RenderGraph about line 2318) builds a `ToneEngine` with the global anchors and bakes `tone.gain(at:)` into its pre-LUT. So the CPU and GPU share one definition.

The cube error lines (S15) pass, and the macOS golden case (contrast +60) improves at both knot counts. The 65-knot worst case rose from 0.025 to 0.033 EV, at c +100, pivot +3. That is inside the bound, but it is the line closest to its limit. It is unlikely to matter to the macOS export parity tests, because those test c +60, 25 and 20.

## Visual (sheets at long edge 1024, as-shot WB/ISO, base vs new; I viewed every sheet and five 100% crops)

The sheets are 6929, 2545, 1346, 983, 983 at Exposure +1.5, and 4694 at contrast −100/−50/0/+50/+100, plus pivot sweeps from −3 to +3 at c +60 on 6929 and 2545.

- **V1, 6929: PASS.**
  - At +100 the foliage midtones are punchier than before.
  - The deep shadows under the foliage keep some texture.
  - −100 is a gentle flattening. Before, it was a grey, lifted wash.
  - +50 and −50 look about equally strong.
- **V2, 1346: PASS, with H1 below.**
  - At +100 the four dark patches read as four tones: codes 17.2 / 12.6 / 8.9 / 6.1.
  - The white patch stays apart from the light greys.
  - The dark surround stays separable.
- **V3, 983 at Exposure +1.5: PASS.**
  - At +100 the pale chart patches and the lantern glass keep clearly more separation than before. Before, the pale patches merged to near-white.
  - There is no new clipped area: 0.18% of pixels against 0.44% before.
- **V4, 2545: PASS.** No new halo or band at the tree line or sky at ±100.
- **Pivot sweeps.** Smooth and monotone in brightness, with no dead step from −3 to +3.
- **Across all sheets.** No banding, posterization or hue shift attributable to the change. Saturated reds on 4694 keep their hue.

### H1, for a human to judge: the compression has moved from the deep toe to −3…−5 EV

At c +100 the new curve's slope in the shadows is:

| EV | −2 | −3 | −4 | −5 | −6 | −7 |
|---|---|---|---|---|---|---|
| New slope | 1.37 | 0.86 | 0.60 | 0.60 | 0.63 | 0.77 |
| Old slope | 1.57 | 1.35 | 1.04 | 0.73 | 0.50 | 0.41 |

This is the S7 goal achieved by flattening the band above it. You can see it on 1346 at +100. The separation between the four dark patches went from 4.7 / 5.9 / 3.7 codes (before) to 4.6 / 3.8 / 2.7 codes (after). The darker tomatoes on 4694 also sit closer together.

The same holds on the highlight side. At c +100 the slope at +2 EV is 0.73 against the old 1.17, while +3…+4.5 EV is better. So the steep band is narrower, about −2…+1 EV.

No spec line forbids this, and S9 and V2 pass. But someone should decide whether that is the intended look.

## Evidence (docs/quality/lanes/WS-06/evidence/)

- `ws06_6929_contrast_before_after.png`: the sweep, before row above after row.
- `ws06_1346_darkpatches_crop100_c0_c100.png`: 100% crop, contrast 0 and +100. This is H1.
- `ws06_983_exp1.5_highlights_crop100_c0_c100.png`: 100% crop for V3.
- `ws06_4694_saturated_crop100_c0_c100.png`: 100% crop of the saturated reds and dark surround.
- `ws06_2545_pivot_sweep_c60_before_after.png`: pivot sweep from −3 to +3 at c +60.

The scratch work is in `/tmp/claude-0/ws06/verify/`: `runall-new.txt`, `runall-base.txt`, `stress-*.txt`, `t-core.log`, `t-proof.log` and `view/`.
