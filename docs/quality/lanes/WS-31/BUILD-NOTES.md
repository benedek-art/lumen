# WS-31 engine build notes

Engine builder's record: what changed, why, the measured numbers, and every existing test that changed with the reason. UI work is the UI builder's (commit f1c2135). Needs from other lanes are in `NEEDS.md` under "## Engine".

## What changed

All in `Sources/LumenCore/Engine/ColorEngine.swift` (mixer block), `Sources/LumenCore/Engine/ExactColorStage.swift` (`ExactColorTwin.mixer`, `ExactColorKernelSource.mixer`, the mixer block of `init`) and the `MixerBand` docs in `Recipe.swift`. CPU reference and GPU twin change together; the kernel keeps its 28-vector budget and its uniform layout (centres at elements 36–43, arcs at vectors 11–18), and uses only constructs the kernel already used plus `exp2`/`pow`.

1. **Band geometry.** Uneven centres, derived as the middle of each band's plateau from eight crossovers and eight transition widths:
   - crossovers `[37.7, 83.5, 121.0, 173.3, 228.5, 276.0, 316.0, 356.6]`, widths `[31.8, 30.5, 30.5, 46.2, 35.0, 31.0, 32.0, 32.0]`;
   - **centres `[17.2, 60.925, 102.25, 143.225, 203.7, 253.25, 295.75, 336.3]`** (OKLCh °, Red…Magenta), gaps 40.55–60.5°;
   - adjacent feathers are complementary raised cosines over the same interval, so the raw weights already sum to 1 and the default normalised weight is exactly a raised cosine (C¹, max slope π/(2·width)); default cores are symmetric (3.5–7.3° per side), so `coreCentre` = centre.
   - Found by a numerical search (Python port of `bandWeights`, corpus region pixels, ColorChecker/MST/sRGB targets) and then tuned on engine renders.
2. **Wire semantics of the ring handles.** `MixerBand.core/feather` are now relative to each band's own default: 22.5 (core) / 15 (feather) means "this band's default on this side". The old wire default therefore resolves to the new per-band default with no migration; `ColorEngine.wireHandles(for:band:)` is the inverse for the UI. Clamps are in degrees: core 3.4–44, feather 12–60 (the old 2° floor gave a 1.2/deg² kink; G6). Minimum reach is per side: half the gap + 8°.
3. **Hue.** A monotone warp of the hue circle through the band centres (`hueDisplacement`): knot k moves by d_k and the displacement hands over between adjacent knots through `hueTransfer` (quadratic ease over 15% at each end, linear between; slope 0 at every knot). d_k = slider × min(30°, 0.6375 × the narrower gap) — symmetric in sign, so ±100 are equal and opposite — and `resolvedHueShifts` scales a whole recipe down if two neighbours would squeeze an interval below slope 0.25. Nothing past the neighbouring centres moves. Gated by the mixer gate. The membership weights no longer carry hue moves (no raised cosine narrow enough for band selectivity is wide enough to carry a 25–30° move without folding).
4. **Luminance.** `mixerLightness`: L × 2^(stops·ω(L)), chroma held (invariant #1). Per-band stops at −100 `[0.30, 0.27, 0.30, 0.30, 0.33, 0.345, 0.33, 0.30]`, at +100 `[0.32, 0.29, 0.32, 0.32, 0.35, 0.36, 0.35, 0.32]`; ω(L) = (min(L, 1)/0.5)^0.9. The lightness scaling is there because the default rendering's shoulder turns the same scene stops into 0.68× the display stops on a bright sky (2545) that it gives a dark one (983); Orange is gentler because mid skin reads 1.4× the display stops of a sky. `lumShape` and `lumKappa` are unchanged (Point Colour still uses them).
5. **Mixer gate.** `mixerGate` = smoothstep(0.022, 0.04, C), used for every gated mixer move and for `dominantBand(for:)`. `chromaGate` (0.02–0.06) is untouched for Point Colour and Skin. Skies (C ≥ 0.047) are on the flat top, so chroma noise no longer becomes luminance noise.
6. **Saturation.** A pull is unchanged (ungated, linear). A push has gain 1 + p·max(0, 1 − r/1.10), where r = C / (L·σ(h)) and σ(h) is a 6-harmonic Fourier fit of ln of the largest C/L an sRGB-primaries colour can have with no negative channel (scale-free cone, `mixerSatReferenceCoefficients`, fitted on a 0.25° grid with `docs/quality/lanes/WS-31/tools/mixlib.py`'s OKLab, which is `OKLabTransform.working`). Monotone in C (dr′/dr ≥ 1 − p) and in the slider.
7. **Names.** `bandNames` = Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta.
8. **B&W kept on the legacy grid** (`uniformBandHueCentres`, `uniformArcs`, `uniformBandWeights`), one line each in `applyBlackAndWhite` and the finish-pass centres; see NEEDS E-2.

## Measured (fresh dir, final binary, tools as in SPEC §0)

`CENT=17.2,60.925,102.25,143.225,203.7,253.25,295.75,336.3`

| line | threshold | measured | verdict |
|---|---|---|---|
| G0 | 8 bands, ordered, gaps ≥ 30° | gaps 40.55–60.5° (`MixerBandGeometryTests`) | PASS |
| G1 | ≥ 0.80 own band | min 0.892 (sRGB red) | PASS |
| G2 | ≥ 0.60 Orange | min 0.659 (CC light skin) | PASS |
| G2b | MST 3–4 ≥ 0.40 | 0.417 | PASS |
| G3 | skies ≥ 0.90 Blue | 1.000 | PASS |
| G4 | Green > 0.50; G+Y ≥ 0.90 | 0.637; 0.912 | PASS |
| G5 | Σm = 1 ± 0.05 | 0.039 | PASS |
| G6 | Σw 1e-9, 0…1, d² ≤ 0.1/deg², all arc corners | `MixerBandGeometryTests` green | PASS |
| H1 | slope ≥ 0.10 | 0.121 | PASS |
| H2 | slope ≤ 3.0 | 3.908 | FAIL (display hue non-uniformity, NEEDS E-3) |
| H3 | centre shift 25–35° | 21.6–32.5° | FAIL (display; stage moves 25.8–30°, NEEDS E-3) |
| H3b | ≤ gap − 2 | all | PASS |
| H4 | direction | all 16 | PASS |
| H5 | ΔC < 2%, ΔL < 0.005 | 1.05%, 0.0012 | PASS |
| H6 | stage-level H1/H3/H4/H5, engine and twin | min slope 0.250 engine / 0.241 twin; shift 25.8–30°; ΔC 5e-14 | PASS |
| L1 | −100: 1.0–1.6 EV | −1.10 / −1.45 / −1.20 (983/1840/2545) | PASS |
| L2 | +100: 0.7–1.2 EV | +1.17 / +1.12 / +0.88 | PASS |
| L3 | newly crushed < 0.5% | 0 / 0 / 0 | PASS |
| L4 | noise ≤ 1.3× | 1.16 / 1.26 / 1.01 | PASS |
| L5 | fringe ≤ 0.342 | 0.264 | PASS |
| L6 | monotone | min step 0.158 EV | PASS |
| L7 | +/− ratio 0.7–1.3 | 1.07 / 0.77 / 0.73 | PASS |
| K1 | monotone | yes | PASS |
| K2 | hue drift ≤ 3° | 14.0° (MST 8 sat) | FAIL (display, NEEDS E-3; stage drift 0) |
| K3 | Y ≥ 0.4 Y0 | 0.413 | PASS |
| K4 | every MST moves ≥ 0.015 | 0.000 (MST 1, 2, 9, 10) | FAIL (conflicts with N4, NEEDS E-5) |
| K5 | spread ≤ 3 | 3.94 | FAIL (NEEDS E-5) |
| N1 | ≤ 1 code | 1 | PASS |
| N2 | p99.9 ΔE00 < 0.5 | 0.00 | PASS |
| N3 | ≤ 1.5 | 1.30 | PASS |
| N4 | ≤ 0.03 | 0.0253 | PASS |
| X1 | finite | all renders; `MixerExtremesTests` | PASS |
| X2 | ≤ 5% code-0 | 3.18% | PASS |
| X3 | median gain ≥ 1.4 | 1.404 | PASS |
| X4 | bit-identical | 0 codes | PASS |
| X5 | seam ≤ 0.10/deg | hue 0.065, sat 0.100, lum 0.095 | PASS |
| X6 | 0 non-monotone | 0 | PASS |
| T1 | twin = engine | family endpoints 0.91 of gate; new 48-endpoint 1° sweep 0.22 of gate | PASS (Linux) |
| T2 | 0 failures, ≥ 3044 + new | 3063 run, 1 failure: `CurveMathTests.testTheMixerGroupRowMovesTheWholeSetTogether` (reads ColorPanel.swift; broken by the UI commit f1c2135, which removed `GroupMove.mean(`; not engine) | see note |
| T3 | listed suites green | green | PASS |
| T4 | macOS jobs | not run here (needs push) | — |
| T5 | pin or NEEDS | NEEDS E-1 | PASS (conditional) |

### Display-transform evidence behind H2, H3, K2 (base binary 9068ded, no Mixer edit)

- Hue ramp row L 0.4 C 0.06: d(display hue)/d(scene hue) runs 0.41 (at 274.6°) to 1.61 (at 235.9°); L 0.6: 0.61–1.51; L 0.8: 0.73–1.47.
- MST patches rendered with scene chroma or lightness scaled at constant scene hue, displayed hue change in degrees (MST 1…10, CC dark, CC light):
  - C×1.5: +0.3 +0.3 +1.1 −0.7 −0.5 −3.2 −4.7 +0.0 −5.2 +2.0 −1.3 +3.0
  - C×2: +0.4 +0.9 +0.7 −0.7 +0.1 −5.4 −4.1 −1.7 −7.8 +0.4 −1.8 +2.9
  - L×0.8: +1.6 +1.2 +1.6 −2.6 +1.2 −7.7 −2.0 −1.0 −6.7 −7.2 −2.5 +3.5
  - L×0.65: +4.1 +3.1 −0.5 −5.9 +4.4 −5.1 −2.3 −3.9 −12.2 −18.1 −4.9 +1.3

## Existing tests changed, and why

- `ColorScienceTests.testBandArcsSanitizeAnythingAFileCanSay`: the reach floor is per band and side now (`bandMinReach`), not the single 27.5° that assumed 45° gaps.
- `ColorScienceTests.testShrunkBandsStillOverlapEverywhere`: the wire is relative, so "shrunk to the minimum" is wire 0 (the sanitizer supplies the floor); the midpoint is half the band's own gap, not 22.5°.
- `ColorScienceTests.testCoreCentreIsTheMidpointOfTheInnerHandles`, `…testUniformityConvergesOnTheCoreArcNotAFixedCentre`: core [5°, 40°] is now written in degrees through `wireHandles`; the assertions (17.5°) are unchanged.
- `ColorScienceTests.testMeasuredMeanHueIsCircular`: the 0° wrap now sits in the Magenta→Red hand-over, not inside Magenta's core; the pair is 355°/5° and both bands' means are checked (tighter: < 5° instead of < 10°).
- `DominantBandTests.testAWidenedBandTakesHuesItsNeighbourUsedToOwn`: probe hues from the Red/Orange crossover instead of fractions of 45°; the widening is written in degrees through `wireHandles`.
- `DominantBandTests.testASaturatedColourResolvesToAStablyNamedBand`: names Mint → Green, Azure → Blue (same band indices).
- `MixerBandNameTests.testEveryBandIsNamedForTheColourAtItsOwnCentre`: the "within half the 45° spacing" rule is meaningless for uneven bands (Blue is centred on sky blue and owns pure blue); the rule is now the one it stood for — the conventional colour of each name has that band as its dominant band with weight ≥ 0.8.
- `MixerBandNameTests.testTheBandCentresAreWhereTheGoldenLockSaysTheyAre`: pins the new centres, and the legacy grid via `uniformBandHueCentres`.
- `ProofFrameTests.testTheWedgeSitsOnTheBandCentres`: the proof wedge (and the ControlProof records made on it) stays on the legacy grid, which B&W still uses; compared against `uniformBandHueCentres`.
- `RobustnessTests.testMixerLuminanceDarkensABlueSkyAtEveryExposure`: probe hue is the Blue centre; the absolute floor is 0.1 instead of 0.2 (−100 was retuned from an additive 0.25 of L — 6 EV on a dark sky, SPEC L1 — to about −1.3 EV); the "does not weaken as the patch brightens" assertion and the chroma/hue holds are unchanged.
- `SliderContractTests.testUniformityConvergesAtBandCentresAndHoldsSeams`: centres and seams read from the engine (seam = crossover) instead of 29.23 + 45k and centre + 22.5; thresholds unchanged.
- `AppliedReadoutTests.testUniformity100LandsEveryHueInsideABandOnOne`: "inside a band" is the band's core (3.5–7.3° per side now) instead of a fixed ±5° that sat inside the old ±22.5° cores; tolerance unchanged.
- `PointColourPickerStageTests.testTheMixerBandPickReadsAfterThePrimaries`: the "strongest" band is measured per stop of that band's own Luminance strength, since bands now have their own −100 strength.

New tests: `MixerBandGeometryTests` (9), `MixerHueMonotoneTests` (4), `MixerExtremesTests` (4), `ExactColorStageTests.testTheMixerTwinMatchesTheEngineOnAOneDegreeHueSweepAtEverySliderEndpoint`, `DominantBandTests.testAPickSelectsTheBandAPhotographerWouldName`.

No golden file changed. `scripts/check-swift-surface.py`: no new failures against the base log (kernels: 48 sources, no reserved identifiers).

## Evidence (`evidence/`)

- `sky_blue_lum_before_after.png`: 983, 1840, 2545 at Blue lum −100 / 0 / +100, before and after.
- `sky1840_edge_zoom2x_before_after.png`: 1840 treeline, base, before −100, after −100.
- `hue_wheel_green_hue_before_after.png`: Green hue −100…+100 on the hue wheel.
- `skin_orange_lum_before_after.png`: Orange lum −100 / 0 / +100 on `skin_tones`.
- `hue_ramp_fold_green_before_after.png`: displayed hue shift against input hue for Green ±100 on the ramp row L 0.6 C 0.06; ticks mark local slope < 0.1 (folds) — present before, none after.
