# WS-02 verify (verifier, round 1)

Diff `c170432..61b7afd` (WS-08 docs excluded). Verdicts below were formed from the spec and the diff alone; BUILD-NOTES
was read only afterwards and agrees on every line.

**Overall: PASS.** I found no FAIL items. There are 4 minor notes (N1–N4), none of which blocks.

## Gates

- Linux `core-tests` (full suite, no filter, release): **3086 tests, 6 skipped, 0 failures**. Base is 3058, and the
  28 new ones are PickSample 7, PickArming 9, PickGeometry 7 and NeutralSampleGuard 5. `PointColorRePickReachTests` (the
  source scan the builder tripped on in round 1) passes 5/5. The working tree was clean after the run.
- macOS evidence for f3a869e: UI layout, GPU parity, UI snapshots and the Proof sweep all passed. test-fast had one
  failure, the BasicPanel slider-inventory citations, and 61b7afd fixes it. `check-citations.py` gives the following.
  - At 61b7afd: 3 unlanded (LookPanel:800, MaskPanel:2411, ZonesPanel:85).
  - At base c170432 (worktree): the same 3.
  - At f3a869e: those 3 plus the 14 BasicPanel citations.
  - So the fix is exactly the +2 shift, and nothing new is unlanded.

## Per spec line

| Line | Verdict | Evidence |
|---|---|---|
| A1 | PASS | `sampleColorStageInput` uses `maskSource: false` (PipelineRenderer ~2532). `sampleMaskStageInput` still uses `maskSource: true` (~2472). The new doc comment says which tap is which and why. `PickTapParityTests` exists and is not vacuous: it compares against `RG.colorStageInput(maskSource:false)` at 1e-4 and requires the `true` read to differ by > 1e-3. It passed on macOS CI. Only the coordinator calls `sampleColorStageInput`, so the mask taps are unaffected. |
| B1 | PASS | PickSampleTests 7/7. Measured: s=6024/1686 → 9 (19 px), 5184/1686 → 8 (17 px), 100 and 1e300 → 31, {0.125, 0.5, 1} → 2, NaN/±∞/0/−1 → 2, monotone over 0.05…60. |
| B2 | PASS | Catcher: `s = 1/displayedPixelsPerSourcePixel(geometry, sourceSize, max(proxy.size)·displayScale)`, and `radius` goes with the click. Chain checked by grep. LoupeView → `resolvePick(radius:)` → `RC.solveNeutral` / `samplePointColorReference` / `sampleMaskReference`. The RC entries have no default `radius`, so no call can quietly fall back to 2. These feed `PR.sampleSceneLinearWindow` / `sampleColorStageInput` / `sampleMaskStageInput`, which pass `radius` on to `sampleMean`/`sampleWindow`. No call site in the chain drops `radius`. |
| B3 | PASS (re-measured) | `neutralizing` is unchanged, but I re-ran `noise_fit.py` + `solve_fit.py` on the native decodes anyway. Per-frame median 1σ at the Fit side: 1332 side 19 → **3.0** mired (< 4); 2348 side 17 → **4.6** (< 5); 2062 side 19 → **2.4** (< 4). At 5x5: 14.7 / 15.1 / 9.3. These are identical to the spec-time numbers. |
| C1 | PASS | PickArmingTests 9/9. Read for edge cases: another photo rejects first, for all 6 targets. A removed swatch, a removed/swapped/appended component, and a deleted mask (including a mask id this photo never had) each reject with a distinct message. The 8-limit applies to newPointColor, sampleLimit and maskSwatchLimit, and each message contains "8" and "limit". A placeholder-only component is exempt, and re-sampling at the cap is accepted. See N1. |
| C2 | PASS | `beginPick` stores the arming after `showLoupe()`. This is a small improvement: previously, with no selection, it bound to `photos.first`. `resolvePick` disarms before the Task, as before, and evaluates `accepts` synchronously. On reject it sets the status, returns, and starts no Task. After each await, `armingStillHolds()` runs `selectionStillOnPickedPhoto()` and then `accepts` against the *current* recipe, before any `updateRecipe`. This also catches a 7 → 8 swatch change during a cold decode. `PickArmingAppTests.testAPickArmedOnOnePhotoNeverWritesAnother` exists and passed on CI. See N2. |
| D1 | PASS | `KeyDispatcher.escapeAction` is pure and `nonisolated`. The pick is checked before slider focus. `cancelPick` returns true, which consumes the key. With the pick gone and the slider still focused, the next press is `yieldToSlider`. The masking/heal/crop/grid order is unchanged, and the branch carries out each action exactly as before. `PickEscapeTests` has 2 cases that cover the first and second Esc and the old order. Passed on CI. |
| E1 | PASS | NeutralSampleGuardTests 5/5. Code matches the spec: peak ≥ 0.95·clip (or non-finite) → clipped, checked first; a channel ≤ 0, a non-finite mean, or Y < 0.002 → tooDark. Corpus check (25 `corpus/lfi` frames, 2000 random 19 px windows each): clipped refusals are 0–4.9% on most frames and 10.8% on the heavily blown GX80 (1569). Dark refusals are ≤ 3.8% (D7200 832, R5 II 7881). Unclipped pixels in [0.95, 1) are ≤ 0.65% of any frame. The guard refuses only blown or near-black spots on real frames. |
| E2 | PASS | `sampleSceneLinearWindow` returns `(mean, max)` through a private `sampleWindow`. `sampleMean` now wraps it with an identical result (a window that is not finite gives nil, as before, because the mean would already be non-finite). `RC.solveNeutral` applies E1 before the `wb.matrix` round trip and returns `.refused`. The old `maxComponent > 1e-9` guard is gone, not kept beside E1. `resolvePick` shows `refusal.message`. |
| F1 | PASS | PickGeometryTests 7/7. The grid covers ±45°, flip, the tiny 0.05 crop, the edge crop (0.7, 0.65, 0.3, 0.35) and a 3x2 source. Round trip < 1e-9 both ways. Corners stay inside [−1e-9, 1+1e-9]. ±45° on a square lands on (0, 0.5) and (0.5, 0). No CGAffineTransform or AffineTransform is used. |
| F2 | PASS | `PickGeometryParityTests` uses the same grid in both directions at 1e-9 against `PR.sourceNormalized`/`displayedNormalized`. It passed on macOS CI, which confirms the flip-then-rotate order. |
| F3 | PASS | The catcher is still inside `.frame(drawn).scaleEffect(stretch).offset(offset)`. `zoomHoldAllowed` still requires `pickTarget == nil`. `s` comes from the overlay's own `proxy.size` (the drawn frame), not the container. |
| G1 | PASS | Refuse was chosen. `pickHasNoCatcher` checks the same crop condition as `LoupeView.cropArmed` (`showCrop && workspace == .crop && !isMasking`) and `beforeMode.isTwoPane`. On refusal it sets `pickTarget` and `pickArming` to nil and puts a reason in the status. `testNoPickIsArmedWithoutAClickTarget` covers both modes plus the normal loupe. See N3. |
| H1 | PASS | All prompts live on `PickArming.Target.prompt` and each contains "Esc". `testEveryPromptNamesEsc`. |
| H2 | PASS | `testEveryTargetHasASuccessMessage`. `resolvePick` has no `statusMessage = nil`. After the write it sets `arming.successMessage(after: recipe(for: photo))`. For every reachable path, the arming re-check before the write guarantees the result is non-nil. Neutral and band messages keep their old text. |
| H3 | PASS | `onContinuousHover` square. Side = `indicatorSidePoints` = (2r+1)/s/backing. Two-tone: black 1 pt just outside the window, then white 1 pt. Test value 2.661 pt; at s ≤ 1 it is 5/s/backing. Measured in the snapshots (2x): inner window ≈ 5 device px at Fit and 10 device px at 200%, which is what the formula gives. |
| H4 | PASS | Exactly two modifier arguments changed (background and foreground switch on `pickTarget == .neutral`). There is no layout change, and the snapshot diff shows only the button pixels changing. See N4. |
| I1 | PASS | All 5 snapshots are in `ui-snapshots/quality-ws-02-08-pickers-zones/f3a869e` with an empty notes column. The cases are appended at the ends of `renderPanels` and `renderWindow`. Every pre-existing snapshot is pixel-identical to the baseline `a93efb2`, apart from two things outside this lane: the random folder UUID text, and the histogram percentage/"Binned" line on `window-1512x982-develop`. |

## Visual claims

- **V1 PASS.** In `panel-develop-white-balance-armed` against `panel-develop-white-balance`, the only changed pixels
  are in the box (684,101)–(732,140), which is the eyedropper button. The armed button has an accent (slate-blue)
  fill and a black glyph, so it is clearly different. Nothing else moved. The point-colour armed panel likewise
  changes only its eyedropper box.
- **V2 PASS.** In `window-1512x982-develop-picking`, the status bar reads "Click something neutral grey in the picture —
  Esc to cancel." There is an accent border around the image.
- **V3: PASS on readability; I overrule the size clause.** The square reads on both the light sun and the dark green
  ridge, because the white outer and black inner strokes are both visible on each. The two squares are not the same
  physical size: the window is ≈ 5 device px at Fit and 10 device px at 200%. **B1/H3 are right and V3's
  parenthetical is a spec error.** Lightroom's rule is 5x5 screen pixels at ≤ 100% and 5x5 *image* pixels above, so
  at 200% the honest indicator covers 5 image px = 10 device px. If it drew 5 device px there, the square would show
  a window smaller than the one actually averaged. The builder was right to follow B1/H3.

## Break attempts (all held)

- **Geometry:** ±45°, flip with edge and tiny crops, and the 3x2 source are all in the Linux grid and the macOS
  parity grid.
- **Radius at zoom extremes:** a huge s (1e300) caps at 31 with no Int trap, and deep zoom gives 2.
- **Edge clamp:** a click at the image edge averages a smaller window without saying so. This is pre-existing and
  logged in NEEDS (7).
- **Arming across targets:** removed swatch, removed or kind-changed component, deleted mask, another photo, and
  the 8-limit (checked both before the Task and after the await) are all covered.
- **Esc with a slider focused:** the pick is cancelled first and the slider keeps focus.
- **Pick with no catcher:** refused (G1).
- **Double click while a solve is in flight:** still disarmed before the Task, so the second click hits the
  `pickTarget` guard.
- **Concurrency:** the local funcs in the Task are `@MainActor`, and `armingStillHolds` reads the live recipe.
- **Scope:** every edit is inside the spec's named files and functions or its lead-granted list. The one exception
  is `LayoutMetricSupport.swift`, where citation line numbers moved because the BasicPanel lines shifted. That edit
  is required and loosens nothing.

## Notes (not FAILs)

- **N1** `.pointColor(index)` snapshots only `pointColors.count`, as the spec says. A `−` followed by a `+` during
  the arm keeps the count, so the pick still re-samples whatever now sits in that slot. This is spec-conformant;
  checking the swatch's identity as well would be stricter.
- **N2** In `testAPickArmedOnOnePhotoNeverWritesAnother`, the byte-identity half is weak. `B.arw` does not exist, so
  even an unguarded path could not write. The immediate `statusMessage == anotherPhoto` assertion is what makes the
  test non-vacuous.
- **N3** The two-pane refusal does not check for `beforeImage`. If the before image has not loaded, the loupe still
  shows the normal canvas, but arming is refused anyway. This is harmless, just slightly over-strict.
- **N4** H4 says "matching ColorPanel's armed mixer button", but the mixer uses `fillColor.opacity(0.35)` and
  primary text, while the WB button uses accent and black. V1 explicitly asks for an accent fill, and the change
  follows the mixer button's pattern of background and foreground switching on armed. The integrator may want the
  two armed styles unified later (WS-03 or WS-48).
