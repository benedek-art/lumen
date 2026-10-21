# WS-16 report: Saturation, Vibrance, Density, Protect Skin, Black & White

Branch `quality/ws-16-saturation-vibrance`. Spec `SPEC.md` (d683438), code 28d62f6 → 44b7b9f → 523b349.
Verdict: **PASS**. 49/49 spec lines and VIS-1..3 pass. The independent verifier failed rounds 1 and 2 and passed round 3.

## For the owner

- Protect Skin was centred on orange instead of skin. It protected the ColorChecker orange and left both skin patches alone. It now covers real skin (ColorChecker skin and Monk 1-9) and leaves oranges free.
- Vibrance was stronger than Saturation, clipped more, and turned photos B&W at −100. It now does what Lightroom's does: it boosts muted colours, protects skin, and is gentler on rich ones; −100 mutes about 50%.
- Saturation is now an exact uniform chroma scale up to the gamut edge and slows down softly near it. It never leaves Rec.2020 and has no dead range. The hue is held to 0.0014°.
- Density is now always shown. It defaults to 0, so Saturation no longer darkens the photo; above 0 it adds a film-like deepening. A B&W band at −100 is now −2 EV instead of pure black.
- Your call: Protect Skin at its default of 70 also holds back browns and straw, because they are skin-coloured (on GX85 2545, Saturation +100 gives ×1.31 against ×1.96 at Protect 0). Lightroom's Saturation has no skin protection. I'd apply Protect Skin to Vibrance only.

Best evidence: `evidence/vis1_wheel_sat_vib_after.png` (hue wheel, against `_before`: the skin-sector seams and the Vibrance −100 colour wedge are gone), `evidence/vis2_2545_bw_azure_after.png` (GX85 sky at Azure −100: grey with clouds instead of a black cut-out), `evidence/vis3_4694_sat_vs_vib_after.png` (Vibrance +100 gentler than Saturation +100; Vibrance −100 still in colour).

## Verdict per spec line

Baseline is 84bcd7c (before the lane); final is 523b349, as measured by the round-3 verifier with
`bash docs/quality/lanes/WS-16/measure/run_all.sh`. The measurement scripts are unchanged since d683438.

| id | threshold | baseline | final | verdict |
|---|---|---|---|---|
| ID-1 | 0 codes | 0 | 0 | PASS |
| ID-2 | identity, 0 passes | yes | yes | PASS |
| ID-3 | ≤ 0.75 | 0.50 | 0.52 | PASS |
| HUE-1 | ≤ 0.1° | 0.0017° | 0.0014° | PASS |
| SAT-1 | ≤ 0.005 | 0.079 | 0.0000 | PASS |
| SAT-2 | ≥ 0.95 | 0.832 | 0.972 | PASS |
| SAT-3a | C ≤ 1e-5 | 6.2e-7 | 6.2e-7 | PASS |
| SAT-3b | ≤ 1 code | 1 | 1 | PASS |
| SAT-4 | 0 samples out of Rec.2020 | 8187 | 0 | PASS |
| SAT-5 | min slope ≥ 0.3 | −0.064 | 0.335 | PASS |
| SAT-6a/b/c | ≤ 26.4 / 16.6 / 14.3 % | 25.4 / 15.6 / 13.3 | 11.5 / 1.3 / 0.8 | PASS |
| VIB-1 | rise ≤ 0.001, ratio ≥ 2.5 | 0, 7.57 | 0, 90 | PASS |
| VIB-2 | ≤ 0.5, ≤ +0.01 | 0.72, 0.000 | 0.29, −0.000 | PASS |
| VIB-3 | ≤ 0.85 | 1.17 | 0.71 | PASS |
| VIB-4 | ≤ 0.8 | 1.92 | 0.42 | PASS |
| VIB-5a | ≤ 0.35 | 1.00 | 0.30 | PASS |
| VIB-5b | ≤ 1.35 | 2.13 | 1.26 | PASS |
| VIB-6 | 0.30–0.80 | 0.00–0.04 | 0.48–0.54 | PASS |
| VIB-7 | ≤ 0.01/°, range ≤ 0.15 | 0.207, 0.695 | 0, 0 | PASS |
| VIB-8 | ≤ 1.6 | 1.89 | 1.49 | PASS |
| SKIN-1 | ≤ 0.45 | 1.00 | 0.30 | PASS |
| SKIN-2 | ≤ 0.15 | 1.00 | 0.00 | PASS |
| SKIN-3 | ≥ 0.8 | 0.39 | 1.00 | PASS |
| SKIN-4a/b | ≤ 0.04 / 0.06 per ° | 0.207 / 0.296 | 0.035 / 0.050 | PASS |
| SKIN-5 | ≤ 0.3, no inversion | 0.169 | 0.163 | PASS |
| SKIN-6 | ≤ 1.45 | 2.12 | 1.35 | PASS |
| DEN-1a | ≥ −0.06 EV | −0.186 | −0.013 | PASS |
| DEN-1b | ≤ 0.08 EV | −0.161 | +0.040 | PASS |
| DEN-2 | ≥ 0.9999 | 0.944 | 1.0001 | PASS |
| DEN-3 | ≥ 2.0 | 4.78 | 6.40 | PASS |
| DEN-4 | monotone, ≥ 0.1 EV | −0.03…−0.34 | −0.013…−0.551 | PASS |
| BW-1 | −100 in [−2.5,−1], +100 in [1,2.5] EV | −97.6 / +1.0 | −1.85…−1.17 / +1.17…+1.85 | PASS |
| BW-2 | ≤ 0.1, ≤ 0.1 | 96.6, 0.49 | 0, 0 | PASS |
| BW-3a | ≥ −3 EV | −99.4 | −2.00 | PASS |
| BW-3b | ≤ 0.1 % | 3.40 % | 0.00 % | PASS |
| BW-4 | ≤ 0.3 EV per 0.01 C | 186 | 0.167 | PASS |
| BW-5 | ≤ 0.08/°, 0.05, 0.1 | 174, 74, 74 | 0.068, 0, 0 | PASS |
| BW-6a | ≤ 1e-6 | 1.2e-7 | 1.15e-7 | PASS |
| BW-6b | ≤ 0.5 code | 0 | 0.00 | PASS |
| BW-7 | ≤ 1e-5 | 1.7e-7 | 1.65e-7 | PASS |
| PAR-1 | ≤ 1e-4 | 1.26e-5 | 2.03e-5 | PASS |
| PAR-2 | no differing constants | none | none | PASS |
| UI-1/2/3 | all drawn, Protect not bipolar, Density enabled | FAIL/FAIL/ok | pass | PASS |
| TEST-1 | 27/27 WS16 tests green | 0/27 | 27/27 (+2 extra) | PASS |
| VIS-1/2/3 | visual | fail | pass (verifier, 100% crops) | PASS |

Margins to watch: SAT-5 (0.335 against 0.3), SKIN-4a (0.035 against 0.04), BW-5 (0.068 against 0.08), VIB-8 (1.49 against 1.6).

Lines the spec did not have, which the verifier made blocking and the lane now meets:
- **No dead range.** Over the in-gamut grid, the +50…+100 half delivers at least 0.332 of the +100 push for Saturation and 0.374 for Vibrance. In round 1, 34.9% of samples got less than 10% (CC orange stuck at ×1.152 from +25 up).
- **Vibrance strength on muted frames.** Vibrance +100 now changes the picture at least as much as Saturation +50 (mean OKLab ΔE×100: 6929 1.28 vs 1.04, 4213 0.46 vs 0.46, 2545 0.80 vs 0.67, 3437 0.66 vs 0.54). In round 2 it was about Saturation +30.

## Gates

- `swift build --target LumenCore --target LumenRender` is clean. The only two warnings were already in VerifiedCopy.swift.
- LumenCoreTests in release on Linux: 3073 passed, 0 failed. The base commit (84bcd7c) had 3044 passed, 0 failed.
- Linux note: on Swift 6.0.3, `swift test` on the base commit does not compile, because of two trailing commas in `Sources/LumenApp/CompareView.swift` (~325 and ~568). That is not this lane's code. Both runs removed them locally and did not commit the change. Debug runs are too slow, so tests were built with `-c release -Xswiftc -enable-testing` and run in class chunks, because `--filter` overflows the argument list.
- `scripts/check-swift-surface.py` exits 1 on the base commit too, on `CommandLine` and the LumenRender Metrics/RecipeKeys inits. This lane adds nothing to it.
- GPU: the GLSL can't run on Linux. The verifier read it line by line against the twin and compiled the generated kernel with `glslangValidator`. macOS GPU parity passed on round-1 code (28d62f6).

## What changed and why

CPU and GPU changed together in every round: `ColorEngine` (Double), `ExactColorTwin` (Float, what ReferenceRenderer runs) and `ExactColorKernelSource.finish` (GLSL). The finish pass keeps its uniform layout.

- **Saturation.** The absolute `satCompress` knee (0.18 / 0.34) is gone. A push is now compressed against the Rec.2020 boundary at the pixel's own lightness and hue (16-step bisection on C/L; `gamutReach`, twin `reach`, GLSL `lumenReach`). It is an exact scale while there is room. Above half the room, a soft knee approaches the boundary but never reaches it, and output keeps rising with the slider. Pulls are an exact `C × gain`. Cause of the old defects: the fixed knee was not uniform inside the gamut (SAT-2 0.83), and pushes left Rec.2020 (8187 grid samples).
- **Vibrance.** The weight is now on absolute chroma, `(1 − C/0.22)²`. It has a chroma-noise floor below C 0.02 and skin protection on pushes. Pulls are a uniform mute (×0.4–0.55) with no skin exception. Before, the old weight gave the full ×2 to everything under C 0.05, skin included, and −100 was B&W with a protected colour wedge. When Vibrance and Saturation both push, their increments add instead of multiplying (+100/+100 was asking for ×3.7).
- **Protect Skin.** It has its own band: centre 63°, core ±25°, 30° feathers. Colourfulness plausibility is on C/L (0.12→0.20), so oranges are not protected. The log-chroma gate reaches MST 1, and the lightness fade starts after L 1.0. Protection scales the fill a push adds, after compression. `skinWeight` and `skinLineDegrees` (vectorscope, Skin tools) are untouched; see NEEDS N3.
- **Density.** `subtractivePush` and its hue restore are removed. Density now darkens a Saturation push at held chroma and hue, by an amount tied to the fill the push added. This keeps it inside the gamut, and it never lowers chroma. **The default changed from 50 to 0**, in both the memberwise init and the decoder fallback, so Saturation alone is brightness-neutral (DEN-1). A recipe with an explicit Density keeps its value. A recipe without the key now renders a Saturation push brightness-neutral, which is the fix. The fingerprint does not change, so the preview cache needs a revision bump (NEEDS N5).
- **B&W.** The grey is now `Y · 2^(Σ wᵢ · gate · bandᵢ/100 · 2 EV)`. Before, it was a linear gain where −100 meant black. The mix has its own soft chroma gate, `smoothstep(0, 0.18, C)`. Neutrals are exact and the all-zero mix is Rec.2020 Y. `bandWeights`, `chromaGate` and `bandHueCentres` are unchanged (NEEDS N2).
- **UI** (`BasicPanel.saturationRows`). All four sliders are always drawn and enabled. Density's tick is at 0. Density and Protect Skin are no longer bipolar (Protect Skin's tick at 70 read as "no protection"). The help texts are rewritten to match the measured behaviour.
- **Tests.** The new file `Tests/LumenCoreTests/WS16SaturationFamilyTests.swift` has the 27 spec lines plus a no-dead-range test and a dark-muted Vibrance strength test.

### Existing tests changed, and why

Each of these encoded the old wrong behaviour. The verifier checked each change in rounds 1–3 and found none loosened to get green.

- `ProtectSkinChromaOrderTests`: the full-protection probes moved from C 0.06/0.08/0.10 to 0.015–0.07. At L 0.6, C 0.08–0.10 is as colourful as orange, which SKIN-3 requires not to be protected.
- `SaturationOutOfGamutChromaTests`: the test of the removed `subtractivePush` is replaced by one asserting that a push holds an out-of-gamut colour exactly. The chroma-never-falls tests are unchanged.
- `ColorScienceTests.testProtectSkinAttenuatesTheMovesItSaysItDoes`: the skin probe moved from C/L 0.18 (orange-level) to a real skin colour. The "protects Vibrance −100" assertion is now "a pull is not changed by Protect Skin" (VIB-7, no colour-splash wedge).
- `HuePreservationTests`: the Density-darkens test names Density 50, because the default is 0. The skin half of the Vibrance test samples `skinProtectionWeight`. The chroma-ordering half is measured at Protect 0, because at Protect 70 the gain rises on vivid oranges by design (Protect fades as colourfulness rises, SKIN-3). The guard half still runs at the default Protect.
- `MaskingTests`: the masked-Vibrance inheritance test uses a push (+80), because pulls are no longer protected. `testAColourMaskSelectsTheColourThatWasClicked` moved its red patch from 61% to 48% of the gamut edge. The verifier confirmed the old red fails only because the bottom of the Saturation slider no longer bunches up (the round-1 fix), and that +100 is identical.
- `RawDenoiseRecipeTests`: the full-tree digest is updated for density 0. The canonical form and the fingerprints are unchanged.
- `ProofRegistry`: the `bw.*` authority floor goes from 107 to 44, which is still 0.7 × the weakest band. The old readings were measured with −100 meaning black. Proof records for color.saturation, vibrance, density, protectSkin and bw.* were re-recorded. The registry belongs to WS-58, so this is NEEDS N6.
- `scripts/gen-fixtures.py`: the Python mirror follows the new algorithm. `enginemath.json` and `default-recipe.json` were regenerated, and `--check` passes.
- `Tests/LumenAppTests/LayoutMetricSupport.swift`: the four slider citations point at the moved BasicPanel lines (CI `LayoutMetricSelfTests` failed on 28d62f6). WS16 test-local types were renamed for the swift-surface checker.

## What I could not fix, and what a human must judge

- **Output hue drift** (up to 15.6° on the ColorChecker at Sat +100) comes from `DisplayTransform` and the sRGB channel clamp, not from S9. S9 holds the hue to 0.0014°. This is NEEDS N1 (WS-13/WS-12). The lane has cut newly clipped pixels at Sat +100 from 25.4% to 11.5% on the hue wheel and from 15.6% to 1.3% on 2242.
- **Protect Skin and earth tones** (owner decision, NEEDS N4): see "For the owner".
- **Density 100 speckle:** on a noisy red (2062 at Sat +100), high-pass lightness noise is ×1.68 against Density 0. It is mild grit at 100% and only at the extreme. Lowering the darkening would fix it, but would fail the WS-58 proof authority floor for `color.density`.
- **B&W band names:** "Orange" sits at 74° and skin falls in the Red band (NEEDS N2, the band centres are shared with the Colour Mixer).
- **Cost:** a push runs one 16-step boundary bisection per pixel, three with Vibrance > 0. It was not measured on GPU.
- **Vibrance asymmetry:** on 2545 and 1192, −100 changes the picture about twice as much as +100, because the pull mutes everything while the push is aimed at muted colours. That is the intended shape. `vibrancePullStrength` is the lever if it should be closer.
