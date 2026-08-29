# 31 — The defect audit

Eight parallel read-only investigations over the whole application, run in one sitting:
control wiring, slider calibration, the keyboard grammar, state and observation,
persistence, the export path, masks and geometry, concurrency and lifecycle. Roughly
1.9 million tokens of reading against ~40,000 lines of Swift.

Nothing here is a style opinion. Every entry is a defect with a user-visible consequence,
and each was traced end to end before it was written down — several were confirmed by
building the relevant LumenCore file standalone and running the arithmetic.

The value of the exercise is not the count. It is that **six of the findings are the same
shape**: a thing that was built, is correct, and is not reachable — or is reachable and
reaches nothing. This repository has shipped that defect class at least nine times now
(SpeedEdit, snapshots, the ⌥-scroll, `showCrop`, the whole design system, `Upright`,
`look.lut`, the LUT palette entry, and the crop tab). It is the house defect.

---

## Fixed in this pass

### Data loss

| What | Where | What it cost |
|---|---|---|
| Escape in the crop tool wrote the **primary's** pre-crop framing onto every selected photograph | `CropPanel.revert` | Three frames selected, two already cropped: Escape destroyed both other crops. One undo step, so ⌘Z recovered it — but nothing on screen said it had happened, from a key that means "cancel" |
| A `cache.db` written by a newer build took the **authoritative catalog** down with it | `CatalogStore.init` | `schemaTooNew` is a `CatalogError`, the catch clause was `SQLiteError`-typed, so the throw escaped `init` and the whole session ran in memory — no catalog rows **and no sidecars**, because the sidecar writer lives inside `CatalogService`. Every edit, rating and flag made that day was discarded at quit. Run a dev build, go back to a release build, and this fired |
| A half-parsed sidecar was rewritten from the partial read | `XMPSidecar.parse`, `CatalogService.flushSidecars` | `XMPMerge` strips every Lumen-owned element before re-emitting what it was handed, so an element the parse never *reached* was deleted. Press `3` on a frame whose `.xmp` is damaged below its rating and the intact `<lumen:recipe>` further down is gone. Nothing looked wrong — the catalog still had it. What was destroyed was the copy that exists for when the catalog does not |
| An unpainted Brush component refused **export of the whole photograph** | `MaskPanel.makeComponent` | The panel seeded every new brush with the content hash of an empty stroke set that nothing ever wrote to the blob store, so export refused: "1 brush stroke set could not be read". Reachable in one click — add a mask (Brush is first in the picker), use a gradient instead, export |

### Hangs and unbounded work

| What | Where | What it cost |
|---|---|---|
| Unbounded main-actor loop on an unreadable file with an AI mask | `AppState.ensureMaskMattes` | The re-entry guard was released before the re-entry, and `attempted` is only recorded inside an optional-binding chain — so a missing original, an ejected volume or a RAW Apple refuses meant nothing was ever attempted and the condition stayed true forever. The loupe showed the embedded preview and looked fine while the app span at 100%. Now re-enters only when the attempted set actually grew |

### Things that silently did nothing

| What | Where |
|---|---|
| Mask **Blending** and **Balance** were overwritten by the global wheels before either render path saw them — and if they were the only mask grade edit, `isNeutral` stayed true and no table was baked at all | `MaskPanel`, rows deleted per docs/08 §8.4 |
| Display Transform **Black target**: the engine saturates at 9, the track ran to 15 — the top 40% did nothing. Its own preset default (0.0152) was unlandable at step 0.01 and printed as "0.02", a number 31% higher | `LookPanel` → range 0…9, step 0.001 |
| Radial mask **Rotation** ran ±180° on a shape with 180° period — half the track duplicated the other half | `MaskPanel` → ±90 |
| Z, `=` and `+` wrote `zoomLevel` in the grid, Compare and Survey where nothing draws it, **and swallowed the press**. Pressing Z in the grid then made the next `E` open at 1:1 with the arrows panning instead of paging | `Keymap` |
| ⌘K offered a **LUT** control with no picker, no importer and no stage | `ControlIndex` — entry deleted, aliases moved to Film Lab |

### Things that did the wrong thing

| What | Where |
|---|---|
| **Temp and Tint could never report themselves modified.** Both passed the displayed value as *both* the binding's stand-in and its `defaultValue`, so `value == defaultValue` identically for every value. The app's two most-used rows were the only two whose deviation mark never drew, whose neutral tick sat hidden under the thumb, and whose crossing haptic could never fire | `BasicPanel` |
| **The watermark grew the exported file.** `composited(over:)` takes the union of two extents and this was the only stage in the export tail that did not bound itself — a 27-character notice at 5% on a portrait delivery produced a 1645 × 2048 file with 280 points of black down one side | `PipelineRenderer.applyWatermark` |
| **Flip re-framed instead of mirroring.** The mirror is applied before the crop is measured, so ticking "Flip horizontal" on a crop of the left half delivered a mirrored version of the *right* half — the subject gone, and the masks left behind on it | `CropPanel` — the crop now mirrors with the frame |
| **Export "Megapixels" and "Pixels" shared one field with no conversion.** Switch the shipped 2048 preset to Megapixels and it computes two gigapixels; drag it to 24 and switch back and every photograph exports **24 pixels wide** | `ExportSheet` |
| **One arrow press on a hard-range value jumped it by the whole soft-range gap.** Type −8 into Exposure (legal) and tap → once: −5. A three-stop jump from a gesture that promises 0.01 EV, in either direction | `SliderDrag.nudged`, with tests |
| **A held key could stick permanently.** The key-up was answered below the dispatcher's guards, so touching ⌘ mid-hold discarded the release: the frame stayed lifted three stops and *both* inspection holds were dead for the rest of the session. Shift had a second route to the same place | `Keymap` |
| ⌃N, ⌃P, ⌃A, ⌃E, ⌃H — the standard macOS bindings — fired culling verbs | `Keymap` |
| A popover owned no keys, so `x` while reading the filter list rejected the photograph behind it | `Keymap` |
| **M forced the loupe on the way out**, breaking its own round trip, and left the crop rectangle armed under the mask canvas | `Keymap` |
| Auto-repeat was allowed for P/X/U/digits, which all *invert* — holding P with auto-advance off gave you the parity of how long you held it | `Keymap` |
| **The Effects section's dot and Reset ignored Grain**, which the section draws — so the header said "nothing changed" directly above a sub-header saying "changed", and its Reset left the grain alone | `WorkspaceModification` |
| **Undo never refreshed the mask overlay.** Undo a mask edit and the red wash stayed at the pre-undo shape; undo a mask *deletion* and the overlay for a mask that no longer existed stayed painted | `AppState.apply(step:)` |
| **Auto Tone skipped the scope refresh and the library requery.** The histogram kept describing the picture from before Auto ran — the one instrument you would use to judge it | `AppStateActions` |
| Every remaining stock AppKit control (26 switch rows, a checkbox, two progress views) was tinted the system accent — a saturated blue capsule inches from the photograph, against Law 7 | `LumenSwitch.swift` |
| The dropdowns shipped an hour earlier opened and closed on the same click | `LumenMenu` |
| `check-swift-surface.py` judged calls against `private` functions in other files, and read `case .mask(let id):` as a method call on something named `case` | `scripts/` |

---

## Not fixed — carried forward

Ranked. Each was confirmed; none was reached before the session ended.

### Data loss

1. **Two RAW files with the same base name share one `.xmp`.** `sidecarURL` maps every RAW
   to `NAME.xmp`, and `PhotoFormats.raw` contains both `nef` and `dng` — DNG alongside the
   original is an ordinary archival workflow. Editing the NEF then the DNG destroys the
   NEF's recipe in the sidecar, and the next launch's merge resolves `sidecarWins` and
   writes the wrong recipe into the catalog. *Verified by running `SidecarMerge.resolve`.*
   Fix: `NAME.EXT.xmp` unless it is the only browsable file with that base name, with a
   read-only fallback to `NAME.xmp` for Lightroom interop.
2. **Export presets are decoded with `try?` against a strict synthesized codec.** One new
   field or one unknown enum case in `ExportRecipe`, `Watermark`, `HDRSettings`,
   `MetadataPolicy`, `OutputSharpen` or `SoftProof` and the whole preset list silently
   reverts to the stock four. `RecipeCodecToleranceTests` walks `Recipe` and `LookSubset`
   and does not reach these six.
3. **Losing the catalog loses the session.** With `catalog == nil` there are no sidecars
   either, and the only notice is 10 pt text at the bottom of a hideable sidebar.
4. **Brush strokes are in neither backup.** The blob store sits outside `VACUUM INTO` and
   outside the sidecar, so a restored catalog gives you masks that rasterize empty.
5. **`recoverIfNeeded` has nothing to recover from** — `backup()`'s only caller is a menu
   item, and every press writes a full copy that nothing prunes.
6. **A recipe written by a newer build is silently downgraded in place**, because the guard
   compares the decoded recipe's carried-forward version rather than this build's.

### Correctness

7. **⌘C / ⌘V / ⌘A are taken from every text field.** `CommandGroup(replacing: .pasteboard)`
   deletes the standard items and binds plain ⌘V to *paste develop settings*. Type a
   keyword, press ⌘V, and a recipe lands on the photograph. Ten text fields are affected.
   The fix moves settings copy/paste to ⌘⇧C/⌘⇧V and must land with `KeyGrammar` and the
   Help sheet in one commit.
8. **The radial mask's on-image ellipse rotates in the wrong space.** `MaskRaster` was
   fixed to rotate in long-edge units; `MaskCanvas` still rotates in per-axis normalized
   units. On a 3:2 frame at 45° the canvas draws an axis-aligned ellipse and the renderer
   produces a tilted one, and the handle you drag is 1.5× off in y.
9. **"Move the whole gradient" and "move the radial centre" add a displayed-space delta to
   source coordinates.** On a crop of `w=0.5` the mask runs away at twice the pointer's
   speed; with a straighten angle it slides diagonally.
10. **A ratio lock is silently broken by any change of angle.** 16:9 at 0° becomes 1.83:1
    at 2° and 2.13:1 at 10°, while the padlock still says it is holding the ratio.
11. **"Don't resize" resamples anyway.** The target is computed from a truncated crop
    extent, so any cropped or straightened photograph is resampled at ~0.9999× and comes
    out one pixel short on each axis.
12. **`scaled()` runs Lanczos with no edge clamp** — a darkened, semi-transparent rim on
    every resized export. The golden test insets its comparison by 6 px to avoid it.
13. **The metadata policy reads its base dictionary from the rendered image**, after ~40
    custom kernels. Either the whole policy is a no-op on an empty dictionary (so `EXIF:
    on` delivers files with no camera data at all) or the source's orientation and pixel
    dimensions survive onto a resized file. One `print` on the macOS lane settles which.
14. **Reset on the Looks header applies a second tone map to every JPEG.** A rendered file
    starts at preset "Linear"; `RenderParams()` is "Neutral"; so an untouched JPEG wears a
    modified dot and its Reset crushes the picture. The same bug was already fixed one
    level in, on the inner Display Transform header.
15. **The Detail header's Reset gives every selected photograph the primary's ISO denoise
    baseline.** The whole-recipe Reset does this correctly; the section reset was written
    against the wrong overload.
16. **The mask canvas is dead whenever `activeMaskID` is nil** while the panel shows a mask
    as selected — three readers of one selection with two different fallbacks.
17. **⇧⌘G (Unstack) is dead on a fresh install**, behind a sidebar section that ships
    closed. The comment above it asserts the opposite.
18. **⌘K → "Lens Corrections" arms the crop rectangle with no crop panel**, and Escape then
    fails to revert because no session was begun.
19. **Capture Sharpening and "Built-in profile" are dead on every non-RAW file**, with the
    profile ticked by default. The neighbouring AI-denoise row already branches its help
    text on exactly this.
20. **Grain does nothing while Film Lab Strength is 0**, and the two controls live in a
    different workspace section from the one that gates them.

### Performance

21. **`zoomLevel` publishes on `AppState` per pinch and per scrub event** — a whole-window
    and whole-`Scene` rebuild, seven menus included, for a number none of them read.
22. **`InspectionGain` runs a full-resolution Core Image render inside `body`**, memoised
    one entry deep — so Survey with N panes does N renders per pass while the key is held,
    on the main thread. Its two static caches are never cleared.
23. **The draft ladder is taught the size it asked for, not the size it got**, which makes
    its own guard a tautology and its settle-recovery a no-op on any cropped photograph.
24. **Export holds the serial render actor for the whole batch** with no cancellation
    point, so the loupe freezes for the duration.
25. **`AppUpdater` blocks the main thread** through `ditto` and a deep `codesign`, and its
    failure message claims the running build is untouched on a path where it may have been
    moved away.
26. **`NSCursor` push/pop is unbalanced** in `ContentView`'s divider and in
    `lumenScrubCursor`/`lumenClickCursor`, whose `enabled` guard covers both directions.
27. **Decode memory is bounded per file but twelve files are cached** — up to ~3.8 GB.

### Smaller, recorded

28. The View menu's first inner `Group` sits at exactly ten children and the arity guard
    test only scans top-level builders.
29. Coalescing keys shared between distinct decisions: two white-balance presets, two curve
    points, two aspect ratios each fold into one undo step.
30. Contrast is linear where docs/04 specifies log-scaled — the whole usable band occupies
    9% of the track.
31. Zones sliders run 2.5× past the point where the tone map stops being monotone; a single
    zone at +3 EV flattens 11.9% of the tonal axis.
32. `wand` — the per-slider Auto affordance — is declared and passed by zero of 88 call
    sites. `showReadout` is a `@Published` with no writer.
33. In "All bands" mode the mixer readout is a mean and the thumb springs back on release
    whenever the bands have any spread, contradicting the caption.
34. Five `LocalAdjust` fields and eight `Upright` fields still round-trip through the wire
    format meaning nothing. `BUILDING.md` claims two deleted sections still explain them.
