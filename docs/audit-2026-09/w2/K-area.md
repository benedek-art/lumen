# W2 — K · Crop, lens & geometry

**Question owned:** the crop tool's grammar against Lightroom's (overlay cycling, aspect
lock under an angle, the straighten ruler, R R reset), ⌘K arming the rectangle with no
panel, Upright / removeCA / Defringe existing in the model with no UI, and Heal with no
stage.

**Files read every line:** `Sources/LumenCore/Model/CropGeometry.swift` (581),
`Sources/LumenCore/Model/Straighten.swift` (95),
`Sources/LumenApp/CropPanel.swift` (783),
`Sources/LumenApp/ViewerOverlays.swift` §`CropOverlayView` (880–1658) and
§`StraightenOverlayView` (1676–1760),
`Sources/LumenCore/Interaction/FrameOrientation.swift` (89),
`Sources/LumenCore/Recipe/Recipe.swift` §`Geometry`/`Crop`/`Upright`/`LensCorrections`/
`Defringe`/`Heal` (1225–1419) and §`renderIdentity` (116–192),
`Sources/LumenApp/EffectsPanel.swift` §Lens Corrections (1–110, 418–474).

**Read to prove presence/absence:** `PipelineRenderer.swift` (`geometryRects` 1462–1484,
`sourceNormalized`/`displayedNormalized` 1696–1732, `applyGeometry` 1762–1825),
`LoupeView.swift` (1013–1065, 1215–1240, 1411–1420, 1495–1540, 1596–1695, 2026–2040,
2300–2328), `WorkspaceEntry.swift` (all), `PanelLayout.swift` (72–160),
`Keymap.swift` (200–320, 540–590), `AppState.swift` (540–626, 3158–3220, 2373–2377),
`WorkspaceModification.swift` (78–100, 225–265), `Workspace.swift` (115–225),
`ControlIndex.swift:110–116`, `CanonicalJSON.swift:212–243`,
`Tests/LumenCoreTests/CropGeometryTests.swift`, `GeometryAndOutputTests.swift:410–490`.

**Spec/prior:** `docs/09-spec-geometry.md`, `docs/audit-2026-09/w1/gap-table.md §K`.

---

## 0. The coordinate bridge, checked rather than assumed

The brief asks whether `sourceNormalized` and `displayedNormalized` are actual inverses.
**They are, exactly**, and I could not break them.

`geometryRects` (`PipelineRenderer.swift:1462–1484`) builds one transform,
`orientation = flip ∘ rotate` — `CGAffineTransformRotate(t, θ)` pre-concatenates, so
`identity.scaledBy(x: -1).rotated(by: -a)` rotates first and mirrors second, which is what
`Straighten`'s derivation (`Straighten.swift:14–28`) assumes. Both functions take
`(orientation, target)` from that same call and compose

```
source→displayed :  p ↦ ((O·s).x − t.minX)/t.w ,  (t.maxY − (O·s).y)/t.h
displayed→source :  u ↦ O⁻¹·(t.minX + u·t.w , t.maxY − v·t.h)
```

which is algebraically one map and its inverse; there is no second copy of the arithmetic
to drift. Four consequences I checked and found **correct**, so they are recorded here and
not reported as findings:

- **The mirror composes with the crop correctly.** `geometryRects` measures the crop from
  the left edge of the *already mirrored* frame, and `CropPanel.swift:381–390` compensates
  by writing `crop.x = 1 − x − w` whenever the toggle moves. Working in centred
  coordinates: mirroring the crop box in the usable frame is `M(box')= box`, so the source
  region selected is `R⁻¹(box)` with or without the flip — identical, **at every angle**,
  and the mirror is an involution so toggling back restores. The one-line fix is right.
- **The view-layer tilt matches the renderer's.** `cropCanvas` draws the flip-only plate
  and turns it by `tilt = flipH ? −angle : angle` (`LoupeView.swift:1626–1630`). A y-up
  rotation by −a appears y-down as +a clockwise; a following x-mirror turns it into −a.
  Correct in both branches.
- **`usableSize`'s two branches join.** The degenerate branch (`CropGeometry.swift:76–81`)
  and the general one agree at 45° on a square, and `usableSize(3000,2000,5°)` =
  (2857.7, 1757.6), which `containsInSource` confirms is inside the picture.
- **A crop survives the sidecar byte-for-byte.** `CanonicalJSON.canonicalNumber`
  (`CanonicalJSON.swift:233–243`) emits the shortest decimal that re-parses to the same
  `Double`, falling back to `%.17g` — so `x/y/w/h` round-trip exactly. (`%.6g`, which
  would not have, is recorded at `:218` as already fixed.)

---

## 1. Known-open dispositions

- **K-023** (ratio lock broken by a change of angle) — **FIXED-SINCE for a single
  photograph.** `CropGeometry.reangled` (`CropGeometry.swift:454–484`) states the
  rectangle in pixels, scales **both axes by one factor** (`:475–477`) and restates it
  against the new usable frame, so `w2/h2 == w/h` by construction; the ratio menu reads
  back through `displayedAspect` against the same usable frame
  (`CropGeometry.swift:286–293`, `CropPanel.swift:637–643`) and the drag's `frameAspect`
  is recomputed per angle (`LoupeView.swift:2303–2312`). All three angle writers call it —
  the slider (`CropPanel.swift:764–779`), the rotate drag and the ruler (both
  `LoupeView.applyRotation:1681–1695`). `CropGeometryTests
  .testThePixelAspectSurvivesEveryAngleChange:646` sweeps 3 crops × 2 frames × 3 start
  angles × 17 end angles to 1e-6. **Two residual holes, filed below: KG-01** (the fix is
  bypassed for every non-primary photograph in a multi-selection) and **KG-04** (the
  floor in `normalized` still breaks a lock at the extremes).

- **K-029** (⌘K → "Lens Corrections" arms the crop rectangle with no crop panel; Escape
  can't revert) — **STILL-OPEN. The mechanism has changed and is now structural.**
  `ControlIndex.swift:115` files "Lens Corrections" (aliases "distortion", "chromatic
  aberration", "ca") under `.optics`; `Workspace.swift:196` puts `.optics` in the `.crop`
  workspace; the palette calls `AppState.jump(to:)` (`WorkspaceEntry.swift:93–96`), which
  is `PanelLayout.reveal` — `next.click(section, keepingOthersOpen: false)`,
  `PanelLayout.swift:121–126`, i.e. it **solos Lens and closes Crop** — followed by
  `settle(in: .crop)`, which sets `viewport.showCrop = true`
  (`WorkspaceEntry.swift:140–141`). So the rectangle is armed, the crop and the straighten
  are stripped from the render (`LoupeView.renderRecipe:1059–1065`), and the column shows
  one toggle that is not CA. The Escape half is worse than the row states: `CropTool
  .beginSession` has exactly two callers, both inside `CropSection`
  (`CropPanel.swift:414, 433`), and `CropSection` is not mounted on this route — so
  `baselineGeometry(for:)` returns nil, `CropTool.revert` (`CropPanel.swift:173–179`)
  falls into its `endSession()` branch, and Escape (`Keymap.swift:575–580`) closes the
  tool while **keeping** whatever the photographer just dragged. Escape means cancel
  everywhere else in this app.

- **K-093** (Heal has no stage; Upright the same) — **STILL-OPEN, all four fields.**
  `grep -rn "upright\|Upright" Sources/ --include=*.swift` outside `Recipe.swift` returns
  one comment (`CropPanel.swift:401`), one unrelated word in `PipelineRenderer.swift:970`,
  and one modified-state read (`WorkspaceModification.swift:90`). `heal` is the same
  shape (`Recipe.swift:230`, `WorkspaceModification.swift:138, 258`, no reader).
  `removeCA` and every `Defringe` field have no reader either — `EffectsPanel.swift:454–471`
  says so and shows one row. `Recipe.renderIdentity` (`:142–192`) strips `look.lut` and
  explains exactly why (`:165–181`) but leaves all four of these in — see **KG-06**.

**Cross-cutting rows.** K-014, K-058, K-073: not touched, no disposition. **K-102**
applies to KG-01, KG-02 and KG-03, whose tests would have to live in `LumenAppTests`
unless the rule is first lifted into LumenCore — which is what each fix below proposes.

**No S1 findings in this area.** Nothing here loses work that cannot be recovered or
delivers a wrong file: every crop write goes through `updateRecipe`, which records an undo
entry (`AppState.swift:3195–3201`) before it persists, and the export path takes the same
`geometryRects` the overlay inverts.

---

## 2. Findings

### KG-01 — With more than one photograph selected, every crop, angle and ratio write is computed from the PRIMARY's frame and stamped on all of them
severity: S2
confidence: measured
class: defect
size: M
evidence: `Sources/LumenApp/LoupeView.swift:1681–1695`
```swift
private func applyRotation(_ angle: Double) {
    let source: CGSize = sourceFrameSize ?? …          // the PRIMARY's frame
    state.updateRecipe(coalescingKey: "straighten") { recipe in
        recipe.develop.geometry.crop = CropGeometry.reangled(
            recipe.develop.geometry.crop,
            sourceWidth: Double(source.width), sourceHeight: Double(source.height), …)
```
`sourceFrameSize` is `state.sourceFrameSize`, which is derived from `primaryFrameSize`
(`AppState.swift:610–614`); the one-argument `updateRecipe` fans out over `editTargets`
(`AppState.swift:3160–3162, 3183`), and `editTargets` is the **whole selection** whenever
`selection.count > 1` (`AppState.swift:2373–2377`). Same shape at
`CropPanel.angleBinding:764–779`, `applyAspect:695–704`, `swapOrientation:729–741` and
`LoupeView.cropBinding:2317–2327`. `CropTool.revert` is the one geometry write that got
this right — it passes `targets: [photo]` and its comment (`CropPanel.swift:180–188`)
argues at length that "framing is a per-photograph gesture: the rectangle is on ONE
picture" — and nothing else in the tool adopted the argument.

Measured, on a selection of one 3000×2000 landscape (primary) and one 2000×3000 portrait,
crop `(0.1, 0.1, 0.8, 0.8)` on both, straightening the primary 0° → 5°:
`reangled` with the primary's frame returns `(0.0801, 0.0448, 0.8398, 0.9103)`. The
portrait's own usable frame at 5° is 1757.6 × 2857.7, so that rectangle is
**1476 × 2601 px = 0.5675:1**, where before the straighten it was 1600 × 2400 =
**0.6667:1**. A **15 % aspect error**, on a photograph the photographer did not touch,
from the one operation K-023 was closed to make safe.

how the owner sees it: he picks three frames from a sequence, nudges the horizon on the
one in the loupe, and the two behind it come back re-cropped — the portrait one at a shape
neither he nor the ratio menu ever asked for. Nothing on screen says the other two moved,
and their padlocks still read locked.

fix: give every geometry write the photo-aware overload it already has. In
`LoupeView.applyRotation` and `CropPanel`'s four writers, take
`state.updateRecipe(coalescingKey:) { photo, recipe in … }` and resolve the frame size
**per target** (`AppState` already caches sizes per URL for the primary; extend
`refreshPrimaryFrameSize`'s task into a `[URL: CGSize]` map, or fall back to
`targets: [primary]` and refuse to batch framing at all, which is Lightroom's behaviour
and what `revert`'s comment argues for). THE TEST: this is currently unreachable from
LumenCore, so lift the decision first — a pure
`CropGeometry.reangled(_:frames:)` taking `[(id, w, h)]`, with a LumenCore test that a
landscape and a portrait frame carried through the same angle change each keep **their
own** pixel aspect to 1e-9. Substituting one shared `sourceWidth/sourceHeight` back makes
the portrait assertion red at 0.5675 vs 0.6667. (K-102: an `AppState`-level test would sit
in `LumenAppTests`, which no CI lane runs.)

### KG-02 — Pressing `O` while framing opens the mask editor without putting the crop tool away: the picture loses its crop AND its straighten, the rectangle is stranded, and no overlay appears
severity: S2
confidence: traced
class: defect
size: S
evidence: `Sources/LumenApp/Keymap.swift:251–263`
```swift
case "o":
    … state.toggleMaskOverlay() …
    PanelLayout.shared.setMasking(true)
    state.showLoupe()
```
It calls `PanelLayout.setMasking` directly instead of `state.toggleMasking()`, whose
entire documented job is the other half of entering masking
(`WorkspaceEntry.swift:108–112`: *"the crop tool goes away … Without this, entering masking
while framing left the rectangle and its handles drawn under `MaskCanvas`: unreachable,
because the canvas takes the drags, and the renderer still showing the UNCROPPED frame
because that is what `showCrop` asks it for."*). `cropArmed` is
`viewport.showCrop && panel.layout.workspace == .crop` (`LoupeView.swift:1043–1045`) and
knows nothing about `isMasking`, so after `O`:
`content` still routes to `cropCanvas` (`LoupeView.swift:1414–1417`); `renderRecipe` still
strips `crop` and `angle` (`:1059–1065`); and **both** `MaskOverlayView` (`:1506`) and
`MaskCanvas` (`:1531`) live inside `canvas`, which is never built — so the overlay the key
was pressed for is not drawn at all. `'` (invert) has the same missing disarm at
`Keymap.swift:264–268` but does not force masking on.

how the owner sees it: mid-crop he presses `O` — which in Lightroom cycles the crop
guides, and which docs/09 also binds to the guides — the develop column turns into the
mask editor, the photograph snaps back to its full uncropped, un-straightened self with
the crop rectangle still sitting on it, and no mask overlay ever appears. Pressing `O`
again changes nothing on screen.

fix: `Keymap.swift` — replace the bare `setMasking(true)` in `case "o"` (and add the same
to `case "'"`) with the entry verb `state.toggleMasking()`-equivalent that clears
`showCrop`/`showStraighten` and calls `CropTool.shared.forgetArming()`; better, add
`AppState.enterMasking()` beside `toggleMasking` in `WorkspaceEntry.swift` so the entry
contract exists in exactly one place, as that file's header demands. Separately, make
`cropArmed` include `&& !panel.layout.isMasking` so no third route can strand it. THE
TEST: the arming contract is a pure rule — put it in LumenCore as
`WorkspaceLayout.cropStaysArmed(enteringMasking:) -> Bool` and assert it is false; the
view-level assertion (`showCrop == false` after `O` from the crop workspace) belongs in
`LumenAppTests`, which needs the K-102 CI filter to count.

### KG-03 — A portrait photograph that already carries a crop never has its orientation reconciled, so every overlay outside the crop tool lays itself out sideways
severity: S2
confidence: traced
class: defect
size: S
evidence: `Sources/LumenApp/LoupeView.swift:1035–1039`
```swift
private var deliveringWholeFrame: Bool {
    if cropArmed { return true }
    let geometry = recipe.develop.geometry
    return geometry.crop == Crop() && geometry.angle == 0
}
```
`learnSourceOrientation` is guarded on it (`:1022–1029`) and is the only caller of
`AppState.noteFrameTransposed`; `primaryFrameTransposed` is reset to `false` on **every**
selection change (`AppState.swift:555`), and `sourceFrameSize` — which the crop overlay,
`MaskCanvas` (`LoupeView.swift:1535`), `MaskOverlayView` (`:1505`) and
`NeutralPickerOverlay` (`:1561`) all place themselves against — is
`FrameOrientation.sourceSize(reported:transposed:)` of that flag
(`AppState.swift:610–614`). So for a portrait exposure whose recipe already has a crop or
an angle, the guard is false for the whole visit and the flag stays at its `false`
default: `FrameOrientation.isTransposed` is never consulted, and the reconciliation
`FrameOrientation.swift:16–33` exists to perform never happens. Entering the crop tool
forces `cropArmed`, learns it, and fixes it — until the next selection change resets it.

how the owner sees it: exactly the report `FrameOrientation.swift:6–8` was written from —
*"it's stretching my entire image out into a horizontal landscape photo, not a vertical
photo like it is"* — still true, but now only on the vertical photographs he has already
cropped. Masks land in the wrong place and the eyedropper samples the wrong pixel on those
frames; opening and closing the crop tool silently repairs it, which makes it look
intermittent.

fix: two changes, both small. (1) Key the answer to the photograph — a
`[URL: Bool]` on `AppState` rather than one `@Published Bool` reset per selection — so a
frame that has ever delivered whole keeps its answer. (2) Learn it from a source that is
always whole: compare `ImageSource.nativePixelSize` with the **decoded** extent inside the
pipeline, before `applyGeometry` runs, and hand that up with the render; a crop cannot
confuse a comparison taken upstream of the crop. THE TEST: `FrameOrientationTests`
already covers the predicate; add a LumenCore test of the new
`FrameOrientationStore.answer(for:reported:delivered:cropped:)` asserting that a cropped
delivery leaves a previously learned answer intact and never sets one — substituting
today's "reset on selection, learn only when uncropped" rule makes it red.

### KG-04 — `CropGeometry.normalized`'s per-axis floor is the one place a locked ratio still breaks, and it is the last line of every writer
severity: S2
confidence: measured
class: defect
size: S
evidence: `Sources/LumenCore/Model/CropGeometry.swift:154–166`
```swift
var w = Num.clamp(finite(crop.w, 1), minimumCropFraction, 1)
var h = Num.clamp(finite(crop.h, 1), minimumCropFraction, 1)
```
Each axis is floored **on its own**, which is the exact mistake `shrinkIntoFrame`'s own
comment forbids twelve lines earlier (`:356–361`: *"Flooring each axis on its own is the
same mistake as clamping each edge on its own"*) and `refit`'s repeats (`:505–507`). And
`normalized` is the **last** call in `resize` (`:268`), `reangled` (`:480`), `refit`
(`:513`) and `swappingOrientation` (`:548`), so it runs after every ratio-preserving floor
those functions apply. Two measured cases, both on a 3000×2000 frame:

- **A typed panorama ratio.** `aspect(fromText:)` deliberately accepts up to 60:1
  (`:556–577`). `centred(aspect: 60, …)` computes `h = frameAspect/aspect = 0.025`, which
  `normalized` floors to 0.05 — delivering **30:1**, not 60:1. Worse, `applyAspect`
  (`CropPanel.swift:695–704`) has meanwhile armed the lock at 60, so every later corner
  drag runs `w = h·40` → `w = 2.0` → clamped to 1 with `h` left at 0.05: **every drag
  re-writes 30:1 under a padlock reading 60:1**. The threshold is
  `pixelAspect > 20 × frameAspect` — 30:1 on a 3:2 body, 26.7:1 on 4:3.
- **A locked crop at the minimum size, carried through an angle.** A 2.13:1 crop at the
  floor at 10° — `(w 0.0593, h 0.05)` of the 2774.4 × 1541.8 usable frame, i.e.
  164.5 × 77.1 px — carried back to 0° by `reangled` gives `w2 = 164.5/3000 = 0.05483`,
  `h2 = 77.1/2000 = 0.03855`; `normalized` floors `h` alone to 0.05, so the pixel
  rectangle becomes 164.5 × 100 = **1.645:1**. A 23 % aspect change from returning the
  angle to zero.

`CropGeometryTests` has a locked-drag case (`:255`), a locked-against-the-edge case
(`:271`) and a full aspect sweep (`:646`), and none of them puts a locked rectangle at the
floor or asks for a ratio above 20× the frame's.

how the owner sees it: he types 60:1 for a panorama strip and gets a 30:1 rectangle with
the padlock still saying 60:1, and every attempt to drag it back re-writes 30:1. On a
tight locked reframe the padlock quietly stops holding at the moment the box gets small.

fix: `CropGeometry.swift` — give `normalized` an optional `preservingRatio: Double?` and
apply the floor to both axes together when it is supplied (`if w < min { w = min; h = w/r }`
then the symmetric branch, as `shrinkIntoFrame:354–361` already does), passing the live
lock from `resize`/`reangled`/`refit`/`swappingOrientation`; and cap
`aspect(fromText:)`'s bounds at what the floor can actually express, or lower
`minimumCropFraction` — 0.05 of a 45 MP frame is 400 px, which is not the constraint the
constant was chosen for. THE TEST: `CropGeometryTests` — assert
`displayedAspect(centred(aspect: 60, 3000, 2000, 0°), …) == 60 ± 1e-6` and sweep
`resize` at the floor for lockedAspect ∈ {16/9, 3, 10, 30, 60}; both are red today
(30 vs 60, and 1.645 vs 2.134 on the reangled case).

### KG-05 — "Original" in the ratio menu reads back as a decimal on any straightened photograph
severity: S3
confidence: measured
class: defect
size: S
evidence: `Sources/LumenApp/CropPanel.swift:715–720` — `restoreOriginal()` writes
`Crop()`, i.e. 100 % of the **usable** frame. `currentRatio` (`:637–643`) measures the
rectangle against that usable frame through `CropGeometry.displayedAspect`, while
`originalRatio` (`:647–650`) is the **source's** aspect, and `currentAspectName`
(`:654–661`) compares them at a 0.005 tolerance. On a 3000×2000 body at 5° the usable
frame is 2857.7 × 1757.6 = **1.6259:1**, against a source ratio of 1.5 — a gap 32×
the tolerance — so `name(forRatio:)` falls through its 1…16 denominator search and prints
**"1.626"**.

how the owner sees it: on a straightened photograph he picks "Original" to get the whole
frame back, the whole frame comes back, and the menu immediately relabels it a custom
ratio he never typed. The Size row beside it reads 2858 × 1758 px, which is the honest
number for the same rectangle — so the panel tells him two different stories about one
crop.

fix: `CropPanel.swift` — make `currentAspectName` recognise the untouched rectangle rather
than its ratio: `if recipe.develop.geometry.crop == Crop() { return "Original" }` ahead of
the ratio comparison; the remaining branches are already correct because `refit` writes
pixel ratios and `displayedAspect` reads them. THE TEST: extend
`CropGeometryTests.testTheMenuReadsBackWhatItWrote:299` with a straightened frame —
`displayedAspect(Crop(), 3000, 2000, degrees: 5)` is 1.6259 and not 1.5, which is the fact
the panel has to stop treating as a ratio; the label rule itself belongs in LumenCore
beside `displayedAspect` so it is testable at all.

### KG-06 — Three dead geometry fields are hashed into `renderIdentity`, and the two Resets both called "Crop" have different scope
severity: S3
confidence: traced
class: defect
size: S
evidence: `Sources/LumenCore/Recipe/Recipe.swift:165–181` strips `look.lut` and states the
rule in full — *"NO STAGE READS IT … a hand-edited sidecar carrying `look.lut` got a
different `recipe_fp`, threw away every cached preview and artifact for that photo,
re-rendered the frame, and produced identical bytes, and the library called it edited"* —
then `:182–191` records `develop.heal` as the deliberate opposite choice and says heal
*"should adopt the tripwire when somebody is next in that code."* `geometry.upright`,
`geometry.lens.removeCA` and `geometry.lens.defringe` are in **neither** list, have no
reader anywhere (§1, K-093), and therefore carry the LUT defect with none of the LUT's
reasoning. (`lens.profile` genuinely reaches `AppleRawSource` and must stay.)

The second half: `WorkspaceModification.swift:89–90` counts `geometry.upright != nil` as
modifying the Crop section and `:231–233` resets it by clearing the whole `Geometry`,
while `CropSection.isGeometryModified` (`CropPanel.swift:743–746`) omits `upright` and
`CropTool.resetGeometry` (`:215–224`) leaves it behind. Two Resets under one heading, with
different scope — the defect class `Workspace.swift:123–128` says the `.frame`/`.optics`
split was made to remove.

how the owner sees it: a photograph whose sidecar was written by another tool (or by an
older build) carrying `upright` or `removeCA:false` opens with a modified dot on Crop for
a framing nobody changed, is counted as edited in the library, and has every cached
preview of it discarded and re-rendered to produce identical pixels. Which of the two
Resets clears it depends on whether he is in the Crop workspace or on the Effects tab.

fix: `Recipe.renderIdentity` — add `copy.develop.geometry.upright = nil`,
`copy.develop.geometry.lens.removeCA = LensCorrections().removeCA` and
`copy.develop.geometry.lens.defringe = nil` beside the `look.lut` line, with the same
"delete this in the same commit as the stage" note; and drop `upright` from
`WorkspaceModification.nonDefault`'s `.frame` clause until it renders. THE TEST: the
pattern already exists — copy
`testALookCarryingALUTRendersTheSamePictureAsOneWithout` into
`testARecipeCarryingUprightRendersTheSamePictureAsOneWithout` (and the same for
`removeCA`/`defringe`), which is red today and goes red again the day a stage lands
without the strip being removed.

### KG-07 — docs/09's crop grammar is a keyboard and a set of overlays; Lumen has the mouse half of it
severity: S3
confidence: measured (greps)
class: parity-gap
size: M
evidence: every row below is a grep that returned nothing, or a hard-coded constant.

| docs/09 §Crop / §Straighten | Lumen | evidence |
|---|---|---|
| **O cycles 6 overlays** | **A** — 5 styles, and `O` is the mask overlay | `CropOverlayStyle` has `off/thirds/grid/golden/diagonals` (`CropPanel.swift:41–50`, its own comment concedes the two missing); the only writer of `CropTool.overlay` is the panel's menu (`CropPanel.swift:612`); `case "o"` is `toggleMaskOverlay` + `setMasking(true)` (`Keymap.swift:251–263`) — see **KG-02** |
| **⇧O cycles the 8 orientations of Spiral/Triangle** | **A** | neither style exists |
| Overlay visibility Auto/Always/Never | **∂** | the guide is always drawn; the only auto behaviour is the grid standing in during a rotation (`ViewerOverlays.swift:1230–1233`) |
| **Shield opacity 0–100 %, default 80 %, remembered globally** | **A** — hard-coded 0.5 | `ViewerOverlays.swift:1039` `.fill(Color.black.opacity(0.5), …)`; `CropPanel.swift:23–26` cites the same docs/09 line for guides and never adds the control |
| **Auto straighten button** (Vision horizon + gradient histogram, declines below confidence) | **A** | `grep -rn "autoStraighten\|VNDetectHorizon\|horizonDetect" Sources/` → 0 hits |
| **⌘-drag ruler anywhere in crop mode, no tool switch** | **A** — a panel button arms it | `StraightenOverlayView` is built only under `viewport.showStraighten` (`LoupeView.swift:1661`), whose only setter is the "Straighten by line" button (`CropPanel.swift:590–594`) |
| **Scroll to scale the crop** | **A** — scroll is refused | `LoupeView.applyScroll:2032–2034` `guard !cropArmed else { return }` |
| X = flip orientation | **deliberately ⇅ instead** | `CropPanel.swift:511–514` argues X is the reject flag with no crop-mode branch; **not reported** — the substitution is the safer choice and the button is there |
| Return commits / Esc reverts / R R resets | **P** (Return retired on purpose) | `WorkspaceEntry.toggleCropTool:177–194`, `Keymap.swift:575–580` |

how the owner sees it: framing works entirely with the mouse and the panel. The two
guides he would actually use to place a subject — the golden spiral and the triangle — are
not there, `O` does something violent instead of cycling them, there is no way to lighten
or darken the shield over the discarded part of the frame, and levelling a horizon means
finding a button in the column rather than ⌘-dragging on the picture the way he has for
fifteen years.

fix: three separable pieces, in increasing size. (S) Bind the guide cycle: move the `O`
family behind a `PanelLayout.shared.layout.workspace == .crop` branch that cycles
`CropTool.overlay` and add `H` to hide it, and add a shield-opacity row to `CropPanel`
reading a `@AppStorage` global as docs/09 specifies. (M) `CropOverlayStyle.goldenSpiral`
and `.triangle` with an orientation index, drawn from a pure path builder in LumenCore —
the orientation cycle is what makes them worth having, and is what
`CropPanel.swift:38–40` correctly says they need. (M) Arm the ruler on a ⌘-drag inside
`CropOverlayView.rotateGesture` rather than through `showStraighten`, since the sign
arithmetic (`Straighten.angle`) is already shared. Auto-straighten is (L) and belongs with
the Vision work, not here. THE TEST: the cycle order, the spiral's eight orientations and
the shield default are all pure values — put them in LumenCore next to `CropOverlayStyle`
and assert `allCases.count == 6` plus an orientation round trip; `KeyGrammarTests` already
has the shape for asserting a key reaches a verb.

---

## 3. One-line verdict for the owner

The **arithmetic** is in good shape: the crop, the straighten, the flip and the output
scale really do compose into one transform, the overlay's inverse of it is exact rather
than a second implementation, a locked ratio now survives an angle change on a single
photograph, and a crop round-trips through the sidecar byte-for-byte. What is left are
four seams where the tool meets the rest of the application — a batch selection
(**KG-01**), the mask editor (**KG-02**), the orientation reconciliation (**KG-03**) and
the minimum-crop floor (**KG-04**) — plus the whole keyboard half of Lightroom's crop
grammar (**KG-07**), which is where "the crop tool is kind of broken in a sense" will keep
coming from.
