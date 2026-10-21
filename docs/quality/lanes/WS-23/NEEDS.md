# WS-23 / WS-24 (lane C1): changes needed outside this lane

## 1. Constrain to Image against the turned picture (C2 renderer, WS-58 recipe semantics)

Lumen stores the crop as fractions of the largest CENTRED axis-aligned rectangle inside
the turned picture (`CropGeometry.usableSize`), and `CropGeometry.normalized` clamps it
to [0, 1]². So a crop can never leave that rectangle. Lightroom's Constrain to Image only
requires the crop's four corners to be inside the turned picture, which allows larger
crops whenever the ratio differs from the inscribed rectangle's own.

Measured (`CropInteractionTests.testUsableFrameModelGapIsWhatTheReportSays`, 3:2 frame):

| angle | crop ratio | Lumen area ÷ Lightroom area |
|---|---|---|
| 2° | 3:2 | 99.7 % |
| 5° | 1:1 | 90.6 % |
| 5° | 4:5 | 87.7 % |
| 10° | 3:2 | 92.1 % |
| 10° | 1:1 | 79.7 % |
| 10° | 4:5 | 75.0 % |

The maths for the fix is in LumenCore already and tested:
`CropGeometry.largestInRotatedImage(aspect:width:height:degrees:)` (closed form, checked
against brute force) and `CropGeometry.cropIsInsidePicture(...)` (the corner test).

What C2 / WS-58 would need to do: let `normalized` accept a crop that runs outside
[0, 1]² of the usable frame as long as `cropIsInsidePicture` holds (clamp by sliding /
shrinking against the turned rectangle instead of the unit square), and make
`PR.geometryRects`, the CPU geometry twin, `sourceNormalized` / `displayedNormalized`
and `BatchFraming` honour it. `geometryRects` already computes `target` as
`usable.origin + resolved.x…`, so a negative `x` lands on real pixels of the turned
picture; the risk is every other reader of `normalized`. Existing recipes are unchanged
(they are all inside [0, 1]² today). Once that lands, the overlay's clamps
(`resize`, `move`, `panImage`, `reangled`) should switch to the polygon clamp in this lane.

## 2. Flip vertical (WS-58 recipe field, C2 renderer)

Lightroom has Flip Horizontal and Flip Vertical. The recipe has `flipH` only. A vertical
flip needs a `Geometry.flipV` field (CodingKeys, sidecar), a renderer stage, the
`Straighten` sign derivation extended (a vertical mirror also negates the angle), and
the crop mirrored on y as `CropPanel`'s flip toggle does on x. The UI toggle is a
one-row change in this lane once the field exists.

## 3. Shared files this lane touched, one hook each (integrator, please keep)

- `Sources/LumenApp/Keymap.swift`: one line in `KeyDispatcher.handle`, after the Tab
  chord, offering the key to `CropKeys` (new file, this lane). No switch case changed,
  so `KeyGrammar.dispatchedKeys` and its parity test are untouched.
- `Sources/LumenCore/Interaction/KeyGrammar.swift`: six rows under Develop documenting
  the crop tool's keys, and one comment corrected (Return now commits).
- `Sources/LumenApp/LoupeView.swift` `cropCanvas`: the stack is wrapped in
  `CropImagePanOffset` (drag inside moves the picture) and `CropOverlayView` is handed
  the plate (`plate: cg`) for Auto straighten.
- `Tests/LumenAppTests/PanelSnapshotTests.swift`: three snapshots appended
  (`overlay-crop-triangle`, `overlay-crop-spiral`, `overlay-crop-rotating`) and two
  defaulted parameters on `SnapshotCropOverlay`; existing entries unchanged.
