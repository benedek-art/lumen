# WS-06 Contrast & Pivot: report

Verdict: **PASS** (22 of 23 spec lines PASS; S20 OPEN, needs WS-07). Verifier: PASS, round 1
(`VERIFY.md`). Commits on `quality/ws-06-contrast-pivot`: audit `7d2fe14`, spec `3b71523`,
code `7e7b13b`, report (this commit).

## For the owner

- Contrast is now as balanced as Lightroom's: +50 and −50 are equal and opposite on screen (0.99–1.06, was 0.75–0.81), and the slider feels even end to end.
- +100 no longer crushes shadows: code-0 pixels on 1346 fall from 8.97% to 2.34%, and the top two stops keep 60% of their separation (was 42%).
- Hue holds (0.6° mean, 2.0° max), and the white and black points never move, so it still cannot clip grey.
- Not Lightroom yet: Contrast still adds no saturation, so +100 looks slightly duller than LR. That needs a chroma term in S7, requested from WS-07 (NEEDS.md N1).
- Judge one trade-off yourself: at +100 the −3…−5 EV band is a little flatter than before (`evidence/ws06_1346_darkpatches_crop100_c0_c100.png`).

Best evidence:

1. `evidence/ws06_6929_contrast_before_after.png` (A7 IV, −100…+100, before row vs after row)
2. `evidence/ws06_1346_darkpatches_crop100_c0_c100.png` (100% crop, shadow toe at +100)
3. `evidence/ws06_2545_pivot_sweep_c60_before_after.png` (GX85, Pivot −3…+3 at Contrast +60)

Also: `evidence/ws06_983_exp1.5_highlights_crop100_c0_c100.png`,
`evidence/ws06_4694_saturated_crop100_c0_c100.png`.

## What changed and why

`ToneEngine.contrastMapped` was `d · mix(slope, 1, smoothstep(0.2, 1, |d|/reach))` with
`slope = 1 + 0.6c`. That law makes −100 twice as strong as +100 in log slope, and it pays
for the steep middle with a slope dip to 0.41 at 77% of the reach, which flattened the top
two stops 2.3× and dragged −6/−7 EV down by 1.35/0.79 EV (code-0 crush).

The new curve integrates a positive log-slope profile on each side of the pivot. It has a
closed form, with one level solved per side so that the live white and black anchors are
exact fixed points. Monotonicity and fixed anchors hold by construction, not by tuning.
The shadow side returns to slope 1 well before the black anchor (soft toe), the highlight
side eases from the pivot, and every transition is at least about 1 EV wide so the 32/65-knot
GPU gain cube can follow it. The slope law is `log2 σ = 0.96u − 0.17u² + 0.12u³` (u = c/100),
σ(+100) = 1.879, σ(−100) = 0.420. Pure log-symmetry was rejected because the display
transform absorbs positive slope less than negative, so it made +100 1.8× stronger on
screen. This law is balanced on screen, which is what a photographer sees.

Saturation decision: Lightroom couples about +16% chroma at +50 and +29% at +100. Lumen's
target is half that rate (+6…+15% C/L at +100), because a full LR rate over-saturates skin
at strong settings. S7 applies one scalar gain per pixel and the lane cannot add chroma from
`contrastMapped`, so today Contrast changes lightness only (S19, measured) and the chroma term
is requested from WS-07 with an exact interface (NEEDS.md N1).

Pivot: drag range narrowed to ±3 EV with `hardRange` ±4. Typed values and old recipes at
±4 still render, and the engine clamp is unchanged. Beyond ±3 the pivot mostly acts as a
brightness control and, with Whites ≥ +67, runs into the lowered white anchor (dead travel).

UI: the Contrast tooltip claimed it "cannot clip a highlight", which is false for bright
colours under a ratio-preserving gain. It now says the white and black points stay fixed and
strong settings compress the brightest and darkest tones. The Pivot tooltip says a raised
pivot darkens under positive Contrast.

CPU/GPU: the GPU bakes its gain cube from the same `ToneEngine.stops`, so no kernel changed.
S15 checks the baked LUT equals `stops()` exactly and that cube interpolation error stays in
bound.

## Spec lines (measured by `measure/run_all.sh` on `7e7b13b`; baseline in brackets)

| # | Verdict | Measured |
|---|---|---|
| S1 identity of curve | PASS | 0 mismatches [0] |
| S2 identity render | PASS | 0 PNG mismatches [0] |
| S3 monotone | PASS | min slope 0.420, 0.560 for c > 0 [0.400, 0.410] |
| S4 fixed points | PASS | 0 EV error [0] |
| S5 slope law | PASS | 1.879 / 0.420, strictly rising [1.6 / 0.4] |
| S6 limiter never scales Contrast | PASS | 0 [0] |
| S7 soft toe | PASS | −0.486 / −0.178 EV at −6/−7 EV [−1.354 / −0.792] |
| S8 top stops | PASS | 0.605 at +100, 0.802 at +50 [0.419 / 0.686] |
| S9 shadow crush | PASS | code-0 2.34 / 0.52 / 1.04 % on 1346/4694/2348 [8.97 / 4.38 / 3.14] |
| S10 highlight clipping | PASS | 0.18 % on 983 [0.44] |
| S11 grey clean, pivot fixed | PASS | 0 clipped/reversed columns, drift ≤ 1 code |
| S12 midtone contrast | PASS | 98 / 23 codes/EV at ±100 [85 / 21] |
| S13 authority | PASS | 58.51 (floor 55, line ≥ 57), frontLoading 0.576 [68.38, 0.635] |
| S14 limiter | PASS | HL 0.998, SH 0.909, paired 0.884, corner 0.627, moderate 1.0 [0.846, 0.619, 0.619, 0.647, 0.994] |
| S15 CPU = GPU source | PASS | LUT err 0; cube32 0.0665, cube65 0.0334, +60 golden 0.0276 / 0.0073 EV |
| S16 slider evenness | PASS | step ratio 1.14 / 1.25 on 6929/2545 [2.28 / 2.15] |
| S17 ±N symmetry | PASS | ±100 1.02 / 1.19, ±50 0.99 / 1.06 [0.56–0.65, 0.75–0.81] |
| S18 hue held | PASS | 0.60° mean, 2.00° max [0.49°, 1.98°] |
| S19 saturation honest | PASS | C/L −1.65% at +100 |
| S20 LR-like saturation | **OPEN** | −1.65% vs target +6…+15%; needs WS-07 (NEEDS N1) |
| S21 pivot live | PASS | authority 66.0 over ±3 |
| S22 panel ranges | PASS | Pivot −3…3 / hard ±4; Contrast unchanged |
| S23 tooltips truthful | PASS | both |

Visual claims V1–V4: PASS (verifier, `VERIFY.md`). No banding, halos or hue shifts.

Tight margins: S13 authority 58.5 vs 57, S14 four-way corner 0.627 vs 0.620, S15 cube65
0.0334 vs 0.035 (worse than base 0.0249, still in bound; the macOS golden case at +60 improved).

## Tests and gates

- `swift build --target LumenCore --target LumenRender`: clean (Swift 6.1.2; the 6.0.3
  toolchain from `cloud-setup.sh` cannot parse LumenApp's trailing commas).
- `swift test --parallel --filter LumenCoreTests --skip ControlProofTests`: 3055 tests,
  0 failures (base: 3044, 0 failures; +11 in `ContrastCurveTests.swift`).
- `swift test -c release --filter ControlProofTests`: 6 tests, 0 failures. Only
  `tone.contrast.json` and `tone.contrastPivot.json` were re-recorded.
- `scripts/gen-fixtures.py --check`: passes.

Existing tests changed, each because it encoded the old curve, none loosened:

- `EngineTests` slope test expects the new slope law.
- `enginemath.json` regenerated by `gen-fixtures.py`.
- Two limiter coverage cases (generator and `RobustnessTests`) no longer bound, because the
  new curve leaves Highlights/Shadows more room. They were swapped for cases that still bind
  and test the same "inverts 2% past the solved limit" property (pivot +1 in the Whites
  sweep; Shadows +100 at c −100 instead of Blacks +100). Limiter floors unchanged.
- `AppliedReadoutTests` re-pointed at the four-way corner, which is now the binding case.

## Not fixed, and what a human must judge

- S20 saturation coupling: out of lane (WS-07, NEEDS N1).
- Edge halo band of 6–7 codes around 1 EV edges at ±100 comes from the guided mask (WS-07).
- The interactive 33-cube finish table swings low-chroma skin hue 2–4° for any small
  exposure change (WS-12). It makes Contrast look like it shifts skin in the preview.
- H1: at +100 the flattening moved from −6/−7 EV (now much better) to −3…−5 EV, slope
  0.60 vs 0.73–1.04 before. On 1346 the dark patches differ by 4.6/3.8/2.7 codes vs
  4.7/5.9/3.7 before. No spec line forbids it; judge from the 1346 crop.
- Cost: one curve evaluation is 2.6× slower (18.8 vs 7.2 ns), a CPU masked-adjust pixel
  about 20% slower; LUT bake time unchanged.
- No Lightroom reference exports exist yet (`corpus/lightroom/` absent). LR comparisons use
  Adobe's documented behaviour and an RGB-curve model of it. Re-run `run_all.sh` against the
  exports when they land.
