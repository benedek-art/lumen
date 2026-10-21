# WS-31 Colour Mixer: acceptance spec

Branch `quality/k2-color-mixer`. Baseline is commit `9068ded` with the release `lumen-render` built from it. Audit: `/tmp/claude-0/audit/AUDIT.md`.
Every line below is PASS or FAIL. "Baseline" is the value measured on the baseline binary with the same command.
Thresholds are fixed. If a line turns out to be wrong, the builder reports it as such and does not quietly loosen it.

## 0. How to measure

```
export PATH=/opt/swift612/usr/bin:$PATH
swift build -c release --product lumen-render
BIN=.build/release/lumen-render; T=docs/quality/lanes/WS-31/tools
O=/tmp/ws31-$(git rev-parse --short HEAD)    # use a fresh dir per build: the tools cache renders by file name
CENT=<the 8 centres ColorEngine ships, OKLCh deg, wire order red..magenta, comma-separated>
python3 $T/membership.py --bin $BIN --corpus corpus --out $O/mem          # lines G1-G5
python3 $T/hue_ramp.py   --bin $BIN --out $O/ramp --centres $CENT         # H1-H5, X5
python3 $T/monotone.py   --bin $BIN --ramp $O/ramp/ramp.lfi --out $O/mono # X6
python3 $T/sky.py        --bin $BIN --corpus corpus --out $O/sky          # L1-L7
python3 $T/skin.py       --bin $BIN --corpus corpus --out $O/skin         # K1-K5
python3 $T/neutrals.py   --bin $BIN --corpus corpus --out $O/neu          # N1-N4, X1-X4
python3 $T/sheets.py     --bin $BIN --corpus corpus --out $O/sheets       # V1-V3
```

The tools need only python3, numpy and Pillow, and each one prints a `PASS`/`FAIL` line per check.

- All measurements are taken on the engine's display PNGs, decoded to OKLab.
- **Band membership** is measured through the engine and needs no knowledge of the geometry. It is m_b = Δlog₂Y(band b lum ±5) / Δlog₂Y(all 8 bands lum ±5). Under a partition of unity this equals the band weight, and the chroma gate cancels.
- **Swift lines** run on Linux:
  - Suite: `swift test --parallel --filter LumenCoreTests --skip ControlProofTests`.
  - A single new test class: `swift test --filter LumenCoreTests.<Class>`.

## 1. Band geometry

- **G0.** There are 8 bands, in wire order red, orange, yellow, green, aqua, blue, purple, magenta. The centres increase strictly around the circle and every adjacent gap is ≥ 30°. Measured by the new `MixerBandGeometryTests`, which reads `ColorEngine` directly.
- **G1.** Each full-saturation sRGB primary and secondary (HSV 0/30/60/120/180/240/270/300) has membership ≥ 0.80 in its own band (lead decision: 0.90 left no room between sRGB red at 29.2° and CC light skin at 40.7°). Script: `membership.py`, check `S1`. Baseline: min 0.49 (sRGB orange 0.49/0.49 Red, sRGB green 0.50/0.50 Yellow).
- **G2.** ColorChecker light skin, ColorChecker dark skin and MST 5–8 each have Orange membership ≥ 0.60; MST 3–4 (h ≈ 84.6°, at Lightroom's own Orange/Yellow boundary) ≥ 0.40. Script: `membership.py`, checks `S2`, `S2b`. Baseline: min 0.17 (CC light skin; Red 0.86); CC dark 0.24, MST 8 0.32, MST 7 0.52.
- **G3.** The sky regions of 1840, 2545 and 983 have Blue mass ≥ 0.90. Script: `membership.py`, check `S3`. Baseline: 1.00 on all three (keep it).
- **G4.** The foliage regions (6929 tree, 1840 field, 1569 sunlit) have Green mass > 0.50 and Green + Yellow ≥ 0.90. Script: `membership.py`, check `S4`. Baseline: Green min 0.11 (6929; Yellow 0.86); G+Y min 0.95.
- **G5.** Engine partition of unity: Σ_b m_b = 1 ± 0.05 on every patch with a measurable response (|ΔEV_all| > 0.1) and on every region. Script: `membership.py`, check `S5`. Baseline: 0.023.
- **G6.** Partition and smoothness in the stage, checked by `MixerBandGeometryTests` on a 0.01° grid over 0..360° (raw weights and normalised weights):
  - Σw = 1 within 1e-9.
  - 0 ≤ w ≤ 1.
  - C¹: max |w(h+δ) − 2w(h) + w(h−δ)|/δ² ≤ 0.1 /deg² at δ = 0.01°, which means no slope jump.
  - This must also hold for every arc set that `sanitizedBands` can produce from the panel's arc limits.
  - The existing test `EngineIntegrationTests.testMixerBandWeightsFormAPartitionOfUnity` stays green.

## 2. Hue

- **H1.** No fold. At ±100, for every band and on every ramp row (L 0.4/0.6/0.8 × C 0.03/0.06/0.12/0.2), the slope of output hue against input hue (over a 2° baseline) is ≥ 0.10. Script: `hue_ramp.py`, check `H1`. Baseline: min −2.94 (and 14–20° of input hue folded on every band; audit M1).
- **H2.** No seam in hue. The same slope is ≤ 3.0 everywhere. Script: `hue_ramp.py`, check `H2`. Baseline: max 7.41.
- **H3.** Magnitude. At the band centre, row L 0.6 C 0.06, |Δh| at ±100 lies in [25°, 35°]. It must also be ≤ (gap to the neighbour it moves toward − 2°), so a move never reaches that neighbour's centre. Script: `hue_ramp.py`, checks `H3` (two lines). Baseline: 39.0–50.2°, reaching the neighbour centre.
- **H4.** Direction. +100 moves toward the next band in wire order (red → orange … magenta → red) and −100 toward the previous one, on all 8 bands. Script: `hue_ramp.py`, check `H4`. Baseline: PASS (keep it).
- **H5.** Hue moves do not change chroma or lightness. Each output pixel is compared with the base pixel of the same displayed hue: |ΔC|/C < 2% and |ΔL| < 0.005 on rows with C ≥ 0.06. Script: `hue_ramp.py`, checks `H5`. Baseline: 1.02% / 0.0011 (keep it).
- **H6.** The stage-level versions of H1, H3, H4 and H5 hold, with the same thresholds, in the new test `MixerHueMonotoneTests`.
  - It uses a 0.05° grid with the same L × C rows.
  - It runs on both `ColorEngine.applyMixer` and `ExactColorTwin.mixer`.
  - "Strictly increasing" means a minimum slope ≥ 0.10.

## 3. Luminance (Blue band on skies; sky patches and noise formula are the audit's `skym.py`)

- **L1.** Blue lum −100 darkens the median sky Y by 1.0–1.6 EV on 983, 1840 and 2545. Script: `sky.py`, check `L1`. Baseline: −6.08 / −3.47 / −2.31 EV.
- **L2.** Blue lum +100 brightens by 0.7–1.2 EV on all three. Script: `sky.py`, check `L2`. Baseline: +2.68 / +1.52 / +0.96 EV.
- **L3.** At −100, fewer than 0.5% of sky pixels are newly crushed to code 0. Script: `sky.py`, check `L3`. Baseline: 11.24% on 983, 0 on the other two.
- **L4.** Noise. Sky L high-pass std divided by median L (the edit's value over the untouched render's value) is ≤ 1.3× at both −100 and +100. Script: `sky.py`, check `L4`. Baseline: 7.52× / 10.44× / 1.72× at −100.
- **L5.** Fringe. The 1840 treeline fringe metric (definition in the `sky.py` header) at Blue −100 is ≤ 0.342, which is the baseline divided by 3. Script: `sky.py`, line `(L5) fringe`. Baseline: 1.026.
- **L6.** Monotone. Median sky EV increases strictly over the slider values −100, −80, …, +100. Script: `sky.py`, check `L6`. Baseline: PASS.
- **L7.** Symmetry. |EV(+100)| / |EV(−100)| lies in [0.7, 1.3] on each frame. Script: `sky.py`, check `L7`. Baseline: 0.44 / 0.44 / 0.41.

## 4. Skin (Orange band on `skin_tones`)

- **K1.** Orange lum (on L) and Orange sat (on C) respond monotonically on all 12 patches over −100..+100 in steps of 20. Script: `skin.py`, checks `K1`. Baseline: PASS.
- **K2.** Hue drift is ≤ 3° on every MST patch, for every Orange sat and lum value. It is evaluated only where both base and edit chroma are ≥ 0.008. Script: `skin.py`, check `K2`. Baseline: 7.9° (MST 8, sat); 7.1° (MST 6, lum).
- **K3.** Orange lum −100 keeps Y ≥ 0.4 × Y₀ (≤ 1.32 EV) on every MST patch, so one ~1.2 EV luminance scale serves both skies (L1) and skin. Script: `skin.py`, check `K3`. Baseline: 0.108 (MST 6 goes near-black).
- **K4.** Every MST patch from 1 to 10, the palest and darkest included, moves by |ΔL| ≥ 0.015 at both Orange lum −100 and +100. Script: `skin.py`, check `K4`. Baseline: 0.000 (MST 1, 2, 9 and 10 do not move).
- **K5.** Even response. Across MST 3–8, the ratio max/min of |EV| at Orange lum −100 is ≤ 3. Script: `skin.py`, check `K5`. Baseline: 14.0.

## 5. Greys and low chroma

- **N1.** On grey_ramp and flat_grey, neutral pixels (C < 0.01) move by ≤ 1 code under each of the 48 single sliders at ±100 and under all +100, all −100 and alternating ±100. Script: `neutrals.py`, check `N1`. Baseline: 1.
- **N2.** Under the same renders, the p99.9 ΔE2000 on those pixels is < 0.5. Script: `neutrals.py`, check `N2`. Baseline: 0.00.
  - The 99.9th percentile is used because a single 1-code step in the deepest shadows can reach ΔE00 ≈ 1 on its own.
- **N3.** On the six ColorChecker grey patches (interiors), the p99.9 ΔE2000 is ≤ 1.5 under the 3 combos. This is a no-regression line. Script: `neutrals.py`, check `N3`. Baseline: 1.30.
- **N4.** On hue_wheel, low-chroma pixels (0.01 ≤ C < 0.02) move by max ΔOK ≤ 0.03 under the 3 combos. Script: `neutrals.py`, check `N4`. Baseline: 0.0253.

## 6. Extremes, identity, smoothness

- **X1.** No NaN or inf.
  - Every `neutrals.py` render is finite (check `X1`).
  - The new `MixerExtremesTests` feeds the stage these inputs: L 0..1.5, C up to 0.4, negative RGB, 0, 1e4, and every all-±100 combination. Outputs from `ColorEngine` and from `ExactColorTwin` must all be finite.
  - Baseline: no NaN (audit M6).
- **X2.** Sat +100 rolls off. With all 8 Sat at +100 on the ColorChecker, ≤ 5% of pixels have a code-0 channel. Script: `neutrals.py`, check `X2`. Baseline: 28.6%.
- **X3.** Sat +100 still saturates. With the same all-Sat +100 ColorChecker render, the median chroma gain over patches with C > 0.05 is ≥ 1.4. Script: `neutrals.py`, check `X3`. Baseline: 1.75.
- **X4.** Default is identity: explicit zeros on all 24 sliders give a render bit-identical to the default recipe on hue_wheel, colorchecker and 2545. Script: `neutrals.py`, check `X4`. Baseline: 0 codes (keep it).
- **X5.** No seams in S or L (hue is covered by H2). On ramp rows with coverage ≥ 0.9, the steepest hue-edge of the effect, max |d|Δlab|/dh| divided by its peak, is ≤ 0.10 /deg for every band's H, S and L at ±100. Script: `hue_ramp.py`, checks `X5`. Baseline: 0.091 / 0.091 / 0.102.
- **X6.** Every one of the 24 sliders is monotone per pixel, from −100 to +100 in steps of 10, on the ramp. There must be 0 non-monotone pixels. Script: `monotone.py`, check `X6`. Baseline: 0.

## 7. Twins and tests

- **T1.** `ColorEngine` (CPU reference) and `ExactColorTwin.mixer` / `ExactColorKernelSource.mixer` (GPU) change in the same commit.
  - `ExactColorStageTests` passes in full, including `testTheTwinMatchesTheIndependentEngineOnEveryFamilyEndpoint` and `testNoSanitizedArcsCanEmptyThePartition`.
  - A new case compares engine and twin at all 48 single-slider endpoints on a 1° hue sweep, within that test's gate.
- **T2.** `swift test --parallel --filter LumenCoreTests --skip ControlProofTests` reports 0 failures, with test count ≥ 3044 plus the new tests. Baseline: 3044 tests, 0 failures.
  - An existing test that encodes the old band geometry is updated in the same commit, and REPORT.md names it and gives the reason.
- **T3.** These suites stay green with no tolerance loosened: `BlackAndWhiteMixTests`, `DominantBandTests`, `HuePreservationTests`, `RobustnessTests` (mixer cases), `PointColourGateTests`, `PointColourPickerStageTests`. The B&W mix and Hue Equalizer share the canonical arcs.
- **T4.** The macOS jobs `gpu-parity.yml` (`swift test --filter LumenPipelineTests`, which includes `ExactColorStageGPUTests`) and `ci.yml` are green on the lane's pushed sha. Read from the GitHub Actions run.
- **T5 (conditional).** Recipes stay version-pinned (docs/14 §8.2, D52): an existing recipe renders bit-identically to baseline.
  - If that requires per-version dispatch outside the lane's owned functions (`Recipe.swift` `pipelineVersion`, cache key, migration UI), the lane does not build it. Instead, NEEDS.md records it with the geometry constants old recipes must keep.
  - Either the golden test or the NEEDS.md entry must exist.

## 8. Visual claims (a human judges; sheets from `sheets.py`, compared against the audit's `/tmp/claude-0/audit/sheets/`)

- **V1.** In `hw_b3_hue.png` (Green hue −100…+100 on the hue wheel) and `1569_b3_hue.png`:
  - The green sector rotates as one piece, with no crease, ridge or doubled band at its edges.
  - Foliage shifts toward yellow-green or toward a cooler green, with no autumn-orange or teal blotches.
  - Before: audit `hw_b3_hue.png`, `1569_2_hue.png`, `crops/hw_b3hue_crops.png`.
- **V2.** In `sky_1840_b5lum.png` and `sky1840_edge_0_vs_m100_zoom3x.png`:
  - Blue −100 reads as a deeper blue sky, not navy or neon, and the sky grain is no coarser than in the untouched tile.
  - At 3× there is no light blue-grey outline around the leaves.
  - Before: audit `sheets/sky_1840_b5lum.png`, `crops/sky1840_m100_edge_zoom3x.png`.
- **V3.** In `hw_b1_sat.png` (Orange sat), `hw_b5_lum.png` (Blue lum) and `skin_b1_lum.png` (Orange lum on MST):
  - Band sectors have soft sides, with no crisp wedge and no radial apex.
  - The MST row darkens and lightens evenly from MST 1 to MST 10, and no patch goes near-black at −100.
  - Before: audit `sheets/hw_b1_sat.png`, `hw_b5_lum.png`, `skin_b1_lum.png`.

## 9. UI (ColorPanel mixer, judged from macOS `ui-snapshots` PNGs at 2×, dark)

**Where the snapshots come from.**
- Baseline set: `origin/ui-snapshots:claude-inspiring-dirac-ulgpch/a93efb2/`. After set: `quality-k2-color-mixer/<sha>/`.
- Existing states: `panel-grade-colour.png` (default), `panel-grade-colour-point-colour.png` (band index 2, Yellow, selected, with a sample edit), and `panel-grade-colour-all-bands.png`.
- New states are appended to the end of `Tests/LumenAppTests/PanelSnapshotTests.swift`:
  - `panel-grade-colour-mixer-hue.png`
  - `panel-grade-colour-mixer-saturation.png`
  - `panel-grade-colour-mixer-luminance.png`, which shows Adjust set to Hue, Saturation and Luminance respectively
  - `panel-grade-colour-mixer-band-range.png`, which shows Band view with "Band range" expanded
- If the Adjust mode needs a new `AppState` property so the test can set it, add one `@Published` line. If that is not allowed, put it in NEEDS.md (WS-02).

**Lines.**
- **U1.** Header row. One row holds an icon-only eyedropper (the same glyph and size as Point Colour's) and an "Adjust" segmented control reading exactly `Hue | Saturation | Luminance | Band`. The text label "Pick a colour" is gone. Judged on all mixer snapshots. Baseline: "Pick a colour" text plus `Band | All bands`.
- **U2.** Hue, Saturation and Luminance views.
  - Each view shows 8 sliders labelled Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta, in that order.
  - Every track is coloured for its band: Hue runs from the previous band's colour through the band's own to the next band's; Saturation runs from grey to the band colour; Luminance runs from dark to light band colour.
  - Readouts and label column match the Point Colour rows.
  - Judged on the three `panel-grade-colour-mixer-{hue,saturation,luminance}.png`. Baseline: no such view.
- **U3.** Band view.
  - It shows 8 round swatches in wire order, each with a tooltip, and the selected band's name in text.
  - The selected state is a ring that contrasts clearly at 1×.
  - Edited bands carry a marker of at least 3 pt (6 px in the PNG) that is visible on the edited Yellow band.
  - Below the swatches sit the 3 sliders Hue, Saturation and Luminance.
  - Judged on `panel-grade-colour-point-colour.png`. Baseline: 16 pt bars, no names, and a 3 px edited dot that is barely readable.
- **U4.** "All bands = move together" is gone from the primary control.
  - If the group offset is kept, it is a separate control labelled with what it does ("Shift all bands"), placed in the Band range disclosure.
  - No swatch is ever dimmed so that it reads as disabled.
  - Judged on `panel-grade-colour-all-bands.png`; that state name is kept and shows whatever the relabelled control looks like when on, or Band view if the mode is dropped. Also judged on `panel-grade-colour.png`.
- **U5.** Hierarchy.
  - The ring, the ribbon and arc-handle editing sit inside a "Band range" disclosure, collapsed by default. "Even out hues" sits either inside that disclosure or below a divider under the sliders.
  - In Band view, the first slider row starts ≤ 160 px (2×) below the bottom of the segmented control. In Hue, Saturation and Luminance views it starts ≤ 60 px below.
  - Judged on `panel-grade-colour.png` and `panel-grade-colour-point-colour.png` (both collapsed) and on `panel-grade-colour-mixer-band-range.png` (expanded). Baseline: about 446 px from the control to the Hue slider.
- **U6.** No colour-science jargon in the UI. `grep -nE '"[^"]*(OKLCh|feather|core [−-])[^"]*"' Sources/LumenApp/ColorPanel.swift` returns 0 hits, and no snapshot caption shows a degree value. Baseline: "Yellow — centred on 119.2° in OKLCh, core −22°/+22°, feather 15°/15°."
- **U7.** Swatch colours match their band.
  - Check: `python3 $T/swatch_hues.py --png panel-grade-colour-point-colour.png --points "<8 swatch centres x,y>" --centres $CENT` reports a worst offset ≤ 5° OKLCh hue.
  - The same must hold at the midpoint of each Saturation-view track.
  - Baseline: 20.5° (the "Mint" chip shows green h 143.7° against a centre of 164.2°).
- **U8.** Lumen spacing.
  - Mixer slider rows have the same pitch as the Point Colour rows in the same PNG, within ±2 px (baseline Point Colour pitch is 64 px).
  - Labels start at the same x as Point Colour labels, and readout pills have the same width.
  - Judged on all mixer snapshots.
- **U9.** `LayoutMetricTests` (`ui-layout.yml`), `ColorPanelTests` and the snapshot job (`ui-snapshots.yml`) are green on the lane's pushed sha.

## 10. Eyedropper

- **E1.** Select-band stays.
  - A pick selects the band with the highest membership (`ColorEngine.dominantBand`). New `DominantBandTests` cases assert:
    - sRGB HSV 0/30/60/120/180/240/270/300 select their own band;
    - CC light skin and CC dark skin select Orange;
    - hues 127.6°, 134.3° and 137.9° (the foliage medians) select Green;
    - hues 251° to 260° select Blue.
  - In Hue, Saturation and Luminance views, a pick highlights that band's slider row; in Band view it selects the swatch.
  - Baseline: orange and CC skin are seam or Red picks.
- **E2 (conditional).** Drag-on-image targeted adjustment works LR-style: press and drag vertically on the image to change the active attribute, spreading the change over bands in proportion to the pixel's membership, with greys as a no-op plus a message.
  - It is in scope only if it can be built without changing `AppState.resolvePick` or the pick routing, which WS-02 owns. `ColorPanel.pickBandButton` and the `bind` helper are owned by WS-32.
  - Otherwise NEEDS.md carries that contract for WS-02 and WS-32, and the lane ships only E1.
  - Verifier: either the feature exists and is reviewed from code, with REPORT.md listing what to try by hand, or the NEEDS.md entry exists.

## Amendment after verify round 1 (lane lead rulings)

Recorded after the round-1 verifier (VERIFY-R1) confirmed the builder's measurements independently. The original lines stay above, unedited, so the change is visible.

- **R1 (H2, H3).** The display-level hue lines measure the display transform as much as the Mixer: with no Mixer edit, the base renderer stretches displayed hue by 0.54–1.51× across the C 0.06 rows. H2 and H3 are judged at stage level by H6 (slope 0.25–1.75 ≤ 3.0; centre move 25–35°). `hue_ramp.py` H2/H3 stay as informational numbers in the report. The display non-uniformity goes to WS-13 (NEEDS E-3).
- **R2 (K2).** Hue drift is judged in the stage (Mixer output vs input hue on the MST patches, ≤ 3°). Display-level drift is reported, not gated: on the base binary, Presence Saturation −60 alone drifts MST 8 by 14° and Exposure ±1 by 10–23°.
- **R3 (K4).** Greys win. N4 (grey-wall chroma noise stays put) and K4 (MST 10 at C 0.011 must respond) cannot both hold for a chroma-gated kernel. K4 is restricted to MST 3–8 and the CC skins; MST 1, 2, 9, 10 not responding is reported as a known limitation for the owner.
- **R4 (K5).** K5 applies to MST 5–8, the patches G2 requires to be majority Orange. MST 3–4 sit on Lightroom's own Orange/Yellow boundary (G2b, ≥ 0.40); their partial response is by design and is reported.
- **R5 (ControlProofTests).** Added gate: `swift test -c release --filter ControlProofTests` passes; proof records that change are re-recorded only through the repo's recording path, with each moved control named in the report.
- **R6 (hue follows the ring).** Added gate: a band's Hue move is scoped by its Band range ring exactly as Saturation and Luminance are (narrow ring ⇒ fewer hues move), tested in LumenCoreTests.
- **R7 (Uniformity + Hue).** Added gate: H6's monotone-slope claim (≥ 0.10) holds with Uniformity 0/50/100 combined with any band Hue ±100, including alternating signs, tested in LumenCoreTests.
