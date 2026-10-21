# WS-02 spec: eyedroppers & pick routing

From `AUDIT.md` plus the lead's scope decisions A–I. Every line is PASS/FAIL. `core-tests` = `bash
/tmp/claude-0/bin/core-tests.sh <XCTestFilter>` (Linux runner; patches the two pre-existing CompareView trailing
commas for the run and restores them). [macOS-CI] = only checkable on the macOS runners (LumenPipeline/LumenApp do not
build on Linux); the verifier reads the code there and checks the named test/snapshot after push. Abbreviations as in
the audit (AS, PR, RC, RG). Lead-granted edits outside the workstreams row: `NeutralPickerOverlay` (ViewerOverlays),
the catcher mount in `LoupeView` (~2094-2106), the Keymap Esc branch (~633-645), the three RC sample entries, two
modifier arguments of the BasicPanel WB button. Tools for the measured lines are in `docs/quality/lanes/WS-02/tools/`.

## A. Colour-stage tap includes Presence/denoise

- **A1** [macOS-CI] `PR.sampleColorStageInput` builds its stage with `RenderGraph.Options(..., maskSource: false)`,
  the same input the render's colour stage receives (after S3 denoise and S8 `applyPresence`). New test
  `Tests/LumenPipelineTests/PickTapParityTests.swift` `testPointColourTapReadsThePresenceAppliedStageInput`: synthetic
  frame, Dehaze +60, Clarity +40. The sampler's value at (0.3, 0.6) equals `ColorEngine.selectionInput` of
  `RG.colorStageInput(maskSource: false)` read at the same 5x5 window, within 1e-4 per channel. The same value differs
  from the `maskSource: true` read by > 1e-3 in at least one channel (proves the test is not vacuous). The mask taps
  (`sampleMaskStageInput`) stay `maskSource: true`. Code review: the doc comment states which tap is which and why.

## B. Zoom-aware sample window (Lightroom's 5x5 screen-pixel rule)

- **B1** New `Sources/LumenCore/Model/PickSample.swift`: `PickSample.radius(sourcePixelsPerDevicePixel s: Double) ->
  Int` `= clamp(ceil((5·s − 1)/2), 2, 31)`. That gives a 5x5 device-pixel window at ≤100 % zoom, a 5x5 image-pixel
  window above 100 %, and a 63 px cap. Non-finite or ≤0 input → 2. `Tests/LumenCoreTests/PickSampleTests.swift`
  (`core-tests PickSampleTests`): `testAbove100PercentIsFiveImagePixels` (s ∈ {0.125, 0.5, 1.0} → 2);
  `testFitOnA24MPFrameIsNineteenPixels` (s = 6024/1686 → 9); `testFitOnTheG9IsSeventeenPixels` (s = 5184/1686 → 8);
  `testTheCapIs63Pixels` (s = 100 → 31); `testRadiusNeverDecreasesWithZoomOut` (s from 0.05 to 60 in steps of 0.01);
  `testGarbageInputFallsBackToTwo` (NaN, ∞, 0, −1).
- **B2** [macOS-CI] Plumbing. The catcher computes `s = 1 / PR.displayedPixelsPerSourcePixel(geometry, sourceSize:,
  displayedLongEdge: drawnLongEdgePoints × backingScaleFactor)` and passes `PickSample.radius(s)` with the click. The
  chain is `AS.resolvePick(on:sourceX:sourceY:radius:)` → `RC.solveNeutral` / `samplePointColorReference` /
  `sampleMaskReference(…, radius:)` → the `radius:` of `PR.sampleSceneLinear` / `sampleColorStageInput` /
  `sampleMaskStageInput`. Code review: no call site in the chain drops `radius` or falls back to the default 2. The
  only exception is a caller with no click (none today).
- **B3** Measured justification: neutral wander at the Fit radius. Inputs are native decodes (`python3
  scripts/proof/decode_raw.py RAW out.lfi --long-edge 0`). Run `tools/noise_fit.py <1332,2348,2062 .lfi>` (KS =
  5,15,17,19,25; 120 simulated clicks within ±8 px on each of the 3 flattest near-neutral 64 px patches), then
  `tools/solve_fit.py noise_fit.json <tools/solver binary>`. The solver runs the real
  `WhiteBalanceEngine.neutralizing`. Pass: per-frame median 1σ neutral wander at the B1 side for that frame's Fit is <
  4 mired on 1332 (77D, ISO 3200; side 19), < 5 mired on 2348 (G9, ISO 3200; side 17; 5184 px wide, so a smaller
  window by Lightroom's rule), and < 4 mired on 2062 (X9, ISO 6400; side 19). Measured at spec time: 5x5 (today) 14.7
  / 15.1 / 9.3 mired; Fit side 3.0 / 4.6 / 2.4 mired (tint 3.1 / 2.6 / 2.0). This line re-runs only if
  `neutralizing`'s maths changes. The radius itself is pinned by B1. *Lead note:* the G9 misses "< 4 mired on the ISO
  3200 frames" at Lightroom's own rule (4.6). I kept parity with Lightroom and set 5 mired for it. A 19 px floor at
  Fit would get under 4, but the rule would then no longer be Lightroom's.

## C. A pick is bound to the photo and targets it was armed on

- **C1** New pure type `Sources/LumenCore/Model/PickArming.swift`: `PickArming` (Equatable, Sendable) holds the
  armed photo identity, a LumenCore twin of the target (neutral, newPointColor, mixerBand, pointColor(i),
  maskSample(maskID, component), maskPointColor(maskID)), and a snapshot taken at arm time: `pointColors.count`, and
  the mask's `components.count` and `components[c].kind` / `adjust.pointColors.count`. The type has `func
  accepts(photo:recipe:) -> PickArming.Verdict` (`.accept` or `.reject(message)`).
  `Tests/LumenCoreTests/PickArmingTests.swift`, `core-tests PickArmingTests`:
  `testAcceptsOnTheArmedPhotoWithNothingChanged` (all 6 targets); `testRejectsAnotherPhoto` (all 6);
  `testRejectsAResampleAfterASwatchWasRemoved`; `testRejectsAMaskSampleAfterItsComponentWasRemovedOrItsKindChanged`;
  `testRejectsAMaskThatNoLongerExists`; `testRejectsAtTheEightLimitWithAMessageThatSaysSo` (8 swatches, 8 samples, 8
  mask swatches; the message contains "8" and "limit"; covers audit §1.7);
  `testEveryRejectionHasADistinctNonEmptyMessage`.
- **C2** [macOS-CI] `AS.beginPick` stores a `PickArming`. `AS.resolvePick` evaluates `accepts` before the Task, and
  again after each await before any `updateRecipe`, alongside `selectionStillOnPickedPhoto`. On reject it sets the
  verdict's message as the status, and never calls `updateRecipe`. Code review plus a new LumenAppTests case
  `PickArmingAppTests.testAPickArmedOnOnePhotoNeverWritesAnother`: arm `.newPointColor` on photo A, select B, call
  `resolvePick(on: B, …)`. B's recipe stays byte-identical (canonical JSON) and `statusMessage` equals the reject
  message.

## D. Esc cancels a pending pick first

- **D1** [macOS-CI] In `Keymap` (Esc branch ~640), `state.pickTarget != nil` is checked before
  `state.sliderHoldsFocus`. With a pick armed and a slider focused, the first Esc cancels the pick and consumes the
  key. The slider keeps focus, and a second Esc drops it. The decision is extracted into an internal pure function,
  e.g. `Keymap.escapeAction(pickArmed:sliderHoldsFocus:masking:…)`. Test:
  `Tests/LumenAppTests/PickEscapeTests.testFirstEscapeCancelsAPickWhileASliderHoldsFocus` plus
  `testEscapeWithNoPickStillDropsSliderFocusFirst` (no regression of the nested idiom).

## E. Neutral guard: too dark, clipped

- **E1** In `WhiteBalanceEngine` (beside `neutralizing`): `static func neutralSampleRefusal(mean: RGB, windowMax:
  RGB, clipLevel: Double = 1.0) -> NeutralSampleRefusal?` with cases `.tooDark` and `.clipped`, each with a distinct
  `message`. Thresholds, on the camera-reference decode in linear Rec.2020: `.clipped` when `max(windowMax.r, .g, .b)
  ≥ 0.95 × clipLevel`. Clipped wins over dark. `.tooDark` when `Y(mean) = 0.2627R + 0.6780G + 0.0593B < 0.002`, or
  when any mean channel is ≤ 0. Why these numbers: sensor white is 1.0 in the decode convention (CORPUS.md). Measured
  corpus decodes put clipped areas at 1.00–1.19 per channel, with p99.99 ≈ 1.0 on every clipped frame. 0.95 is 0.07 EV
  of headroom, below sensor non-linearity and the reconstruction ramp. The 0.002 floor (−6.5 EV, a near-black on
  screen) is measured with `tools/dark.py` at the Fit window: on ISO 3200 frames the wander is 36 mired at Y ≈ 0.002,
  15–22 at 0.004, 9–18 at 0.01 and 5–6 at 0.02. On the ISO 100 Z7 II it is 0.9 mired at 0.01. The floor refuses only
  where every ISO is mostly noise. It does not try to be ISO-aware.
  `Tests/LumenCoreTests/NeutralSampleGuardTests.swift`, `core-tests NeutralSampleGuardTests`: `testDarkFloor` (grey at
  Y 0.0019 refused `.tooDark`; 0.0021 accepted); `testClipLevel` (window max 0.951 → `.clipped`, 0.949 → nil; with
  clipLevel 2.0, 1.9 → `.clipped`); `testZeroOrNegativeChannelIsTooDark`; `testAGreyCardIsAccepted` (mean 0.18, max
  0.2); `testTheTwoMessagesDiffer`.
- **E2** [macOS-CI] `PR.sampleSceneLinear` (or a sibling owned by WS-02) returns the window's per-channel max with
  the mean. `RC.solveNeutral` applies E1 to the decoded sample before the `wb.matrix` round trip and returns the
  refusal. `resolvePick` shows the refusal's message. Code review: the old `maxComponent > 1e-9` guard is replaced,
  not kept beside E1.

## F. Coordinate mapping twin (PR's functions unchanged; WS-25 owns them)

- **F1** New `Sources/LumenCore/Model/PickGeometry.swift`:
  `PickGeometry.sourcePoint(displayedX:displayedY:geometry:sourceWidth:sourceHeight:) -> (x: Double, y: Double)` and
  the inverse `displayedPoint(sourceX:sourceY:…)`. They mirror `PR.geometryRects` (flipH, then rotate by −angle, then
  the `CropGeometry.resolve` usable and target rects centred on the rotated box, y-up internally) in plain Double 2x2
  arithmetic. *Correction to decision F:* `CGAffineTransform` does not exist in Linux Foundation (`swiftc` here:
  "cannot find 'CGAffineTransform' in scope"). Foundation's `AffineTransform` does exist, but its composition order
  differs, so do not use it. `Tests/LumenCoreTests/PickGeometryTests.swift`, `core-tests PickGeometryTests`:
  `testRoundTripBothWays`: grid of angle ∈ {−45, −30, −7.3, 0, 0.5, 12, 30, 45} × flipH × crops {full,
  (0.1,0.2,0.5,0.6), (0,0,0.05,0.05), (0.7,0.65,0.3,0.35)} × sources {6000x4000, 4000x6000, 3x2} × an 11x11 point
  grid. The round trip is < 1e-9 both ways. `testIdentity` (no edit → source = displayed, 1e-12). `testPureCrop`
  (angle 0 → x = cx + u·cw, y = cy + v·ch). `testFlipHMirrorsX` (x = 1 − u, y = v). `testCentreMapsToCentre` (centred
  crop, any angle and flip → (0.5, 0.5), 1e-12). `testDisplayedCornersLandInsideTheSource` (all within [−1e-9,
  1+1e-9]). `testFortyFiveDegreesOnASquare` (square source, full crop: the displayed top-left corner lands on the
  source point (0, 0.5) at +45° and on (0.5, 0) at −45°, within 1e-9. These values are derived from `geometryRects`'
  convention, `rotated(by: −angle)` in y-up; F2 is the authority if the two disagree).
- **F2** [macOS-CI] `Tests/LumenPipelineTests/PickGeometryParityTests.swift`
  `testTheCoreTwinMatchesTheRenderersMapping`: on the F1 grid, `PickGeometry` equals `PR.sourceNormalized` /
  `displayedNormalized` within 1e-9.
- **F3** Code review (zoom and pan): the catcher stays inside `.scaleEffect(stretch).offset(offset)` on the `drawn`
  frame, so `value.location` is pre-scale. `zoomHoldAllowed` is false while picking (`stretch == 1`). B2's `s` uses
  the displayed size at that zoom, not the container.

## G. No armed state without a click target

- **G1** [macOS-CI] With the crop tool armed or a two-pane before/after showing (the `LoupeView` content branches
  without `NeutralPickerOverlay`), `beginPick` either refuses (status names why, `pickTarget` stays nil) or leaves
  that mode first. The builder picks one. Test `PickArmingAppTests.testNoPickIsArmedWithoutAClickTarget`: in both
  modes, after `beginPick(.neutral)`, either `pickTarget == nil` or the mode is off.

## H. Feedback

- **H1** Prompts move onto the LumenCore target twin (C1) and every one names Esc (e.g. "… — Esc to cancel").
  `PickArmingTests.testEveryPromptNamesEsc`.
- **H2** Every successful pick sets a non-nil status: point colour ("Swatch 3 added", "Swatch 1 re-sampled"), mask
  sample ("Sample 2 of 8 added"), mask point colour ("Mask swatch 2 added"), plus the existing neutral and mixer
  messages. The strings come from LumenCore: `PickArmingTests.testEveryTargetHasASuccessMessage`. Code review
  [macOS-CI]: `resolvePick` contains no `statusMessage = nil` after a successful write.
- **H3** [macOS-CI] While armed, the catcher draws a square that follows the pointer (`onContinuousHover`), with
  side `PickSample.indicatorSidePoints(radius:sourcePixelsPerDevicePixel:backingScale:) = (2r+1)/s/backingScale` pt.
  It uses a two-tone stroke (dark and light) so it reads on any tone.
  `PickSampleTests.testIndicatorSideMatchesTheSampleWindow`: r = 9, s = 3.57, backing 2 → 2.661 pt ± 0.001; at s ≤ 1 →
  5/s/backing.
- **H4** [macOS-CI] Decision: taken in-lane. The armed look on the WB button is two modifier arguments in
  `BasicPanel` (~388-389): background and foreground switch on `state.pickTarget == .neutral`, matching ColorPanel's
  armed mixer button. There is no layout change and nothing else in WS-03's file moves. Recorded in NEEDS as a
  courtesy note to WS-03.

## I. Snapshots (append-only to `Tests/LumenAppTests/PanelSnapshotTests.swift`) [macOS-CI]

- **I1** New cases, all rendered with no failure note in `index.md`: `panel-develop-white-balance-armed`
  (`beginPick(.neutral)`); `panel-grade-colour-point-colour-armed` (after `addPointColours`,
  `beginPick(.newPointColor)`); `window-1512x982-develop-picking` (border and prompt in place);
  `overlay-pick-indicator-fit` and `overlay-pick-indicator-200` (the catcher over the sample photograph with an
  injected pointer location, so H3 is visible). The Zones cases are WS-08 Z8.

## Visual claims (human judges, from the lane branch's `ui-snapshots` set)

- **V1** `panel-develop-white-balance-armed.png` vs `panel-develop-white-balance.png`: the armed eyedropper is
  unmistakably different at a glance (accent fill), and nothing else in the panel moved.
- **V2** `window-1512x982-develop-picking.png`: the status line reads as an instruction and names Esc. The image
  border shows the picture is the instrument.
- **V3** `overlay-pick-indicator-fit.png` / `-200.png`: the square reads on both the light and dark parts of the
  sample photograph, and it is visibly the same physical size on screen in both (5 device px). The cursor itself
  cannot be captured.

## Gates

`swift build --target LumenCore --target LumenRender` is clean. `core-tests` passes the full LumenCoreTests filter, or
the report lists failures proven pre-existing on base. Existing tests are untouched except where this spec says so.

## Non-goals (to NEEDS.md, with owner)

- `primarySelection.didSet`, workspace change, `setMasking`, crop arm and compare entry should call `cancelPick()`,
  so a stale prompt does not linger. C2 only makes the write safe; this is the reverse direction of G (AppState
  selection/workspace owners, LoupeView).
- `LoupeView`: do not mount the catcher while `sourceFrameSize == nil` (wrong fallback on cropped photos, audit §3).
- MaskPanel armed styling, and the toggle-off on second press, for mask add-sample and mask point colour
  (WS-48/MaskPanel).
- Marquee (drag-rectangle) sampling and a live loupe/RGB readout: above Lightroom, later.
- S5 heal applied before the neutral sample (audit §1.5).
- The Upright lane must extend `geometryRects` and `PickGeometry` together (WS-25).
- Silent edge-snap in `sampleMean`'s clamp (cosmetic).
- WS-03 courtesy note: the H4 two-argument change in BasicPanel.

