# WS-06 Contrast & Pivot: acceptance spec

This spec was written after the audit (`AUDIT.md`) and before any code change. The branch is
`quality/ws-06-contrast-pivot`. The baseline is the code at `7d2fe14`, which is the same
code as `84bcd7c`.

**Owned code.** WS-06 owns:

- `ToneEngine.contrastMapped`, plus the contrast constants and comments above it
  (`minContrastReachEV`, `contrastShoulderStart`, ToneEngine.swift about lines 530-690).
- The Contrast and Pivot `LumenSlider(...)` literals in `BasicPanel.toneRows` (about lines
  475-496): range, hardRange, step and `help:` only.

Nothing else is in lane. Requests to other lanes are in `NEEDS.md`.

## How to measure

```
export PATH=/opt/swift/usr/bin:$PATH
swift build -c release --product lumen-render
bash scripts/proof/fetch_corpus.sh          # corpus/lfi + corpus/synthetic, if not present
bash docs/quality/lanes/WS-06/measure/run_all.sh \
     "$(swift build -c release --show-bin-path)/lumen-render" corpus /tmp/ws06-measure
```

`run_all.sh` takes about 1.5 minutes cold. It prints one row per measured key:

```
id key measured rule baseline verdict
```

It exits 1 if any lane line FAILs. The scripts, all committed under `measure/`, are:

| Script | What it measures |
|---|---|
| `probe.swift` | Engine and plan properties. Compiled by `run_all.sh` against the release LumenCore objects next to the binary, so it measures the Swift that ships. |
| `measure.py` | Rendered measurements through `lumen-render`: grey ramp, ColorChecker, and the photos. |
| `mkframes.py` | The 3200 px grey ramp (−10…+6 EV) and the mid-edge frame. |
| `ui_check.py` | The two `LumenSlider` literals. |
| `sheets.sh`, `compose.py` | The visual sheets V1-V4 and the committed evidence. |

**Photos**, from `corpus/lfi`, rendered with their sidecar's as-shot Kelvin, Tint and ISO:

| Id | Camera | Content |
|---|---|---|
| 6929 | Sony A7 IV | foliage |
| 2545 | Panasonic GX85 | sky, hard shadow |
| 983 | Canon 5D IV | snow, lantern, chart |
| 2348 | Panasonic G9 | low key |
| 4694 | Canon R5 | dark surround |
| 1346 | Canon 5D | Passport chart, dark surround |

2242 is in the audit sheets and is not used by any line.

Settings per measurement:

- **Shadow and highlight clipping:** long edge 1600 with dither, the same as the audit. The
  metric is taken before the dither.
- **Smoothness:** long edge 1024 without dither.
- **Synthetic frames:** 65-cube tables (`--lut-size 65`) without dither.

Every "baseline" number below was printed by `run_all.sh` on the baseline build. The full
output is at the end of this file. 17 lane lines FAIL at baseline, which is expected: the
spec describes the improvement.

## Decisions

**D1. Curve shape: rebuild `contrastMapped` from a slope profile.**

The current curve is `d · mix(slope, 1, smoothstep(0.2, 1, |d|/reach))`. It fails on four
counts:

- Its slope law `1 + 0.6c` makes −100 about twice as strong as +100 in log-slope.
- It spends the compensation for its steep middle in a dip to slope 0.41, at 77% of the
  reach. That flattens the top two stops by 2.3× and crushes the −4…−7 EV shadows to code 0.
- It costs Highlights and Shadows 15-38% of their travel through the zonal limiter.
- Contrast −50 does more than Contrast +50.

The new curve must be built so that monotonicity and the fixed points hold *by
construction*:

- On each side of the pivot, define a positive log-slope profile s(x) over the live reach R
  (x = |t − pivot|) and integrate it: mapped = pivot ± ∫₀ˣ s.
- Solve one free level per side so that ∫₀ᴿ s = R. Then the anchor maps to itself exactly.
- Make s > 0 by construction, so the curve is monotone everywhere.
- Make s = 1 for x ≥ R (identity beyond the anchors).
- Make s ≡ 1 when c = 0, with the existing `guard c != 0` kept, so the identity is exact.
- On the shadow side, let the profile ease from the pivot and return to slope 1 well before
  the black anchor. That gives the softer toe: the deep shadows are left nearly alone (S7,
  S9).
- On the highlight side, let the profile ease from the pivot, which keeps the top stops
  separated (S8).
- Make every transition at least about 1 EV wide, so that the 32- and 65-knot GPU gain cube
  can follow it (S15).

**The slope law.** Use log2 s_pivot(c) = a·u − b·u², with u = c/100, or any law that meets
S5, S16 and S17. Plain log-symmetry (b = 0) was tried and rejected. With the eased profile
it makes +100 about 1.8× stronger *on screen* than −100: the ratio dRMS(+100)/|dRMS(−100)|
is 1.70-1.87 in the prototype. The reason is that the display transform absorbs positive
and negative log-slope differently. The quadratic term trades log-symmetry for symmetry on
screen, which is what a photographer sees. The asymmetry `log2 s(+100) + log2 s(−100)` is
reported as INFO only.

**Feasibility witness** (non-binding; the builder may choose differently):

- a = 1.1, b = 0.2. That gives s(+100) = 1.866, s(+50) = 1.414, s(−50) = 0.660,
  s(−100) = 0.406.
- s(x) = σ(1 − r₁) + r₁((1 − r₂)β + r₂), where σ is the pivot slope and β is the solved
  level, with:
  - r₁ = smoothstep(f₀R, max(f₁R, f₀R + min(1, R/2)), x)
  - r₂ = smoothstep(max(min(MR, R − min(1.5, R/2)), end of r₁), R, x)
  - highlight side (f₀, f₁, M) = (0, 0.4, 0.8)
  - shadow side (f₀, f₁, M) = (0.05, 0.45, 0.6)

A Python prototype of the witness was composed with the measured contrast-0 display curve.
It reproduces the baseline's authority (69.0 against 68.38), step ratio and limiter numbers
exactly. Measured on the witness:

| Quantity | Witness | Baseline |
|---|---|---|
| Authority | ≈ 59 | 68.38 |
| frontLoading | ≈ 0.54 | 0.64 |
| Top-span ratio at +100 | 0.60 | 0.42 |
| Top-span ratio at +50 | 0.79 | 0.69 |
| Shift at −6 EV | −0.48 | −1.35 |
| Shift at −7 EV | −0.18 | −0.79 |
| Minimum derivative | 0.406, or 0.567 for c > 0 | 0.400 |
| Step ratio on 6929 / 2545 | ≤ 1.42 | 2.28 / 2.15 |
| Symmetry at ±100 | 1.03-1.15 | 0.56-0.65 |
| Symmetry at ±50 | 1.01-1.07 | 0.75-0.81 |
| Cube error, worst, 32 / 65 knots | 0.065 / 0.033 | 0.101 / 0.025 |
| Cube error, contrast +60, 32 / 65 knots | 0.030 / 0.0081 | 0.034 / 0.0084 |
| Highlights −100 applied at contrast +100 | 0.999 | 0.846 |
| Shadows +100 applied at contrast −100 | 0.895 | 0.619 |
| Worst paired case | 0.890 | 0.619 |
| Four-way corner | 0.631 | 0.647 |
| Moderate band | 1.000 | 0.994 |
| Code-0 proxy | −28% | — |

The prototype scripts were scratch work and are not committed. The thresholds below were
set from these numbers with margin. A different curve that passes the lines is equally
acceptable.

**D2. Saturation: Lumen's Contrast should couple chroma, at about half Lightroom's rate.**

- Lightroom-like hue-locked contrast gives +16% chroma at +50 and +29% at +100. The audit
  measured this on the same tonal curve; it is an upper bound.
- Lumen today: OKLab C/L is −1.6% at +100, and whole-frame chroma falls 19% on 6929. So +100
  reads as darker and duller.
- The target is OKLab C/L of +6…+15% at +100, +3…+8% at +50 and −8…−20% at −100, with hue
  held (S18).
- Why half Lightroom's rate: Lumen has separate Vibrance and Saturation controls, and its
  ratio-preserving tone path already avoids Lightroom's per-channel hue skew. A milder
  coupling removes the "dull" look without making Contrast a second saturation slider.

`contrastMapped` returns a tone, and S7 multiplies one scalar gain per pixel. So WS-06
cannot add chroma, and S20 is **OPEN**: the requested interface (`contrastChromaGain(at:)`,
applied by WS-07 in S7) is in `NEEDS.md` N1. What this lane *can* promise, and S19
measures honestly, is that the new curve stays ratio-preserving: C/L within ±3% and hue
held. S19 is retired when N1 lands.

**D3. Pivot range: drag range −3…+3 EV, with hardRange −4…+4. The engine clamp stays ±4.**

- At contrast 0, pivot ±3 EV renders at codes 20 and 234, and ±4 renders at 10 and 250.
- Beyond about ±3 EV, Contrast mostly acts as a brightness control. On 6929 at +100 the
  median code is 140 at pivot −4 and 11 at pivot +4.
- The white anchor's lowest live value is +3.5 EV, at Whites +100. A drag range of ±3
  therefore never reaches the dead travel above a lowered white anchor. Today pivots
  3.5-4.0 render identically at Whites +100 (S9 INFO line, 0.0000 EV).
- Typed values from 3 to 4 remain accepted. Their dead part under Whites ≥ +67 is accepted
  and documented in the Pivot tooltip's scope: it is typed-only.
- Recipes stored with pivot ±4 still decode, because the Recipe struct is unchanged. They
  still render through the same ±4 clamp, and S11 checks pivots ±4 on the grey ramp.
- The proof-registry travel (WS-58) is requested in `NEEDS.md` N2. Authority at ±3 is 84.09
  against a floor of 20.

**D4. Tooltips must be true.**

Contrast. The current text says "cannot clip a highlight". That is false: 983 at exposure
+1.5 goes from 0.001% to 0.439% at +100. The text also says nothing about shadows. Proposed
text, or equivalent text that passes S23:

> Steepens or flattens the midtones around the Pivot below. The white and black points stay
> where they are, so a grey is never pushed past white or black, but strong settings
> compress the brightest and darkest tones and can clip bright saturated colours. It
> changes lightness only; colours keep their saturation.

The last sentence is removed or reworded when S20 lands.

Pivot. Proposed text:

> Where Contrast hinges, in stops from mid-grey — the tone it holds still. Raise it to
> anchor the brights and let contrast work the shadows; lower it for the reverse. With
> Contrast raised, a raised Pivot darkens the picture overall and a lowered one brightens
> it.

**D5. CPU and GPU.**

- S7 (`RR.applyTone`) multiplies each pixel by `plan.toneGainLUT`.
- The GPU (`RG.applyTone`) multiplies by a gray cube baked from the same `toneGainLUT`
  (`RenderPlan` 505-575, `toneGainCube`).
- `toneGainLUT` is `ToneEngine.bakeGainLUTAndFloor()`, which samples
  `stops(at:) = zonalStops + (contrastMapped(t) − t) + zonePanelStops`.

So a change confined to `contrastMapped` is identical on CPU and GPU by construction. No
kernel and no WS-07 function changes. S15 checks this, and also checks that the new curve
is smooth enough for the cube's knot spacing: one knot per 0.77 EV at 32, one per 0.37 EV
at 65. Without that, `ToneShippingGoldenTests` (macOS parity, contrast +60) could lose its
headroom.

## Spec lines

The keys are as printed by `run_all.sh`, which is the command for every line.

| # | Claim | Key(s) | Threshold | Baseline |
|---|---|---|---|---|
| **S1** | Contrast 0 is an exact identity of the curve. `contrastMapped(t) == t` holds bitwise for t in ±12 EV at 0.001 EV steps, at pivots {−4, −3, −2, −1.3, 0, 2, 2.37, 3, 3.5, 4} × Whites {−100, 0, 67, 100} × Blacks {−100, 0, 100}. `isIdentity`, `toneIsIdentity` and the default LUT hold at every pivot. | `S1_identity_mismatches` | = 0 | 0 |
| **S2** | Contrast 0 renders byte-identical PNGs to the default recipe: 6929 at pivots −4, −1.3, 2.37 and 4. | `P5_identity_png_mismatches` | = 0 | 0 |
| **S3** | The curve is monotone with margin, over c ∈ ±100 in steps of 5 × the S1 pivot/anchor grid, inside the live anchors. Secant derivative at 0.001 EV: overall minimum ≥ 0.40 (−100's own flattening). For c > 0, minimum ≥ 0.50 (shoulder and toe margin). No inversion anywhere in ±12 EV. | `S2_min_derivative`, `S2_min_derivative_positive_c`, `S2_full_scale_inversions` | ≥ 0.40; ≥ 0.50; = 0 | 0.400; 0.4105; 0 |
| **S4** | The pivot (as clamped) and both live anchors are fixed points. Points 0.01-4 EV beyond either anchor map to themselves. | `S3_fixed_point_error` | ≤ 1e-12 EV | 0 |
| **S5** | Slope law at the pivot: s(+100) in [1.60, 2.00] and s(−100) in [0.40, 0.50]. The slope rises strictly with every unit of the slider (c = −100…100, step 1). | `S4_slope_plus100`, `S4_slope_minus100`, `S4_slope_nonincreasing_steps` | as stated; = 0 | 1.600; 0.400; 0 |
| **S6** | The zonal limiter never scales Contrast. The pivot slope with H −100 / S +100 (c +100), and with all four zonal sliders (c −100), equals the slope alone. | `S4_limiter_touches_contrast` | ≤ 1e-9 | 0 |
| **S7** | Softer toe: deep shadows are not dragged down. At c +100, pivot 0, \|mapped(−6) + 6\| ≤ 0.55 EV and \|mapped(−7) + 7\| ≤ 0.30 EV. | `S5_shift_minus6EV_c100`, `S5_shift_minus7EV_c100` | ≤ 0.55; ≤ 0.30 | −1.354; −0.792 |
| **S8** | The top two stops keep their separation. On the rendered grey ramp (pivot 0), codes spanned by +2…+4 EV relative to contrast 0 are ≥ 0.55 at +100 and ≥ 0.75 at +50. Lightroom also compresses here; there is no measured LR number. | `R3_top_span_ratio_c+100`, `R3_top_span_ratio_c+50` | ≥ 0.55; ≥ 0.75 | 0.419 (18 of 43 codes); 0.686 |
| **S9** | Shadows are not crushed to code 0. % of pixels with any channel at code 0 at contrast +100: 1346 ≤ 7.0, 4694 ≤ 3.6, 2348 ≤ 2.0. At contrast 0 these are 0.53, 0.007 and 0.66. See the note on S9 below. | `P1_code0_pct_c+100_{1346,4694,2348}` | ≤ 7.0 / 3.6 / 2.0 | 8.968 / 4.379 / 3.144 |
| **S10** | Highlight clipping does not get worse. 983 at Exposure +1.5, Contrast +100: % of pixels with a channel at 255. This is non-regression only. A ratio-preserving gain with a pinned white must brighten bright colours between pivot and white, so the tooltip (S23) now says so instead of claiming otherwise. | `P2_code255_pct_983_exp+1.5_c+100` | ≤ 0.45 | 0.439 (0.001 at c 0) |
| **S11** | Grey stays clean, and the pivot stays put in the output. Ramp at pivots {−4, −3, −2, 0, 2, 3, 4} × c {±100, ±50, 0}: 0 columns at 255 or 0 within −9…+4.5 EV, and 0 reversed columns. The rendered code at the pivot EV moves ≤ 1.0 code for pivots within ±3. Pivots ±4 are included for old recipes. | `R2_grey_clipped_or_reversed_columns`, `R1_pivot_code_drift` | = 0; ≤ 1.0 | 0; 0.5 |
| **S12** | It still feels like contrast. Rendered midtone slope at the pivot (codes/EV over ±0.25 EV, ramp): ≥ 80 at +100 and ≤ 26 at −100. At contrast 0 it is 54. | `R4_mid_slope_c+100`, `R4_mid_slope_c-100` | ≥ 80; ≤ 26 | 85; 21 |
| **S13** | Proof authority stays above the floor with margin, and the travel is balanced. This is a replica of `ProofRunner.measure` for `tone.contrast` on `ProofFrames.neutralRamp`, 21 steps, 65 tables. It reproduces the committed 68.3819 and 0.635477 exactly. Authority ≥ 57 (floor 55); frontLoading in [0.42, 0.58]; deadSteps = 0. | `S8_authority_tone.contrast`, `S8_frontLoading_tone.contrast`, `S8_deadSteps_tone.contrast` | ≥ 57; in [0.42, 0.58]; = 0 | 68.38; 0.635; 0 |
| **S14** | The zonal limiter does not get materially worse; see the note on S14 below. Applied fraction of Highlights −100 at c +100 ≥ 0.845. Shadows +100 at c −100 ≥ 0.619. Worst of the 16 single-slider-vs-±100 pairs ≥ 0.619. Four-way corner (c ∈ {80, 100}, the generator's grid) ≥ 0.620. Moderate band (the generator's ±60/±40 grid) ≥ 0.990. Composed tone map `t + stops(t)` minimum derivative ≥ −0.001 (WS-05's sampling residue, not to grow). | `S6_*` | as stated | 0.8460; 0.6192; 0.6192; 0.6468; 0.9939; −0.00084 |
| **S15** | CPU = GPU source, and the cube can follow the curve. For c {−100, −37, 50, 100} × pivot {−3, 0, 2.5}, `RenderPlan.toneGainLUT == tone.bakeGainLUT()`, and every sample equals 2^stops(t_i) (≤ 1e-9 EV). Linear interpolation of the LUT at 32 and 65 knots, against the 1024-sample LUT, over −9…+5 EV: worst over c {±50, ±100} × pivot {−3, 0, 3} ≤ 0.105 / 0.035 EV. At contrast +60, pivot 0 (the `ToneShippingGoldenTests` case) ≤ 0.036 / 0.0090 EV. | `S7_lut_vs_stops_max_err_EV`, `S7_cube{32,65}_interp_err_EV`, `S7_golden_c60_cube{32,65}_interp_err_EV` | as stated | 0; 0.1013 / 0.0249; 0.0341 / 0.0084 |
| **S16** | The slider is smooth and evenly weighted. 6929 and 2545, contrast −100…+100 in steps of 10. Per-step mean \|Δluma\|: max/min ≤ 1.6, and every neighbouring-step ratio ≤ 1.15. RMS luma rises at every step. | `P3_step_ratio_*`, `P3_adjacent_step_ratio_*`, `P3_rms_nonincreasing_*` | ≤ 1.6; ≤ 1.15; = 0 | 2.279 / 2.153; 1.050 / 1.044; 0 |
| **S17** | +N and −N are about equal and opposite on screen, as a Lightroom user expects. dRMS(+100)/\|dRMS(−100)\| in [0.75, 1.33], and dRMS(+50)/\|dRMS(−50)\| in [0.80, 1.25], on 6929 and 2545. | `P4_sym_100_*`, `P4_sym_50_*` | as stated | 0.558 / 0.653; 0.750 / 0.806 |
| **S18** | Hue is held. ColorChecker (synthetic, 65 table), 18 chromatic patches, worst over ±50 and ±100: mean \|Δh\| ≤ 0.75°, max ≤ 2.5°. Lightroom is "usually within ±3°". | `C1_hue_mean_abs_deg`, `C1_hue_max_abs_deg` | ≤ 0.75; ≤ 2.5 | 0.492; 1.984 |
| **S19** | Honest saturation statement for what this lane ships: Contrast changes lightness only. Chart mean OKLab ΔC/L at ±100 within ±3%. Photo mean C/L (6929, 2545) moves ≤ 1% across the sweep. Retired when S20 lands. | `C2_sat_CL_pct_c+100`, `C2_sat_CL_pct_c-100`, `C2_photo_CL_change_pct_*` | as stated | −1.562; +0.250; 0.159 / 0.341 |
| **S20** | **OPEN: needs WS-07 (NEEDS.md N1).** Lightroom-like coupling at half rate: chart mean ΔC/L of +6…+15% at +100, +3…+8% at +50 and −20…−8% at −100, with S18 still met. `run_all.sh` prints OPEN, never PASS, until it is in range. | `C2_sat_CL_pct_c+100/+50/-100` | as stated | −1.562; −0.614; +0.250 |
| **S21** | Pivot stays a live control inside its drag range. Authority (proof replica, contrast 50, pivot −3 vs +3) ≥ 20. Every 0.25 EV move of the pivot within ±3 changes `contrastMapped` by ≥ 0.05 EV somewhere, at Whites {0, 100} × Blacks {−100, 0, 100}. | `S8_authority_pivot_-3_3`, `S9_min_move_per_quarter_EV_pivot_in_pm3` | ≥ 20; ≥ 0.05 | 84.09; 0.075 |
| **S22** | Panel ranges. Pivot: `range: -3...3, hardRange: -4...4`, step 0.01. Contrast unchanged: −100…100, step 1. | `U1_pivot_range_ok`, `U1_contrast_range_ok` | = 1 | 0 (range −4…4, no hardRange); 1 |
| **S23** | Tooltips are true (D4). Contrast: no "cannot clip"; says the white and black points stay fixed and that strong settings compress or flatten the brightest and darkest tones; claims no saturation boost while S20 is open. Pivot: says a raised Pivot darkens the picture under positive Contrast. | `T1_contrast_tooltip_truthful`, `T2_pivot_tooltip_truthful` | = 1 | 0; 0 |

**Note on S9.** The target is a reduction of about 20-35%, not elimination. Code 0 on these
frames comes mostly from dark *saturated* pixels whose smallest channel reaches 0 under a
ratio-preserving gain. Any curve that darkens the −2…−4 EV band (an S-curve has to) produces
some of it. S7 is the line that guarantees the deep toe itself is left alone.

**Note on S14.** Only the four-way corner may fall, by at most 0.027, to the generator's
existing floor of 0.62. All the other limiter numbers may not fall at all. This is the
"how much is allowed" for the limiter: the witness raises the paired cases from 0.62 to
0.89, and Highlights −100 from 0.85 to 1.00. The generator floors (0.60 paired, 0.62
four-way, 0.93 moderate) stay as they are and must not be lowered.

**INFO rows**, printed but not judged:

- slope at ±50
- log2 asymmetry
- log-span +2…+4 EV
- proof-ramp per-step peak ratio
- pivot authority over ±4
- pivot 3.5 vs 4 at Whites +100, which is dead and typed-only (D3)
- rendered code at each pivot

## Visual claims

A human judges these. Render the before set with a build of the baseline commit, for
example `git worktree add /tmp/ws06-base 7d2fe14` and `swift build -c release --product
lumen-render` there. Render the after set with the branch, then:

```
bash docs/quality/lanes/WS-06/measure/sheets.sh <base lumen-render>  /tmp/ws06-sheets/before
bash docs/quality/lanes/WS-06/measure/sheets.sh <after lumen-render> /tmp/ws06-sheets/after
python3 -I docs/quality/lanes/WS-06/measure/compose.py /tmp/ws06-sheets/before /tmp/ws06-sheets/after docs/quality/lanes/WS-06/evidence
```

The full-resolution sheets (long edge 1024, Contrast −100, −50, 0, +50, +100) are
`/tmp/ws06-sheets/{before,after}/V*/sheet.png`; judge at 100%. The committed evidence is
eight files under 400 KB each: `V*_sweep_before_after.png` and
`V*_crop100_before_after.png`.

- **V1. 6929 (A7 IV) sweep, `V1_6929/sheet.png`.**
  - +100 reads as clearly more contrasty in the foliage midtones than before.
  - The deep foliage shadows keep their leaf separation instead of going to flat black.
  - −100 is a gentle flattening, not a grey wash.
  - +50 and −50 look about equally strong.
  - The crop (`V1_6929_crop100_before_after.png`, foliage against the wall) shows shadow
    texture surviving at +100.
- **V2. 1346 (Passport, dark surround) sweep, `V2_1346/sheet.png`.**
  - At +100 the dark chart patches, the black card and the dark surround stay separable
    from one another.
  - The white patch does not merge with the light greys.
  - Check in the crop (`V2_1346_crop100_before_after.png`) that the four dark patches still
    read as four tones.
- **V3. 983 at Exposure +1.5 sweep, `V3_983_exp1.5/sheet.png`.**
  - At +100 the snow, the lantern glass and the pale chart patches keep visible separation
    (crop `V3_983_exp1.5_crop100_before_after.png`).
  - There is no new clipped area compared with before.
- **V4. 2545 (GX85), `V4_2545/sheet.png` and the crop at the sky/tree edge.**
  - No new halo or band appears at the tree line at ±100.
  - The S7 mask is WS-07's. This claim is that the curve change did not make the audit's
    finding 6 worse.

## Tests the builder must add (Tests/LumenCoreTests, e.g. `ContrastCurveTests.swift`)

Each is the unit-test form of a spec line, with the same threshold:

1. `testContrastZeroIsABitwiseIdentityAtEveryPivotAndAnchor` (S1).
2. `testContrastIsMonotoneWithMarginInsideTheLiveAnchors`, over the S3 grid, including
   Whites/Blacks ±100 and pivots 3.5 and 4. Minimum ≥ 0.40 overall and ≥ 0.50 for c > 0.
3. `testContrastFixesThePivotAndBothLiveAnchors`, including beyond-anchor identity (S4).
4. `testContrastSlopeLaw` (S5). It replaces the pinned values of
   `EngineTests.testContrastHitsItsSlopeAtThePivot`; see below.
5. `testContrastIsNeverScaledByTheZonalLimiter` (S6).
6. `testContrastLeavesTheDeepShadowsAlmostAlone` (S7).
7. `testContrastKeepsTheTopTwoStopsApart`, rendered with `ReferenceRenderer` on a
   `ProofFrames.neutralRamp`-style ramp, 65 tables, sRGB codes: ratio ≥ 0.55 at +100 and
   ≥ 0.75 at +50 (S8).
8. `testContrastTradeTable`: the five S14 limiter numbers.
9. `testTheBakedGainLUTIsStopsForContrastRecipes` and
   `testTheGainCubeCanFollowTheContrastCurve` (S15: 32/65-knot errors at the S15 bounds).
10. `testContrastTravelIsBalancedOnTheProofRamp`: authority ≥ 57 and frontLoading in
    [0.42, 0.58], using `ProofRunner.measured` for `tone.contrast` (S13).

## Existing tests and fixtures that change. Do not loosen them silently.

Each change goes in the same commit as the curve, with the reason stated in REPORT.md. A
test that encodes the old curve's *numbers* is updated to the new numbers, measured. A test
that encodes a *property* (monotone, fixed point, identity, the floors) must pass
unchanged.

- **`Tests/LumenCoreTests/Fixtures/enginemath.json`** (`contrast_mapped` block, checked at
  1e-12 by `EngineMathFixtureTests.testContrastMappingMatchesTheReference`).
  - Port the new curve to `contrast_mapped` in `scripts/gen-fixtures.py`, then regenerate
    with `pip install xxhash && python3 scripts/gen-fixtures.py`.
  - Commit only the fixture diffs the curve causes. `python3 scripts/gen-fixtures.py
    --check` must pass afterwards.
  - The generator's own contrast checks change with the curve and must be updated to the
    new law, not deleted: the slope at the pivot (about line 1573), the shoulder comment,
    and `CONTRAST_SHOULDER_START` if it goes away.
  - Its limiter floors stay: paired ≥ 0.60, four-way ≥ 0.62, moderate > 0.93, and the
    `bound > 0` / `worst_scale < 1` binding assertions.
- **`EngineTests.testContrastHitsItsSlopeAtThePivot`.** It pins 1.6, 1.3 and 0.4. Update it
  to the new law's values at ±0.01, and keep the test.
- **`EngineTests`** `testContrastPivotHoldsStill`,
  `testContrastLeavesTheExtremesOfTheLogScaleAlone`,
  `testContrastCannotPushAPixelPastTheDisplayAnchors`,
  `testTheContrastFixedPointFollowsTheAnchorsWhitesAndBlacksMove`,
  `testAPivotPastTheWhiteAnchorStillCannotPushAPixelPastIt` and
  `testContrastIsMonotoneAcrossTheWholeScaleAtEverySetting`: must pass unchanged.
- **Must pass unchanged:**
  - `RobustnessTests.testToneIsMonotoneAcrossTheWholeContrastRange` and
    `testRenderedLuminanceIsMonotoneAtExtremeSettings`
  - `ColourAccuracyTests.testContrastKeepsTheWhiteAnchorFixedWhenWhitesPullsItBelowThePivot`
  - `AccuracyProbeTests.testContrastLeavesMidGreyExactlyAlone` (0.25 code)
  - `MaskingTests.testAMaskedContrastPinsTheGlobalDisplayAnchorsNotTheFactoryOnes`. The local
    masked Contrast uses the same `contrastMapped`.
  - `ZoneFlatteningTests.testTheSixSlidersNeverReachTheClamp`
- **`AppliedReadoutTests.testAnEasedSliderIsNamedWithTheAmountTheRenderApplies`.** It
  expects "−94" for Highlights −100 at Contrast −100, and "Blacks (tone shelf) +91 of +100".
  With a better curve these cases may no longer ease at all.
  - Re-point the test at a recipe that still binds, for example the four-way corner, and
    assert the engine's own applied value. Do not delete it.
  - Also check `testUntouchedAndSingleSliderAtContrastZeroAreNeverCaptioned` and the grid
    test after it.
- **`RobustnessTests` limiter cases, about lines 1027-1320.** These include the comment at
  1182 citing 0.846 / 0.619. Update the numbers to the measured new ones. The "stops rising
  2% above the solved limit" probes must still pass.
- **Proof records.**
  - Re-record `Tests/LumenCoreTests/Proof/records/tone.contrast.json` and
    `tone.contrastPivot.json` with `LUMEN_RECORD_PROOFS=1 swift test --filter
    ControlProofTests`.
  - Commit only those two. If any other record moves, explain it, or treat it as a bug.
  - Do not change `authorityFloor` (55 / 20); that is WS-58's registry.
- **Comments that state numbers.** The trade table and the derivative paragraph in the
  `contrastShoulderStart` and `contrastMapped` comments say "the generator asserts all three
  numbers". Rewrite them with the new measured numbers, or remove them together with the
  constant.
- **macOS-only parity tests** (not runnable on Linux; the verifier reasons about them from
  S15): `ToneShippingGoldenTests.testEachToneSliderMovesTheShippingGraphAndTracksTheReference`
  (contrast +60, bounds 0.018 export / 0.035 interactive), `KernelGoldenTests` (contrast 25)
  and `DragProbeTests` / `PerfProbeTests` (contrast 20). S15's golden-case lines keep the
  cube error at or below the baseline's for the +60 case.

## Out of lane, recorded, not acted on here

- The chroma term (N1, WS-07).
- The proof-registry pivot travel (N2, WS-58).
- The 33-cube finish table's 2-4° low-chroma hue swing (WS-12).
- Exposure-driven hue rotation of bright saturated colours (WS-13).
- The mask band at about 1 EV edges under strong Contrast (WS-07, audit finding 6).
- Whether a global Contrast should use the guided mask at all (WS-07).

## Baseline run (build `7d2fe14`, `run_all.sh`, 2026-10-21)

```
id   key                                            measured  rule            baseline  verdict
S1   S1_identity_mismatches                                0  == 0                   0  PASS
S2   P5_identity_png_mismatches                            0  == 0                   0  PASS
S3   S2_min_derivative                                   0.4  >= 0.40            0.400  PASS
S3   S2_min_derivative_positive_c                   0.410481  >= 0.50           0.4105  FAIL
S3   S2_full_scale_inversions                              0  == 0                   0  PASS
S4   S3_fixed_point_error                                  0  <= 1e-12               0  PASS
S5   S4_slope_plus100                                    1.6  in 1.60 2.00       1.600  PASS
S5   S4_slope_minus100                                   0.4  in 0.40 0.50       0.400  PASS
S5   S4_slope_nonincreasing_steps                          0  == 0                   0  PASS
S6   S4_limiter_touches_contrast                           0  <= 1e-9                0  PASS
S7   S5_shift_minus6EV_c100                         -1.35417  abs<= 0.55        -1.354  FAIL
S7   S5_shift_minus7EV_c100                        -0.792181  abs<= 0.30        -0.792  FAIL
S8   R3_top_span_ratio_c+100                        0.418605  >= 0.55            0.419  FAIL
S8   R3_top_span_ratio_c+50                         0.686047  >= 0.75            0.686  FAIL
S9   P1_code0_pct_c+100_1346                         8.96761  <= 7.0             8.968  FAIL
S9   P1_code0_pct_c+100_4694                          4.3791  <= 3.6             4.379  FAIL
S9   P1_code0_pct_c+100_2348                         3.14448  <= 2.0             3.144  FAIL
S10  P2_code255_pct_983_exp+1.5_c+100               0.438612  <= 0.45            0.439  PASS
S11  R2_grey_clipped_or_reversed_columns                   0  == 0                   0  PASS
S11  R1_pivot_code_drift                                 0.5  <= 1.0               0.5  PASS
S12  R4_mid_slope_c+100                                   85  >= 80                 85  PASS
S12  R4_mid_slope_c-100                                   21  <= 26                 21  PASS
S13  S8_authority_tone.contrast                      68.3819  >= 57             68.382  PASS
S13  S8_frontLoading_tone.contrast                  0.635477  in 0.42 0.58       0.635  FAIL
S13  S8_deadSteps_tone.contrast                            0  == 0                   0  PASS
S14  S6_hl-100_at_c+100                              0.84595  >= 0.845          0.8460  PASS
S14  S6_sh+100_at_c-100                             0.619248  >= 0.619          0.6192  PASS
S14  S6_worst_paired_scale                          0.619248  >= 0.619          0.6192  PASS
S14  S6_four_way_corner_scale                        0.64682  >= 0.620          0.6468  PASS
S14  S6_moderate_band_scale                         0.993856  >= 0.990          0.9939  PASS
S14  S6_composed_min_derivative                    -0.000843  >= -0.001       -0.00084  PASS
S15  S7_lut_vs_stops_max_err_EV                            0  <= 1e-9                0  PASS
S15  S7_cube32_interp_err_EV                        0.101347  <= 0.105          0.1013  PASS
S15  S7_cube65_interp_err_EV                        0.024937  <= 0.035          0.0249  PASS
S15  S7_golden_c60_cube32_interp_err_EV             0.034118  <= 0.036          0.0341  PASS
S15  S7_golden_c60_cube65_interp_err_EV              0.00842  <= 0.0090         0.0084  PASS
S16  P3_step_ratio_6929                              2.27868  <= 1.6             2.279  FAIL
S16  P3_step_ratio_2545                              2.15321  <= 1.6             2.153  FAIL
S16  P3_adjacent_step_ratio_6929                     1.05036  <= 1.15            1.050  PASS
S16  P3_adjacent_step_ratio_2545                     1.04423  <= 1.15            1.044  PASS
S16  P3_rms_nonincreasing_6929                             0  == 0                   0  PASS
S16  P3_rms_nonincreasing_2545                             0  == 0                   0  PASS
S17  P4_sym_100_6929                                0.558219  in 0.75 1.33       0.558  FAIL
S17  P4_sym_100_2545                                0.652576  in 0.75 1.33       0.653  FAIL
S17  P4_sym_50_6929                                 0.750305  in 0.80 1.25       0.750  FAIL
S17  P4_sym_50_2545                                 0.806445  in 0.80 1.25       0.806  PASS
S18  C1_hue_mean_abs_deg                            0.491831  <= 0.75            0.492  PASS
S18  C1_hue_max_abs_deg                              1.98428  <= 2.5             1.984  PASS
S19  C2_sat_CL_pct_c+100                            -1.56236  abs<= 3           -1.562  PASS
S19  C2_sat_CL_pct_c-100                            0.249855  abs<= 3            0.250  PASS
S19  C2_photo_CL_change_pct_6929                    0.158754  <= 1               0.159  PASS
S19  C2_photo_CL_change_pct_2545                    0.340532  <= 1               0.341  PASS
S20  C2_sat_CL_pct_c+100                            -1.56236  in 6 15           -1.562  OPEN
S20  C2_sat_CL_pct_c+50                            -0.613588  in 3 8            -0.614  OPEN
S20  C2_sat_CL_pct_c-100                            0.249855  in -20 -8          0.250  OPEN
S21  S8_authority_pivot_-3_3                         84.0936  >= 20             84.094  PASS
S21  S9_min_move_per_quarter_EV_pivot_in_pm3           0.075  >= 0.05            0.075  PASS
S22  U1_pivot_range_ok                                     0  == 1                   0  FAIL
S22  U1_contrast_range_ok                                  1  == 1                   1  PASS
S23  T1_contrast_tooltip_truthful                          0  == 1                   0  FAIL
S23  T2_pivot_tooltip_truthful                             0  == 1                   0  FAIL
INFO: slope ±50 1.300/0.700; log2 asymmetry −0.644; log span +2..+4 1.363 EV;
      proof-ramp step peak ratio 2.304; pivot authority ±4 100.29 (record 100.288);
      pivot 3.5 vs 4 at Whites +100 0.0000 EV; codes at pivot −4…4: 10 20 40 118 207 234 250
17 lane line(s) FAIL
```
