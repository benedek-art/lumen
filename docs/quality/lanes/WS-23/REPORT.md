# WS-23 + WS-24 (lane C1): crop framing and straighten, report

Branch `quality/c1-crop` from `claude/inspiring-dirac-ulgpch` (9068ded). Spec:
`SPEC.md`. Cross-lane asks: `NEEDS.md`.

## For the owner

1. Press R, drag inside the box: the photo should slide under a fixed box and stop at the edge. Then double-click or press Return (done) and Esc on a second try (puts it back).
2. Drag outside the box to tilt it, then press Auto on a building or horizon shot (a foliage shot should say it found nothing). Hold ⌘ and drag along a horizon.
3. Press O several times, then ⇧O on Golden Triangle and Golden Spiral.
4. Press X on a landscape crop, then use the arrow keys and ⇧-arrows to nudge.
5. Drag a corner with ⇧ held (ratio holds) and with ⌥ held (grows from the centre). Watch the pixel-size chip.

## Verdict per spec line

| # | Line | Verdict | Evidence |
|---|---|---|---|
| 1 | Handles; ⇧ holds ratio; ⌥ about centre | PASS (maths), owner to feel | M1, `CropInteractionTests` |
| 2 | Presets + Letter, A-series | PASS | `panel-crop-frame` |
| 3 | Aspect lock | PASS (unchanged) | existing tests |
| 4 | X swaps orientation in the crop tool | PASS (code + maths), owner to try | `testSwapIsAnInvolutionInPixels`, `CropKeys` |
| 5 | Drag inside moves the picture | PASS (maths + code), owner to feel | M2 |
| 6 | Drag outside rotates | PASS (unchanged) | |
| 7 | Constrain to Image while rotating | PASS: no corner ever leaves the picture | M4: 85,260 verifier checks |
| 8 | Largest rect at a locked ratio | PASS within the usable-frame model; **gap to Lightroom recorded** (see below) | M5 |
| 9 | Straighten line, also ⌘-drag | PASS (code), owner to try | |
| 10 | Auto straighten | PASS (verifier round 1 FAIL on three bugs, all fixed; round 2 PASS) | M6, corpus numbers, `evidence/auto-straighten-corpus.png` |
| 11 | O cycles 6 guides + None, ⇧O turns | PASS | M7, `overlay-crop-triangle`, `overlay-crop-spiral` |
| 12 | Fine grid whenever the angle moves | PASS | `overlay-crop-rotating` |
| 13 | Dimmed outside | PASS (unchanged) | snapshots |
| 14 | Reset | PASS (unchanged) | |
| 15 | Flip | H kept; V needs a recipe field → NEEDS.md | |
| 16 | Arrow nudge, ⇧ ×10 | PASS | M3 |
| 17 | Pixel-size readout | PASS (panel row + on-photo chip while dragging) | owner to see |
| 18 | Return / double-click commit, Esc cancel | PASS (code), owner to try | |

## Numbers

- M1 ⌥-resize: centre drift ≤ 1.1e-16, locked ratio error ≤ 4e-16 over 20k random cases (verifier).
- M2 pan: returned delta equals negated displacement exactly; clamps at the edge.
- M3 nudge: width and height never change.
- M4: every corner inside the turned picture for θ ∈ ±45° step 0.5°, 4 frame shapes × 10 crops (test) and 85,260 cases (verifier).
- M5: `largestRect` ≥ 99.5 % of brute force (verifier's 2-D grid: 1.0000).
- M6 Auto, synthetic: horizons −12°…+12° and building verticals −8°…+7° within 0.25°; noise, flat frames and diagonals steeper than 20° return nil.
- M6 Auto, corpus (25 RAW frames, each also turned +1°, −2°, +3°, −5°): fires on 8 of 25 as-shot frames, declines on the rest (foliage, a leaf, a cake on a curved plate). Where it fires, the turned copies move the answer by the turn: error median 0.06°, p90 0.26°, max 0.69° (32 pairs). Timing 61–107 ms per 800 px frame. A weaker tier for small corrections was tried and dropped: median error 0.43°, max 4.1°.
- Constrain-to-image gap (Lightroom bound vs this model, 3:2 frame): 3:2 at 10° gets 92.1 % of Lightroom's area, 1:1 at 10° gets 79.7 %, 4:5 at 10° gets 75.0 %. Fix needs the renderer (NEEDS.md §1).

## What changed and why

- LumenCore (tested on Linux): `CropInteraction.swift` (⌥-resize, picture pan, nudge, largest rect, Lightroom bound, corner-in-picture test), `CropGuides.swift` (styles, O order, ⇧O orientations, segment geometry incl. golden triangle and spiral), `AutoStraighten.swift` (projection-profile energy over horizontal and vertical edge families, one confidence bar, rim guard).
- App: `CropOverlayView` draws guides from `CropGuides`, swaps in an 8×8 grid whenever the angle changes (any hand), moves the picture on inside drags, reads ⇧/⌥/⌘ on drags, shows a pixel chip, double-click commits. `CropKeys.swift` holds X / O / ⇧O / arrows / Return while the tool is up. `CropPanel`: Auto button, Letter and A-series ratios, `CropTool` session state (guide orientation, picture pan, plate per photo).
- Shared files touched with one hook each are listed in NEEDS.md §3.

## Not fixed

- Constrain to Image against the turned picture rather than its centred inscribed rectangle (NEEDS.md §1). Off-ratio crops on straightened photos are up to 25 % smaller in area than Lightroom allows at 10°.
- Flip vertical (NEEDS.md §2).
- Auto declines on 17 of 25 corpus frames. That is deliberate: every looser threshold tried gave wrong answers of several degrees.
- `8559` (bench, watering cans) gets +4.65°: Auto levels the bench and boxes, which a human may judge as perspective. Worth a look.

## Verification

Independent verifier, two rounds. Round 1: FAIL on Auto straighten only:
- B1: a diagonal steeper than the search was "levelled" to 20.3°.
- B2: Auto could measure a stale plate from another photograph.
- B3: Auto wrote the primary's angle onto every selected photo.

All three are fixed in 9b1ccad: a rim guard plus a test for the diagonal, a plate
tagged per photo and deferred until it lands, and a primary-only write with its own
undo key. Round 2: PASS, with corpus answers byte-identical. Its one low note (a queued
Auto press never cancelled) is fixed in 5160c5a.

## CI

- Linux: the full `LumenCoreTests` suite (3,067 tests, `--parallel`, ControlProofTests
  skipped as CI does) passes locally on Swift 6.1.2. On CI, `engine-linux` caught a
  slider-evidence registry miss for the new `geometry.angle.auto` key. That is fixed in
  b0f7a37, with one row on the not-a-slider list.
- `fixtures-linux` (Swift surface) is red on the base branch too, on `CommandLine` and
  LumenRender inits, so it was pre-existing. This lane's two findings on it (a local
  `Point` struct and `UnicodeScalar`) are gone.
- macOS: `UI snapshots` passed on b0f7a37, so the whole app including this lane's SwiftUI
  compiles, and the three new overlay states render. `build-macos`, `test-fast` and GPU
  parity were still queued behind the shared macOS queue at the time of writing. See the
  final push's runs.

## Evidence

The three best:
1. `evidence/overlay-crop-rotating.png`: the picture turned 6° under the frame, tilted
   corners dimmed, and the fine grid shown while the angle moves.
2. `evidence/auto-straighten-corpus.png`: three corpus frames before and after Auto,
   with level lines.
3. `evidence/overlay-crop-spiral.png`: the golden spiral turned once with ⇧O. The
   triangle is in `overlay-crop-triangle.png`.

Panel before and after: `panel-crop-frame-before.png` and `panel-crop-frame.png` (Auto
beside the ruler). Spiral chords were raised after this snapshot (outer arc was
faceted); the final push's snapshot shows the smoother curve.
