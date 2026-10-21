# WS-15 Dehaze: acceptance spec

The Spec role wrote this from `AUDIT.md`, before any code change. Every measurable line below is checked by one command, and the baseline column is what that command measured on the **current, unfixed** code (branch `quality/ws-15-dehaze`, renderer built from it).

## How to run

Run from `docs/quality/lanes/WS-15/`. The builder rebuilds first with `PATH=/opt/swift/usr/bin:$PATH swift build -c release --product lumen-render`.

```
tools/check_spec.sh spec-work/current            # render (~3 min, 4 cores) + check every line (~2 min)
tools/check_spec.sh spec-work/current --swift    # also runs `swift test --filter WS15` (U-lines, gates A1-A3)
tools/check_spec.sh spec-work/current --no-render --only P1,C3   # re-check selected lines
```

- Each line prints `PASS`/`FAIL` with every per-frame number. The exit status is 0 only when every evaluated line passes.
- The results JSON goes to `<WORKDIR>/spec_results.json`.
- The baseline run is in `spec-work/baseline/`:
  - `check.txt` holds the full printout.
  - `spec_results.json` holds the same results as JSON.
- In the table, "command" means `tools/check_spec.sh W --no-render --only <ID>` after one full render into `W`.

### What gets rendered

`tools/spec_render.py` renders:

- All six frames: 983, 1840, 4213, 3437, 2545, 6929.
- For each frame:
  - 2400 px renders at dehaze 0, +50, +100, −50 and −100, plus one with no dehaze key at all.
  - 512 and 2048 px renders at 0, +60 and −60.
  - A 512 px sweep from −100 to +100 in steps of 10.
  - A 1024 px sheet.
- The synthetic frames colorchecker, hard_edge and grey_ramp at 1024 px.
- The crops for the visual claims.

Render settings: undithered, with as-shot WB taken from each sidecar.

### Tool changes made for this spec

These are measurement scripts only. No product code was touched.

- `tools/spec_render.py` (new): renders everything above.
- `tools/check_spec.py` and `tools/check_spec.sh` (new): run the checks.
- `tools/dehaze_metrics.py` gained `box_blur`, `local_contrast`, `band_std_L`, `mottle_index` and `sky_bands`.
- `tools/airlight_probe.py` gained a `--json` spec mode that reports the selection's share inside forbidden boxes and its stability between 512 and 2048 px.
- `tools/regions.json` gained `airlight_forbidden`, `skyband` and `mottle` boxes.

### Lightroom wording

There are no Lightroom exports (`corpus/lightroom/` is empty). Lines marked **[LR-doc]** follow documented or widely reported LR behaviour:

- Positive Dehaze raises saturation and contrast in hazy regions and darkens moderately.
- Negative Dehaze adds a milky, near-neutral veil that is stronger in the distance.

Lines marked **[LR-est]** use the auditor's *estimate* of LR's magnitudes, for example LR +100 darkening by about 0.3–0.7 EV. None of these is measured against LR. Re-derive the bands once LR exports exist.

The remaining lines come from physics or colour science, or from the brief's "no halos, no hue shifts that weren't asked for, identity at default" rule.

## Measurable lines

**Baseline: 6 of 40 lines pass. The baseline fails 34 lines.**

Notes on the column contents:

- "all six" means 983, 1840, 4213, 3437, 2545 and 6929.
- "landscapes" means 983, 1840, 4213, 3437 and 2545.
- Unless a line says otherwise, renders are 2400 px and the comparison is always against dehaze 0 of the same frame at the same size.
- The baseline column lists the failing rows, or the worst row when the line passes.

### I: identity

| # | Claim | Threshold | Frames | Baseline | Command |
|---|---|---|---|---|---|
| I1 | Dehaze 0 renders pixel-identical to a recipe without the key | max \|diff\| = 0 codes | all six + colorchecker, hard_edge, grey_ramp | **PASS**, 0 everywhere | `--only I1` |

### P: positive Dehaze, tone and detail

| # | Claim | Threshold | Frames | Baseline | Command |
|---|---|---|---|---|---|
| P1 | No new crushed shadows: % of pixels that newly reach code 0 in any channel | +50 ≤ 0.02 %, +100 ≤ 0.05 % | all six | **FAIL**: 983 +100 0.147; 4213 +100 0.141; 1840 +100 0.061; 1840 +50 0.020 (edge) | `--only P1` |
| P2 | Deep shadows kept, not driven to black: ratio of p1 linear Y, out/base | +50 ≥ 0.70, +100 ≥ 0.50 | all six | **FAIL**: 4213 +100 0.296; 3437 +100 0.288; 983 +100 0.333; 6929 +100 0.404; 3437 +50 0.608; 983 +50 0.667 | `--only P2` |
| P3 | [LR-est] Overall exposure drift is moderate: mean linear-Y change | +50 in [−0.40, +0.10] EV; +100 in [−0.70, +0.10] EV | all six | **FAIL**: 4213 +100 −1.551, +50 −0.625; 983 +100 −0.960, +50 −0.421 | `--only P3` |
| P4 | [LR-est] Overcast sky is not turned into a storm sky: sky0 OKLab L change | +100 dL ≥ −0.15 | 4213 | **FAIL**: −0.247 | `--only P4` |
| P5 | [LR-doc] Haze-region detail rises, not just darkens. Local RMS contrast in the `far` box (std of encoded Y minus its 21×21 box mean at 2400 px), out/base | 4213: +50 ≥ 1.12, +100 ≥ 1.30. 983, 1840, 3437: +100 ≥ 1.15 | 4213, 983, 1840, 3437 | **FAIL**: 4213 1.021 / 1.041; 1840 1.007; 3437 1.088 (983 1.312 ok) | `--only P5` |
| P6 | Low-haze frames are not wrecked at +50: ΔE2000 vs base | mean ≤ 2.5, p95 ≤ 6.0 | 2545, 6929 | **FAIL**: 6929 p95 7.01 (mean 2.02; 2545 0.76 / 1.57) | `--only P6` |
| P7 | No mottling on flat white surfaces. OKLab L (5×5 box) of the output is fitted to the base as `g·L+c`. The residual std divided by the base L std counts the new blotches that are neither an exposure nor a contrast change | +50 ≤ 0.12, +100 ≤ 0.20 | 6929 `wall_upper` and `white_wall`, 983 `snow`, 2545 `house_wall` | **FAIL**: 6929 upper 0.206 / 0.520, white_wall 0.186 / 0.445; 983 snow 0.177 / 0.478 (2545 0.075 / 0.188 ok) | `--only P7` |

### C: colour

| # | Claim | Threshold | Frames | Baseline | Command |
|---|---|---|---|---|---|
| C1 | [LR-doc] Blue-sky chroma does not fall; it rises modestly. sky0 OKLab C (of mean a,b), out/base | +50 and +100 in [1.00, 1.40] | 983, 1840, 2545 | **FAIL**: 983 0.821 / 0.599; 1840 0.886 / 0.794; 2545 0.959 / 0.848 | `--only C1` |
| C2 | Sky mean hue holds, so the sky does not go purple or cyan: sky0 OKLab hue shift | \|dh\| ≤ 3.0° at +50 and +100 | 983, 1840, 2545 | **FAIL**: 1840 +50 3.19 (others ≤ 2.62) | `--only C2` |
| C3 | No violet/cyan banding toward the horizon. Sky pixels in the `skyband` box are cut into strips 2 % of the frame high, and each strip's OKLab hue shift is measured | max \|dh\| ≤ 3.0° and max − min ≤ 4.0° at +50 and +100 | 983, 1840, 2545 | **FAIL**: 1840 +100 4.58 / spread 8.10; 1840 +50 4.08 / 6.42; 2545 +100 3.30 / 4.39 | `--only C3` |
| C4 | Neutrals stay neutral: OKLab a/b drift on 983 snow, CC B1/E3/E4/E5, 4213 tower and grey sky, 2545 house wall and 6929 white wall | \|da\|, \|db\| ≤ 0.003 at +50 and +100 | 983, 4213, 2545, 6929 | **PASS** (worst 0.0023, 983 snow +100) | `--only C4` |
| C5 | [LR-est] Snow and white walls are not crushed to grey: OKLab L change at +100 | snow and walls dL ≥ −0.08; CC white B1 ≥ −0.05 | 983, 4213, 2545, 6929 | **FAIL**: 983 snow −0.188; 6929 wall −0.119 | `--only C5` |
| C6 | Synthetic ColorChecker at +50 and +100 (patch rects from the frame's truth): <ul><li>greys 19–24 keep their lightness (dL ≥ −0.05) and neutrality (\|da\|, \|db\| ≤ 0.003)</li><li>no patch gets a rim/centre split (\|split\| ≤ 0.02 OKLab L)</li><li>patches with C > 0.02 keep their chroma (ratio ≥ 0.90) and hue (\|dh\| ≤ 3°)</li></ul> | as stated | colorchecker | **FAIL**: <ul><li>+100: grey #21 dL −0.49, rim split 0.261, chroma #5 0.427, \|dh\| 5.78</li><li>+50: grey #22 dL −0.157, split 0.061, chroma 0.806, dh 5.97</li><li>grey tint ok (0.0024)</li></ul> | `--only C6` |
| C7 | Synthetic hard_edge: <ul><li>the flat 0.18 grey band is not darkened</li><li>no rim forms around the bright disc. The rim is ΔL in the 1.03–1.12 R annulus minus ΔL in the 1.4–1.6 R annulus</li></ul> | band dL ≥ −0.05 at +100; \|rim\| ≤ 0.02 at ±100 | hard_edge | **FAIL**: band −0.395; rim +0.030 (+100) and −0.037 (−100) | `--only C7` |
| C8 | Synthetic grey_ramp has no tone reversal: <ul><li>continuous ramp: no drop of more than 1 code between columns</li><li>15-step wedge: no step drops by more than 0.5 code</li></ul> | at +100 and −100 | grey_ramp | **PASS** (guard line) | `--only C8` |

### H: halos

Every edge profile in `regions.json` is measured on both sides of the edge. The near-edge value is log2(out/base) next to the edge minus the far plateau on the same side (`dehaze_metrics.m_halo`).

| # | Claim | Threshold | Frames | Baseline | Command |
|---|---|---|---|---|---|
| H1 | No glowing or dark band at horizons, canopies or trunks at +100 | \|near − plateau\| ≤ 0.30 EV, every side of every profile | 4213 (×2), 983 (×2), 2545, 1840 (×2), 3437 trunk | **FAIL**: 4213 +3.18 / +3.01 EV; 983 peak +2.25; 3437 trunk +1.17 / −1.59; 2545 +0.78; 983 trees +0.74; 1840 x650 +0.42 / −0.33 | `--only H1` |
| H2 | Halo band width at +100: px from the edge where \|dev\| > 0.1 EV | ≤ 48 px (2 % of the long edge) | same | **FAIL**: 983 peak 193; 4213 134 / 99; 2545 133; 983 trees 132; 1840 87; 983 dark 65; 3437 dark 55 | `--only H2` |
| H3 | No halo from the veil at −100 | ≤ 0.30 EV | same | **FAIL**: 3437 +0.86 / −0.61; 983 peak −0.53; 4213 dark −0.52 / −0.31 | `--only H3` |

### A: airlight

The baseline comes from emulating the current rule (`airlight_probe.py --json`). After the fix, the gate is U10, which prints the same fields; with `--swift`, `check_spec` takes U10's numbers.

| # | Claim | Threshold | Frames | Baseline | Command |
|---|---|---|---|---|---|
| A1 | The airlight comes from sky or haze, not from white or coloured objects. Measured as the share of the selected pixels inside the `airlight_forbidden` boxes: CC chart and lamp (983), tank and pink lid (3437), house wall and roof (2545) | ≤ 0.05 at 512 and 2048 px | 983, 3437, 2545 | **FAIL**: 983 1.00 / 1.00; 2545 1.00 / 0.062; 3437 0.291 / 0.487 | `--only A1` (gate: `--swift --only A1`) |
| A2 | 3437's airlight, and hence its veil, is not magenta: g/(r+g+b) of A | ≥ 0.315 at 512 and 2048 px | 3437 | **FAIL**: 2048 0.299 (512 0.320) | `--only A2` |
| A3 | The airlight does not change between 512 and 2048 px: chromaticity distance and luminance ratio | dist ≤ 0.010; ratio in [0.90, 1.10] | all six | **FAIL**: 2545 0.127 / 1.389 (the wall↔sky flip); 3437 0.022 | `--only A3` |

### N: negative Dehaze (veil)

| # | Claim | Threshold | Frames | Baseline | Command |
|---|---|---|---|---|---|
| N1 | [LR-doc] The veil is atmospheric: the distance is lifted more than the foreground. Far-box OKLab L lift divided by the lift of the bottom 15 % | ≥ 1.20 at −50 and −100 | landscapes | **FAIL**: 3437 0.34 / 0.34; 2545 0.63 / 0.63; 1840 0.93 / 0.95 (983 1.45, 4213 1.72 ok) | `--only N1` |
| N2 | [LR-doc] The veil is near-neutral, with no pink or mauve wash and no blue foreground. Mean OKLab shift at −100 | near: hypot(da, db) ≤ 0.006 and da ≤ +0.003. far: da ≤ +0.003 and db ≥ −0.006 (desaturating toward grey is allowed) | all six | **FAIL**: 3437 near 0.0112 (da +0.0104), far da +0.0054; 2545 near 0.0069 (blue) | `--only N2` |
| N3 | [LR-doc] A milky veil lifts the blacks of the distance: far-box p1 OKLab L rise at −100 | ≥ +0.02 | landscapes | **FAIL**: 1840 0.003; 2545 0.010 | `--only N3` |
| N4 | Contrast falls monotonically as the veil grows: far-box OKLab L std at 0, −10 … −100 (512 px sweep) | strictly decreasing, and std(−100)/std(0) ≤ 0.85 | all six | **FAIL**: <ul><li>1840 and 4213 are not monotone</li><li>ratios are 0.92–1.02 on every frame</li></ul> | `--only N4` |

### S: slider response (512 px sweep, steps of 10)

| # | Claim | Threshold | Frames | Baseline | Command |
|---|---|---|---|---|---|
| S1 | Monotone: mean ΔE2000 vs dehaze 0 strictly increases with \|v\| on each side | every step > 0 | all six | **PASS** (min step 0.148, 1840 neg) | `--only S1` |
| S2 | Even: max/min step on each side | ≤ 1.5 | all six | **PASS** (worst 1.48, 4213 neg) | `--only S2` |
| S3 | No jump and no dead zone at 0: first step / median step | in [0.5, 1.5] | all six | **PASS** (range 0.84–1.26) | `--only S3` |
| S4 | Rough balance of strength: ΔE(−100)/ΔE(+100) | in [0.50, 1.50] | 983, 1840, 4213, 3437 | **FAIL**: 4213 0.39 | `--only S4` |

### R: preview vs full size

The 2048 px render is area-averaged in linear light down to 512 px and compared with the 512 px render. "Excess" means the difference minus the same pair's difference at dehaze 0.

| # | Claim | Threshold | Frames | Baseline | Command |
|---|---|---|---|---|---|
| R1 | Excess mean ΔE2000 | ≤ 0.40 at +60 and −60 | all six | **FAIL**: 2545 1.483 / 0.649; 3437 0.667 / 0.498 (6929 +60 0.366 ok) | `--only R1` |
| R2 | Excess p95 ΔE2000 | ≤ 1.20 at ±60 | all six | **FAIL**: 2545 +60 2.753; 3437 +60 1.355 | `--only R2` |
| R3 | Brightness agreement: \|mean encoded-Y difference − the dehaze-0 difference\| | ≤ 1.5 codes at ±60 | all six | **FAIL**: 2545 7.53 / −5.14; 3437 3.66 / −2.13; 6929 +60 2.18 | `--only R3` |

### G: CPU/GPU structural parity

The GPU path cannot run on Linux. These lines are greps over the source, with `//` comments stripped.

| # | Claim | Threshold | Baseline | Command |
|---|---|---|---|---|
| G1 | The GPU dehaze kernel (`Kernels.dehazeSource`) has the sky guard: a bright-and-flat term that lifts the t floor | kernel source contains a `sky…` term | **FAIL** | `--only G1` |
| G2 | The GPU negative branch uses the CPU distance, `max(1 − t, skyness)` | the kernel's `distant` expression contains `max` and the sky term | **FAIL**: `clamp(1.0 - raw, 0.0, 1.0)` | `--only G2` |
| G3 | The sky-guard constants are named once in `DetailEngine` and read by both paths | <ul><li>at least 3 `static let dehazeSky*` constants</li><li>each is referenced in `RenderGraph.swift` or `Kernels.swift` and in CPU `applyDehaze`</li><li>no bare `smoothstep(0.5, 2.0` or `smoothstep(0.05, 0.35` left in CPU `applyDehaze`</li></ul> | **FAIL**: 0 names, 2 literals | `--only G3` |
| G4 | The GPU airlight rule is the CPU rule | <ul><li>`RenderGraph.applyDehaze` has no `* 0.99` threshold</li><li>it calls the shared estimator (`estimateAirlight`, `airlightEstimate` or a `DetailEngine.dehazeAirlight*` constant)</li></ul> | **FAIL** | `--only G4` |
| G5 | The GPU guide radius comes from the filtered image, as on the CPU, not from `options.longEdge` | no `Double(longEdge) * 0.02` in `RenderGraph.applyDehaze` | **FAIL** | `--only G5` |
| G6 | BUILDING.md no longer says the dehaze sky guard is reference-only | phrase absent | **FAIL** | `--only G6` |

**G7. Read by the verifier, not scripted.** In the diff, CPU (`DetailEngine.applyDehaze`, `Decomposition.airlight/transmission`, `SpatialOps.estimateAirlight`) and GPU (`RenderGraph.applyDehaze`, `Kernels.dehazeSource`) must share all of the following:

- (a) the same ω, tMin/Distance, t clamp [0.02, 1] and dark-channel radius rule (short edge / 100, ≥ 3);
- (b) the same airlight selection rule: the same region restriction, rejection of white or specular objects, and fraction, evaluated at a resolution-normalised scale on both paths. The GPU may run it on a proxy only if A1–A3 hold at 512 px, which is the proxy's own scale;
- (c) the sky-guard "flat" measure, defined resolution-independently (gradient per fraction of the frame, not EV/px; AUDIT 14) and computed identically on both paths;
- (d) the same recovery formula on both paths, per channel or ratio-plus-chroma, whichever the CPU adopts, with the same trust/clamp guards;
- (e) the same negative-branch veil colour and distance;
- (f) any new plane the kernel needs (gradient, logLum or skyness) is built from the same definition as the CPU's `Decomposition` plane.

Each mismatch is a FAIL, with the line number.

### U: unit tests

The builder adds these Swift tests to `Tests/LumenCoreTests`. They must pass on Linux with `swift test --filter WS15`, and `check_spec --swift` reports each one.

They live in class `WS15DehazeSpecTests`, except U10, which lives in `WS15DehazeAirlightCorpusTests`. They use synthetic frames built in the test, mostly `ProofFrames.hazySky` plus small additions, and call `DetailEngine.Decomposition` / `applyDehaze` directly at S8, in scene-linear.

| # | Test | Assertion |
|---|---|---|
| U1 | `testIdentityAtZero` | `applyDehaze(amount: 0)` returns the input bit-for-bit (I1). |
| U2 | `testPositiveRestoresSkyChromaAndGroundContrast` | On `hazySky` at +100: sky-half OKLab chroma ≥ 1.0× base (C1); ground RMS log contrast ≥ 1.3× (P5); recovered sky colour is closer to the clear-scene sky than the input is (ground truth is known). |
| U3 | `testPositiveExposureDriftBounded` | On `hazySky` at +100, mean linear-Y change ≥ −0.7 EV (P3) and zero negative pixels. |
| U4 | `testAirlightIgnoresWhiteCard` | `hazySky` plus a flat white card (RGB 0.9, in the lower 40 % of the frame, 10 % of its area): `airlight()` chromaticity is within 0.02 of `hazySkyAirlight`, and ≤ 5 % of the selection lies on the card (A1). |
| U5 | `testAirlightIgnoresMagentaObject` | `hazySky` plus a bright pink patch (0.6, 0.35, 0.6) in the lower frame: A has g/(r+g+b) ≥ 0.315, and the −100 veil over the ground has OKLab da ≤ +0.003 (A2, N2). |
| U6 | `testNeutralPatchKeepsLightnessAndTint` | A grey card (0.45) in the `hazySky` ground at +100: OKLab dL ≥ −0.05, \|da\|, \|db\| ≤ 0.003, and rim-centre split ≤ 0.02 (C5, C6). |
| U7 | `testNegativeVeilFarExceedsNear` | On `hazySky` at −100: the top-third OKLab L lift is ≥ 1.2× the bottom-third lift, and the veil's (da, db) hue is within 30° of the airlight's (N1, N2). |
| U8 | `testNoHaloAtSkyTreelineStep` | Hazy sky over a dark step edge (256 px frame): the log2(out/in) deviation from each side's plateau is ≤ 0.3 EV and wider than 0.1 EV for at most 2 % of the long edge, at +100 (H1, H2). |
| U9 | `testScaleStableAirlightAndOutput` | `hazySky` plus a white card rendered at 128 and 512 px: airlight chromaticity distance ≤ 0.01 and luminance within 10 %. The 512 px output area-averaged to 128 px is within mean ΔE 0.4 of the 128 px output, above the dehaze-0 pair's own difference (A3, R1). |
| U10 | `testCorpusAirlight` (`WS15DehazeAirlightCorpusTests`) | Skipped with `XCTSkip` when `corpus/lfi/*.lfi` is absent. Otherwise, for each of the six frames: <ul><li>read the LFI (16-byte header, then float32 RGB)</li><li>area-downsample to 512 and to 2048 long edge, as `lumen-render` step 1 does</li><li>build `Decomposition(image:workingRadius: max(2 % long edge, 3))` and read the airlight together with its selection (the builder exposes the selection weights or mask)</li><li>print one line `WS15AIRLIGHT {json}` with exactly `airlight_probe.py --json`'s per-frame schema plus `"id"`, with forbidden boxes from `tools/regions.json`</li><li>assert A1–A3</li></ul> |
| U11 | `testMonotoneBothSides` | On `hazySky`, mean \|Δ\| vs the input strictly increases over −100…100 in steps of 10, and the first-step/median ratio is in [0.5, 1.5] (S1–S3). |

Update the existing tests that encode the old behaviour in the same commit and give the reason: `FieldBaselineProbeTests.testPrintsTheDehazeBaseline`, `Proof/records/detail.dehaze.json` and `ScaleHonestyTests`. Do not loosen them.

Baseline for U: **FAIL**, because none of these tests exists. `check_spec.py --swift` reports all eleven by name, so the names above are binding.

## Visual claims (human judgement)

Crops come from `tools/spec_render.py`, written to `<WORKDIR>/crops/`. Each is a 100 % crop of the 2400 px renders, placed side by side. For the baseline they are in `spec-work/baseline/crops/`.

- **V1. Depth without darkening.**
  - Crops:
    - `crops/4213_horizon.png` (0 | +50 | +100)
    - `crops/983_peak_snow.png` (0 | +50 | +100)
    - `crops/983_snow_fg.png` (0 | +100)
  - Pass when:
    - At +100 the treeline and castle show more separation and detail than at 0.
    - The overcast sky keeps its cloud structure and is not a storm-dark band.
    - There is no glow band above the treeline.
    - The snow on the peak and in the foreground stays white snow, with no grey or black blotches.
  - Baseline: FAIL. The sky goes storm-dark with a bright band over the treeline, and the snow peak turns mottled grey and black.
- **V2. Sky colour and edges.**
  - Crops (`1840_treeline` has ×1.6 gain to show the bands):
    - `crops/1840_treeline.png` (0 | +50 | +100)
    - `crops/2545_sky_tree.png` (0 | +50 | +100)
    - `crops/3437_trunk.png` (0 | +100)
  - Pass when:
    - The blue sky gets richer, not duller.
    - There is no lavender band high in the sky and no cyan rim hugging the canopy.
    - There is no bright or dark band along branches or trunks.
  - Baseline: FAIL. The 1840 +100 sky shows a violet upper band over a cyan rim, and the 3437 trunk edges are darkened and haloed.
- **V3. Believable haze and clean walls.**
  - Crops:
    - `crops/3437_veil.png` (0 | −50 | −100)
    - `crops/4213_veil.png` (0 | −50 | −100)
    - `crops/6929_wall.png` (0 | +50 | +100)
  - Pass when:
    - The veil reads as a light, near-neutral atmospheric haze that thickens with distance: background meadow and treeline more than the foreground grass.
    - The grass does not turn lilac.
    - At +50 and +100 the white wall stays a clean wall: darker or more contrasty is fine, but no new dark blotches.
  - Baseline: FAIL. The 3437 grass goes mauve-grey and the foreground is veiled more than the distance. The 6929 wall grows dark blotches at +100, already visible at +50.

The 1024 px sheets (`<WORKDIR>/sheets/<id>_sheet.png`, values −100 to +100) and the 512 px fine sheets (`<WORKDIR>/sweep/<id>_fine_sheet.png`) back up the judgement on smoothness.

## Why these thresholds

- Each threshold is set just tighter than the audit's failing number, and loose enough that a sound He-style method can pass it. A sound method here means:
  - recovery per channel, or ratio plus chroma;
  - an airlight restricted to bright, flat regions in the upper frame, with white and specular objects rejected;
  - a sky/neutral guard that is resolution-independent;
  - a negative veil that is near-neutral and weighted by distance.
- The baseline already passes some of these numbers on its good frames, so the thresholds are reachable:
  - 4213 and 983 already reach a veil far/near ratio of 1.45–1.72 (N1).
  - Neutral tint is already ≤ 0.0024 (C4).
  - The low-haze frame 2545 already has a residual mottling of 0.19 (P7).
  - The 512/2048 excess is ≤ 0.16 everywhere except where the airlight flips (R1).
- P3, P4, C5 and P6 are only as LR-relative as the audit's estimates (marked [LR-est]). If LR exports later show a stronger darkening, widen those bands, and only those.
- C8, C4 and S1–S3 pass today. They are guard lines that must stay passing.
