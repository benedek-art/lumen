# WS-41 Vignette: verification (round 2)

**Verdict: FAIL.** Line 18 still misses its written threshold. In skin_tones mid_BR, Color Priority shifts hue by +4.9° at +2 and +3.2° at +1.5 (8-bit, the spec's `corner.py` command), against a limit of 3°. In float the +2 case is +3.65°.

Every other line, 1-23 and 25-30, passes on my own measurement. Lines 24 and 27 can only run on macOS CI; their code reads correct.

Three new defects sit outside the written lines (D2-D4 below). One of them is a regression that this round introduced (D2).

Inputs:
- SPEC.md, including Amendment A1.
- LANE-BRIEF §4.
- VERIFY.md (round 1).
- `git diff de61270 627245c`, with the round-2 slice `73ec6f9..627245c` read line by line.

BUILD-NOTES.md was not used for any number. Environment: Linux, Swift 6.0.3.

## What was run

| Step | What |
|---|---|
| Builds | `swift build -c release --product lumen-render` at HEAD: clean, apart from the 2 pre-existing `VerifiedCopy.swift` Sendable warnings. `swift build --target LumenCore --target LumenRender` (debug) on a `git archive HEAD` copy in /tmp/claude-0/ws41/v2: exit 0, same warnings. Base `de61270` and round-1 `73ec6f9` were built in git worktrees under /tmp/claude-0/ws41; both worktrees are removed. |
| Tests | `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` on the archive copy, full suite. The two `CompareView.swift` trailing commas were removed in the copy only. Result: **3080/3080 executed, 0 failures, exit 0.** That includes all 57 Vignette* tests and the new A1 tests. |
| Identity | Base vs HEAD `lumen-render`, byte for byte: flat_grey, skin_tones, 6929 and 2545 × Amount −4/−1/+2 × {no feather key, feather 50} × {dither, no dither}, no crop. **48/48 identical.** |
| Probes | `huefloat.py` with the probe built into my own scratch path, for float display and scene-linear. A separate stress executable that links LumenCore. 3024 combinations of all six controls × 7 geometries: none, 6:1, 1:6, 1:1 rotated 45° and flipped, rotated −13°, a 0.0001 crop (resolves to the minimum fraction), and 9:16. It also covers NaN, inf, negative, 0 and 1e6 pixels, NaN/inf/1e308 settings, and step-1 sweeps of every control. |
| Other | `gen-fixtures.py --check`: all match. `check-swift-surface.py`: the same 6 init-site and 2 Range findings as base (exit 1 on both). There are no new findings; round 1's "green" was inaccurate. `swiftc -parse` passes on Kernels.swift, RenderGraph.swift, EffectsPanel.swift, VignetteStyleParityTests.swift and VignetteGeometryContractTests.swift. |

## Per-line results (verifier's own measurements)

| # | Result | Measured | Threshold |
|---|---|---|---|
| 1 | PASS | `identity.py` 0/52. Independent base-vs-HEAD comparison 48/48 identical. See D3 for frames ≤ 5 px. | 0/52 |
| 2 | PASS | `--explicit` 0/52 | 0 |
| 3 | PASS | `--amount-zero` 0 mismatches | 0 |
| 4 | PASS | `VignetteLegacyIdentityTests` green (2 tests) | bitwise |
| 5 | PASS | VignetteRecipe/CanonicalJSON/Feather green; gen-fixtures OK. `"bogus"` style and `null` style render byte-identical to HP. A type-mismatched value rejects the recipe, the same as the existing `vignetteFeather`. | all hold |
| 6 | PASS | r50 0.250 / 0.687 / 0.950 at midpoint 0/50/100. Reversal 0. Smallest step of 10: 0.051. | 0.6875±0.005; ≤0.30; 0.90-1.00; step ≥0.02 |
| 7 | PASS | r50 spread over feather 0…100: 0.002 (M25), 0.002 (M50), 0.001 (M75) | ≤ 0.02 |
| 8 | PASS | w(50) 0.381, w(100) 0.609. Strictly increasing; smallest step of 10 is 0.022 (30→40). | 0.381±0.006; ≥0.60; ≥0.02 |
| 9 | PASS | 768 px: w_px 2.0, edge_px 1, aa_rms 0.015. 1536 px: 2.2 / 1 / 0.015. | ≤3; 1-3; ≤0.15 |
| 10 | PASS | Corner 1.005 (m50 f50), 0.569 (m100 f100 = frac(1)), 1.005 (m0 f0). `VignetteGeometryTests` green. | ±0.015 |
| 11 | PASS | −100: side/top 0.949/0.949, variance 0.000. 0: 0.540/0.540. +100: circ 1.002, side 0.824, top 0.199. Corner 1.005 at all three. | as listed |
| 12 | PASS | top_mid 0.949→0.199 strictly decreasing. circ 1.273→1.002 strictly decreasing. Smallest step of 20: 0.040. 1:1 over 0…+100: Δ 0.000. | rev 0; ≥0.02; ≤0.01 |
| 13 | PASS | flat_grey codes 10,15,20,30,41,53,73,95,118,145,169,189,207 in all 3 styles. Smallest step 5. CP−HP = PO−HP = 0. | ≥2; ±1; ±4 |
| 14 | PASS | HP at −4 H100: snow 0.98, white 1.00, sky 0.95, 6929 TL 0.88. Mid-grey corner frac 0.892. CP the same to 0.01. | ≥0.80/0.90/0.70/0.65; ≥0.75 |
| 15 | PASS | (a) Smallest step: snow 0.040, white 0.028. (b) H0→H1: 0.007 (skytest), 0.003 (6929). (c) 22/22 hashes identical. | ≥0.01; ≤0.02; identical |
| 16 | PASS | WORST_REVERSAL 0: HP/CP × H{0,50,100} × {−4,−1}; all styles at +2; PO −4/−1/+1.5 at H100; CP +1. `VignetteToneTests` green. | 0 |
| 17 (A1) | PASS | (a) Scene dh 0.00° for CP and PO in all 20 box×amount cases; the unit test asserts < 0.01°. (b) Float \|dh_CP\| ≤ \|dh_HP\|+0.5° everywhere. Worst is green_BL −4: 0.75 vs 0.26, an excess of 0.49°, a 0.01° margin. (c) cl: sky −2 is 1.155 against HP's 1.168 (within 0.02); all others 0.963-1.124. L_CP−L_HP ≤ 0.0009. 8-bit dh (reported only): tan_TR −8.9/−5.6, dark_BL −4.1/−1.8, 983 TL −0.0/+6.2, 2545 TR +3.3/+2.9. | A1 |
| 18 | **FAIL** | See D1. Passing: clip255 0.00 % in all 14 cases (HP has 100 % on red_TL/skin_BR); C/C0 ≥ 0.850 (sky +2); ΔL 61-86 % of HP's. | C/C0≥0.80, \|dh\|≤3°, ≥60 %, clip≤1 % |
| 19 (A1) | PASS | sdL: PO 0.53 vs HP 0.66 at −2; 0.56 vs 0.77 at +1.5. Mean L within 0.01. (a) Scene dh 0.00°. (b) Lightness-matched excess ≤ +0.06° in every box (mid_BR +4.07 vs HP′(−2.20) +4.01; tan_TR −9.14 vs −9.11). | ≤HP−0.08 / −0.15; +1.0° |
| 20 | PASS | shadowsPct HP/CP/PO: 1569 5.340/5.247/0.991, 983 1.226/1.208/0.002, 2545 0.571/0.560/0.002 | ≤HP+0.05 |
| 21 | PASS | All 42 cases: maxstep 1, reversal 0, dithered local-mean reversal 0.00. Defaults: flat 15/30 px (−4) and 11/19 px (+2), the same as before. | ≤1; 0; ≤1.5×; ≤0.25 |
| 22 | PASS | CROP_MAXDIFF 0.020 (crop), 0.020 (flip), 0.023 (1:1), 0.023 (m30 r60 f20 on all three). Extra: 6:1, 1:3.6, 1:1.5 and 9:16-ish at f0/f50 give 0.000-0.023. (A non-pixel-aligned crop at f0 reads 0.57; that is a script artifact.) | ≤0.04 |
| 23 | PASS | `VignetteCropFieldTests` green (3); the ReferenceRenderer geometry test passes | 1e-9 |
| 24 | CI-only; reads correct | Kernel signature has 26 parameters. The `arguments` array has 26 entries, in matching order and types: profile vec4 (centre, width, n, w), control vec4 (+hardEdgePx), edge vec2, lift vec3, srgb0-2. The gradient expression is term for term `vignetteRadiusGradient` × invHalf. Width is `max(max(width, 2.5·\|∇ρ\|), 1e-6)`. The lift key, share and φ hold match the CPU. All constants come from `vignetteUniforms` or `DetailEngine`. pow(0, n−1 ≥ 1) and the ρ floor are safe in fp32. The new parity test compiles by inspection (`Geometry(crop:)`, `Crop(x:y:w:h:)` and `worst(_:dithered:geometry:)` exist). Unverifiable here: whether the 26-parameter CIKernel compiles on Metal. | CI |
| 25 | PASS | Build clean; 3080/3080 | green |
| 26 | PASS (see D6) | Round 2 touches only lane-owned or SPEC-listed tests. One tolerance widened: `testInnerRadiusIsMonotoneAndBounded`, inner(0) from 1e-12 to 1e-6. KernelGoldenTests untouched. | diff review |
| 27 | CI-only; reads correct | EffectsPanel is unchanged since round 1. Order: Style picker :131, then Amount :148, Midpoint :162, Roundness :172, Feather :182, Highlights :193, with `.disabled` in PO at :203. | CI |
| 28 | PASS | `lumen-render keys` lists Highlights, Midpoint and Roundness with their ranges. `--set look.vignetteStyle=paintOverlay` works. Wiring tests green. | as stated |
| 29 (A1) | PASS | `edge.py` w_min 1.55/1.52/1.53/1.55 px (1:1/3:2/6:1/1:6), aa_rms ≤ 0.015. Also at roundness ±100, midpoint 0/100 and −100+m100: w_min ≥ 1.52, aa_rms ≤ 0.052. 6:1 centre column 41→61→108→118 (round 1: 20→45→118). 12:1 and 1:16 give 2-px ramps. Rotated −30°/13°+flip zooms: no stair-steps. | ≥1.0 px; ≤0.15 |
| 30 (A1) | PASS | `profile.py` feather 0…100 step 1: largest step over 0…10 is 0.010, against a median over 10…100 of 0.004. Ratio 2.5× (bar 3×). | ≤3× |

## Round-1 defects re-checked

1. **D1 (line 17).** Re-scoped by A1 and PASS. CP equals HP in float, and the scene hue is exact.
2. **D2 (line 18).** Partly fixed:
   - Clipping: 100 % → 0 %.
   - colour4 skin_BR: +3.5° → −0.4°.
   - mid_BR: still fails (D1 below).
3. **D3 (line 19).** Re-scoped by A1 and PASS.
4. **D4 (feather-0 wide-crop AA).** Fixed: 0.27 → 1.53 px on 6:1.
5. **Feather low-end jump.** Fixed: 14× → 2.5×.

There is a residual in the feather response, noted as D5.

## Defects

1. **D1. Line 18 FAIL: skin_tones mid_BR hue under the CP lift.**
   - How measured: `corner.py --frame skin_tones --set look.vignette=A --set look.vignetteStyle=colorPriority`.

   | | 8-bit +2 | 8-bit +1.5 | Float +2 | Float +1.5 | Limit |
   |---|---|---|---|---|---|
   | CP dh | **+4.9°** | **+3.2°** | +3.65° | +1.90° | ≤ 3° |
   | HP dh (same Amount) | +4.6° | +4.7° | +3.36° | +3.41° | — |

   - BUILD-NOTES says "13 of 14" cases pass in 8-bit. In 8-bit 2 of 14 fail.
   - Visibility: not visible to a human. The box has C ≈ 0.061 at L 0.83, so +4.9° is ΔH_OK 0.0052, about a quarter of a just-noticeable difference (≈0.02).
   - In a 100 % crop shown next to HP at the same lightness, CP and HP cannot be told apart.
   - Comparison with Highlight Priority at the same lightness:
     - HP at +1.15 lands at L 0.830 (CP +2: L 0.832) and turns the hue +5.0° (CP +4.9°).
     - HP at +0.90 matches CP +1.5 at L 0.808 with +3.2° (CP +3.2°).
     - The shift is therefore the display transform at that lightness, not CP.
   - As written, though, line 18 keeps its absolute 3° bar (A1 explicitly did not re-scope it), so this is a FAIL.
   - Fix options:
     - re-scope line 18's hue part the way A1 re-scoped line 17 (lightness-matched against HP); or
     - pre-compensate the display transform's hue in CP.

2. **D2. NEW, worse than round 1: the CP lift is non-monotone and jumps hue on bright saturated colours.** Outside the written lines; LANE-BRIEF §4 asks for "smooth, monotonic … no hue shifts that weren't asked for".
   - How measured: a synthetic frame with corner patches at scene Y 1/2/4, `look.vignetteStyle=colorPriority`, Amount 0→2 in steps of 0.25, OKLab L and hue of each patch.
   - Results:

   | Patch | L over the sweep | Hue |
   |---|---|---|
   | Red, Y 2 | 0.869→0.862→0.852→0.837→**0.820**→0.827→…→0.855 | 43° → 31° between 0.75 and 1.0 |
   | Red, Y 4 | 0.936 → 0.902 | 56° → 43° in one step |
   | Red, Y 1 | Dips 0.743 → 0.729 at +1.5 | 32° → 26° |

   - On the same patches at the round-1 commit, the L decline was smaller and later (Y 2: 0.869→0.843 only by +2), and Y 1 was monotone.
   - Mechanism:
     - `vignetteColourLiftChroma` went from 0.4 to 1.0 (`DetailEngine.swift:742`).
     - The resulting OKLab chroma push drives the minor channels negative.
     - `vignetteHoldColour` clamps them to 0 (`max(kept, min(c,0))`). This removes luminance and rotates hue.
   - Scene probe: pixel (17.3, 0.87, 0.35) → g 0.049 → 0.023 → 0.0, b 0.0, between Amount 0.76 and 0.80.
   - The line-18 boxes are too dark to show this, which is why it passes.

3. **D3. NEW: legacy identity breaks on frames with a short side ≤ 5 px.**
   - Base vs HEAD on flat32 at Amount −2, legacy recipe, long edge 4, 6 and 8 px: all differ. Long edge 12 is identical.
   - Cause: `vignetteEffectiveWidth` now also applies at feather 50. Width = max(0.625, 2.5·|∇ρ|), and 2.5·|∇ρ| > 0.625 when the delivered half-height is < 2.83 px.
   - Low impact (tiny thumbnails only), but it contradicts "the default value of every control is an exact identity".
   - Fix: apply the AA floor only below the default feather, or cap it.

4. **D4. NEW (since round 1, not fixed): Paint Overlay lift turns near-black pixels with negative or near-zero luminance into hot pixels.**
   - Formula: `cover = (log2White − log2(max(lum, 1e-10)))·liftSpanInverse`. A pixel at the floor gets stops = 2 × 7.1 → ×2^14, and a negative channel is scaled with it.
   - Probe: (−1, 0.1, 0.1) → (−20145, 2014, 2014); (−0.001, 0.0005, 0.0003) → ×55.
   - On a real raw, 1569 at `look.vignette=2 look.vignetteStyle=paintOverlay` (defaults otherwise):
     - 1 new isolated hot pixel at 1536 px, 2 at 4000 px.
     - With midpoint 0: base [0 0 1] → [255 210 254], a white-magenta speck in deep shadow.
     - None in HP or CP, none at PO +1, none on 2545.
   - Fix: clamp the lift cover, or key it on max(lum, a sane floor such as 1e-4).

5. **D5. Feather response (observation, no spec line).**
   - Width per unit is 0.025 over 10…25 and 0.002 over 25…50. That is a 12× slope break at 25, where (f/25)² meets the linear segment.
   - At 768 px, feather 0…2 render identically: the AA floor wins.
   - Line 8 passes with only 0.022 per 10 at 30→40, so 25-50 feels nearly dead next to 10-25.

6. **D6. Minor bookkeeping.**
   - The `VignetteFeatherTests.testInnerRadiusIsMonotoneAndBounded` tolerance went from 1e-12 to 1e-6 without a stated reason in the 627245c message. It follows from `vignetteMinimumWidth` = 1e-6, and the test is on SPEC's may-change list, but it is still a loosened assertion.
   - NEEDS.md still says the kernel signature went "from 12 to 21 arguments"; it is 26.
   - BUILD-NOTES gives line 22 m30/r60/f20 as 0.017; I measure 0.023 (both pass).

## Visual (100 % crops, opened with Read)

All 12 evidence files are opened. There are 12 files, the largest 388 KB, so the folder is within ≤ 12 files and < 400 KB each.

My own 1536-px dithered corner crops:
- 6929 TL, 2545 TR, 983 TL (exposure +1.5, H100 at −4) and skin_tones BR, each as base / HP / CP / PO at −4 and +2. No halos and no banding. PO reads flat, and CP keeps the sky blue at +2.
- flat_grey 1024 for each style at −4 and +2, with and without `--no-dither`, plus a 16× residual stretch: smooth, 1-code steps only, and identical across styles on grey.
- Feather-0 edges on rotated (−30°, 13°+flip) and 9:16 crops are anti-aliased with no stair-steps.
- The D4 hot pixel and the mid_BR crop (D1) were inspected at 8×.

## Robustness (stress probe)

- No non-finite or new negative output in 3024 combinations × 7 geometries from finite, non-negative input.
- NaN, inf and 1e308 settings all fall back to clamped or default values with finite output.
- A NaN pixel stays NaN. An inf pixel becomes NaN under CP lift and PO burn, whereas HP keeps inf; garbage in.
- Step-1 sweeps: midpoint and Amount are uniform (ratio 1.0), roundness ≤ 2.3× its median step (6:1: 1.9×), Highlights is uniform.
