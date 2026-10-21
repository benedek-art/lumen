# WS-42 / lane M1: mask list and overlay, acceptance spec

## Audit finding that drives this spec

`AppState.setMaskOverlaySuppressed` (the "hide the overlay while an adjustment is dragged"
rule) had **zero call sites** on the base commit `9068ded`
(`grep -rn "setMaskOverlaySuppressed(" Sources` returns only its definition). Its only
caller had been removed from `MaskPanel.adjustSections`, whose comment still describes it.
Meanwhile `addMask` calls `beginPersistentMaskOverlay`, which keeps the overlay up "until
the first Effect press", and the only thing that ends that phase is the dead function. So
on the base commit: create a mask, the red goes up, drag Exposure, the red stays, forever,
until `O` is pressed twice or the photo changes. That is the owner's report, exactly.

Secondary findings: nine writers of `soloMaskOverlay` with precedence expressed by call
order; a 1400 ms flash timer that races the hover timer; overlay opacity hard-coded at 45 %
(`LoupeViewport.maskOverlayOpacity`); overlay mode/colour not remembered across launches;
every row draws an empty "◯ Invert" chip that reads as a radio button; the editing header
says "Sun · 2 masks", which reads as "Sun contains two masks".

## Target behaviour (Lightroom Classic masking rule, made explicit)

The overlay is a pure function of six inputs held in `MaskOverlayMachine`
(`Sources/LumenCore/Interaction/MaskOverlayRule.swift`):

| input | set by | cleared by |
|---|---|---|
| `pinned` + `pinnedID` (Show Overlay / `O`) | `O` or the Overlay button while nothing shows; selecting another mask moves `pinnedID` | `O` / button while something shows, mask deleted, photo change |
| `litID` (just created / selected / selection being edited) | create, select (row, rail, on-image pin), duplicate, any edit to that mask's components, invert or edge, Edge-row press | the first **adjustment** edit, `O` off, delete, photo change |
| `hoverID` | pointer dwells 120 ms on a row or rail thumbnail | pointer leaves, adjustment edit |
| `inGesture` | first movement of any slider/wheel gesture (`sliderGestureSink`, `sliderWheelSink`) | release, 8 s watchdog, photo switch |
| `suppressed` | an **adjustment** edit while `inGesture` | gesture end |

An **adjustment** edit is any recipe change outside the masks' selection: develop/look
fields, mask groups, or a mask's `adjust`, `amount` or `blend`. A **selection** edit
changes a mask's `components`, `invert` or `refine`. Renames, reorders, enable/disable
are neither. Classification is `MaskOverlayEdit.classify(old:new:)`, pure, in LumenCore.

Visible mask = `suppressed ? nil : (hoverID ?? (pinned ? pinnedID : litID))`.

### State table (owner's scenarios; each row is a unit test in `MaskOverlayMachineTests`)

| # | from | event | to (visible) | Lightroom |
|---|---|---|---|---|
| T1 | nothing | create m1 | m1 | new mask shows overlay |
| T2 | lit m1 | gesture begins + Exposure edit | **nil** | overlay hides on slider drag |
| T3 | after T2 | gesture ends | **nil** (stays hidden) | comes back only by O / Show Overlay / hover |
| T4 | after T3 | hover m1 row | m1; hover exit → nil | hover shows |
| T5 | after T3 | select m1 (click row) | m1 | selecting shows |
| T6 | pinned m1 | gesture + Exposure edit | nil | hides during drag even when pinned |
| T7 | after T6 | gesture ends | m1 | Show Overlay brings it back on release |
| T8 | lit m1 | `O` | nil, and stays nil after hover-exit | O off means off |
| T9 | nothing, m1 selected | `O` | m1 pinned; `O` again → nil | O toggles |
| T10 | lit m1 | brush stroke / radial feather drag on m1 (selection edit, even inside a gesture) | m1 | overlay is the only view of a selection |
| T11 | lit m1 | gesture + Edge (Refine) edit | m1 | edge work keeps overlay |
| T12 | pinned m1 | select m2 | m2 | overlay follows selected mask |
| T13 | pinned m1 | delete m1 | nil, pin off, later hover works | never stuck |
| T14 | any | photo change | nil, everything cleared | per-photo ids |
| T15 | suppressed | hover m2 | nil (ignored) | no red over pixels being judged |
| T16 | lit m1 | typed value / reset in Exposure field (adjustment, no gesture) | nil | "doing whatever" |
| T17 | lit m1 | global Basic-panel Exposure drag | nil | ANY adjustment slider |
| T18 | lit m1 | rename / reorder / enable toggle | m1 | cosmetic edits don't hide |

## Measurable lines

| id | claim | threshold | measured by |
|---|---|---|---|
| S1 | T1-T18 hold | 18/18 | `swift test --filter MaskOverlayMachineTests` |
| S2 | edit classification is right for every recipe field family | 8 cases | `swift test --filter MaskOverlayEditTests` |
| S3 | the hide-on-drag rule has a live call path from the slider latch | `openSliderGesture`/`closeSliderGesture` and `updateRecipe` call the machine | `grep -n "maskOverlay.send\|overlayEvent(" Sources/LumenApp/AppState.swift` |
| S4 | exactly one writer of `soloMaskOverlay` outside snapshot tests | 1 assignment site in Sources | `grep -rn "soloMaskOverlay = " Sources` |
| S5 | no overlay timer other than hover intent | 0 `maskOverlayHideTask`/flash timers | `grep -n "maskOverlayHideTask\|maskOverlayFlashMS" Sources` |
| S6 | overlay colour (4), mode (6) and opacity (4 steps, 25-85 %) are selectable in the panel and remembered across launches | menu sections present; UserDefaults keys `lumen.maskOverlay.*` | code read + snapshot |
| S7 | existing LumenCore tests unaffected | same pass/fail set as base | `swift test --filter LumenCoreTests` |
| S8 | `ui-layout.yml` and `ui-snapshots.yml` green on the lane branch | green | GitHub Actions |

## Visual claims (judge from the lane's ui-snapshots set)

- V1 `panel-masks-two.png` / `window-1512x982-masking-overlay.png`: unselected rows carry no
  empty Invert chip; the second line is the stack in words; nothing reads as a radio button.
- V2 the editing header under the mask name says what the mask is (its stack), not a count.
- V3 new snapshot `window-1512x982-masking-after-exposure-drag.png`: same scene as the
  overlay shot after an Exposure drag; the red is gone.
