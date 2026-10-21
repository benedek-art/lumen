# WS-02 build notes (builder, round 1)

Base `c170432`. Linux runner: `bash /tmp/claude-0/bin/core-tests.sh <filter>` (release build). LumenPipeline /
LumenApp code and their tests do not build on Linux; those lines are `[macOS-CI] pending` and were checked by
reading every call site and by `python3 scripts/check-swift-surface.py` (all thirteen passes clean: inits, labels,
members, access, switches, scopes).

## Per spec line

- **A1** [macOS-CI] pending. `PipelineRenderer.sampleColorStageInput` now stages with
  `RenderGraph.Options(longEdge:, maskSource: false)`; its doc comment says why it differs from
  `sampleMaskStageInput` (which stays `maskSource: true`, comment unchanged and still right). New
  `Tests/LumenPipelineTests/PickTapParityTests.swift` `testPointColourTapReadsThePresenceAppliedStageInput`:
  192x128 textured frame, Dehaze +60, Clarity +40, (0.3, 0.6), r = 2. Expected = `ColorEngine.selectionInput` of the
  `colorStageInput(maskSource: false)` window mean, read through a CIContext with the renderer's options (RGBAh,
  extended linear Rec.2020 working space) over the same rect `sampleMean` uses; tolerance 1e-4 per channel; the
  `maskSource: true` read must differ by > 1e-3 (non-vacuity).
- **B1** PASS (Linux). `Sources/LumenCore/Model/PickSample.swift`, `radius(sourcePixelsPerDevicePixel:)` =
  clamp(ceil((5s − 1)/2), 2, 31), clamped as Double before the Int conversion; non-finite / ≤ 0 → 2.
  `core-tests LumenCoreTests.PickSampleTests`: 7 tests, 0 failures (the six B1 cases plus H3's
  `testIndicatorSideMatchesTheSampleWindow`). Measured: s = 6024/1686 → 9, s = 5184/1686 → 8, s = 100 → 31,
  s ∈ {0.125, 0.5, 1} → 2, monotone over 0.05…60 step 0.01, NaN/±∞/0/−1 → 2.
- **B2** [macOS-CI] pending (code review). `NeutralPickerOverlay` computes `s = 1 /
  PR.displayedPixelsPerSourcePixel(geometry, sourceSize:, displayedLongEdge: max(proxy.size) × displayScale)` and
  passes `PickSample.radius(s)` as the third argument of `onPick`. Chain: LoupeView mount →
  `AS.resolvePick(on:sourceX:sourceY:radius:)` → `RC.solveNeutral(…, radius:)` /
  `samplePointColorReference(…, tap:, radius:)` / `sampleMaskReference(…, pointColorSwatch:, radius:)` → the
  `radius:` of `PR.sampleSceneLinearWindow` / `sampleColorStageInput` / `sampleMaskStageInput`. The three RC entries
  take `radius` with NO default, so no call site can silently fall back to 2. `resolvePick` is the only caller of
  all three (grep of Sources/ and Tests/).
- **B3** PASS by pin. `WhiteBalanceEngine.neutralizing` is untouched (E1 adds a sibling function only), so per the
  spec the measurement is not re-run; the radius it was measured at is pinned by B1. Spec-time numbers stand:
  Fit-side 1σ neutral wander 3.0 / 4.6 / 2.4 mired on 1332 / 2348 / 2062 against limits 4 / 5 / 4.
- **C1** PASS (Linux). `Sources/LumenCore/Model/PickArming.swift`: `PickArming` (Equatable, Sendable) holds the photo
  URL, `PickArming.Target` (the six cases), and a `Snapshot` (pointColors.count; the mask's components.count,
  components[c].kind, adjust.pointColors.count). `accepts(photo:recipe:) -> Verdict` (`.accept` /
  `.reject(message)`); rejections are `PickArming.Rejection` (anotherPhoto, swatchesChanged, componentChanged,
  maskGone, swatchLimit, sampleLimit, maskSwatchLimit), each with a distinct message; the three limit messages read
  "8 … is the limit". A component holding only its placeholder grey is not at the cap (the first pick replaces it).
  `core-tests LumenCoreTests.PickArmingTests`: 9 tests, 0 failures (the seven C1 cases plus H1/H2).
- **C2** [macOS-CI] pending. `AS.beginPick` stores `pickArming` (bound to `primarySelection` after `showLoupe()`).
  `AS.resolvePick` evaluates `accepts` synchronously before the Task (reject → status = message, no Task, no write),
  and again after each await (`armingStillHolds()`, which also runs `selectionStillOnPickedPhoto()`) before any
  `updateRecipe`, against the photo's recipe as it is then. New `Tests/LumenAppTests/PickArmingAppTests.swift`
  `testAPickArmedOnOnePhotoNeverWritesAnother`: arm `.newPointColor` on A, select B, `resolvePick(on: B, …,
  radius: 2)`; asserts `statusMessage == Rejection.anotherPhoto.message` immediately, then waits 0.3 s and asserts B's
  canonical recipe JSON is unchanged.
- **D1** [macOS-CI] pending. The Esc branch of `Keymap` now asks `KeyDispatcher.escapeAction(pickArmed:
  sliderHoldsFocus:masking:healArmed:cropShowing:inGrid:)` (nonisolated, pure) and carries out its answer; the pick
  is checked before slider focus. The arrows' `if state.sliderHoldsFocus { return nil }` yield (which
  `KeyGrammarTests` scans) is untouched. New `Tests/LumenAppTests/PickEscapeTests.swift`:
  `testFirstEscapeCancelsAPickWhileASliderHoldsFocus`, `testEscapeWithNoPickStillDropsSliderFocusFirst`.
- **E1** PASS (Linux). `WhiteBalanceEngine.neutralSampleRefusal(mean:windowMax:clipLevel:)` and the top-level
  `NeutralSampleRefusal` (`.tooDark`, `.clipped`, distinct `message`s). Clipped (max channel of the window max ≥ 0.95
  × clipLevel, or non-finite) wins over dark; dark when any mean channel ≤ 0 or Y < 0.002.
  `core-tests LumenCoreTests.NeutralSampleGuardTests`: 5 tests, 0 failures.
- **E2** [macOS-CI] pending (code review). New sibling `PR.sampleSceneLinearWindow` returns `(mean, max)` through a
  new private `sampleWindow` (which `sampleMean` now wraps, so every other tap is byte-for-byte the same read).
  `RC.solveNeutral` returns `NeutralSolve` (`.solved` / `.refused(NeutralSampleRefusal)` / `.unreadable`), applying
  E1 to the decoded window before the `wb.matrix` round trip; the old `sample.maxComponent > 1e-9` guard is gone.
  `resolvePick` shows `refusal.message`. `sampleSceneLinear` (used by KernelGoldenTests and AuditPreviewReliability)
  keeps its signature.
- **F1** PASS (Linux). `Sources/LumenCore/Model/PickGeometry.swift`, plain Double 2x2: orientation
  M = F·R(−angle) (CG's `scaledBy(...).rotated(by:)` applies the rotation first), usable rect centred on M·centre,
  target from `CropGeometry.resolve`, y-up internally. `core-tests LumenCoreTests.PickGeometryTests`: 7 tests,
  0 failures. Round trip over the full grid (8 angles × flip × 4 crops × 3 sources × 11x11, both directions) < 1e-9;
  ±45° on a square lands on (0, 0.5) and (0.5, 0) as the spec derived.
- **F2** [macOS-CI] pending. `Tests/LumenPipelineTests/PickGeometryParityTests.swift`
  `testTheCoreTwinMatchesTheRenderersMapping`: same grid, both directions, < 1e-9 against
  `PR.sourceNormalized` / `displayedNormalized`. This is the authority check on the flip-then-rotate order.
- **F3** PASS (code review). The catcher is still mounted inside `.frame(drawn).scaleEffect(stretch).offset(offset)`;
  `zoomHoldAllowed` still includes `state.pickTarget == nil`; `s` is computed from the overlay's own `proxy.size`
  (the drawn frame at the live zoom), not the container.
- **G1** [macOS-CI] pending. Chosen: refuse. `beginPick` returns early with a status naming why, leaving
  `pickTarget == nil`, when the crop tool is armed in its workspace (`LoupeViewport.showCrop && workspace == .crop &&
  !isMasking` — `LoupeView.cropArmed`'s gate) or `beforeMode.isTwoPane`. Test
  `PickArmingAppTests.testNoPickIsArmedWithoutAClickTarget` (both modes, plus the ordinary loupe still arming).
- **H1** PASS (Linux). Prompts live on `PickArming.Target.prompt`; `PickTarget.prompt` forwards to it; every one
  names "Esc". `PickArmingTests.testEveryPromptNamesEsc`.
- **H2** PASS (Linux) for the strings; [macOS-CI] code review for the wiring. `PickArming.successMessage(after:)`
  ("Swatch 3 added.", "Swatch 1 re-sampled.", "Sample 3 of 8 added.", "Mask swatch 2 added."),
  `neutralMessage(kelvin:tint:)` (unchanged text) and `bandMessage(bandName:)` (unchanged text).
  `PickArmingTests.testEveryTargetHasASuccessMessage`. `resolvePick` no longer has `statusMessage = nil`; it sets
  `arming.successMessage(after: recipe(for: photo))` after the write.
- **H3** [macOS-CI] pending (visual). While armed the catcher tracks `onContinuousHover` and draws a square of side
  `PickSample.indicatorSidePoints(radius:sourcePixelsPerDevicePixel:backingScale:)` with a black inner and white
  outer 1 pt stroke drawn outside the window edge. The formula's test is Linux PASS (2.661 pt at r 9, s 3.57, 2x).
- **H4** [macOS-CI] pending (visual). Two modifier arguments of the BasicPanel WB button: armed → `Lumen.accent`
  background, black glyph. I used the accent (V1 says "accent fill") rather than ColorPanel's
  `fillColor.opacity(0.35)`; the shape of the change (background and foreground switch) matches the mixer button.
  Courtesy note to WS-03 in NEEDS.md.
- **I1** [macOS-CI] pending. Appended at the end of `renderPanels`: `panel-develop-white-balance-armed`,
  `panel-grade-colour-point-colour-armed`, `overlay-pick-indicator-fit` (24 MP source in the 1000x700 viewer),
  `overlay-pick-indicator-200` (source long edge = drawn long edge in points, i.e. s = 0.5 at 2x); appended at the
  end of `renderWindow`: `window-1512x982-develop-picking`. Each indicator shot injects two pointers (the sun and the
  dark near ridge) through `NeutralPickerOverlay.injectedPointers`.

## Visual claims

- **V1, V2** — judge on the lane's ui-snapshots set.
- **V3** — note for the verifier: at 200% the window is 5x5 IMAGE pixels = 10 device px (H3's formula, 5/s/backing
  with s = 0.5), so the two squares are NOT the same physical size; at Fit it is ≈ 5 device px. The spec's "the same
  physical size on screen in both (5 device px)" contradicts B1/H3; I followed B1/H3 (Lightroom's rule).

## Existing tests changed

None. No existing test encoded the old behaviour (the prompts, the neutral guard and `resolvePick`'s signature had
no test coverage).

## Gates

- `swift build --target LumenCore --target LumenRender`: clean (only the pre-existing VerifiedCopy.swift Sendable
  warnings and the pre-existing Proof/evidence exclude warning).
- New classes: `PickSampleTests` 7, `PickArmingTests` 9, `PickGeometryTests` 7, `NeutralSampleGuardTests` 5 — 28
  tests, 0 failures.
- Full Linux suite (`core-tests`, no filter, release): **3086 tests, 6 skipped, 0 failures**. The first full run
  had 3 failures in `PointColorRePickReachTests.testTheResolverReplacesTheSampleAndRebuildsNothing`: that source
  scan anchors on the FIRST `case .pointColor(let index):` in AppState.swift, and my new `PickTarget.core` switch
  used the same binding name above the resolver. Renamed the binding to `swatch` in `core` (no test changed); the
  re-run is the clean result above.
