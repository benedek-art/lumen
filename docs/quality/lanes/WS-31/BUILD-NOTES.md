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
3. **Hue** (revised in round 2, see below). A monotone warp of the hue circle (`hueDisplacement`). Band k turns its whole core by d_k, and the move falls off through `hueTransfer` (quadratic ease over 10% at each end, linear between) from the core edge to `hueReachFactor` (1.35) × the band's reach (core + feather) on each side, so the Band range ring scopes the Hue move as it scopes Sat and Lum. d_k = slider × min(35°, (1 − 0.25 − 0.01) × the shorter falloff × 0.9): symmetric in sign, so ±100 are equal and opposite, and a single band keeps slope ≥ 0.26. `resolvedHueShifts` measures the composed warp's steepest slope on a 0.05° grid and scales the recipe's moves down together if they combine to squeeze below that. Gated by the mixer gate. The normalised membership weights no longer carry hue moves: their transitions are as narrow as band selectivity needs, which is too narrow to carry a 25–35° move without folding.
   - Uniformity and Hue **compose**: Uniformity is applied first (it reads the input hue), and the warp is evaluated at the converged hue. Before, the two displacements were added at the same input hue, which folded the circle (verify R7).
4. **Luminance.** `mixerLightness`: L × 2^(stops·ω(L)), chroma held (invariant #1). Per-band stops at −100 `[0.30, 0.27, 0.30, 0.30, 0.33, 0.345, 0.33, 0.30]`, at +100 `[0.32, 0.29, 0.32, 0.32, 0.35, 0.36, 0.35, 0.32]`; ω(L) = (min(L, 1)/0.5)^0.9. The lightness scaling is there because the default rendering's shoulder turns the same scene stops into 0.68× the display stops on a bright sky (2545) that it gives a dark one (983); Orange is gentler because mid skin reads 1.4× the display stops of a sky. `lumShape` and `lumKappa` are unchanged (Point Colour still uses them).
5. **Mixer gate.** `mixerGate` = smoothstep(0.022, 0.04, C), used for every gated mixer move and for `dominantBand(for:)`. `chromaGate` (0.02–0.06) is untouched for Point Colour and Skin. Skies (C ≥ 0.047) are on the flat top, so chroma noise no longer becomes luminance noise.
6. **Saturation.** A pull is unchanged (ungated, linear). A push has gain 1 + p·max(0, 1 − r/1.10), where r = C / (L·σ(h)) and σ(h) is a 6-harmonic Fourier fit of ln of the largest C/L an sRGB-primaries colour can have with no negative channel (scale-free cone, `mixerSatReferenceCoefficients`, fitted on a 0.25° grid with `docs/quality/lanes/WS-31/tools/mixlib.py`'s OKLab, which is `OKLabTransform.working`). Monotone in C (dr′/dr ≥ 1 − p) and in the slider.
7. **Names.** `bandNames` = Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta.
8. **B&W kept on the legacy grid** (`uniformBandHueCentres`, `uniformArcs`, `uniformBandWeights`), one line each in `applyBlackAndWhite` and the finish-pass centres; see NEEDS E-2.

## Round 2 (after VERIFY-R1 and the SPEC amendment R1–R7)

- **R5 / ControlProofTests.** `mixer.blue.hue` measured 13.0 against a floor of 17. The hue move now falls off over the band's own reach instead of stopping at the neighbouring centre, and the cap is 35°, so the Blue band's move reaches the ColorChecker blue patches 13–16° off its centre. Blue hue authority is now 20.06 and Purple hue 28.23; the lowest mixer authorities are hue 20.06, sat 38.68 and lum 75.96, against floors of 17, 35 and 71; Uniformity is 8.66 against 7. Records were re-recorded with `LUMEN_RECORD_PROOFS=1 swift test -c release --filter ControlProofTests`, the path proof.yml's `record_proofs` uses. The check-mode run then passes: 6 tests, 0 failures. **Changed records: exactly the 25 mixer records** — `mixer.{red,orange,yellow,green,aqua,blue,purple,magenta}.{hue,sat,lum}.json` and `mixer.uniformity.json`. No other record moved. These records were already stale against the round-1 engine (geometry, gate, luminance, saturation), and round 2 adds the hue-reach change. Each one is a deliberate fix (SPEC G/H/L/X lines), not a regression.
- **R6.** Hue follows the ring. `MixerHueMonotoneTests.testTheHueMoveIsScopedByTheBandRangeRing`: for every band, on the engine and on the twin, a ring at the panel's minimum moves fewer hues by more than 1° than the default does (by more than 5° of input hue), and a widened ring moves more. Every ring stays monotone (slope ≥ 0.10).
- **R7.** `MixerHueMonotoneTests.testUniformityCombinedWithHueNeverFolds`: Uniformity 0/50/100 × every band Hue ±100 plus alternating signs, on the engine and the twin, over three rows. At Uniformity 0 and 50 the minimum slope is ≥ 0.10. **At 100 the floor is ≥ 0, not 0.10.** Uniformity 100 by itself lands every hue inside a core on one value (slope 0; that is its specified job, `AppliedReadoutTests.testUniformity100LandsEveryHueInsideABandOnOne`), so no Hue setting can lift that slope to 0.10. The test asserts there is no fold. The Float32 twin's flats jitter by about ±0.005 over the 0.05° grid. This is a spec-owner point on R7's wording.
- **Polish (item 4) not done.**
  - Lawn speckle under Orange lum −100: the stage is per-pixel, so it cannot smooth the gate or the membership spatially. A wider gate ramp would break N4.
  - V3's soft radial apex comes from the same gate ramp (C 0.022–0.04).
  - The faint leaf outline at 6× (V2) is about 4× weaker than base.
  - All three are left for the owner to judge.
- **RobustnessTests floor 0.2 → 0.1 kept.** The old floor encoded the old additive luminance kernel: 0.25 of L at full authority, which took 983's dark sky about 6 EV down. SPEC L1 requires −100 to be 1.0–1.6 EV, which is a drop of about 0.13 in L at mid-grey, so a 0.2 floor cannot hold under L1. This is a spec conflict with T3's "no tolerance loosened" and is listed as such. The property the test exists for, that the drop does not weaken as the patch brightens, is unchanged.

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
| H1 | slope ≥ 0.10 | 0.105 | PASS |
| H2 | (R1: judged by H6) display 4.07 informational; stage max 1.75 | stage PASS | PASS (R1) |
| H3 | (R1: judged by H6) display 25.4–35.9° informational; stage 28.2–33.2° | stage PASS | PASS (R1) |
| H3b | ≤ gap − 2 | all | PASS |
| H4 | direction | all 16 | PASS |
| H5 | ΔC < 2%, ΔL < 0.005 | 1.05%, 0.0012 | PASS |
| H6 | stage-level H1/H3/H4/H5, engine and twin | min slope 0.260 engine / 0.251 twin; shift 28.2–33.2°; ΔC 5e-14 | PASS |
| L1 | −100: 1.0–1.6 EV | −1.10 / −1.45 / −1.20 (983/1840/2545) | PASS |
| L2 | +100: 0.7–1.2 EV | +1.17 / +1.12 / +0.88 | PASS |
| L3 | newly crushed < 0.5% | 0 / 0 / 0 | PASS |
| L4 | noise ≤ 1.3× | 1.16 / 1.26 / 1.01 | PASS |
| L5 | fringe ≤ 0.342 | 0.264 | PASS |
| L6 | monotone | min step 0.158 EV | PASS |
| L7 | +/− ratio 0.7–1.3 | 1.07 / 0.77 / 0.73 | PASS |
| K1 | monotone | yes | PASS |
| K2 | (R2) stage drift ≤ 3° | stage < 1e-9° (HuePreservationTests band sat/lum); display 14.0° informational | PASS (R2) |
| K3 | Y ≥ 0.4 Y0 | 0.413 | PASS |
| K4 | (R3) MST 3–8 + CC skins move ≥ 0.015 | min 0.052 (MST 3 +100); MST 1, 2, 9, 10 static (known limitation) | PASS (R3) |
| K5 | (R4) MST 5–8 spread ≤ 3 | 1.71 (MST 3–8: 3.94, informational) | PASS (R4) |
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
| T2 | 0 failures, ≥ 3044 + new | 3068 run, 0 failures | PASS |
| T3 | listed suites green | green | PASS |
| T4 | macOS jobs | not run here (needs push) | — |
| T5 | pin or NEEDS | NEEDS E-1 | PASS (conditional) |
| R5 | ControlProofTests pass | 6 tests, 0 failures after re-recording the 25 mixer records | PASS |
| R6 | Hue scoped by the ring | `testTheHueMoveIsScopedByTheBandRangeRing` | PASS |
| R7 | Uniformity + Hue slope ≥ 0.10 | ≥ 0.10 at U 0/50; ≥ 0 at U 100 (Uniformity's own flats) | PASS at 0/50; 100 see note |

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
- `RobustnessTests.testMixerLuminanceDarkensABlueSkyAtEveryExposure`: probe hue is the Blue centre; the absolute floor is 0.1 instead of 0.2. The 0.2 encoded the old additive kernel (0.25 of L, about 6 EV down on 983's dark sky); SPEC L1 requires 1.0–1.6 EV, a drop of about 0.13 at mid-grey, so the old floor cannot hold — a spec conflict with T3, flagged, not hidden. The "does not weaken as the patch brightens" assertion and the chroma/hue holds are unchanged.
- `SliderContractTests.testUniformityConvergesAtBandCentresAndHoldsSeams`: centres and seams read from the engine (seam = crossover) instead of 29.23 + 45k and centre + 22.5; thresholds unchanged.
- `AppliedReadoutTests.testUniformity100LandsEveryHueInsideABandOnOne`: "inside a band" is the band's core (3.5–7.3° per side now) instead of a fixed ±5° that sat inside the old ±22.5° cores; tolerance unchanged.
- `PointColourPickerStageTests.testTheMixerBandPickReadsAfterThePrimaries`: the "strongest" band is measured per stop of that band's own Luminance strength, since bands now have their own −100 strength.

New tests: `MixerBandGeometryTests` (9), `MixerHueMonotoneTests` (6), `MixerExtremesTests` (4), `ExactColorStageTests.testTheMixerTwinMatchesTheEngineOnAOneDegreeHueSweepAtEverySliderEndpoint`, `DominantBandTests.testAPickSelectsTheBandAPhotographerWouldName`.

No golden file changed. `scripts/check-swift-surface.py`: no new failures against the base log (kernels: 48 sources, no reserved identifiers).

## Evidence (`evidence/`)

- `sky_blue_lum_before_after.png`: 983, 1840, 2545 at Blue lum −100 / 0 / +100, before and after.
- `sky1840_edge_zoom2x_before_after.png`: 1840 treeline, base, before −100, after −100.
- `hue_wheel_green_hue_before_after.png`: Green hue −100…+100 on the hue wheel.
- `skin_orange_lum_before_after.png`: Orange lum −100 / 0 / +100 on `skin_tones`.
- `hue_ramp_fold_green_before_after.png`: displayed hue shift against input hue for Green ±100 on the ramp row L 0.6 C 0.06; ticks mark local slope < 0.1 (folds) — present before, none after.

## UI test changes

Made in the UI fix round (after 49cf99b), with the reason for each.

- `CurveMathTests.testTheMixerGroupRowMovesTheWholeSetTogether` → `testTheMixerRowsEachWriteTheirOwnBand`. The old test read ColorPanel.swift and required `GroupMove.moved(`/`GroupMove.mean(`, which encoded the All-bands group-offset mode. WS-31 removed that mode on purpose (U4; reasons in `ColorPanel.mixerHeaderRow` and NEEDS "## UI" item 3). The replacement states the new contract: the mixer binding writes exactly its own band, clamped to ±100, under the per-band undo key `mixer.<attr>.<band>`. It also asserts that no `GroupMove.` call and no `state.mixerAllBands` read remain, and that the Hue, Saturation, Luminance and Band views all exist. `GroupMove`'s own tests (`CurveAdversarialTests`) are untouched.
- New `MixerRingWireTests` (in `ColorPanelReachTests.swift`, 3 tests), for E-4. `ColorPanel.moveHandle` now reads the drawn arc through `ColorEngine.bandArcs` and moves one side in degrees (`ColorPanel.draggedArc`, clamped to `bandCore/FeatherMin/MaxDegrees`). It writes back through `ColorEngine.wireHandles`. The three tests are:
  - a source scan pinning that route, including that `MixerBand.defaultCore` is no longer treated as degrees;
  - a round trip over every band, all four handles and drag targets ±80° around the centre in 2.5° steps: `bandArcs(wireHandles(dragged))` equals the dragged arc, with the feather only ever widened to `bandMinReach`;
  - a check that the canonical arc written back, and `resetArc`'s wire defaults, both resolve exactly to `canonicalArcs`, so the Band range "reshaped" dot cannot light from a no-op.
- `Tests/LumenAppTests/LayoutMetricSupport.swift`: the ColorPanel slider citations moved with the lines `moveHandle`'s rewrite added.
- Verify round 1 fixes, as listed below.
  - `PanelSnapshotTests`: the `panel-grade-colour-mixer-band-range` state now opens the fold by setting `AppState.mixerRangeExpanded = true` (and closes it after). Previously it used `press: ["Band range"]`, which the accessibility walk never found ("could not find" in index.md), so that PNG was identical to the collapsed state.
  - `LayoutMetricSupport.swift`: the ColorPanel and `LumenControls.swift:2231` (colour-wheel bar) citations moved with the lines this round added.
