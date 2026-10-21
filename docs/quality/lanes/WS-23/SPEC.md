# WS-23 + WS-24 (lane C1): crop framing and straighten, acceptance spec

Owner: "The cropping isn't working really well. I mean, it's working okay, but it's not
really top to bottom." Target: Lightroom Classic's Crop tool (R) as the floor.

Audit baseline: `ui-snapshots/claude-inspiring-dirac-ulgpch/a93efb2/` (`overlay-crop.png`,
`panel-crop-frame.png`, `window-1512x982-crop.png`) plus a read of `CropOverlayView`,
`CropPanel`, `KeyDispatcher` and `CropGeometry`.

How each line is verified: **U** = unit test on Linux (`swift test --filter <name>`),
**S** = a named UI snapshot from `ui-snapshots.yml`, **H** = the owner by hand (listed in
REPORT.md), **C** = code read by the verifier.

## The interaction table

| # | Gesture / key | Lightroom Classic | Lumen at a93efb2 | Target | Verify |
|---|---|---|---|---|---|
| 1 | Corner and edge handles | 8 handles | 8 handles, brackets + bars | keep; ⇧-drag holds the current ratio while unlocked; ⌥-drag resizes about the centre | U `CropInteractionTests.testAltResizeIsAboutTheCentre`, `testAltResizeLockedKeepsRatio`; H |
| 2 | Aspect presets | Original, 1×1, 4×5, 8.5×11, 5×7, 2×3, 4×3, 16×9, 16×10, Custom | Original, 1:1, 5:4, 4:3, 3:2, 7:5, 16:9, 16:10, Custom | add 11:8.5 (Letter) and √2:1 (A-series) | C, S `panel-crop-frame` |
| 3 | Aspect lock | padlock | padlock | keep | existing `CropAspectConstraintsTests` |
| 4 | X swaps orientation | X | ⇅ button only; X rejects the photo even inside the crop tool | X (crop tool armed) swaps; the reject flag is not touched | U swap maths (`testSwapIsAnInvolutionInPixels`); C hook; H |
| 5 | Drag inside | the PICTURE moves under a fixed frame | the frame moves over a fixed picture | picture follows the pointer, frame holds still on screen, release re-fits | U `testPanImageMovesCropOppositeAndClampsAtTheEdge`; H |
| 6 | Drag outside rotates | yes | yes | keep | existing; H |
| 7 | Constrain to Image while rotating | crop shrinks to stay inside the rotated picture | crop shrinks to the largest CENTRED inscribed rectangle | every corner of the crop stays inside the rotated source at every angle in ±45° (step 0.5°), for 40 random crops; no transparent corner ever | U `testReangledCropNeverLeavesTheRotatedPicture` |
| 8 | Largest inscribed rect at a locked aspect | yes | `centred(aspect:)` within the centred inscribed frame | U checks area against a brute-force search: within 0.5 % of the best rectangle at that aspect inside the usable frame; reports the gap to the true Lightroom optimum | U `testLargestRectAtAspect*` |
| 9 | Straighten tool (draw a line) | yes, also ⌘-drag inside the crop | ruler button | keep the button; ⌘-drag anywhere on the photo draws the line too | U existing `Straighten` sign tests; H |
| 10 | Auto straighten | Auto button | none | Auto button; synthetic horizons and verticals at known tilts within ±0.25°; returns nil (changes nothing) on a frame with no dominant line | U `AutoStraightenTests` |
| 11 | Guides cycle with O | Thirds, Grid, Diagonal, Triangle, Golden Ratio, Golden Spiral, Aspect Ratios; ⇧O rotates triangle/spiral | menu only, 4 styles, no triangle/spiral; O is the mask overlay key everywhere | O cycles Thirds → Golden Ratio → Grid → Diagonals → Triangle → Golden Spiral → None; ⇧O turns the triangle/spiral through its 4 orientations | U `CropGuidesTests` (every segment inside the rect; triangle perpendicular property; spiral ends in the right corner per orientation); S `overlay-crop-triangle`, `overlay-crop-spiral` |
| 12 | Live grid while rotating | fine grid while the angle moves | grid only if guides are off, only during the on-image drag | a fine 8×8 grid whenever the angle is changing, from any hand (drag, ruler, slider, Auto), fading 0.6 s after the last change | S `overlay-crop-rotating`; C |
| 13 | Dimmed outside | yes | 50 % black, reaches the tilted corners | keep | S `overlay-crop`, `overlay-crop-rotating` |
| 14 | Reset | ⌥⌘R / panel Reset | section header Reset, R R | keep | existing |
| 15 | Flip | Photo menu, H and V | Flip horizontal toggle | keep H; V needs a recipe field and renderer stage → NEEDS.md | — |
| 16 | Keyboard nudging | — (Photoshop: arrows) | arrows page photos even in the crop tool | ← → ↑ ↓ move the crop 0.2 % of the frame, ⇧ ×10; clamped to the frame | U `testNudgeClampsAndKeepsSize`; H |
| 17 | Numeric size | info overlay | panel Size row | panel row kept; W × H px chip on the photo while resizing or moving | S (chip is drag-only; H) |
| 18 | Enter / Esc | Enter commits, Esc cancels | Esc reverts; Enter does nothing | Enter (and double-click inside the crop) closes the tool keeping the crop; Esc reverts to the session's opening framing | C hook; H |

## Measurable claims for the maths

- M1. `CropGeometry.resize(..., fromCentre: true)` keeps the rectangle's centre within
  1e-9 for every handle, locked and unlocked, until a frame edge stops it; locked, the
  pixel ratio holds within 1e-9.
- M2. `CropGeometry.panImage(crop, dx, dy)` moves the crop by (−dx, −dy), clamped so
  the crop stays in [0,1]²; the returned applied delta equals the crop's actual
  displacement, negated.
- M3. `CropGeometry.nudge(crop, dx, dy)` never changes w or h.
- M4. For θ ∈ [−45°, 45°] step 0.5° and 40 seeded crops, `reangled` keeps all four
  corners inside the rotated source (`containsInSource`, tolerance 1e-6 px).
- M5. `largestRect(aspect:)` is ≥ 99.5 % of the area of a 200×200 brute-force search
  over centred-and-offset rectangles at that aspect inside the usable frame.
- M6. `AutoStraighten.estimate` on synthetic 512×340 frames with a horizon (and,
  separately, building verticals) drawn at tilts −12° … +12° plus noise returns the
  levelling angle within 0.25°; on pure noise and on a flat frame it returns nil.
- M7. `CropGuides.segments` returns segments with both endpoints inside the rect (1e-9)
  for every style × orientation × aspect in {0.5, 1, 1.5, 3}; the triangle's two
  perpendiculars meet the diagonal at a right angle (|dot| < 1e-9).

## Visual claims (named snapshots)

- V1. `overlay-crop-triangle` and `overlay-crop-spiral`: the guide reads as the
  Lightroom shape, stays inside the rectangle, and is as quiet as the thirds lines.
- V2. `overlay-crop-rotating`: the picture visibly turned, the tilted corners dimmed,
  a fine grid inside the crop.
- V3. `panel-crop-frame`: the Ruler row carries Straighten by line and Auto, nothing
  clipped at the 380 pt column.
