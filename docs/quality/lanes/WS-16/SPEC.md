# WS-16 acceptance spec: Saturation, Vibrance, Density, Protect Skin, Black & White

Lane: `quality/ws-16-saturation-vibrance`. Owned code: the WS-16 row of `docs/quality/workstreams.md`
(line 48). Source of findings: the WS-16 audit (F1-F14). Cross-lane items are in `NEEDS.md`.

## How to measure

```
export PATH=/opt/swift/usr/bin:$PATH
bash docs/quality/lanes/WS-16/measure/run_all.sh        # ~2 min after the builds
```

`run_all.sh` builds `lumen-render` and the stage probe in release, runs each `m_*.py`, and renders the
visual sheets. Each line prints `<ID> PASS|FAIL <measured value> (threshold: ...)`. You can also run
any single script with `python3 docs/quality/lanes/WS-16/measure/m_<group>.py`.

There are two kinds of measurement:

- **Stage.** `measure/probe` (`ws16probe`) runs the S9 finish pass alone, through `ColorEngine`
  (Double) and `ExactColorStage` (the Float twin that ReferenceRenderer and the GPU run). It takes
  OKLCh in Lumen's working context (Rec.2020 linear, `OKLabTransform.working`). The skin and
  ColorChecker hues quoted below are in this measure. Standard Ottosson OKLab of the same patches
  agrees to within 0.1 deg. The standard grid is L {0.3, 0.45, 0.6, 0.75, 0.9} x C {0.01 ... 0.30} x
  h every 5 deg. "In-gamut" means the input has no negative Rec.2020 channel. Stage lines use the
  twin's output.
- **Output.** These go through `lumen-render` (`--no-dither`) to an 8-bit sRGB PNG and are measured
  in standard OKLab. Real photos are rendered at `--long-edge 1024`. The six photos are 6929 (A7 IV),
  2545 (GX85), 2242, 4694, 1346 and 8559. Renders are cached under `/tmp/ws16-measure`, keyed on the
  binary's size and mtime.

"Default Density" and "default Protect" mean whatever `lumen-render keys` reports, so if the
default changes, the measurement follows it.

## Scoping decisions

1. **Hue is specified at the S9 stage output (HUE-1), not at the PNG.** S9 already holds OKLab hue
   to 0.002 deg. The output hue drift (up to 15.6 deg on the ColorChecker at Sat +100) comes from
   `DisplayTransform`. It soft-clips to the Rec.2020 boundary, and then the sRGB encode hard-clamps
   each channel. Neither step belongs to this lane. That is NEEDS N1, with target numbers.
2. **What the lane owns on gamut is SAT-4 and SAT-5.**
   - SAT-4: a push must never take an in-gamut colour out of the working gamut, Rec.2020. That is
     also the boundary `DisplayTransform` clips to.
   - SAT-5: the push must approach that boundary softly, without plateaus. Plateaus are what show up
     as clipping blotches.
   - This is feasible inside the owned functions. `shapedChromaScale` and the twin's `chromaScale`
     already work on (J, C, h). They can find the boundary chroma at that J and h, either by bisection
     on min(RGB) >= 0 (about 12 steps; at fixed L each channel is a cubic in C) or with a closed-form
     cubic root. They can then replace the absolute knee (`satCompress`: knee 0.18, ceiling 0.34) with
     a compression relative to that boundary. The GLSL needs the same loop.
   - S9 is not given the sRGB/P3 output gamut, so the lane does not limit to it. SAT-6 only guards
     against making sRGB clipping worse.
3. **Protect Skin gets its own band.** The probe measures skin in the stage context as follows:
   - ColorChecker light skin h 40.7 / C 0.068, dark skin h 42.3 / C 0.052.
   - Monk MST 1-9: h 43.6-84.6, C 0.015-0.070 (MST 3/4 at 84.6, MST 8 at 43.6). MST 10 is C 0.011
     and is treated as neutral.
   - ColorChecker orange is h 53.6 / C 0.152, and orange-yellow is h 75.8 / C 0.149.

   **Orange and skin overlap completely in hue.** Hue cannot separate them, but chroma can: every skin
   patch is C <= 0.070, and the oranges are C >= 0.149. So the protection band must be a hue band
   covering about 38-88 deg, plus a chroma plausibility that is full up to about 0.09 and zero by
   about 0.145.
   - Both edges need wide smooth feathers (SKIN-4 and SKIN-5). For example, a smoothstep about 30 deg
     wide in hue and 0.09 -> 0.145 in chroma is enough.
   - The low-chroma gate must reach MST 1 (C 0.015). The current log ramp from 0.006 to 0.06 gives
     only 35% there.
   - The current band is +/-10 deg around `skinLineDegrees` = 56.4, which centres it on orange. That
     is the cause of F1.
   - `skinWeight` has the same fault: it scores light skin 0, MST 3/4/5 0 and orange 1. However,
     `skinLineDegrees` and `skinBandDegrees` are read by the vectorscope (`Scopes.swift`, not owned),
     and `skinWeight` is pinned by Skin-tool tests. **So the builder adds new constants for
     `skinProtectionWeight` and leaves `skinWeight`, `skinLineDegrees` and `skinBandDegrees`
     unchanged.** The realignment of those is NEEDS N3.
4. **Density stays.** Reasons:
   - It has a visible, distinct effect (DEN-3: dE 4.8 on 2242) that is free of artefacts. Colours
     deepen like dye instead of going neon.
   - It costs nothing when it is off.

   But it must not act **silently at its default**. At the default of 50, Sat +100 is a 0.16-0.19 EV
   darkening that the user never asked for, and Lightroom's Saturation is luminance-neutral.
   - **Decision:** at the default Density, a Saturation push is a pure chroma scale (DEN-1, SAT-2).
   - **Recommended implementation:** change the `ColorAdjust.density` default to 0 and draw Density as
     a plain (non-bipolar) slider from 0 to 100. Saved recipes keep their stored value. Recentring 50
     as a neutral point of a bipolar control would also satisfy the lines, but it changes what stored
     values mean, so it is discouraged.
   - Density must be drawn at all times, enabled, like Protect Skin (UI-1, UI-3). That gives the owner
     "all of the sliders showing up". Its help text must say that it shapes Saturation pushes.
   - Making it act on Vibrance pushes as well is allowed but not required.
   - Update `ColorAdjust.densityIsLive` and its test (`testDensityIsLiveExactlyWhereItChangesThePicture`)
     to match. The panel must no longer gate drawing on it.
5. **Vibrance protection on pulls.** VIB-7 forbids the hue wedge that Vib -100 now leaves at the
   default Protect. The builder chooses how: no protection on pulls, or protection that is uniform in
   effect. Saturation -100 must still reach true B&W everywhere (SAT-3).
6. **B&W:**
   - The response must become exponential in EV, for example grey = Y * 2^(k * Σ w_i * gate(C) * b_i),
     symmetric in +/-, with a soft chroma gate that keeps growing to C about 0.12.
   - That gate must be the lane's own. `chromaGate` and `bandWeights` belong to WS-31 and must not be
     changed.
   - Band centres (`bandHueCentres`) are out of scope (NEEDS N2). BW lines are measured at whatever
     centres the code has.
7. **Twin and GPU.** Every constant change goes into `ColorEngine`, `ExactColorTwin` and
   `ExactColorKernelSource.finish` in the same commit. PAR-2 is a structural text check that the GLSL
   finish kernel carries exactly the twin's literals. macOS `gpu-parity.yml` is the real GPU check.

## Acceptance lines

Status is the baseline: the current code at `84bcd7c`, measured on 2026-10-21. Every FAIL here is
expected to become PASS.

### Identity and continuity (`m_identity.py`)

| id | claim | threshold | baseline | status |
|---|---|---|---|---|
| ID-1 | Every default is an exact identity at the output: Vib 0, Sat 0, Density default, Protect default, Density 0/100 + Protect 0/100 with Sat = Vib = 0, B&W disabled with bands set. Measured on colorchecker, hue_wheel, skin_tones and 2545. | max \|dcode\| = 0 | 0 | PASS |
| ID-2 | At the default `ColorAdjust`, with no B&W, the stage reports identity and builds no pass. | `engine=true stage=true passes=0` | as required | PASS |
| ID-3 | No step leaving the default. Sat/Vib +/-1 (colorchecker, hue_wheel) and each B&W band +/-1 (colorchecker) move about half as far as +/-2. | max (d1-1)/d2 <= 0.75 | 0.50 | PASS |

### Hue and Saturation (`m_saturation.py`)

| id | claim | threshold | baseline | status |
|---|---|---|---|---|
| HUE-1 | Stage: Sat and Vib at -100/-50/-25/+25/+50/+100 hold OKLab hue. Covers Density 0/default/100 and Protect 0/default/100, in-gamut grid, C0 > 0.02. | max \|dh\| <= 0.1 deg | 0.0017 deg | PASS |
| SAT-1 | Stage: pulls are a uniform chroma scale. Sat -25/-50/-75, every in-gamut sample with C0 > 0.02. | max \|C1/C0 - (1+s)\| <= 0.005 | 0.079 | **FAIL** |
| SAT-2 | Stage: pushes are a uniform chroma scale where they stay well inside the gamut. Sat +25/+50/+100 at default Density and Protect 0, samples with (1+s)·C0 <= 0.6 x the Rec.2020 boundary chroma at (L, h), L 0.3-0.75. | min C1/C0/(1+s) >= 0.95 | 0.832 | **FAIL** |
| SAT-3a | Stage: Sat -100 is monochrome whatever Protect (0/default/100) and Vibrance (-100/0/+100) are. | max output C <= 1e-5 | 6.2e-7 | PASS |
| SAT-3b | Output: Sat -100 at Protect 100 is grey on colorchecker, hue_wheel and skin_tones. | max \|R-G\|, \|G-B\| <= 1 code | 1 | PASS |
| SAT-4 | Stage: pushes keep in-gamut colours inside Rec.2020. Sat +25/+50/+100, Vib +50/+100, and Vib +100 with Sat +100, each at Density 0/default/100 and Protect 0. | 0 samples with a channel < -1e-4 | 8187 samples, worst -0.177 | **FAIL** |
| SAT-5 | Stage: no plateau (no gamut blotch). Output chroma keeps rising with input chroma. Sat +100 (Protect 0/default; Density 0/default/100), Vib +100 (Protect 0/default), Vib + Sat +100. Lines at C 0.002-0.40, 200 steps, every L and h of the grid. | min dCout/dCin >= 0.3 | -0.064 (Sat +100, Density 100); Vib +100 0.042 | **FAIL** |
| SAT-6a | Output guard: newly clipped pixels at Sat +100 on hue_wheel. | <= 26.4% (baseline + 1 pp) | 25.4% | PASS |
| SAT-6b | Same, on 2242. | <= 16.6% | 15.6% | PASS |
| SAT-6c | Same, on 4694. | <= 14.3% | 13.3% | PASS |

### Vibrance (`m_vibrance.py`)

| id | claim | threshold | baseline | status |
|---|---|---|---|---|
| VIB-1 | Stage: low-chroma priority. Gain never rises with chroma (C 0.02-0.30; L 0.45/0.6/0.75; non-skin hues 0/150/200/250/300; Vib +50/+100), and low chroma gets much more. | rise <= 0.001 and (g(0.03)-1)/(g(0.20)-1) >= 2.5 | 0.000 and 7.57 | PASS |
| VIB-2 | Stage: gentler than Saturation (Protect 0, Density 0). On non-skin colours with C0 >= 0.12, Vib +100 adds at most half what Sat +100 adds. Nowhere does Vib +100 add more than Sat +100. | max (gV-1)/(gS-1) <= 0.5 and max (gV - gS) <= 0.01 | 0.72 and 0.000 | **FAIL** |
| VIB-3 | Output, 6 photos: Vib +100 is visibly gentler overall. Median chroma ratio over pixels with C0 > 0.02. | (medVib-1)/(medSat-1) <= 0.85 on each photo | 1.17 (4694) | **FAIL** |
| VIB-4 | Output, 6 photos: Vib +100 clips less than Sat +100. Newly clipped fraction, denominator floored at 0.5%. | Vib/Sat <= 0.8 on each photo | 1.92 (6929) | **FAIL** |
| VIB-5a | Stage: skin is protected at the default Protect. For each skin patch (CC light/dark skin, MST 1-9), compare its gain increment at Vib +100 with that of a matched (L, C) colour at h 150 and 250, taking the smaller. | <= 0.35 x | 1.00 | **FAIL** |
| VIB-5b | Output: skin_tones MST 1-9 at Vib +100, default Protect. | max patch chroma gain <= 1.35 | 2.13 (MST 3) | **FAIL** |
| VIB-6 | Output, 6 photos: Vib -100 leaves a muted image, not a monochrome one. | median chroma ratio within [0.30, 0.80] on each | 0.00-0.04 | **FAIL** |
| VIB-7 | Stage: Vib -100 has no hue wedge (colour-splash). L 0.6, C 0.06/0.10, h every 0.5 deg, default Protect. | max \|dgain/dh\| <= 0.01/deg and gain range over hue <= 0.15 | 0.207/deg and 0.695 | **FAIL** |
| VIB-8 | Output: shadow chroma noise on 2348 (ISO 3200), Vib +100. High-passed a/b std over L < 0.35. | amplification <= 1.6 | 1.89 | **FAIL** |

### Protect Skin (`m_skin.py`)

| id | claim | threshold | baseline | status |
|---|---|---|---|---|
| SKIN-1 | Stage, Sat +100, default Protect: every skin patch (CC light/dark skin, MST 1-9) is protected. Gain increment relative to the same patch at Protect 0. | (g-1)/(g_P0-1) <= 0.45 | 1.00 (light skin) | **FAIL** |
| SKIN-2 | Same at Protect 100. | <= 0.15 | 1.00 (light skin) | **FAIL** |
| SKIN-3 | Stage, Sat +100, default Protect: non-skin colours that share the skin hues are not protected. Patches: orange, orange yellow, yellow, red, moderate red, foliage. | (g-1)/(g_P0-1) >= 0.8 | 0.39 (orange) | **FAIL** |
| SKIN-4a | Stage: no seam in hue. Sat +100 and Vib +100, default Protect, L 0.5/0.7, C 0.03/0.06/0.10, h every 0.5 deg. | max \|dgain/dh\| <= 0.04/deg | 0.207/deg | **FAIL** |
| SKIN-4b | Same at Protect 100. | <= 0.06/deg | 0.296/deg | **FAIL** |
| SKIN-5 | Stage: no seam in chroma in the skin hues (h 40/55/70/85, L 0.6/0.75, C 0.03-0.20), Sat/Vib +100 at default Protect and Protect 100. Chroma order is kept. | \|dgain\| per 0.01 C <= 0.3, no inversion | 0.169, none | PASS |
| SKIN-6 | Output: skin_tones MST 1-9 at Sat +100, default Protect. | max patch chroma gain <= 1.45 | 2.12 (MST 3) | **FAIL** |

### Density (`m_density.py`)

| id | claim | threshold | baseline | status |
|---|---|---|---|---|
| DEN-1a | Stage: at the default Density, Sat +100 does not darken. Median log2(Y1/Y0) over the in-gamut grid with C0 > 0.02. | >= -0.06 EV | -0.186 EV | **FAIL** |
| DEN-1b | Output: mean luminance of Sat +100 (default Density) vs Sat 0 on 2242, 4694 and 6929. | \|shift\| <= 0.08 EV | -0.161 EV (2242) | **FAIL** |
| DEN-2 | Stage: a positive Saturation never lowers chroma. Sat +25/+50/+100 x Density 0/25/50/75/100. | min C1/C0 >= 0.9999 | 0.944 | **FAIL** |
| DEN-3 | Output: Density does something visible. 2242, Sat +100, Density 100 vs 0, mean OKLab dE x 100. | >= 2.0 | 4.78 | PASS |
| DEN-4 | Stage: Density's effect is monotone. Median dY at Sat +100 does not rise with Density 0 -> 100, and at 100 it is at least 0.1 EV below Density 0. | monotone and <= -0.1 EV | -0.029 ... -0.343 | PASS |

### Black & White (`m_bw.py`)

EV here is log2(grey / default-mix grey). The default mix (all bands 0) is Rec.2020 Y.

| id | claim | threshold | baseline | status |
|---|---|---|---|---|
| BW-1 | Stage: depth. A band at -100 darkens a saturated colour at its centre (L 0.6, C 0.10/0.15), and +100 brightens it. | -100 in [-2.5, -1.0] EV; +100 in [+1.0, +2.5] EV | -97.6 EV (black); +1.00 | **FAIL** |
| BW-2 | Stage: the response is symmetric and linear in EV, at the same points. | \|EV(+100)+EV(-100)\| <= 0.1 and \|EV(+/-50)/EV(+/-100) - 0.5\| <= 0.1 | 96.6 and 0.49 | **FAIL** |
| BW-3a | Stage: there is a floor. Over the whole in-gamut grid, no single band at -100, and not all eight at -100, takes a colour more than 3 EV down. | min EV >= -3.0 | -99.4 | **FAIL** |
| BW-3b | Output: 2545 (GX85) with Azure -100. Fraction of pixels newly at code <= 2. | <= 0.1% | 3.40% | **FAIL** |
| BW-4 | Stage: soft chroma gate. Band -100 at its centre, L 0.6, C 0-0.20. The effect grows gradually and is not saturated by C 0.04. | \|dEV\| per 0.01 C <= 0.3 and EV(0.04)/EV(0.12) <= 0.75 | 186 EV per 0.01 C | **FAIL** |
| BW-5 | Stage: smooth in hue (L 0.6, C 0.10, h every 0.5 deg, each band +/-100). All eight at -100 is a uniform shift, and two adjacent bands at -100 leave no notch between their centres. | max \|dEV/dh\| <= 0.08 EV/deg, all-band spread <= 0.05 EV, pair spread <= 0.1 EV | 174/deg, 74, 74 | **FAIL** |
| BW-6a | Stage: neutrals are fixed exactly. R=G=B at 0.001-4.0, under every band +/-100, all +/-100, and a mixed setting. | relative error <= 1e-6 | 1.2e-7 | PASS |
| BW-6b | Output: colorchecker neutral patches 19-24 under each band +/-100. | <= 0.5 code | 0.00 | PASS |
| BW-7 | Stage: the default mix (all bands 0) equals Rec.2020 Y. | relative error <= 1e-5 | 1.7e-7 | PASS |

### Parity (`m_parity.py`)

| id | claim | threshold | baseline | status |
|---|---|---|---|---|
| PAR-1 | The Float twin matches the Double `ColorEngine` over a grid (C 0.005-0.30, h every 3 deg, plus neutrals). Settings: 22 combinations of Sat, Vib, Density, Protect and B&W. | max \|dRGB\| / max(1, \|x\|) <= 1e-4 | 1.26e-5 | PASS |
| PAR-2 | The GLSL `ExactColorKernelSource.finish` (plus the prelude helpers it calls) carries exactly the numeric literals of the twin's finish family: `hkFactor` through the end of `finish`, plus `cbrt3/toLab/toRGB/lch/lab/wrapHue/hueDelta/smoothstep/gate/protectGate/membership`. A structural check, since the GPU cannot run on Linux. | no literal in only one of them | none | PASS |

### UI (`m_ui.py`; a text check on `BasicPanel.saturationRows`)

| id | claim | threshold | baseline | status |
|---|---|---|---|---|
| UI-1 | Vibrance, Saturation, Density and Protect Skin are all drawn unconditionally: not inside `if`/`switch`/`guard`, not hidden. | all four | Density inside `if densityIsLive` | **FAIL** |
| UI-2 | Protect Skin is not drawn bipolar. Its range is 0-100 with default 70, so a centre tick is misleading. | no `bipolar: true` | `bipolar: true` | **FAIL** |
| UI-3 | Density is enabled at all times, like Protect Skin: no `.disabled(...)`. | no `.disabled(` | none | PASS |

Help strings are not measured, but the verifier must read them against these results. The Vibrance
help ("skin is protected ... safer everyday boost") must be true by VIB-2, VIB-3 and VIB-5. The
Protect Skin help must not say a Vibrance pull reaches B&W. The Density help must say that it
deepens Saturation pushes and is off by default (or whatever the chosen default means).

### Unit tests (`m_tests.py`)

| id | claim | threshold | baseline | status |
|---|---|---|---|---|
| TEST-1 | Each of these lines has an XCTest in `Tests/LumenCoreTests` whose name contains `WS16_<ID without dash>` (e.g. `testWS16_SKIN4a_NoHueSeam`), asserting the threshold above on the Double engine and/or `ExactColorStage`: HUE-1, SAT-1, SAT-2, SAT-3a, SAT-4, SAT-5, VIB-1, VIB-2, VIB-5a, VIB-7, SKIN-1, SKIN-2, SKIN-3, SKIN-4a, SKIN-5, DEN-1a, DEN-2, DEN-4, BW-1, BW-2, BW-3a, BW-4, BW-5, BW-6a, BW-7, PAR-1, ID-2. `swift test --filter WS16` passes, and `swift test --filter LumenCoreTests` passes, or its failures are proven pre-existing. | 27/27 present, all green | 0/27 | **FAIL** |

Existing tests that encode the old behaviour must be changed in the same commit, with the reason
given in REPORT.md. They include `ProtectSkinChromaOrderTests` (and its assertion that `skinWeight`
is unchanged; keep that one, since `skinWeight` is not to move), the B&W tests that assume a linear
gain in Y, `testDensityIsLiveExactlyWhereItChangesThePicture`, and any golden that renders Sat > 0 at
the old default Density.

## Visual claims (`python3 docs/quality/lanes/WS-16/measure/visual.py`)

The sheets are written to `/tmp/ws16-measure/sheets/`. The top row is labelled tiles and the bottom
row is 100% crops. Copy the before/after versions into `evidence/`.

- **VIS-1** `vis1_wheel_sat_vib.png` (hue_wheel at Sat 0 / Sat +100 / Vib +100 / Vib -100, with a
  100% crop of the 0-90 deg quadrant):
  - No straight radial edge or wedge anywhere in the orange-skin sector at any of the three settings.
  - Vib -100 is evenly muted all round, with no sector that stays coloured.
  - Sat +100 shows no flat, featureless blotches where colours meet the gamut edge.
  - Baseline: two radial seams at about 41 deg and 71 deg on Sat +100 and Vib +100, and a coloured
    wedge on Vib -100. **FAIL.**
- **VIS-2** `vis2_2545_bw_azure.png` (GX85, B&W, Azure -100/-50/0/+50/+100, with a 100% crop of the
  sky and tree edge):
  - At -100 the sky is a deep grey that still shows its cloud gradient.
  - The branches against the sky keep their fine structure, with no black matte, halo or hard cut-out
    edge.
  - Going from -100 to +100 looks evenly spaced.
  - Baseline: the sky is pure black at -100, and the tree is a hard matte against it. **FAIL.**
- **VIS-3** `vis3_4694_sat_vs_vib.png` (still life 0 / Sat +100 / Vib +100 / Vib -100) and
  `vis3_6929_vib.png` (A7 IV, 0 / Vib -100 / Vib -50 / Vib +100):
  - Vib +100 is visibly gentler than Sat +100 on the lemon and the tomatoes. The tomatoes keep their
    modelling and do not go to flat red.
  - Vib -100 looks muted but clearly coloured, not black and white.
  - Baseline: Vib +100 is stronger than Sat +100, and Vib -100 is near-monochrome. **FAIL.**

## Baseline summary

19 of 49 measured lines pass (TEST-1 included), and 0 of 3 visual claims do. Every failing line maps
to an audit finding:

| failing lines | finding |
|---|---|
| SKIN-*, VIB-5 | F1, F2 |
| VIB-2/3/4 | F3 |
| VIB-6/7 | F4 |
| SAT-4/5 | F5, the lane-owned half |
| DEN-1/2 | F6 |
| UI-1/2 | F7 |
| SAT-1/2 | F8 |
| BW-1 to BW-5 | F9 |
| VIB-8 | F12 |
