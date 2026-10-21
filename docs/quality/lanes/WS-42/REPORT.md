# WS-42 / lane M1: mask list and overlay, report

Branch `quality/m1-mask-overlay`, from `claude/inspiring-dirac-ulgpch` @ `9068ded`.

## For the owner

1. Make a radial mask: the red shows. Drag its Exposure: the red disappears the moment you move, and stays gone after you let go.
2. Hover the mask's row: red while hovering, gone when you leave. Click the row: red again until your next slider move.
3. Press `O` (or the Overlay button): the overlay stays up. Drag any slider: it hides while you hold, comes back when you release. `O` again turns it off for good.
4. Paint a brush stroke or drag the Edge > Refine slider: the red stays up, because you are shaping the selection, not judging pixels.
5. Overlay menu (next to the Overlay button): pick a colour, a mode and an opacity (25/45/65/85 %). Quit and relaunch: your choice is still there.

## What was wrong

The rule that hides the overlay during an adjustment drag (`setMaskOverlaySuppressed`) had
**no caller** on the base commit. `addMask` kept a new mask's overlay up "until the first
adjustment", and the only thing that could report an adjustment was that dead function. So
the red stayed over the photo through every Exposure drag until `O` was pressed. That is the
owner's report, exactly. Around it: nine writers of `soloMaskOverlay` with precedence set by
call order, a 1400 ms flash timer racing the 120 ms hover timer, opacity hard-coded at 45 %,
overlay settings forgotten on relaunch, an empty "◯ Invert" chip on every row that read as a
column of radio buttons, and an editing header that said "Sun · 2 masks".

## What changed

- `Sources/LumenCore/Interaction/MaskOverlayRule.swift`: `MaskOverlayMachine` (pin, lit,
  hover, gesture, suppressed → `visibleID`) and `MaskOverlayEdit.classify(old:new:)`, which
  sorts every recipe edit into *adjustment* (develop, look, group Strength, a mask's adjust,
  Strength or blend), *selection* (components, invert, edge) or neither (rename, reorder,
  enable, add or delete). Replaces the `MaskOverlayRule` guard struct.
- `AppState.swift`: `sendMaskOverlay` is the single writer of `soloMaskOverlay` (now
  `private(set)`). The slider latch (`openSliderGesture`/`closeSliderGesture`, which every
  `LumenSlider` drag, arrow nudge and ⌥-scroll burst goes through) sends gesture events.
  `updateRecipe`, undo/redo `apply` and Auto Tone send the classified edit. A photo switch
  resets. The flash timer and `setMaskOverlaySuppressed` are deleted. New: `selectMask`,
  plus `maskOverlayOpacity`, with mode, tint and opacity persisted to UserDefaults
  `lumen.maskOverlay.*`.
- `MaskPanel.swift` (row and menu builders): the row tap, name tap and duplicate go through
  `selectMask`. Delete no longer does its own bookkeeping. The Overlay button uses `O`'s rule
  and its help text says what it will do. The overlay menu gains an Opacity section. The
  Invert chip shows only on the selected row or an inverted row. The editing header shows
  the stack ("Radial Gradient", or "Inverted · …") instead of a mask count.
- Callers outside the owned files, one line each: `MaskFloatingPanel` rail button and the
  `LoupeView` on-image pin call `selectMask`. `LoupeView` reads `state.maskOverlayOpacity`
  instead of the deleted constant. `AppStateActions.applyAutoToneSuggestions` reports its
  edit to the overlay.
- Tests: `MaskOverlayMachineTests` (23) and `MaskOverlayEditTests` (8) replace
  `MaskOverlayRuleTests`. They restate its three guards as scenarios: the pin is clearable,
  a drag blocks ambient overlays, and the lit mask survives a hover exit. One deliberate
  change: hovering a row while another mask is pinned now previews the hovered mask, as
  Lightroom does. The old struct blocked hover while pinned. `PanelSnapshotTests` gains
  `window-1512x982-masking-after-exposure-drag`, which drives the real latch and
  `updateRecipe` and asserts `soloMaskOverlay == nil`.

## Verdict per spec line

| line | result | measured |
|---|---|---|
| S1 T1-T18 | PASS | 23/23 machine tests, every table row asserted (verifier checked twice) |
| S2 classification | PASS | 8/8, develop and look both covered |
| S3 live call path | PASS | 19 call sites of `sendMaskOverlay(`/`noteMaskOverlayEdit(` across the latch, `updateRecipe`, `apply` and Auto Tone |
| S4 one writer | PASS | 1 assignment, `AppState.swift` `sendMaskOverlay` |
| S5 no flash timer | PASS | 0 matches |
| S6 colour, mode, opacity selectable and remembered | PASS (by code read and snapshot of the menu trigger; persistence must be tried by hand) | 4 tints, 6 modes, 4 opacities |
| S7 LumenCoreTests | PASS | 3061 tests, exit 0, local Linux (Swift 6.0.3, with the 6.1 trailing commas in `CompareView` patched locally only, never committed) |
| S8 CI | UI snapshots, UI layout, GPU parity, Proof sweep, build-macos, app-bundle and engine-linux green on `aec0762` | `aec0762` failed two jobs I caused, both fixed in the next commit: `LayoutMetricSelfTests` (43 slider citations into MaskPanel moved with my edits, remapped by diff against base) and the Swift-surface checker (it could not parse a two-pattern `case` or a variadic call). fixtures-linux stays red on pre-existing findings that also fail on base `a93efb2` (`set(_:forKey:)` labels, `Font` target, `Range` inits) |
| V1 rows | PASS | evidence 02: Sky row lost its empty chip, the selected Sun row keeps it as the control |
| V2 header | PASS | evidence 03: "2 masks" → "Radial Gradient" |
| V3 after drag | PASS | evidence 01: red wash gone after Exposure 0.30 → 0.60, Overlay button reads off |

## Verifier

Round 1: **FAIL**. The verifier found S3's grep pattern matched nothing (the call path was
live but the spec named the wrong function), and four paths that skipped the machine or
could defeat it:

- Auto Tone wrote `recipes` directly.
- Undo/redo sent no `.edited`.
- `O`/`⌥O`/`⇧O` mid-drag (⌥-scroll, then O inside the 0.5 s window) cleared the suppression and showed the pin over the pixels being judged.
- A selection edit after an adjustment in the same gesture did the same.

Also, a photo switch mid-drag dropped `inGesture`. All five are fixed, and the two machine
defects have regression tests.

Round 2: **PASS**. 31/31 tests. Every round-1 defect was traced as fixed, no macOS compile
errors were found by reading, and no path was found that leaves the overlay up during or
after an adjustment drag. Its one in-lane nit is fixed: the row menu's Rename now selects
through `selectMask`. Known and accepted: `O` pressed mid-drag on a pinned overlay keeps the
pin, so the overlay returns on release rather than turning off.

## Not fixed here

- Tapping a **component** row of an unselected mask (`MP.maskDetail`, owned by WS-43) selects
  it without `selectMask`, so on that one path the overlay does not show and a pin stays
  on the old mask. One-line ask in `NEEDS.md`.
- If a row disappears under a stationary pointer, SwiftUI never sends `onHover(false)`, so a
  hover preview can outlive its row until the next click, slider, O or photo change. This
  predates the lane.
- `MaskPanel.adjustSections`'s doc comment (WS-53) still describes the old dead function.

## Human judgement needed

- `O` flips what is on screen. With a just-made mask showing, the first `O` hides it and the
  second pins it. Lightroom's checkbox would pin on the first press, with no visible change.
  I chose "the key always changes what you see", because a key that seems to do nothing
  reads as broken.
- A row click re-shows the overlay until the next adjustment. If that feels noisy, the
  alternative is hover-only after the first adjustment.

## Evidence

- `evidence/01-create-then-exposure-drag-before-after.png`: same scene, left just created (red), right after an Exposure drag (no red).
- `evidence/02-mask-list-rows-before-after.png`: floating list, base vs lane.
- `evidence/03-editing-header-before-after.png`: "2 masks" vs the mask's stack.
