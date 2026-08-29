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

## Fixed in the second pass

Eight more from the list below, chosen for being confirmed and small:

| What | Where |
|---|---|
| **"Move the whole gradient" and "move the radial centre" added a DISPLAYED-space delta to SOURCE coordinates.** On a crop of `w=0.5` the mask ran away at twice the pointer's speed, and with a straighten angle it slid diagonally. Every other gesture in the file already routed through the inverse transform; these two did not | `MaskCanvas` |
| **The on-image mask canvas was dead whenever `activeMaskID` was nil** while the panel showed a mask as selected — three readers of one selection, two using `?? masks.first?.id` and this one requiring non-nil. A photograph with a mask from an earlier session showed the row lit, the sliders bound, and no handles on the picture | `LoupeView.maskEditTarget` |
| **The first `O` after every photo change did nothing.** `soloMaskOverlay` holds a per-photograph mask id and was not cleared with the rest of the mask selection, so it pointed at the previous photo's mask: the overlay did not draw, and `O` took the "solo is set, clear it" branch | `AppState.cursorDidChange` |
| **⇧⌘G (Unstack) was dead on a fresh install** — its only key equivalent lived on a button inside a sidebar section that ships closed, and a `.keyboardShortcut` on a view that is not in the hierarchy is never registered. The comment above it asserted the opposite | `ContentView` |
| **Capture Sharpening and its Amount were live on every non-RAW file and reached nothing.** Their only reader is the raw decoder; a JPEG goes through `RenderedImageSource`, whose `decode` reads nothing from the recipe but the scale factor | `DetailPanel` |
| **"Built-in profile" was the same, and it defaults to ON** — so every rendered file in the library carried a ticked box that reached nothing, which is precisely the state that got Remove CA deleted | `EffectsPanel` |
| **Grain did nothing while Film Lab Strength was 0**, with the control that explains it in a different workspace section. A real workflow reaches it: pick a stock, pull Strength to 0, come to Effects for the texture without the palette | `EffectsPanel` |
| **`showReadout` was a `@Published` with no writer** — a constant wearing a setting's clothes, four reads and nothing that could change it | `LoupeView` |

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
9. ~~FIXED (second pass)~~ **"Move the whole gradient" and "move the radial centre" add a displayed-space delta to
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
16. ~~FIXED (second pass)~~ **The mask canvas is dead whenever `activeMaskID` is nil** while the panel shows a mask
    as selected — three readers of one selection with two different fallbacks.
17. ~~FIXED (second pass)~~ **⇧⌘G (Unstack) is dead on a fresh install**, behind a sidebar section that ships
    closed. The comment above it asserts the opposite.
18. **⌘K → "Lens Corrections" arms the crop rectangle with no crop panel**, and Escape then
    fails to revert because no session was begun.
19. ~~FIXED (second pass)~~ **Capture Sharpening and "Built-in profile" are dead on every non-RAW file**, with the
    profile ticked by default. The neighbouring AI-denoise row already branches its help
    text on exactly this.
20. ~~FIXED (second pass)~~ **Grain does nothing while Film Lab Strength is 0**, and the two controls live in a
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


---

# Round two

Four more investigations, over the areas round one said it did not reach: the render
graph and its kernels, the colour and tone engines, the catalog's query builder and XMP
merge rules, and **the test suite itself**. Findings below were largely produced by
compiling the relevant LumenCore files standalone and RUNNING them — the numbers are
measured, not reasoned.

## The finding about the tests, which outranks the rest

`ProofRegistry.shippingReader` is the guard against this project's house defect — it names
the line in the SHIPPING renderer that reads each control, so a proof cannot be filed for
something the GPU never touches. It is a `String` that **no assertion reads**, and it is
excluded from the drift check.

All 59 entries name a line in `RenderGraph.swift`, across eleven distinct line numbers.
**58 of 59 point at a comment, a closing brace or a blank line.** So a control can be
deleted from the shipping graph entirely and its proof still passes, because the sweeps
run through `ReferenceRenderer`, which by the registry's own admission renders no user
pixels. The apparatus proves the mathematics is alive; the one field that connected it to
the shipping path is inert prose.

Two more of the same shape, both demonstrated rather than argued:

- `WorkspaceModificationTests`' "every section" property tests pass **either way** on the
  grain fix. I reverted `grainIsModified` and watched them stay green. The fixture lights
  `.effects` through the vignette, so a section with two independent triggers is only ever
  exercised through one. Two tests that do fail were added with the fix.
- `DragBroadcastTests` exists to assert that nothing writes `AppState` per event, and
  **never observes `AppState`** — it counts publishes on the three objects extracted away
  from it. That is why `zoomLevel` publishing on every pinch sat there green.

The app layer has six test files, 65 unobserved `@Published` properties, and four text
scans standing in for behavioural tests — and those four scans are, between them, the only
guard on ten of the defects in this document.

## Fixed from round two

| What | Where |
|---|---|
| **⌘G on a selection containing another stack's pick made that stack's remaining frames vanish from the grid.** `stack_member.photo_id` is UNIQUE and the insert was `OR REPLACE`, so re-stacking deleted the old membership while `pick_photo_id` still pointed at the moved frame — and `collapsedTopsOnly` is then false for every survivor. Reproduced with a probe: B and C on disk, in the catalog, in no view, with nothing in the interface able to bring them back. Membership now moves rather than being replaced, an orphaned stack re-picks or is deleted, and a pick that is not a member is refused (which `setStackPick` already did) | `CatalogStore.createStack` |
| **"Sort by Label" ordered alphabetically on the stored key** — blue, green, purple, red, yellow — which is neither the swatch row nor the 6/7/8/9 keys, and is the reverse of what the catalog-less path does. One menu item, two orders, neither the one the interface teaches | `CatalogStore.orderClause` |
| **`OKLabTransform.toRGB` inverted a 3×3 on every call.** `Mat3.inverse` is a computed property that allocates four `[[Double]]`s and re-derives; measured at 2.07 µs per read, which is why OKLab→RGB cost 2.74 µs against RGB→OKLab's 0.82 for the same arithmetic. Every hue-selective tool, both grading engines and `Gamut.softClip` paid it per pixel | `Perceptual.labToLMS` |

## Round two, carried forward — ranked

**Engine, and severe:**

1. **The grading wheels' Luminance inverts the tone response at the shipped defaults.**
   `scaleBrightness` scales OKLab **L**, whose linear value is `L³`, so the realised
   response is `1 + 3·scale·slope` while the limiter solves `1 + scale·slope` — 2.85×
   too permissive, reporting "nothing to limit" on settings that fold the curve. Midtones
   +1 with Highlights −1, one drag each: 33 code values of reversal across 1.75 stops of
   midtone. **345 of 810 sampled combinations invert.** `ColorBalanceGrid` has no limiter
   at all.
2. **The Film Lab discards the user's display transform**, rebuilding a Neutral one and
   copying only `whiteTarget`. Because the gate is `amount > 0`, this is a discontinuity:
   Strength 0 renders through your transform, Strength **1** renders 99% Neutral. On the
   "Linear" preset — the show-me-the-data control — one point of Strength moves the
   picture 51 code values, and Black target is dropped outright.
3. **Every masked export delivers a mask edge resolved to 1/1024 of the frame.** Masks are
   rasterized at 1024 on every path and bilinearly upsampled; on a 45 MP file that is an
   8-pixel ramp with the boundary quantised to 8 px. The comment above it says the
   refinement "runs at full resolution in the graph" — there is no such stage. The CPU
   reference rasterizes at full resolution, so the two renderers do not agree either.
4. **The stale-table door hands a new photograph the previous photograph's picture
   formation.** On a miss it returns the newest entry in the slot from *any* recipe and
   *any* photograph. Step from a black-and-white edit to a colour frame and the colour
   frame renders monochrome for a frame. The documented contract is "one mouse event
   behind"; across a photo change it is a different photograph's look.
5. **The GPU's log-luminance plane has no floor; the reference clamps at zero first.**
   Scene-linear luminance goes negative routinely after white balance, and the toe branch
   is linear and unbounded: −0.01 encodes to −4.83 where the reference gives +0.0024. One
   such pixel drives the guided filter's `a` from 0.087 to 0.917 across a 103×103 patch,
   which is the edge-aware tone mask degenerating into the raw luminance.
6. **The grading zone pivots are guessed fractions, not the documented EVs.** `[0.33,
   0.67]` puts the shadow pivot at −4.38 EV and the highlight pivot at +0.38 EV against a
   spec of −2.0/+1.5. At mid-grey the Highlights wheel already carries 30.6% of the
   weight; at −2 EV the Shadows wheel carries 0%. This is the identical defect
   `Zones.defaultPivots` was already fixed for.
7. **Every spatial stage runs on a half-float plane whose quantum exceeds the contrast
   threshold it is compared against.** The stages work on the log-ENCODED plane, which
   parks the range in [0.29, 0.71] where one fp16 step is 0.0117 EV; the presence
   regulariser's √ε is 0.100 EV, below its own numerical noise floor. Simulated, the
   guided filter's mean `a` is 0.632 exact against 0.414 in fp16. The fix is a change of
   denomination, not of format, and the denoise engine already uses the trick.
8. **The soft proof's perceptual intent degrades to a per-channel clip near white** —
   `softClip` declines above L = 1 and the clamp takes over, which is exactly what the
   perceptual intent exists to avoid. Mean hue rotation 28° above L = 1, worst 171°.
9. **The text filter returns nothing, permanently, once `cache.db` has been recreated.**
   `photo_fts` lives in the disposable database and nothing rebuilds it, while
   `ftsEnabled` stays true so the builder keeps preferring it. Reachable by the same
   newer-build path round one fixed for the catalog. Probe: every search returns zero.
10. **A colour label Lumen cannot name is deleted from the sidecar on the first culling
    keystroke** — Lightroom's "To Print" and any translated colour name. `XMPMerge`'s own
    header promises every other byte of somebody else's document survives.
11. **`xmp:Rating="-1"`, Lightroom's reject marker, is silently rewritten as 0.**
12. **The grid query materializes every row in the folder with no LIMIT, per keystroke.**
    Measured: 350 ms for 50,000 rows, on the serial queue that also serves thumbnails,
    with no debounce on the search field.
13. **First open of a card is ~1 s of catalog work at 5,000 frames and ~10 s at 50,000**,
    held inside one `queue.sync` — a per-photo savepoint and a full text re-index each.
14. The text chip is prefix-only on the FTS path and infix on the fallback: typing "202"
    finds `IMG_2202` on one branch and nothing on the other.
15. Texture's GPU gain has no excursion limit where the reference clamps at ±4 EV; the
    gamut-warning flag sits on opposite sides of grain in the two renderers; the album
    sidebar counts offline frames the grid excludes and blames the wrong cause; `rebuild`
    writes bare LFs into a CRLF sidecar; a Lumen-owned element name is stripped wherever
    it appears, including inside another tool's provenance record.
16. **A non-finite zone pivot indexes past the end of the pivot array** — a real trap,
    not reachable through JSON decode today, but reachable in shape: a short pivot array
    from a foreign writer is padded with the tail of the defaults, producing an unsorted
    array the engine accepts and the panel sanitizes only for its own drawing.
17. **An untouched recipe is not a passthrough**: the finish table costs 3.5 code values
    on midtone grey at preview resolution against 0.9 at export, so the frame an editing
    decision is made against differs from the file by about 2.5 codes.
18. `CurveStack.bakeChannelLUTs` has zero callers and would drop `preserveLuminance` and
    the luma curve if wired — the house defect, in the curve stage.


---

## Postscript: the guard that should have caught the guard

The compile error that took CI down for three pushes — `help:` passed before `step:` in a
`LumenSlider` call — is worth a paragraph of its own, because two separate mechanisms that
exist to catch exactly it both let it through.

`swiftc -parse` cannot: argument order is a type-checking rule and the call is
syntactically valid. That is the known blind spot — `Sources/LumenApp` needs AppKit and
`Sources/LumenPipeline` needs CoreImage, so both type-check on the macOS lanes and nowhere
else. Fine, expected, and the reason the macOS lanes exist.

**`scripts/check-swift-surface.py` also cannot, and that is not expected.** Its `inits`
pass walks a declaration's labels in order and requires every call label to be consumed,
which is precisely the rule that rejects out-of-order arguments. Verified by hand: with the
arguments in the wrong order the pass still reports *"2797 call sites match a declared
initializer, 0 unparseable"*. It is not reporting the site as unparseable and skipping it —
it is passing it.

The call site has a multi-line ternary argument (`help: cond ? "…" + "…" : nil`) spanning
five lines. Something in `split_top` or `LABEL.match` swallows the site without counting it
as a skip. That is a silent hole in the middle of the one guard this repository has against
wrong arguments, and a silent hole is worse than an absent guard, because the pass reports
a confident count either way.

This is the same shape as `ProofRegistry.shippingReader` above: a mechanism that reads as a
guard, is cited as a guard, and is not one. Section A20 of the test audit already records
that the checker has no fixture suite — twenty lines of known-good and known-bad snippets.
This is the second false negative it has shipped today, after the two false POSITIVES fixed
earlier in the session, and it is the more dangerous direction.

**Next action:** a fixture suite for `check-swift-surface.py` whose known-bad set includes
an out-of-order argument on a call with a multi-line ternary, then fix whatever it exposes.
