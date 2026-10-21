# WS-41 Vignette: verification (round 1)

**Verdict: FAIL.** Lines 17, 18 and 19 miss their written thresholds. One more defect is outside the 3:2 spec lines: the feather-0 edge aliases on wide crops.

The parts that pass are solid:
- Legacy identity holds, checked independently against the base build (0 mismatches).
- The geometry controls (Midpoint, Feather, Roundness), Highlights, tone monotonicity, banding and the crop-relative CPU all pass.
- 3077 LumenCoreTests pass, and the GPU kernel matches the CPU code argument for argument.

The failures are colour lines. Part of each failure cannot be reached by a stage that holds scene hue exactly; part of it is the implementation's fault. Details below.

Inputs: SPEC.md, LANE-BRIEF §1/§4 and `git diff de61270 HEAD` (BUILD-NOTES.md not used). Linux, Swift 6.0.3.

## What was run

| Step | What |
|---|---|
| Builds | `swift build -c release --product lumen-render` (HEAD). `swift build --target LumenCore --target LumenRender` from a deleted debug dir: clean (2 pre-existing `VerifiedCopy.swift` Sendable warnings only). Base `de61270` built in a worktree for byte comparison. |
| Tests | `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` on a `git archive HEAD` copy, clean build. This is CI's Linux lane. The two `CompareView.swift` trailing commas were removed in that scratch copy only, because Swift 6.0.3 cannot parse them. Result: **3077 tests, 0 failures**, including all Vignette*Tests, CanonicalJSON, CanonicalDefaultsBaseline, LookAmount, SettingsSubset, SavedLook, ControlIndex, SliderEvidence and SliderContract. ControlProofTests was not run (CI skips it in that lane). |
| Other checks | `python3 scripts/gen-fixtures.py --check`: all match. `scripts/check-swift-surface.py`: green. `swiftc -parse` of all Sources: only the pre-existing CompareView errors. |
| Float probe | A scratch SwiftPM package outside the repo linking LumenCore. It runs `ReferenceRenderer.render` (display-linear float, no 8-bit rounding) or `DetailEngine.vignette` alone (scene-linear) on the same downsampled input. Used for the hue analysis (lines 17-19) and the extreme-value sweeps. |

## Per-line results (measured by the verifier)

| # | Result | Measured (threshold) |
|---|---|---|
| 1 | PASS | `identity.py`: 0/52 mismatches. Independent base-vs-HEAD byte compare: 48/48 identical without crop. Cases: flat_grey, skin_tones, 6929, 2545 × Amount −4/−1/+2 × {no feather key, feather 50} × {dither, no dither}. With a crop, 48/48 differ, by design: the CPU now lays the vignette out on the crop (line 22). |
| 2 | PASS | `identity.py --explicit`: 0/52. |
| 3 | PASS | `--amount-zero`: 0 mismatches. Also: Amount 0 bit-identical for all 96 extreme combinations (probe). |
| 4 | PASS | `VignetteLegacyIdentityTests` green. The frozen copy matches the base function line for line. 64 Amounts per frame, including ±1e-3, the clamp ends and out-of-range values; Y reaches 8. |
| 5 | PASS | `VignetteRecipeTests` and CanonicalJSON/Defaults/Feather tests green, unmodified where required. gen-fixtures check passes. Unknown style (`"bogusStyle"`, `"ColorPriority"`) renders identically to HP. |
| 6 | PASS | r50: 0.250 / 0.687 / 0.950 at midpoint 0/50/100. Reversal 0. Smallest step of 10: 0.051 (≥ 0.02). Step-1 sweep: no reversal. |
| 7 | PASS | r50 spread over feather 0…100: 0.002 (M25), 0.002 (M50), 0.001 (M75). Limit ≤ 0.02. |
| 8 | PASS | w(50) 0.381, w(100) 0.609. Strictly increasing; smallest step of 10 is 0.022. |
| 9 | PASS | 768 px: w_px 1.8, edge_px 2, aa_rms 0.013. 1536 px: 2.2 / 2 / 0.012. 5× crops show no stair-steps at roundness −100/0/+100. |
| 10 | PASS | Rendered corner: 1.005 (m50 f50), 0.569 (m100 f100; analytic 0.575), 1.005 (m0 f0). `VignetteGeometryTests` green. |
| 11 | PASS | −100: side/top 0.949/0.949, vars 0.000. 0: 0.540/0.540. +100: circ 1.002, side 0.824, top 0.199. Corner 1.005 at all three. |
| 12 | PASS | top_mid strictly decreasing 0.949→0.199. circ strictly decreasing 1.273→1.002. Smallest step of 20: 0.040. 1:1 over 0…+100: Δ 0.000. |
| 13 | PASS | flat_grey corner codes 10,15,20,30,41,53,73,95,118,145,169,189,207 for Amount −4…+2. Smallest step 5. CP − HP = 0 and PO − HP = 0 at every Amount. |
| 14 | PASS | HP at −4, H100: snow 0.98, white 1.00, sky 0.95, 6929 TL 0.88. Mid-grey corner frac 0.892. Y 0.09 corner keeps the full burn (knee starts at Y 0.127). CP within 0.01 of HP. |
| 15 | PASS | (a) Smallest step of 10: snow 0.040, white 0.028. (b) H0→H1: 0.007. (c) 22/22 hashes identical (skytest and 6929, +0.3/+1.5/+2 in all styles, PO at −2/−4). |
| 16 | PASS | WORST_REVERSAL 0 for HP/CP × H{0,50,100} × {−4,−1}, and for all styles at +2 (also PO at −4/−1). `VignetteToneTests` green. |
| 17 | **FAIL** | See D1. |
| 18 | **FAIL** | See D2. |
| 19 | **FAIL** | sdL and mean L pass: PO 0.53 vs HP 0.66 at −2; 0.56 vs 0.77 at +1.5; ΔL ≤ 0.01. Hue fails, see D3. |
| 20 | PASS | shadowsPct HP/CP/PO: 1569 5.340/5.247/0.991, 983 1.226/1.208/0.002, 2545 0.571/0.560/0.002. |
| 21 | PASS | All 42 cases: maxstep 1, reversal 0, dithered reversal 0.00. Flat run at defaults 15/30 px (−4) and 11 px (+2), the same as before. Extra cases on flat Y 0.6 and Y 0.03: reversal 0 everywhere (diag maxstep 2 at Y 0.6 is the legacy gradient, byte-identical to base). |
| 22 | PASS | CROP_MAXDIFF 0.020 (crop), 0.020 (flip), 0.023 (1:1), 0.023 (m30/r60/f20, all three crops). Extra: 9:16 0.023; 48×32 px crop 0.011/0.000; 6:1 crop 0.000/0.020. Crops below 5 % resolve to `minimumCropFraction`, so their field follows that, as the GPU's does. |
| 23 | PASS | `VignetteCropFieldTests` green: angle ±13/±90/−7/0 × flip, 1e-9 bar. The ReferenceRenderer test checks that the plan's geometry is passed. |
| 24 | NOT-RUNNABLE-ON-LINUX; code reads correct | Kernel signature has 21 args and matches the `arguments` array in order and type: vec2 centre/invHalf, vec3 axes, vec4 profile, vec3 control/luma, vec4 tone/knee/paint/chroma, 3×vec3 LMS rows, vec3 lightRow, 3×vec3 RGB rows, float dither. Every branch matches the CPU: PO cover, CP lift roll-off, legacy plus knee protection gated `ev<0 && H>0`, CP burn/lift φ, signed cube root, `max(kept, min(rgb,0))`. y-up convention matches `VignetteField.uv` (y = h − row − 0.5); \|u\|,\|v\| make sign irrelevant. All constants come from `vignetteUniforms`. Double→CGFloat implicit conversions are fine. `VignetteStyleParityTests` is correct. |
| 25 | PASS | Build clean; 3077/3077 (see above). |
| 26 | PASS | Every modified hunk in an existing test is one the SPEC lists or an additions-only sample. The pins that move with the 4 new default keys (full-tree digest, Look field count 10→14) are justified. KernelGoldenTests are untouched. Reasons are in the 243e3f4 commit message. |
| 27 | Reads correct (CI-only) | Order: Style (LumenMenuPicker, Destination pattern), Amount, Midpoint, Roundness (bipolar), Feather, Highlights (`.disabled` in PO; help says negative Amount only). Old help text is gone. Dot and Reset cover all 6 fields, with one test per field. LayoutMetricSupport line refs were checked against the file (148/162/172/182/193/305/329/353/364/375, proof intent :578), and callSiteCount 109 matches 109 `LumenSlider(` sites. |
| 28 | PASS | `lumen-render keys` lists the 3 ranges. `--set look.vignetteStyle=paintOverlay` works. Wiring tests are green. |

Evidence folder: 11 files, largest 388 KB (≤ 12, < 400 KB). I opened every sheet. I also made my own 100 % corner crops (6929 TL/TR, 2545 TR, 983 TL with exposure +1.5 and H100, 983 BR, skin TR) for each style at −4 and +2, plus interaction crops (exposure ±1, grain 60, halation 80):
- No halos: the Highlights hold is per-pixel, so it follows content edges.
- No banding in grey surrounds.
- The feather-0 edge is clean at 3:2.
- PO reads flat, as intended.

## Defects

**D1. Line 17 (CP burn colour) misses its written threshold.**
- How measured: `corner.py --frame F --set look.vignette=A --set look.vignetteStyle=colorPriority` vs HP. All values are dh.

| Box | CP at −2 | CP at −4 | Limit |
|---|---|---|---|
| skin tan_TR | −8.9° | −5.6° | 3° (−2), 4° (−4) |
| skin dark_BL | −4.1° | — | 3° |
| 2545 TR | +3.3° | — | 3° |
| 983 TL | — | +6.2° | 4° |

- The "never worse than HP + 0.5°" floor also fails at 8-bit in two boxes: green_BL −2 (+1.1° vs +0.4°) and colour4 skin_BR −4 (−2.4° vs −1.3°).
- Sky cl at −2: 1.155 (float) against a limit of 1.15.
- Builder's claim: the misses come from the display transform plus 8-bit rounding, and CP equals HP. Verifier's check, using the float probe:
  - In scene-linear, CP, HP and PO all have dh = 0.00° in every box.
  - In float display, CP tracks HP. tan_TR −8.46 vs −8.51, dark_BL −4.43 vs −4.44, 2545 TR +3.27 vs +3.21. The worst excess is green_BL at −4 (+0.75 vs +0.26, i.e. +0.49°).
  - The two-thirds of the miss is the DRT, not rounding: tan_TR is −8.5° in float.
  - 983 TL at −4 is pure 8-bit rounding: −0.16° in float.
- Verdict: the claim holds. **FAIL (spec threshold unreachable for a hue-exact scene-linear stage, because the DRT turns skin hue by up to −8.5° at the burned L).** SPEC note 5 anticipates this. The floor holds in float by 0.01°, but not at the written 8-bit measurement.
- Code: `DetailEngine.swift:727` (`vignetteColourBurnChroma` = 0.01 only moves C/L by 1-3 %, so cl stays 1.155 on sky).

**D2. Line 18 (CP lift) fails, and the implementation is at fault.**
- How measured: `corner.py … --set look.vignette=2|1.5 --set look.vignetteStyle=colorPriority`.
- (a) Clipping. colour4 red_TL clips 100 % at 255 at both +1.5 and +2 (base 0 %; limit ≤ 1 %). colour4 skin_BR clips 100 % at +2.
  - Cause: the CP lift rolls off on luminance only (`DetailEngine.swift:949-953`). A saturated low-Y colour gets the full lift and its max channel clips.
- (b) Hue. colour4 skin_BR at +2: dh +3.5° (8-bit) / +3.79° (float), against HP's +2.71°. CP is 1.1° worse than HP, and C/C0 is 1.04: the lift chroma gain (`vignetteChromaScale`, `DetailEngine.swift:964`, up to 2^0.8) over-saturates.
- (c) skin mid_BR: +3.8° at +2 (8-bit) and +3.60° at +1.5 (float), limit 3°.
- Passes: sky C/C0 0.80 and 0.86, ΔL 62 % and 61 % of HP's, 2545 TR, tan_TR.

**D3. Line 19 (PO hue on skin at −2) fails.**
- Measured: tan_TR −9.6°, dark_BL −3.9°, mid_BR +5.3° (8-bit); −9.14 / −4.20 / +4.07 in float. Limit ≤ 3°.
- PO is hue-exact in scene-linear (0.00°). The miss is the DRT at the painted L. On mid_BR, PO is 3° worse than HP (+4.07 vs +0.98), because PO lands mid_BR darker (L 0.425 vs 0.454).
- **FAIL (largely unreachable for a hue-exact stage, like D1). SPEC note 5's exemption covers only CP.** The lane lead must either re-scope the threshold to scene-linear or the builder must pre-compensate the DRT.

**D4. The feather-0 edge aliases on wide crops (model: "anti-aliased over about 1-2 output pixels").**
- Cause: the edge width is `2.5 px / pixelHalfDiagonal` in ρ units (`DetailEngine.swift:794`, `VignetteGeometry.swift:169`). ρ's pixel gradient is anisotropic, and along the short axis of a wide crop it is far steeper.
- Measured, crop 0,0.375,1,0.25 (6:1), `look.vignetteFeather=0`:
  - transition 0.27 px per edge (3:2: about 1.2 px);
  - the centre column jumps 20→45→118 codes;
  - a 6× zoom shows stair-steps along the near-horizontal contour.
- 4.5:1 is about 0.57 px. Not covered by line 9, which measures 3:2 only.
- Fix: scale the floor by the minimum half extent, or by the local |∇ρ|.

## Non-blocking observations

- **Feather 0→1 is one big step.** The square-root segment (`DetailEngine.swift:795`) makes the first slider unit change w by 0.064, 14× the median step. side_mid goes 1.00→0.74. It is monotone, but the response is not smooth at the hard end.
- **Existing recipes change by design.** Feather ≠ 50 now renders differently (D4 of the lane decisions), and so does any recipe with a crop on the CPU path (line 22).
- **No NaN or negative output.** 96 extreme combinations (midpoint 0/100 × roundness ±100 × feather 0/100 × Amount −4/+2 × 3 styles × H 0/100) on flat and Y 0.001-20 frames, including negative, zero and 1e6 pixels: no NaN, no new negatives, no radial reversal, frac in [0, 1].
- **Out-of-range values clamp.** Amount ±9, midpoint 150/−50/1e308, roundness ±300, feather 1e9/−5 and H 500/−50 all render identically to their clamped values.
