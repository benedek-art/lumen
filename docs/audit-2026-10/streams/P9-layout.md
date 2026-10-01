# P9-layout: panel layout, slider accessibility, crop ratio locks, batch geometry

Branch `worktree-agent-a4412838a835a1e01`, built on trunk `0ecaa58` and merged with trunk
before finishing (`f1c5f3d`). Build dir `/tmp/lumen-build-p9`. Every LumenCore test named
below runs on Linux. The LumenApp halves are source-verified: the commits pin them with
source contracts that run on Linux. `check-swift-surface.py` exits 0.

## Items

| Item | Status | Commit | Red / green | Proof records moved |
|---|---|---|---|---|
| S-08 duplicate roll entries | FIXED | `79075d2` | Red with the revision check removed: 3 tests, 13 failures. Green: 17/17 | none |
| M12 60:1 / 1:60 crop locks | FIXED | `83e6865` | Red with `canHold` accepting everything: 2 tests, 6 failures (2,344 accepted ratios did not hold). Green: 5/5 | none |
| S-11 / KG-01 batch geometry | FIXED | `05e7d41` | Red with the primary's frame substituted: 2 tests, 7 failures (portrait 0.5674 vs 0.6667). Red with the pre-fix app writers: 2 tests, 12 failures. Green: 9/9 | none |
| UX-03 slider accessibility | FIXED (curve editor left to P4) | `56c43fa` | Red with the pre-fix LumenControls/DevelopColumn: 4 tests, 13 failures. Green: 8/8 | none |
| G1-01 denoise label truncation | NOT-A-DEFECT now: already fixed in the tree (rows renamed), and `LayoutMetricTests.testTheRenamedDenoiseRowsAreGoneAndTheirReplacementsFit` holds it | — | — | none |
| G1-02 narrow-column track precision | NOT-FIXED: this is a trade for the owner (see DECISIONS). The 3 LayoutMetric XCTExpectFailures stay | — | — | none |
| G1-04 Export Recipes sentence | Already fixed in the tree, but nothing tested it. Test added | `bb9c915` | Red with `prominent: false`: 1 failure. Green: 2/2 | none |
| G1-05 Display Transform header | NOT-A-DEFECT now: already fixed (stock badge), measured by `testTheDisplayTransformHeaderAndEveryStockBadgeFitTheNarrowColumn` | — | — | none |
| G1-06 Copy/Paste Look footer | NOT-A-DEFECT now: already fixed (two rows of two), measured by `testEveryDevelopFooterButtonFitsItsShareOfTheRow` | — | — | none |
| Trunk slider-inventory citations | DONE | `fb22f25` | `recite-slider-inventory.py HEAD^2 --write`: 2 moved, 0 unplaced | none |

### S-08: RollCursor
- **Ingress check.** Ingress does not permit duplicates today:
  - The folder scan enumerates each file once.
  - The catalog query returns each row once.
  - `strays` carry no catalog id, so they cannot collide with a row.
- **Why the fix needs the owner.** No O(1) check over `(count, idAt)` can tell when a second copy of a URL lands at a different index at the same roll length: the slot that changed is one the check has no reason to read. So the roll's owner now passes a `revision`:
  - `AppState.rollRevision` is bumped next to the one place `photos` is rebuilt.
  - The grid, filmstrip and loupe read the revision right after `photos`, so the pair describes one roll.
  - `ThumbnailLoader` and `rollIndex` key their memo on it.
  - The slot verification stays as a second guard.
- **Cost.** The fast path costs the same as before: one dictionary hit, one comparison and one integer compare.
- **Tests.**
  - The 3 expected-failure cases no longer carry XCTExpectFailure, and they no longer return early on Linux. Each now bumps the revision where its roll changes.
  - The distinct-identity cases still pass a constant revision, so they keep proving the slot guard on its own.
  - A new source contract checks the owner's half.

### M12: crop ratio limits
- The parser's 1:60 to 60:1 bounds are only a typo guard. The geometry floor (`minimumCropFraction`, 5 % per axis) limits a 6000×4000 frame to 0.075 to 30.
- New functions:
  - `CropGeometry.achievableAspects` gives the frame's real range.
  - `canHold` is the gate.
  - A frame-aware `aspect(fromText:sourceWidth:sourceHeight:degrees:)` combines the parser and the gate.
- CropPanel's custom field, the preset and recent menu entries, and `applyAspect` all read the gate. Every preset can be held on an ordinary frame, so nothing a user can pick from the menu changes.
- After a swap, the padlock takes the ratio the rectangle actually holds. Before, it took `1/locked` blindly.

### S-11 / KG-01: batch geometry
- **Every write path found:**
  - CropPanel: Angle slider, ratio menu, custom ratio, orientation swap.
  - LoupeView: `applyRotation` (rotate drag and ruler) and `cropBinding` (rectangle drag).
  - Paths that do not depend on frame size: flip, Original, Reset, Escape-revert. Revert was already per-photo.
- **The rule.** `BatchFraming.apply` (LumenCore) computes each target against its own frame. It returns nil, and leaves the target alone, when the frame is unknown or the target cannot hold the requested ratio.
- **Where frames come from.**
  - The primary still uses its decoded, orientation-reconciled frame.
  - Other targets use their catalog `width`/`height`, transposed for EXIF orientations 5 to 8. These are read once per selection change by `CatalogService.frames(photoIDs:)`, a one-method hunk in a file other streams also touch.
- **Rectangle drag.** It now writes only the photo it is drawn on.

### UX-03: accessibility
- **LumenSlider** is now one element. Its label is the title on screen; for untitled rows it is the new `accessibilityName`. Its value is the readout's digits and its hint is the tooltip text. Increment and decrement are exactly one step of the control through `SliderTrack.nudged`, not the ⇧×10 that `nudge` reads, and each is bracketed as one undo step.
- **LumenColorWheel** is now one element:
  - Its value reads "hue N°, strength P%".
  - Increment and decrement step strength by 1 %.
  - Two named actions turn the hue by 5° either way.
- **Develop section cards** are named groups (`WorkspaceSection.title`). That is the same name `ControlIndex` files its controls under.
- **No runtime accessibility-tree test.** The only LumenApp lane is a headless runner. The arithmetic is runtime-tested in LumenCore and the wiring by source contract.

## DECISIONS (owner may overrule)

1. **G1-02, the narrow-column floor.**
   - At 320 pt the slider track is 142 pt, which is 0.71 pt per unit on a ±100 control. At 380 pt it is 202 pt (1.01 pt per unit); at 520 pt it is 342 pt (1.71). Fold rows now get the same track, because `disclosureInset` is 0.
   - Clearing 1.0 at the minimum width needs one of three things: a 378 pt minimum width, a narrower label column (86), or a narrower readout (52). Each one changes the approved look or the resize range, so none is implemented.
   - The fine-quantum rows (Exposure 0.01 over ±5, for example) cannot clear 1 pt per step at any width. The default-width census expectation is therefore permanent unless the census is narrowed to the ±100 class. That narrowing is a product-promise decision.
2. **Batch targets whose frame is unknown are left untouched.** This covers a photo with no metadata row yet, or one selected before the catalog read lands. The alternative is computing their crop against another photo's frame, which is the defect. As a result, a multi-photo angle or ratio change can skip such a photo.
3. **The rectangle drag no longer fans out over a multi-selection.** It previously stamped the primary's fractions on every frame, which gives a different pixel shape on any frame of another aspect. It now edits the one photo it is drawn on, as `CropTool.revert` already argued. Lightroom-style "sync crop" would need its own per-target rule.
4. **A ratio the primary cannot hold is refused outright**, even if other selected photos could hold it. For a ratio the primary can hold, targets that cannot hold it are skipped.
5. **The S-08 contract changed.** `RollCursor.index(of:inRollOf:revision:idAt:)` replaces the revision-less API, and the header's claim that it "needs no version stamp" is withdrawn in the source. The adversarial tests now model the owner bumping the revision. A forgotten bump on a roll with distinct identities is still caught by the slot check. A forgotten bump on a roll with duplicates is not.

## FOUND-WHILE-FIXING

- **Paste Settings copies the crop as normalized fractions** (`AppState.pasteSettings`, `recipe.develop = source.develop`). So pasting a crop onto a frame of a different aspect changes its pixel shape. That is the same class as KG-01, but paste is a literal copy by design, so whether a pasted crop should keep its pixel aspect is an owner decision. Not changed.
- **Non-primary frames come from catalog EXIF dimensions.** For some RAWs the EXIF extent differs slightly from the decoded extent; the aspect is close, but not identical. Remembering each photo's decoded, reconciled frame once it has been primary would tighten this.
- **Line-number citations in `SliderInventory`** keep breaking whenever a panel file is edited. A sturdier key would be the slider's title plus its enclosing function, resolved by the self-test. That is LumenAppTests work and was not done here.
- **A stale comment in `LumenControls.swift`** ("Luminance Contrast… four rows out of ninety-two", in the `minimumScaleFactor` comment) describes labels that were renamed for G1-01. Left as is, because `LayoutMetricTests` quotes that comment.
- **The curve editor's custom control** (UX-03 scope) is in P4's file and still has no adjustable semantics.
