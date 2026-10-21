# WS-07 acceptance spec: tone stage spatial application

Scope: the guided mask Highlights, Shadows, Whites, Blacks and the Zones read
(`RR.applyTone`, `RG.applyTone`), at the "HDR" combo Highlights −100 / Shadows +100
unless a line says otherwise. The tone curves themselves (zone weights, anchors) are
WS-05's and are not judged here.

Every number comes from one command, run on a release build of `lumen-render`:

    bash docs/quality/lanes/WS-07/run_ws07.sh OUTDIR [--full]

(`measure_tone_spatial.py` holds the definitions; its docstring is the metric spec.)
R is the mask radius, 0.02 × long edge = 32 px at 1600. Baseline = commit 9068ded.

## Audit findings that drive it

1. On hard edges (hard_edge.lfi, 5 to 9.5 EV) the mask is clean: 0 EV overshoot at
   8-bit, no reversal. The 4 EV unit test bar (0.1 EV) passes.
2. On **moderate** edges, 0.75 to 3 EV (a skyline under overcast, a wall against
   sky), the mask paints a counter-gradient ramp: 0.17 EV peak, 34 px (1.1 R) wide at
   0.75 EV, 0.18 EV at 1.5 EV. That is the guided filter's √ε halo: its contrast
   threshold is 0.375 EV and the worst halo sits at edges about 2√ε tall. Visible on
   the baseline step sheet as a dark band inside the shadow side and a glow on the
   bright side.
3. Local contrast: the mask is nearly as flat as no mask at all. Fine-detail retention
   (std of the 1.5 px band, toned / untoned) on 6 photos is 0.77 to 0.81 where a
   pointwise mask (a pure global curve) gives 0.71 to 0.74 and a plain blur 1.1 to 1.3
   (with 0.3 to 1.2 EV halos). Foliage reads milky: the mask's variance test treats
   leaf texture as edges and follows it, so the tone compression lands on the texture.
4. Preview vs full size: the radius already scales with the long edge. 6929 at 1600 vs
   7008 px differs by 0.023 EV mean / 0.13 EV p99 in tone gain, the same as a pointwise
   mask (0.024 / 0.14), i.e. the mixed-pixel floor of resampling before vs after a
   non-linear gain. Nothing to fix; it is pinned so it stays that way.

## Measurable lines

| # | Claim | Threshold | Baseline |
|---|---|---|---|
| S1 | Step-edge halo, steps 0.75/1.5/3/5 EV: peak gain deviation ≥ 3 px from the edge | ≤ 0.09 EV on every step | 0.166 / 0.178 / 0.107 / 0 |
| S1b | Step-edge halo width (deviation > 0.05 EV) | ≤ 20 px (0.63 R) on every step | 34.5 / 21.5 / 28.5 / 0 |
| S1c | Counter-gradient steps along a step row (1-code reversals) | ≤ 5 per step | 10 / 6 / 2 / 1 |
| S2 | hard_edge overshoot (both splits) and gradient reversal | 0.000 EV and 0 | 0 / 0 |
| S3 | Real photo halo, bright side (983, 1840, 4213, 6929, 2545, 1569) | ≤ 0.10 EV and width ≤ 10 px on every photo | max 0.095 (6929), w ≤ 8 |
| S4 | Gradient reversal fraction on every photo | ≤ 0.001 | ≤ 0.00055 |
| S5 | Local contrast retention s1.5: mean over the 6 photos | ≥ 0.911 (baseline), and no photo more than 0.03 below its baseline | 0.911 |
| S6 | Mask does not follow grain: flat −1 EV ± 0.4 EV noise, 5×5-averaged gain std | ≤ 0.012 EV | 0.0113 |
| S7 | Preview vs full size (6929, 1600 vs 7008 px), tone-gain difference | mean ≤ 0.026, p99 ≤ 0.15 EV (pointwise-mask floor 0.024 / 0.143 + margin) | 0.023 / 0.133 |
| S8 | Unit tests: `ToneMaskEdgeTests` (4 EV halo < 0.1 EV, noise σ < 0.02 EV) plus a new 1 EV moderate-edge halo test (< 0.06 EV on the linear stage output) | pass | 1 EV test: fails at baseline |
| S9 | Default recipe is an exact identity (stage skipped) and the GPU twin computes the same mask as the CPU definition (`gpu-parity.yml`, `ci.yml` green on macOS) | green | green |

## Visual claims (human judges, evidence sheets)

- V1 `evidence/steps_before_after.png`: on the 0.75 and 1.5 EV steps the baseline shows
  a dark band inside the shadow side and a glow beside the edge; after, both sides read
  flat to the edge.
- V2 `evidence/6929_foliage_2x.png`: the foliage is no flatter than the baseline (the
  dark gaps between leaves are not filled in more).
- V3 `evidence/1840_skyline_2x.png`: no bright rim in the sky along the treeline.
