# P3-masks: mask caches, correctness and the September mask-canvas backlog

Stream agent P3-masks. Base: `origin/claude/jolly-sagan-k7ch7z` @ cc4cdd7. Build dir `/tmp/lumen-build-p3`.
Inputs: `verify/V3-masks.md`, `audit-2026-09/w2/F1.md`, `F4.md`, `F5.md`, `audit-2026-09/w3/dispositions.md`.

How it was checked: `swift build --build-tests` is clean, and `check-swift-surface.py` exits 0. These LumenCore suites pass: MaskHandles (36), MaskIdentityRepair (3), MaskDependencyAdversarial (14), MaskDependency (14), GlobalPresenceClampReference (1), LocalStageReferenceContract (3), MaskReferenceIdentity (8), MaskRasterKey (4), Masking (24), MaskBlend (14), PolygonMask (17), MaskGroup (12), MaskChannelAndReference (15), CanonicalJSON (14), RecipeCodecTolerance (7), SidecarAndIngest (24), SidecarReseed (7), BrushSidecar (12), ExportRecipeDecode (5), MaskWhiteBalance (14), VignetteFeather (9), MaskDeadField (3), LuminositySeries (20), SimilarityPoint (12) and CreativeGrain (29).
LumenPipeline and LumenApp tests cannot run on this machine. They are marked "source-verified": I traced each one against the old code by hand. **No CI lane runs LumenAppTests (K-102),** so the four LumenApp tests below are written but not exercised until that lane exists.

## The four named items

| # | Item | Status | Commit | Red/green | Proof records that move |
|---|---|---|---|---|---|
| 1 | `forgetMattes` cleared every photo's brush planes on every source-cache miss (51c1ca1 regression) | FIXED | effbf26 | Pipeline test: traced against the old `clear()`, 2 assertions fail (repaint +1, strokes +6). Coordinator test: with `replaced := true`, the two zero-assertions fail (count reads 3, then 16) and the last one reads 17. Both source-verified. | none |
| 2 | Mask thumbnails stale after a same-path replacement | FIXED | 151d6d5 | `MaskThumbnailKeyTests`: with the old key, 2 failures. Source-verified. | none (panel thumbnails only) |
| 3 | Global Texture/Clarity beyond ±100 clamped on CPU, not GPU | FIXED | d495ff6 | Linux reference test: 4 failures with the clamp removed, 1/1 pass with it restored. macOS GPU test: traced, 4 failures on the old instance method. | none. Only sidecars with values beyond ±100 move, and only on GPU. Proofs render through the unchanged reference. |
| 4 | S-07 duplicate mask ids | FIXED (repair on load) | a767fb9 | 2 failures with the repair substituted out. 3 failures with the ambiguity guard disabled. 3/3 pass restored. | none. No proof record has a duplicate id. A recipe that has one moves on GPU only, towards the reference. |

**1.** There are two changes, and both are needed.
- `BrushPlaneCache.clearPictureDependent()` drops only entries whose `sourceKey != "-"` (the Automask ones). `forgetMattes` now calls it instead of `clear()`.
- `RenderCoordinator.source(for:)` forgets only on a real replacement. It compares the identity it saw last for the URL with the identity on disk now. That last-seen identity is kept in `knownIdentities`, which survives the source LRU. A first open, a `warmDecode` prefetch, or a re-acquisition after the LRU no longer forgets anything. `invalidate(url:)` still forgets unconditionally.

Tests:
- `MaskReferencePipelineTests.testForgettingAnotherSourceKeepsGeometryBrushPlanes` checks that a render resumes the brush plane and repaints nothing. The existing Automask same-URL test stays green.
- `AuditPreviewReliabilityTests.testBrowsingAndPrefetchDoNotForgetRendererStateOnlyAReplacementDoes`.

**2.** `AppState.maskThumbnailKey` is a pure static now. It gains the live `SourceFileIdentity` token and each referenced stroke set's loaded count. Two things now trigger `refreshMaskThumbnails`: the folder (re)load that bumps `sourceRevision`, and stroke blobs arriving. Both cost nothing when the key is unchanged.

**3.** `RenderGraph.applyPresence(_:plan:options:)`, the global S8, resolves texture and clarity through `DetailEngine.scaledPresenceAmount` before calling the static. The static stays unclamped, because the local stage passes it Strength-scaled amounts up to ±200 (M11).
I did not bump `PreviewCache.renderingRevision`. The only recipes affected are hand-edited sidecars with values beyond ±100, and a bump would invalidate every user's preview cache to fix that. It is listed under DECISIONS.

**4.** `MaskIdentityRepair`, run in `Recipe.init(from:)`, keeps both rows and renames each later duplicate to `<id>-2`, `-3`, and so on, skipping ids already taken. The naming is deterministic.
- **No reference is rewritten.** Every resolver already reads a reference first-wins, and the first row keeps its id, so every reference keeps its meaning.
- **Why no references need rewriting.** No reference can unambiguously mean the duplicate, so "rewrite references when unambiguous" has nothing to do.
- **When it declines.** A rename changes exactly one thing: the cycle guard. While a duplicate row is rasterized, its own id is in `resolving`. So if a reference chain from inside that row leads back to the same id, the repair leaves the row alone. The mask panel then shows a one-line notice ("Two masks in this file's settings share one identity, so the panel can only reach the first of them").
- **Effects.** Well-formed recipes are returned untouched. A repaired recipe keeps its `recipe_fp`, because `renderIdentity` already canonicalizes ids to stack positions. The test proves the reference render is bit-identical, and shows that the rename it declined would really have changed the picture.
- **Found while fixing.** The GPU keys mask alphas by id (`RenderGraph.maskImages[mask.id]`), so two rows sharing an id were both composited through the last-baked alpha. The repair fixes that whenever it renames.

`SUPPLEMENTAL-BACKLOG.md` lines 13 and 24 are updated.

## September mask-canvas and panel rows

Each row was re-verified against the code at cc4cdd7 and is listed in severity order (S2 first).

| Row | Status | Commit | Evidence |
|---|---|---|---|
| F1-02 linear cannot rotate without changing feather | FIXED before this stream | — | `MaskHandles.LinearGrab.rotate` exists, and so does `turnedLine` (`MaskGestureTests:94–179`). |
| F1-03 rotate band and grab regions invisible | FIXED before this stream | — | `MaskCanvas.liveLinearGrab` / `liveRadialGrab` run the press hit test on hover. `rotateGlyph` is drawn in the band, and `lumenClickCursor(hoverIsOnANamedHandle)` sets the cursor. |
| F1-04 ⇧ on a resize makes a circle; ⌥ unread | FIXED | 137a20d | `MaskHandles.resizedRadii`: ⇧ keeps the ratio, ⌥ holds the opposite rim (centre shift through `MaskRaster.radialOffset`). ⇧ on create is still a circle. Red: 5 failures. Green: 36/36. The canvas wiring is source-verified. |
| F1-05 brush stroke near a foreign pin discarded, selection jumps | FIXED | 3feb3ad | `MaskHandles.pinYieldsToStroke`: for brush and polygon, a pin press is only a candidate, and once it travels `minimumDrawTravel` it becomes the stroke, seeded at the press point (`strokeSeed`). A click still selects. Red: 2 failures. The canvas wiring is source-verified. |
| F1-06 foreign pins swallow pan and scrub-zoom | FIXED before this stream | — | `MaskCanvas` hit-tests only the pin discs when there is no drawable component of its own (comment at `MaskCanvas:357`; `MaskCanvasHitAreaTests`). |
| F4-03 ⌥-Intersect label stale | FIXED (staleness half; the disagreement half was already closed) | 450c076 | `ModifierKeys`, fed by a `.flagsChanged` monitor in `Keymap.install`, is observed by `MaskPanel` for invalidation. Tests are source-verified (LumenAppTests). |
| F4-04 `maskThumbnail` comment / three sizes | FIXED before this stream | — | All three call sites use `MaskPanel.thumbnailSize`, and the comment names its real callers. |
| F4-05 mask Temp on a linear Kelvin axis | FIXED before this stream | — | `optionalAdjustSlider(… scale: MaskPanel.temperatureScale, trackStops: Lumen.temperatureStops)`, and Tint has `Lumen.tintStops`. |
| F4-06 a disclosed mask is about 22 controls; Edge has no fold | NOT-FIXED: DECISION | — | Edge has `isExpanded: nil`. The owner named "the edge stuff" as part of the chevron's contents, so folding it by default is a UI-direction change. See DECISIONS. |
| F5-02 no test for the Vision matte convention | PARTIAL | 777a2d4 | Half (a) is done: `VisionMattesPlaneTests` covers 8-bit and float buffers, padded rows, top-down order and left-to-right, traced against mirror and stride slips. Half (b), Vision end-to-end on a synthetic image, is not written; spec below. The commit also adds `CVPixelBufferCreateWithBytes` to the surface script's KNOWN list. |
| F5-03 People is one union matte | NOT-FIXED: DECISION | — | This is an additive format field plus UI chips. Switching to the instance request is not bit-identical to `VNGeneratePersonSegmentationRequest`, so every existing People mask would move. Spec below. |
| F5-06 Background with no subject selects nothing | NOT-FIXED: DECISION | — | Still open (`VisionMattes.generate`: nothing is emitted when `foregroundPlane` is nil). The fix makes an existing Background mask on such a photo select the whole frame, which changes the look of existing edits. Spec below. |
| F5-09 Vision on an unreadable original says "Computing" forever | FIXED | e3b1301 | `MattePass.sourceUnavailable` leads to `AppState.unreadableMatteSources` and then `MatteStatus.unavailable`, shown as the ORIGINAL UNREADABLE badge. Test is source-verified (LumenAppTests). |

None of these rows moves a proof record.

## DECISIONS (implemented conservatively; the owner can overrule)

1. **S-07 policy.** On load, later duplicate rows are renamed `<id>-N` (deterministic) wherever that changes no selection. Otherwise the rows are kept as they are and the panel shows a notice. References are never rewritten. The notice wording is mine.
2. **F1-04: ⇧ on a radial resize handle changed meaning** from "snap to circle" to "keep the ellipse's ratio", which is Lightroom's handle modifier. ⇧ on create still makes a circle. ⌥ on a handle now holds the opposite rim.
3. **F1-05.** A press on a foreign pin while a brush or lasso is selected is a click if it does not travel (selects the pin) and a stroke if it does. A single-click brush dab placed exactly on another mask's pin now selects that mask instead of stamping.
4. **F5-09 copy:** the badge "ORIGINAL UNREADABLE" and its one-sentence caption.
5. **No `renderingRevision` bump for the global Texture/Clarity clamp (d495ff6).** Cached GPU previews of a hand-edited ±101..±∞ recipe stay at the old look until re-rendered. Bump it if that matters.

## DECISION NEEDED (not implemented, because every option changes the look of existing edits or the UI direction)

- **F4-06.** Fold Edge behind its own per-mask disclosure, closed by default (same `Set<String>` shape as the F4-01 picker flags). The audit's budget is 22 controls dropping to 15. This contradicts the owner's own list for the chevron, so it is his call.
- **F5-03, per-person People.** Switch `personPlane` to `VNGeneratePersonInstanceMaskRequest` plus `generateScaledMaskForImage(forInstances:)`. Add an additive `instances: [Int]?` on `MaskComponent` (absent means all), and draw chips in `componentParameters(.aiPerson)`. Moves pixels for every existing People mask (different request, different matte), so it needs a renderingRevision bump and the owner's agreement. Test: a LumenCore round-trip of the field, plus a two-disc fixture with `instances: [0]`.
- **F5-06, Background with no subject.** Emit `Plane(fill: 1)` for `.aiBackground` when `foregroundPlane` is nil, and replace the "found no clear subject" text with one saying the whole frame was taken. Background masks on such photos go from selecting nothing to selecting everything. This follows docs/08 §8.3's definition, but it is a visible change to existing edits. Test: inject `foreground: { _ in nil }` into `generate` and assert `range.max == 1`.
- **F5-02 (b), end-to-end orientation test.** Draw a 512×384 CGImage with a dark, high-contrast disc in the top-left quadrant, call `VisionMattes.foregroundPlane`, use `XCTAssertNotNil` (never skip), and assert the matte centroid has `x < w/2` and `y < h/2`. If Vision declines the synthetic disc, the right fix is a small photo fixture. I did not add a test that could go red on CI because of Vision's behaviour, which I cannot check from here.

## FOUND-WHILE-FIXING

- **GPU duplicate-id alpha collision** (see item 4). `maskImages` is keyed by id, so duplicate rows rendered through one alpha on the GPU while the reference rasterized each row separately. Fixed whenever the repair renames. It persists for the ambiguous rows the repair declines, which now get the panel notice.
- **The mask overlay has the same same-path staleness as the thumbnails.** `refreshMaskOverlay` is not re-triggered by a rescan. I left it alone: it is outside the named item and refreshes on the next selection or edit.
- **`BrushPlaneCache` keys are not per-photograph** (`maskID#index`). This is safe because reuse is prefix-checked on the actual strokes. But two photographs sharing a pasted mask id evict each other's entries.
- **This stream's own slip, already repaired.** One intermediate commit added `Sources/LumenApp/ModifierKeys.swift` without the `#if os(macOS)` guard every LumenApp file carries, and that broke the Linux build. I folded the fix into that commit (450c076) and replayed the two commits after it, so every commit on the branch builds.
- **No CI lane runs `LumenAppTests` (K-102).** Four of this stream's tests live there: `MaskThumbnailKeyTests`, `ModifierKeysTests`, and two cases in `AuditPreviewReliabilityTests`.

## Commits (branch `worktree-agent-a473b78f5ae231281`, not pushed)

effbf26, 151d6d5, d495ff6, a767fb9, 3feb3ad, 137a20d, 450c076, 777a2d4, e3b1301, plus this report.
