# Lumen — test-area catalogue

For tester agents driving the app through the automation driver. One area per tester. Read
**Part 0** first: it applies to every area.

Source of truth for this file: the code at `main` (HEAD `5ba879f`, read on 2026-11-25), checked
against `docs/02`, `docs/04`–`docs/12`, `docs/29`, `docs/37`, `docs/38`, `BUILDING.md`,
`README.md` and `docs/audits/2026-10-07-deep/CURRENT-STATE.md`. Where code and docs disagree,
both are given and marked **[code≠doc]**. Source comments are long and confident; they are
claims about intent, not proof. Line numbers are approximate (other agents are editing).

All paths are relative to the repo root. `App/` = `Sources/LumenApp/`, `Core/` =
`Sources/LumenCore/`.

---

## Part 0 — rules for every tester

### 0.1 What the window is

- One window (`App/ContentView.swift`), min 1180×720. Left: **sources sidebar** (190–320 pt,
  ideal 230). Top: **filter bar**. Centre: grid / loupe / compare / survey. Right of centre:
  **develop column** (320–520 pt, default 380, drag its left edge), then the **workspace rail**
  (56 pt: Cull, Develop, Crop, Grade, Deliver, then a divider and **Masks**). Bottom:
  **filmstrip** (heights 72/96/128) and **status bar** (22 pt).
- The develop column only shows when: the workspace has sections (not Cull) AND not hidden by
  Tab AND a photo is selected AND view is loupe or compare (`ContentView.showsDevelopColumn`).
  It is **not** shown in grid or survey.
- Dark chrome always (`preferredColorScheme(.dark)`); chrome is meant to be zero-chroma
  (docs/00 Law 7). A coloured UI element near the photo is worth reporting.
- No Settings/Preferences window exists. All configuration is in-panel or in menus.

### 0.2 Menu bar (complete, from `App/LumenApp.swift` and `App/CullCommands.swift`)

- **Lumen (app menu)**: build stamp line (disabled text), *Check for Updates…*.
- **File**: *Open…* ⌘O · *Ingest from Card…* ⇧⌘I · *Relink Missing Original…* · *Back Up Catalog*.
- **Edit**: *Undo <label>* ⌘Z · *Redo <label>* ⇧⌘Z · *Cut* ⌘X (text fields only) ·
  *Copy Settings* ⌘C · *Paste Settings* ⌘V · *Paste Settings Without Masks* ⇧⌘V ·
  *Paste Masks* · *Paste Includes Spot Removal* (checkable) · *Copy Settings…* ⇧⌘C ·
  *Sync Settings…* ⇧⌘S · *Sync Settings Without Dialog* ⌥⇧⌘S · *Paste from Previous* ⌃⌘V ·
  *Copy Look* ⌥⌘C · *Paste Look* ⌥⌘V · *Reset Settings* ⇧⌘R · *Select All* ⌘A ·
  *Select None* ⌘D · *Invert Selection* · *Select Picks* ⌥⌘A · *Select Rejects* ·
  *Select Unflagged* · *Select by Rating ▸* (1★ or More … 5★) · *Deselect Unpicked* ⌥⇧⌘D.
- **View** (custom `CommandMenu`): *Grid — G* · *Loupe — E* · *Compare — C* · *Survey — N* ·
  *Cull* ⌘1 · *Develop* ⌘2 · *Crop* ⌘3 · *Grade* ⌘4 · *Deliver* ⌘5 · *Go to a Control…* ⌘K ·
  *Hide/Show Sidebar* ⌥⌘S · *Filmstrip — F* · *Histogram — H* · *Scopes — S* ·
  *Lights Out — L* · *Assessment Surround* ⌘B (title gains "(on)") · *HDR Preview* ·
  *Zoom In* ⌘= · *Zoom Out* ⌘− · *Info Overlay — I* · *Clipping Overlay — J* ·
  *White Balance Picker — W* · *Hide / Show Panels — Tab* · *Previous Photo — ⌘←* ·
  *Next Photo — ⌘→*. (Bare-key items show the key in the title but do not attach it; the
  dispatcher owns the key.) Check whether macOS also adds its own View menu / "Enter Full
  Screen" — a duplicate View menu is a finding.
- **Debug**: *Show/Hide Latency HUD* ⌥⌘L.
- **Photo**: *Pick · Reject · Unflag · Rating 1…5 · Clear Rating · Auto Tone* ⇧⌘A ·
  *Match Total Exposures* ⌥⇧⌘M · *Stack Selection* ⌘G · *Unstack* ⇧⌘G ·
  *Stack Bursts in Folder* · *Keyword the Selection…* ⇧⌘K · *Move Rejected Photos…* ⌘⌫ ·
  *Remove Rejected from Catalog…* · *New Develop Preset…* ⇧⌘N · *Develop Presets ▸*
  (Manage Presets…, Import Presets…, then one item per preset).
- **Library**: *Filters On / Off* ⌘L · *Show Picks Only* ⌥⌘P · *Show Unflagged Only* ⌥⌘U ·
  *Show Rejected Only* ⌥⌘X · *Show Rated 1★ or More* ⌃⌘1 … *Show Rated 5★* ⌃⌘5 ·
  *Pick Sharpest in Each Burst…*.
- **Export**: *Export…* ⌘E · *Export with Previous* ⌥⇧⌘E · *Show Last Export in Finder*.
- **Help**: *Lumen Keyboard Reference* ⌘/.

Note: ⌘\\ ("Clear the filter") is attached to the filter bar's **Clear** button
(`FilterBar.swift:151`), which exists only while a filter is active and is removed with the
filter bar at Lights Out "out". The repo's own rule is that a shortcut on a view that can leave
the hierarchy goes dead — test ⌘\\ with a filter active at each Lights Out rung and with
⇧Tab.

### 0.3 Keyboard dispatcher rules (`App/Keymap.swift`) that every area must respect

- Bare keys are dropped while: a text field has focus; a sheet is up; a popover/dropdown
  (`LumenMenu`, filter popover) is the key window. Pressing X with a popover open must NOT
  reject the photo.
- Any ⌘ or ⌃ chord is left to the menus (except ⌘←/⌘→ which page photos). ⌃N/⌃P/⌃A/⌃E/⌃H
  must do nothing in the app.
- Key repeat: navigation repeats; flag/rating/label keys repeat only while auto-advance is on
  (or forced with ⇧/Caps Lock). Holding P with auto-advance off must not flicker pick/unpick.
- **Escape order** (innermost first): focused slider → pending eyedropper pick → masking →
  Heal tool → crop tool (reverts the framing to what it was at arming) → back to grid. A
  final Escape in the grid does nothing.
- **Delete (⌫)**: masking → delete the active mask; Heal armed → delete selected spot/stroke
  (no-op if none); else reject the photo.
- **Arrows**: zoomed loupe → pan; focused slider → nudge; else previous/next photo (←/→) and
  row up/down (↑/↓, ±columns in grid, ±1 elsewhere).
- `-` is the purple label outside the loupe and zoom-out inside it. Digits 0–9 are brush Flow
  only when masking AND a brush component is selected; otherwise ratings/labels.
- `A` toggles Automask when masking with a brush selected; else auto-advance.
- `[` `]`: brush size (⇧ = feather) when masking with a brush selected; grid → thumbnail size
  ±24 (96…512); loupe/compare/survey → momentary hold (shadow boost / highlight inspect, 3 EV),
  released on key-up, with a bottom-centre badge. Shift pressed during the hold must not make
  it stick (code folds `{`/`}`).
- Space: in grid, hold = loupe, release = back to grid. In loupe: fit ↔ 1:1 at the cursor.

### 0.4 The slider contract (applies to ~150 sliders; see Area 11 for the dedicated test)

From `App/LumenControls.swift` header: drag track (grab thumb = follows; press track = jumps
once then follows); ⇧ while dragging = fine; drag the **number** to scrub (3 track widths per
full range); click number to type (absolute, or `+= 0.3`, `-= 0.2`, `* 2`, `/ 2`); double-click
label or track = reset to default (or the row's own "auto" reset); range is **soft** for drags
(pins at soft limit) and **hard** for typing; a non-default row shows a modified state; haptic
tick when crossing the default; click row to focus, then ←/→ ±1 step, ⇧←/⇧→ ±10, ↑/↓ also
nudge; Escape drops focus; ⌥-scroll over a row nudges ±1 per wheel click (±10 with ⇧), plain
scroll scrolls the column. One drag = one undo step. Explicitly **not** built: ⌘-double-click
to auto, ⇧⌥-drag to hard limit, hold-to-sweep on arrows.

### 0.5 Section headers (`LumenSectionHeader`, `DevelopColumn.swift`)

Click a section header = open it solo (closes the others in that workspace); ⌥-click = toggle
it while keeping others open (`SectionExpansion.afterClick`). A dot marks a section with a
non-default value; **Reset** fades in on hover only when modified. Develop opens with White
Balance, Tone and Presence expanded (`WorkspaceLayout.initial`). Last card in every workspace
is **History** (closed by default, persisted in `develop.history`).

### 0.6 Latency contract (docs/12 §12.2) — what "slow" means

| Interaction | Budget |
|---|---|
| Slider / wheel / brush / pan / crop drag | visible change ≤16.7 ms (≤8.3 ms on 120 Hz) |
| Refine to full quality after drag pause | ≤200 ms, monotone (no brighter/darker pop, no flicker) |
| Photo switch, panel open/close, rating write, filter, view switch | ≤100 ms perceived |
| Cull paging | <50 ms per photo at key-repeat |
| Grid scroll | zero hitches at 120 Hz, 10k thumbnails |
| Undo/redo, history time-travel, AI mask proposal | ≤100 ms to visible state |
| Anything >1 s | inline indicator; >10 s determinate progress + cancel; never a modal progress dialog |

Turn on **Debug ▸ Show Latency HUD** (⌥⌘L) to read input→draft numbers; the HUD itself adds
main-thread cost (its header says so).

### 0.7 Global "known, do not report as new" (area-specific lists are in each area)

- Not built: Speed Edit (hold-letter + scroll), `` ` `` hold magnifier, `V` face strip, ⌘'
  snapshot key, second window (⌘F11/⇧F11), ⇧R reference view, Looks hover-preview, History
  hover-preview, auto-straighten, perspective/Upright, chromatic-aberration removal and
  Defringe (removed from UI), heal-stroke source drag/re-pick, dust auto-detect, aesthetics
  sort ("Aesthetic score" is in the sort menu but marked unavailable), album drag-reorder,
  HDR gain-map writing (toggle is inert), AI denoise model (AI mode is a RAW-only stand-in),
  Sky/Object/Landscape/Depth Range masks (absent from the picker), CFA/sensor-raw clipping
  stats (⇧H is post-demosaic), `O` raw-clipping overlay, catalog backup retention policy,
  persistent export queue.
- History is **session-only**: one undo stack cleared on folder switch, not saved to disk
  **[code≠doc: docs/12 §12.10 says history persists across restart]**. Named snapshots DO
  persist (catalog). Coalescing window is 1.2 s **[code≠doc: docs/12 says 2 s]**.
- The loupe is a SwiftUI image view; HDR is an opt-in display-only preview.
- Nothing has been verified by a human on: Vision mask orientation, eyedropper click accuracy,
  export metadata additive fields (Copyright/Contact/DPI), real-photo heal-stroke quality.
- `BUILDING.md` is partly stale: it says "Ingest copies nothing yet" (ingest now copies and
  verifies, per CURRENT-STATE and `IngestSheet.swift`), "Heal/clone does not exist" (superseded
  inside the same bullet), and that film exposure / halation size have no wire format (Film
  Lab now shows *Film Exposure* and *Halo Size*). Trust the running app, report divergence.
- Open audit groups (docs/38, `docs/audit-2026-09/w3/dispositions.md`): colour-science
  B1-04…08 (mixer ring authority, Density hue rotation, H-K magnitude, B&W level
  normalisation, band names up to 27° off), film C1-01…08 remainder, mask canvas/panel
  F1-02…06, F4-03…06, F5-01…03, layout truncations G1-01/02/04/05/06 at 320/380/520 pt,
  J1-03 `flushSidecars` stale read, J1-04 `close()` does not back up, J1-05 grid query has no
  LIMIT/debounce. Testers should still report the *symptoms* they see with a repro; tag them
  "possibly known: <id>".

### 0.8 Test corpus every tester should have

Landscape and portrait RAWs from ≥2 makers (e.g. NEF + CR3 + ARW + RAF + DNG); a high-ISO
(≥6400) RAW; a JPEG, a HEIC, a TIFF, a PNG (rendered files take a different path); a very
large file (≥45 MP), a very small file (≤1 MP JPEG); a file with an Adobe XMP sidecar holding
`crs:` settings, keywords and a label; a RAW+JPEG pair with the same basename; two files with
the same basename in different subfolders; a burst of 8–20 frames at ≥5 fps; a folder of
≥2,000 files; an empty folder; a folder with no supported files; a file renamed/moved after
import (for relink); a corrupt/truncated RAW.

### 0.9 How to state "correct"

Every "Correct:" line below is phrased to be checked from a screenshot or a state dump. State
fields worth dumping (on `AppState` unless noted): `viewMode`, `selection`,
`primarySelection`, `autoAdvance`, `filter`, `sortOrder`, `statusMessage`, `currentRecipe`
(and `recipes[id]`), `history` position/steps, `pickTarget`, `inspectionHold`,
`clippingOverlay`, `softProof`, `showFilmstrip/showHistogram/showScopes/showRawTruth`,
`sidebarVisible`, `developColumnHidden`, `developPanelWidth`, `lightsOut`, `assessmentMode`,
`activeMaskID`, `activeComponentIndex`, `maskOverlayMode/Tint`, `maskPanelVisible`,
`gridThumbnailSize`, `activeSheet`; `PanelLayout.shared.layout` (workspace, expanded,
isMasking); `LoupeViewport.shared` (zoom, pan, beforeMode, splitPosition, showCrop,
showStraighten, hdrPreview); `HealTool.shared`; `CropTool.shared`; `MaskBrushStore.shared`;
`CaptureInfoDisplay.shared.mode`; and the photo's `.xmp` sidecar and catalog row on disk.

---

## Area list (30)

| # | Area | One-line scope |
|---|---|---|
| 1 | Launch, open & library housekeeping | First launch, empty state, ⌘O, drag-drop, reopen, relink, backup, quit |
| 2 | Ingest from card | ⇧⌘I sheet: source, destinations, backup, templates, verify, eject, stop, reports |
| 3 | Sources sidebar | Folder header, flag sources, albums (manual/target/smart), keywords, stacks |
| 4 | Filter bar, sort & status bar | Text search, filter popover, metadata facets, sort, Library menu, status sentence |
| 5 | Grid, filmstrip & selection | Click grammar, thumbnail size, badges, filmstrip, Edit-menu selection rules |
| 6 | Culling keys & cull operations | P/X/U, ratings, labels, auto-advance, B, reject sweep, burst pick, stacks |
| 7 | Loupe: navigation, zoom & pan | Zoom ladder, wheel/pinch/drag/double-click, arrows, paging, readout, badges |
| 8 | Viewing instruments on the loupe | I, J, ⇧F peaking, [ ] holds, L lights out, ⌘B assessment, HDR preview |
| 9 | Compare, Survey & Before/After | C, N, synced zoom, badges, \\ Y ⇧Y ⌥Y, split divider |
| 10 | Workspaces, panels & layout | Rail, ⌘1–⌘5, accordion, Tab/⇧Tab/⌥⌘S, resizing, ⌘K palette, ⌘/ reference |
| 11 | Slider & wheel contract (cross-cutting) | Every slider gesture, typing, reset, nudge, wheel puck |
| 12 | White balance | Temp/Tint, preset menu, As Shot, W eyedropper |
| 13 | Tone, Zones, Auto & exposure matching | Exposure…Blacks, Pivot, Zones register, Auto, Match Total Exposures |
| 14 | Curve | Param/Point/R/G/B/Luma curves, points, splits, context menu |
| 15 | Presence & Saturation | Texture, Clarity, Dehaze, Vibrance, Saturation, Density, Protect Skin |
| 16 | Detail: sharpening & noise reduction | Capture sharpening, Sharpening, Noise Reduction (Off/Classic/AI) |
| 17 | Colour: mixer, point colour, B&W | Band picker, ring handles, swatches, B&W mix |
| 18 | Grading | Zone strip, wheel, Blending/Balance, Colour balance, Printer Lights, Primaries |
| 19 | Looks, LUT & display transform | Saved looks, apply amount, Creative LUT, Display Transform |
| 20 | Film Lab & Effects | Stocks, film sliders, vignette, grain |
| 21 | Crop & geometry | R tool, handles, rotate drag, ratios, lock, ruler, guides, flip, lens profile |
| 22 | Heal & clone | Q tool, spots, sources, `/`, brush strokes, Visualize Spots |
| 23 | Masking A: entering, list & overlay | M/door/Esc, floating Masks box, mask rows, groups, overlay keys |
| 24 | Masking B: drawn components | Brush, Linear, Radial, Outline on the canvas; brush settings & keys |
| 25 | Masking C: range/AI components, algebra & edge | Brightness/Luminosity/Colour/Colour Pick/Line, Subject/Background/People, Another Mask, Add/Subtract/Intersect, Edge zone |
| 26 | Masking D: local adjustments | Strength, Applies, Light, Colour, Curve, Grading, Point Colour, Presence & Detail |
| 27 | History, undo/redo, snapshots & reset | ⌘Z/⇧⌘Z, History card, named snapshots, Reset (⇧⌘R, footer, headers) |
| 28 | Copy/paste, sync, presets & looks transfer | ⌘C/⌘V, subsets, Sync, Paste from Previous, Copy/Paste Look, Develop Presets |
| 29 | Histogram, scopes & raw truth | H, S, ⇧H, zone drag, clipping triangles, readout space |
| 30 | Deliver: soft proof & export | ⇧S proof section, Export sheet, recipes, naming, metadata, watermark, ⌥⇧⌘E |

Cross-cutting "slow" testing is part of every area (§0.6).

---

## 1. Launch, open & library housekeeping

**Files**: `App/LumenApp.swift` (WindowGroup, `LumenAppDelegate`, `.dropDestination`),
`App/ContentView.swift` (`EmptyState`), `App/AppState.swift` (`chooseFolder`, `openSources`,
`reopenLastFolder`, `openCatalog`), `App/CatalogService.swift`, `App/AppStateOriginalRelink.swift`,
`App/LumenEmptyState.swift`, `Core/Catalog/*` (`CatalogStore.recoverIfNeeded`, `BlobStore`),
`Core/XMP/*`, `Core/Library/PhotoFormats.swift`, `Core/Relink/*`.

**Controls**
- Empty state: headline "Open photographs, or a folder of them", button **Open…**.
- File ▸ Open… ⌘O (NSOpenPanel; files or folder). Drag files/folders anywhere on the window.
- Finder "Open With Lumen" / launch-with-files (delegate `launchOpens`) beats reopen.
- Auto-reopen of the last folder at launch (silent no-op if the bookmark is gone).
- File ▸ Relink Missing Original… (disabled without catalog, while exporting/scanning/relinking).
- File ▸ Back Up Catalog (disabled without catalog). Backup also happens on quit.
- Status bar spinner while scanning; grid "Scanning…" empty state.
- Catalog-corruption recovery notice (after-the-fact, `catalogStatus`).

**Journeys**
1. Cold first launch (no prior folder) → Open… → pick a RAW folder. *Correct:* empty state then
   grid fills progressively; status bar "N photos"; thumbnails appear without the UI freezing;
   first photo selectable within ~1 s.
2. Quit with a folder open, relaunch. *Correct:* same folder reopens; last culling decisions
   (including those made in the final 2 s before quit) are present in the grid badges and the
   `.xmp` files.
3. Drag 3 individual JPEG files onto the loupe while another folder is open. *Correct:* the
   three open (window-wide drop works); nothing copied/moved on disk.
4. Drag a second folder in while the first is scanning. *Correct:* first scan is abandoned
   cleanly; undo stack cleared; no photos of folder 1 left in folder 2's grid.
5. Open an empty folder; a folder with only `.txt`; a folder of 2,000+ files; a nested folder
   tree (recursive scan). *Correct:* sensible empty state; nested photos appear; two
   `DSC_0001.NEF` in different subfolders are two rows with independent edits.
6. Open a folder that already has Adobe XMP sidecars, press `3` on one photo. *Correct:* the
   `.xmp` keeps every `crs:` field, keywords, label and capture date; only Lumen's own fields
   change (XMPMerge). Diff the file before/after.
7. RAW+JPEG with same basename: edit the RAW, then the JPEG. *Correct:* two sidecars, neither
   overwrites the other.
8. Move/rename an original on disk while Lumen is closed, relaunch, File ▸ Relink Missing
   Original…. *Correct:* the photo shows as missing before; after relink its edits, rating and
   snapshots are intact and the loupe renders.
9. Back Up Catalog twice. *Correct:* status message confirms; a dated backup appears beside the
   catalog with brush blobs included.
10. Corrupt the catalog file (copy garbage in) while closed, relaunch. *Correct:* a notice that
    the catalog was restored from backup; the damaged file set aside, not deleted.
11. Open a corrupt/truncated RAW. *Correct:* the grid shows it with a fallback/“Can't read”
    state; the app does not crash; neighbours still page.
12. Very large (≥45 MP) and very small (≤1 MP) files: open each in the loupe. *Correct:* both
    render; small file's 1:1 is not upscaled blur labelled as 1:1.

**Cross-area risks**: folder switch mid-export (Area 30), mid-ingest (Area 2), mid-edit (undo
must not write into the previous folder's sidecars — previously a bug); relink while a drag
gesture is in flight.

**Known**: catalog backups accumulate forever (no retention); a malformed current recipe
refuses the whole scoped source rather than one photo (CURRENT-STATE §2); preview/artifact
cache unwired (thumbnails re-decode embedded JPEGs every launch); a quiet updater check fires
~3 s after launch (tested under Area 10).

---

## 2. Ingest from card

**Files**: `App/IngestSheet.swift`, `App/AppStateOperationReports.swift`,
`Core/Ingest/{IngestPlan,VerifiedCopy,RenameTemplate,IngestDigest}.swift`.

**Controls** (sheet titled **Ingest**; File ▸ Ingest from Card… ⇧⌘I; empty-state text names ⇧⌘I)
- **Close** (Esc). Source menu "Choose a card or folder": mounted volumes (sdcard glyph),
  "No mounted volumes found", **Rescan volumes**, **Choose Folder…**. "Files" list/preview.
- **Destinations**: primary path + **Choose…**; toggle **Backup copy** + **Choose…**.
- **Naming**: Job name field (placeholder `feeds {job}`), Folder template (`{year}/{date} {job}`),
  toggle **Rename files**, rename template (`{date}-{seq:4}-{orig}`), inline validation error +
  **Rewrite {seqN} as {seq:N}** repair button.
- **Verify**: **Verify every copy** (xxHash64 read-back), **Eject when done** (only once all
  verify).
- Footer: progress caption, **Stop** / "Stopping…", status line, readiness summary,
  **Recent results** popover (Reveal saved report), **Ingest** (default button).

**Journeys**
1. Card with 200 RAWs → primary + backup on two volumes → Verify on → Ingest. *Correct:*
   determinate progress; every file present on both destinations with identical bytes;
   source untouched; result report saved and revealable; Eject offered only if all verified.
2. Type `{date}-{seq4}-{orig}` into rename. *Correct:* inline error; repair button rewrites to
   `{seq:4}`; preview updates live. **[code≠doc]** header says the sheet *starts* on the
   broken `{seq4}` default to show the repair; the placeholder shows `{seq:4}` — record which
   the field actually contains on open.
3. Stop mid-copy. *Correct:* finishes the current frame, stops; report lists exactly what was
   copied; no partial file left looking complete.
4. Destination = same folder as source; destination full; destination unplugged mid-copy;
   backup on the same volume as primary. *Correct:* refused or clear error; never silently
   "verified".
5. Duplicate names across two cards into one job; re-run the same ingest. *Correct:* no
   overwrite; collisions handled; second run doesn't double-copy silently.
6. Press X/P while the sheet is up. *Correct:* nothing happens to the photo behind.
7. Ingest into a folder, then open it in Lumen. *Correct:* catalog picks up the job; `{job}`
   searchable.

**Known**: real disconnected/full/removable volumes and per-file crash checkpoints not
qualified (CURRENT-STATE); BUILDING's "copies nothing" is stale.

---

## 3. Sources sidebar

**Files**: `App/ContentView.swift` (`Sidebar`, `SidebarVerb`, `sourceRow`),
`App/LumenControls.swift` (`SidebarRenameField`, `SidebarEntryField`), `App/AppState.swift`
(albums, smart albums, keywords, stacks), `App/AppStateCullTargets.swift`,
`Core/Catalog/CollectionQueryScope.swift`, `Core/Library/KeywordPath.swift`.

**Controls**
- **Library** header (flag glyph). Folder header: title/subtitle, open button ("Open
  photographs, or a different folder"), click → folder menu (Recent folders ▸, **Open Folder…
  (⌘O)**, **Show in Finder**), right-click context menu: **Reveal in Finder**, **Copy Path**,
  **Open…**.
- Source rows with counts: **All photos**, **Picked**, **Unflagged**, **Rejected**.
- **Albums** section: row "Choose folder…"/"Whole folder"/"Return to folder"; **Save Filter as
  Smart Album** (NSAlert "Save Smart Album" with scope); **New album** field; per-album row
  (click = show album; target album marked); manual album context menu: **Make Target
  Album**, **Remove Selection from <name>**, **Rename…**, **Delete Album…** (inline
  "Delete “x”?" **Keep** / **Delete**); smart album context menu: **Change Scope…**,
  **Update to Current Filter** (disabled without active filter), **Rename…**, **Delete Smart
  Album…**.
- **Keywords** section (collapsible): **Add keyword** field (⇧⌘K focuses it and shows the
  sidebar), keyword chips with × "Remove <word> from the selection", chip context menu **Add
  Synonym…** → "Synonym for …" field. Hierarchical keywords (`KeywordPath`).
- **Stack** section: "N frames", **Expand Stack/Collapse Stack**, **Promote to Pick**,
  **Unstack** (⇧⌘G); empty "No stacks yet. Select two or more frames and stack them."
- ⌥⌘S hides/shows the whole sidebar (removes it from the view tree).

**Journeys**
1. Create album "Selects", make it target, press B on 5 photos in the grid. *Correct:* status
   "Added 5 photo(s)"; album count 5; B with no target → "No target album yet — make one in the
   sidebar first".
2. Rename album inline (Return commits, Esc cancels); delete album → photos remain on disk.
3. Set a filter (3★+ picks), Save Filter as Smart Album, change rating of a member. *Correct:*
   smart album count updates live; Update to Current Filter disabled when no filter.
4. Keyword 10 photos with "travel/japan/kyoto" via ⇧⌘K while sidebar hidden. *Correct:* sidebar
   reappears, cursor in field; keyword chips on each; searchable in filter bar; XMP keywords.
5. Add synonym; remove a keyword chip from a multi-selection where only some have it.
6. Stack 6 burst frames ⌘G, collapse, promote frame 4, unstack ⇧⌘G — with the sidebar hidden.
   *Correct:* chords work with sidebar hidden (they are Scene menu items now); collapsed stack
   shows promoted frame in grid.
7. Click Picked / Unflagged / Rejected rows then flag photos. *Correct:* lists update; current
   photo leaving the filter doesn't strand the loupe on an invisible photo without notice.
8. Sidebar at min width (190) with a 60-char album name. *Correct:* truncates, no overlap.

**Cross-area**: B vs ⌘B (assessment) vs bare-B in masking; keyword field focus must swallow all
bare keys (typing "pxu" must not cull); filter + album intersect.

**Known**: catalog-wide paging and memory for broad smart sources not qualified; no
drag-reorder in albums ("Album order" is add order).

---

## 4. Filter bar, sort & status bar

**Files**: `App/FilterBar.swift`, `App/ContentView.swift` (`StatusBar`), `App/CullCommands.swift`
(Library menu), `Core/Library/{LibraryFilter,FilterShortcuts,LibraryQueryPacing}.swift`,
`App/AppState.swift` (`SortOrder`, `toggleFiltersEnabled`, `toggleFilterShortcut`).

**Controls**
- Text filter field (searches filename, ext, camera, lens, job, keywords via FTS) with ×
  clear.
- **Filter** button → popover groups: **Flag** (chips Pick, Reject, Unflagged, with counts),
  **Rating** (≥ stars 1–5 with counts, click again to clear), **Label** (6 colours +
  **Unlabelled**), **File** (**RAW only**, **Edited/Untouched/Any** chip — only when catalog
  query live), **Metadata** (only when live): menu with Camera, Lens, ISO bands (≤ 400,
  401–1600, 1601–6400, ≥ 6401), Keyword, Stacks (All frames / Collapsed stacks / Unstacked
  only), Culling evidence (**Soft focus**, **Eyes closed**), Bursts (Any / In a burst / Not in
  a burst); **All/Any** match chip; sentence describing the filter.
- **Clear** button (only when a filter is active; tooltip "⌘\\").
- Sort menu: Capture time, Added order, Edit time, Rating, Flag, Label, File name, File type,
  Aspect ratio, Album order, Sharpness score, Aesthetic score (unavailable); direction button.
- **Auto-advance** toggle (also `A`).
- Thumbnail size slider (96–512, `[`/`]` in grid, ⌘=/⌘− in grid).
- Library menu: ⌘L filters on/off keeping them, ⌥⌘P/⌥⌘U/⌥⌘X, ⌃⌘1…⌃⌘5 (toggle on second press).
- Status bar: status message, filter sentence (tooltip), "N photos" / "X of N", "Exporting
  NN%"/"Stopping — finishing this file", "N selected", filmstrip toggle button.

**Journeys**
1. ⌥⌘P then ⌃⌘3 then ⌘L twice. *Correct:* shows picks ≥3★; ⌘L hides filter then restores
   the same criteria; status sentence and count agree with the grid.
2. Filter to nothing. *Correct:* grid says "No photos match this filter" + "The photographs are
   still there — the filter is hiding them." + **Clear Filter** button.
3. Type in the text field: "p", "x", "1". *Correct:* no culling happens; ⌘A selects text in
   the field (not photos); ⌘C/⌘V copy text, not settings.
4. Open the Filter popover and press X. *Correct:* photo is NOT rejected.
5. Sort by Sharpness score on a fresh folder (scores computing in background). *Correct:*
   order stable while scores arrive or clearly marked; no jumping selection.
6. Reject the current photo while "Show Unflagged Only" is on with auto-advance. *Correct:*
   photo leaves the view, selection lands on the next visible, no blank loupe.
7. 2,000-photo folder: type quickly in the search box. *Correct:* no keystroke lag (J1-05 says
   no debounce — possibly known).
8. Metadata menu before EXIF has been read: "No camera has been read yet".

**Known**: aesthetic sort not built; culling evidence thresholds uncalibrated; J1-05.

---

## 5. Grid, filmstrip & selection

**Files**: `App/GridView.swift` (`handleCellClick`, `selectFromClick`, `PhotoCell`),
`App/FilmstripView.swift`, `App/ThumbnailLoader.swift`, `App/AppStateCullSelection.swift`,
`App/CullCommands.swift`, `Core/Interaction/{SelectionMembershipIndex,ArrowNavigation,ThumbnailLadder,RollCursor}.swift`,
`Core/Library/CullSelection.swift`.

**Controls**
- Cell: click = select; ⌘-click = toggle membership; ⇧-click = extend; double-click (no
  modifier) = open loupe; star buttons on cell (click = rate, click current = clear); flag/label
  badges; attention dot (soft focus / eyes closed; tooltip explains).
- Arrows ←/→ prev/next, ↑/↓ row; Space hold = peek loupe; `[`/`]` ±24 pt; ⌘=/⌘− ±size.
- Filmstrip (F, status-bar film button, View ▸ Filmstrip): grid button (back to grid), three
  height steps (72/96/128), same click grammar; ⇧Tab hides it with the rest.
- Edit menu selection: Select All ⌘A, Select None ⌘D, Invert Selection, Select Picks ⌥⌘A,
  Select Rejects, Select Unflagged, Select by Rating ▸, Deselect Unpicked ⌥⇧⌘D.

**Journeys**
1. Double-click a cell not centred on screen. *Correct:* opens that exact photo (the recentring
   jump between clicks was a past bug).
2. Click, ⇧-click 20 cells later, ⌘-click to remove 3. *Correct:* "17 selected" in status bar.
3. Two fast ⌘-clicks on one cell. *Correct:* toggles twice, does NOT open the loupe.
4. Hold → for 5 s in the grid on 2,000 photos. *Correct:* selection moves every repeat, grid
   follows, no hitch; cull paging <50 ms per step.
5. Hold → in the loupe with filmstrip visible. *Correct:* filmstrip lands centred on the
   selected frame (not one behind).
6. `[` repeatedly to 96 then once more; `]` to 512 then once more. *Correct:* clamps.
7. Space-hold from grid, then press ⌘ while holding, release Space. *Correct:* returns to grid
   (a previous stuck-hold bug).
8. Scroll the grid fast at 512 pt and 96 pt. *Correct:* no blank cells lingering, no hitches.
9. Portrait and landscape thumbnails mixed; rotated (orientation flag) RAWs. *Correct:*
   thumbnails upright, cells don't overflow.

**Known**: preview cache unwired (re-decode on launch).

---

## 6. Culling keys & cull operations

**Files**: `App/Keymap.swift`, `App/AppState.swift` (`setFlag/setRating/setLabel`,
`advanceIfNeeded`), `App/AppStateCullTargets.swift`, `App/AppStateCullSelection.swift`
(`pickSharpestInEachBurst`), `App/AppStateRejectSweep.swift`, `App/CullBadgeStrip.swift`,
`Core/Interaction/{CullAdvance,CullTargeting}.swift`,
`Core/Library/{RejectSweep,BurstGrouping,BurstPick,CullingAssist,CullingEncoding}.swift`.

**Controls**
- P pick · X reject · U unflag · ⌫ reject · 1–5 rate · 0 clear · 6 red · 7 yellow · 8 green ·
  9 blue · `-` purple (not in loupe) · each toggles off if already set.
- ⇧ + any decision key (⇧P, ⇧X, ⇧U, ⇧0–9, ⇧-) or Caps Lock = decide and advance even with
  auto-advance off. `A` toggles auto-advance (default **on**).
- Targeting: in grid P/X/U/ratings apply to the **whole selection**; in loupe/compare/survey
  to the **active frame only** (`KeyGrammar` "Culling" rows).
- B add selection to target album.
- Photo menu: Pick, Reject, Unflag, Rating 1–5, Clear Rating.
- Photo ▸ **Move Rejected Photos…** ⌘⌫ → NSAlert "Move N rejected …" with **Move to
  _Rejected** / **Move to Trash** / **Cancel**; in a text field ⌘⌫ stays "delete to line start".
- Photo ▸ **Remove Rejected from Catalog…** → alert **Remove from Catalog** / **Cancel**.
- Library ▸ **Pick Sharpest in Each Burst…** → alert **Pick N** / **Pick N and Reject M
  Others** / **Cancel**; messages "No measured bursts here…" / "Every burst here already has
  a decision".
- Photo ▸ **Stack Bursts in Folder**, ⌘G, ⇧⌘G.
- Compare/Survey pane badge strip: clickable Pick, Reject, stars (display-only label chip).

**Journeys**
1. Cull 300 frames at key-repeat: hold P with auto-advance on. *Correct:* each frame picked
   then advanced; <50 ms per frame; no skipped or double-decided frames; XMP written async.
2. Auto-advance off, hold P for 2 s. *Correct:* exactly one toggle (repeat ignored).
3. Auto-advance off, ⇧P, ⇧3, Caps Lock + X. *Correct:* each decides and advances.
4. Press 3 then 3 again on the same photo (auto-advance off). *Correct:* rating set then
   cleared. A rating keystroke must not destroy a colour label and vice versa (past bug).
5. Cull 20 decisions then ⌘Z ×20. *Correct:* each decision undone one at a time; ⌘Z never
   undoes an unrelated develop edit; menu label names the cull step.
6. Select 30 in grid, press 5. *Correct:* all 30 rated 5; in loupe with 30 selected, press 5:
   only the active frame rated.
7. Reject sweep with 0 rejects; with rejects in two subfolders; Move to Trash then check
   Finder; ⌘⌫ while typing in the search box.
8. Pick Sharpest in Each Burst on a burst folder before culling assists finish. *Correct:*
   sensible message; after they finish, the chosen frame matches the highest sharpness score.
9. Press ⌫ in the loupe while masking. *Correct:* deletes the mask, does NOT reject (F1-01).
10. Cull while the develop column is showing a slider focused. *Correct:* arrows nudge the
    slider (not page); P still flags.

**Known**: culling-evidence thresholds uncalibrated; ⌘Z for library operations shares the
single session stack.

---

## 7. Loupe: navigation, zoom & pan

**Files**: `App/LoupeView.swift` (`LoupeZoom`, `LoupeViewport`, gestures ~1440–1620,
2660–2760), `App/LumenViewerScroll.swift`, `App/ShortcutParityKeys.swift` (`zoomChord`,
`pageChord`), `App/ViewerOverlays.swift` (`ReadoutHUD`, `PixelSampler`), `App/PreviewStore.swift`,
`App/RenderCoordinator.swift`, `App/RenderRequest.swift`,
`Core/Interaction/{ZoomLadder,ContinuousZoom,ViewerScroll,ViewerGestureGate,ZoomRegion,ZoomLayoutHold,DraftLadder,DraftResolution,DecodeWarming,DecodeResidency,FrameDelivery,PreviousPhoto}.swift`.

**Controls**
- E / double-click cell / Space-hold to enter; G / Esc to leave.
- Zoom: Z (fit↔1:1 at cursor), Space (fit↔1:1 at cursor), `+`/`=` in, `-` out, ⌘=/⌘− (View
  menu), double-click on image (fit↔1:1 at click point; gated off while crop armed, masking or
  picking), trackpad pinch (continuous, snaps to fit below 0.35), mouse wheel (non-precise) =
  zoom, ⌥-scroll = zoom, max 16×, ladder fit / 1:1 / 2:1.
- Pan: drag (always pans; nothing at fit), two-finger scroll when zoomed (with momentum),
  arrow keys when zoomed.
- Paging: ←/→ when fit, ⌘←/⌘→ always (also with slider focused), View ▸ Previous/Next Photo.
- **Click does nothing** at fit (click-to-zoom removed) **[differs from Compare, where a click
  toggles zoom — report the inconsistency if it confuses]**.
- Hover readout pill (pixel values under cursor, in the readout space).
- Badges: "EMBEDDED PREVIEW", "BEFORE", "MASK · <name>", "CLIPPING · <MODE>", "<zoom> · PROXY
  W×H", reduced-render labels.

**Journeys**
1. Open a 45 MP RAW. *Correct:* embedded preview within ~100 ms, then the rendered frame with no
   visible brightness pop; "EMBEDDED PREVIEW" badge disappears when rendered.
2. Z over an eye at the corner of the frame. *Correct:* 1:1 centred on the eye, not window
   centre. Space, double-click and pinch also anchor on the pointer.
3. `-` repeatedly from 2:1. *Correct:* 2:1 → 1:1 → … → snaps to Fit (not 0.125).
4. Zoom 1:1, page with ⌘→ ten times fast. *Correct:* each new photo opens at fit (or a
   documented rule); no stale pan; draft then sharp.
5. Zoom with mouse wheel, then trackpad pinch out past fit. *Correct:* lands exactly on fit.
6. Zoomed, hold ← for 2 s. *Correct:* pans, does not page.
7. Drag a slider while zoomed 1:1, release. *Correct:* draft ≤16.7 ms, sharp ≤200 ms; zoom/pan
   unchanged.
8. Resize the window / toggle Tab while zoomed. *Correct:* pan stays clamped, the same point
   stays under the centre (or documented).
9. Portrait 1:1 vs landscape 1:1; a JPEG; a 600 px file at 2:1. *Correct:* "1:1" label honest
   (proxy size shown).
10. Rapidly alternate E/G 20 times. *Correct:* ≤100 ms each, no flash of the previous photo.

**Cross-area**: zoom while masking (canvas must stay registered with the picture at every zoom
and pan); zoom while crop armed (crop canvas is fit-only — wheel/pinch must not invisibly
change zoom); zoom with before/after split; zoom with Heal tool; inspection holds while zoomed.

**Known**: loupe is SwiftUI image view, not Metal/EDR; previews cap at 4096 px so "1:1" on
45 MP is a half-resolution render.

---

## 8. Viewing instruments on the loupe

**Files**: `App/ShortcutParityKeys.swift` (`CaptureInfoOverlay`, `toggleClippingOverlay`),
`App/ViewerOverlays.swift` (`ClippingOverlayView`, `FocusPeakingOverlayView`,
`FocusPeakingHUD`, `FocusPeakingSettings`), `App/InspectionGain.swift`, `App/EDRViewport.swift`,
`App/AppState.swift` (`cycleLightsOut`, `toggleAssessmentMode`, `surroundColor`,
`chromeOpacity/chromeHidden`), `Core/Interaction/{InspectionHolds,ViewingConditions,EDRPreview}.swift`,
`Core/Library/CaptureInfo.swift`.

**Controls**
- **I** cycles info overlay: off → exposure line → camera & lens → off (top-left badges).
- **J** clipping overlay (highlights red, shadows blue); J with any overlay on (incl. a locked
  histogram triangle) turns it off. Status message announces state.
- **⇧F** focus peaking; HUD: colour button (Green/Red/White), sensitivity (Low/Normal/Fine
  detail), ✕ close "(⇧F)"; caption "preview — not a pixel-level read". Settings persist across
  toggles.
- **[** / **]** hold: shadow boost / highlight inspect (3 EV), badge at bottom; never writes the
  recipe.
- **L** lights out: normal → dim chrome → black-out (chrome removed at "out").
- **⌘B** assessment surround (ISO 12646 mid-grey field; wins over black-out).
- View ▸ **HDR Preview** (no key; loupe badge shows state; display-only, opt-in).

**Journeys**
1. Hold `[`, press ⇧, release `[`. *Correct:* hold ends, badge gone (past stuck-hold bug); then
   `]` hold works.
2. Hold `[` and press ⌘ (any chord), release. *Correct:* hold ends.
3. J on a blown sky. *Correct:* red where clipped; matches the histogram triangle percentages.
4. L ×3 then ⌘B. *Correct:* normal→dim→out→normal; ⌘B paints mid-grey around the photo in loupe
   AND compare panes; filter bar/column dimmed not removed in assessment.
5. ⇧F, change colour and sensitivity, ⇧F off/on, next photo. *Correct:* settings persist.
6. HDR Preview on an SDR display and on an EDR display. *Correct:* badge states headroom; SDR
   instruments (scopes, readout) unchanged.
7. I cycle on a JPEG with no EXIF. *Correct:* filename only, no crash.

**Known**: peaking is a preview, not pixel-accurate; HDR viewport incomplete (no slew).

---

## 9. Compare, Survey & Before/After

**Files**: `App/CompareView.swift`, `App/CullBadgeStrip.swift`, `App/ViewerOverlays.swift`
(`BeforeAfterMode`, `BeforeAfterSplit`, `BeforeAfterPair`, `SplitScissor`),
`App/LoupeView.swift` (`beforeModel`, `beforeRecipe`), `Core/Recipe/RecipeReset.swift`
(`Recipe.beforeRendition`).

**Controls**
- **C** compare 2-up (toggle; second C returns to **grid**, not loupe), **N** survey N-up
  (toggle → grid). Populated from the selection.
- Compare: click (travel <3 pt) toggles zoom at the point, synced across both panes; drag pans
  (synced, image-normalised); double-click a pane = make it the active frame (cursor); ←/→ move
  the cursor within the compared set; badge zoom label; filenames; "EMBEDDED PREVIEW"; "Can't
  read <file>".
- Survey: click a tile = active; ✕ "Remove <file> from the survey"; `A` toggles advance to next
  compared frame.
- Badge strip per pane: Pick, Reject, ★1–5 (clickable), label chip.
- Develop column visible in compare (not survey).
- Before/after: **\\** full-frame flip (badge "BEFORE"), **Y** side-by-side, **⇧Y** split with
  draggable divider (BEFORE/AFTER badges), **⌥Y** top/bottom; same key again = off; enabling
  any switches to loupe. "Before" = file as imported, framed like the edit (crop/straighten/flip
  travel; lens profile does not).

**Journeys**
1. Select 2 portrait + landscape frames, C, zoom on one. *Correct:* same image point centred in
   both despite different pixel sizes.
2. Select 5, C, press → 4 times. *Correct:* panes follow the cursor (not stuck on first two).
3. C with 1 photo selected; N with 1; N with 40. *Correct:* defined behaviour, no crash, tiles
   ~square.
4. In survey, X on the active tile with auto-advance. *Correct:* only that frame rejected,
   cursor moves to next compared frame.
5. Edit exposure +2, crop 1:1, press \\. *Correct:* before is unedited but cropped 1:1 (same
   framing), no squash.
6. ⇧Y, drag divider to extremes, zoom 1:1, pan. *Correct:* both halves aligned across the
   divider at every zoom; `[` hold applies to both halves.
7. Y then drag Exposure. *Correct:* only After updates; ≤ one frame.
8. ⇧Y then M (masking) or R (crop). *Correct:* defined (before mode stays or turns off) —
   report confusing combinations.
9. Compare with assessment surround: both panes and the empty half follow the surround.

**Known**: compare panes do not soft-proof; ⇧R reference view not built; before-state is not
pinnable (docs/12 wants Original/Import/Snapshot choice).

---

## 10. Workspaces, panels & layout

**Files**: `App/DevelopColumn.swift` (`WorkspaceRail`, `MaskingReturnBar`, `WorkspaceSections`,
`WorkspaceSectionView`, `ExportRecipesSection`), `App/DevelopPanel.swift` (header, footer,
`DevelopSection`, `DevelopDisclosure`, `DevelopNote`), `App/WorkspaceEntry.swift`
(`enter`, `jump`, `toggleMasking`, `toggleCropTool`), `App/PanelLayout.swift`,
`App/PanelResizeDrag.swift`, `App/ShortcutParityKeys.swift` (`panelChord`),
`App/ControlPalette.swift`, `App/ContentView.swift` (`KeyReferenceSheet`, column resizer),
`App/LumenMenu.swift`, `App/LumenHover.swift`, `App/LumenFocus.swift`, `App/LatencyHUD.swift`,
`App/AppUpdater.swift`, `App/UpdateFileWork.swift`, `Core/Interaction/{Workspace,WorkspaceModification,KeyGrammar,ControlIndex,ShortcutParity}.swift`.

**Controls**
- Rail: **Cull** (grid, no column), **Develop** (White Balance, Tone[+Zones], Curve, Presence
  [+Saturation], Detail), **Crop** (Crop, Lens), **Grade** (Looks [+LUT, Display Transform],
  Colour, Grading, Film Lab, Effects), **Deliver** (Soft Proof, Export Recipes), **Masks**
  door. Tooltips name ⌘1–⌘5. Same as View menu ⌘1–⌘5.
- Keys D (→ Detail section from anywhere), M, R, Q.
- Section accordion (§0.5), History card.
- Develop header: filename; "N photos" badge when multiple targets.
- Footer: **Auto**, **Reset**, **Undo**, **Redo**, **Copy**, **Paste**, **Copy Look**,
  **Paste Look**. Empty column: "Select a photo to develop".
- Tab: hide/show sidebar + develop column; ⇧Tab: all panels incl. filmstrip; status
  "Panels partly hidden — Tab or ⇧Tab brings them back"/"Panels hidden — ⇧Tab brings them back".
  View ▸ Hide/Show Panels — Tab. ⌥⌘S sidebar.
- Column resize: drag the divider left of the column (320–520; width persisted on release).
- **⌘K** palette: field "Go to a control, or run a command…", ↑/↓, Return, Esc, click scrim to
  dismiss; rows "Control — Workspace · Section"; command **Reset** (⇧⌘R; "No photo
  selected"/"Already as imported"); **Apply Preset: <name>** rows; "No control or command by
  that name". Aliases (e.g. "wb", "kelvin", "hsl", "lut", "nr", "horizon").
- **⌘/** / Help ▸ Lumen Keyboard Reference / `?`: sheet "Keyboard" with groups Views, Culling,
  Develop, View controls, Menu commands; **Done**.
- Debug ▸ Latency HUD ⌥⌘L. App menu ▸ build stamp, **Check for Updates…** (alerts: "Updated to
  build …" **Relaunch Now**/**Later**, or error alert).

**Journeys**
1. ⌘1…⌘5 then the rail, then D, R, M, Q from the grid. *Correct:* each lands in its workspace
   with loupe shown; ⌘3/R/rail Crop all arm the crop rectangle; Cull shows grid and no column.
2. ⌥-click three headers in Grade, then plain-click one. *Correct:* ⌥ keeps others open; plain
   click solos.
3. Modify Exposure, hover Tone header, click Reset. *Correct:* Tone (incl. Zones) resets, other
   sections' dots unchanged; Detail header Reset with ISO100 + ISO12800 selected resets each to
   its own ISO profile.
4. Tab, ⇧Tab, Tab while a slider is focused. *Correct:* Tab ignored while slider focused; repeat
   ignored; status messages as above.
5. Drag column 320→520 during a render. *Correct:* only slider tracks widen; labels never
   truncate (G1 group possibly known).
6. ⌘K "kel" ↵. *Correct:* jumps to Develop › White Balance, section expanded, Temp visible.
   ⌘K while Export sheet is open → palette appears above (by design).
7. ⌘/ and compare the sheet with actual behaviour of every key (this sheet is the
   contract; KeyGrammarTests enforce it textually only).
8. Window at 1180×720 with all panels: nothing clipped; at 4K full screen.
9. Check for Updates… offline, and with no newer build. *Correct:* clear alert, no hang.

**Known**: Export Recipes section is only a note + **Open Export…**; masking door un-lights the
five tabs by design; no Preferences window.

---

## 11. Slider & wheel contract (cross-cutting)

**Files**: `App/LumenControls.swift` (`LumenSlider` ~437–1480, `LumenColorWheel` ~1981,
`LumenSegmented`, `LumenToggleRow`), `App/LumenScrollNudge.swift`, `App/LumenFocus.swift`,
`App/LumenBehaviourGlyph.swift`, `App/RenderRequest.swift` (gesture sink),
`Core/Interaction/{SliderDrag,SliderEntry,SliderAccessibility,WheelDrag,HistoryCoalescing,EventRate,RefineBudget}.swift`,
inventory `Tests/LumenAppTests/LayoutMetricSupport.swift` (152 `SliderSpec` rows).

**Controls**: §0.4 for sliders. Wheel (`LumenColorWheel`): drag puck (press picks up where it
is, ⇧ fine), double-click resets, lightness bar (captioned "Luminance" on the 150 pt grade
wheel).

**Journeys** (run on at least: Temp (reciprocal scale), Exposure (±5 soft, ±10 hard),
Contrast, a 0–100 slider, Ramp shape (log), Display-transform Contrast (log 0.1–10), Zones
slider, a mask slider, an export slider)
1. Drag past the soft end. *Correct:* pins at soft limit. Type a value beyond soft within hard
   (e.g. Exposure 8). *Correct:* accepted; thumb pinned at end; readout 8.00.
2. Type `+= 0.3`, `* 2`, `/ 0`, `abc`, `-0`, `1e9`. *Correct:* arithmetic works; invalid input
   rejected without changing value; no NaN/∞ in recipe.
3. Double-click label; double-click track. *Correct:* reset to default (Temp/Tint: As Shot, not
   5500 K).
4. Click row, ←×5, ⇧→, ↑, ↓, Esc, Esc. *Correct:* ±1/±10 steps; first Esc drops focus, second
   goes to grid.
5. ⌥-scroll 3 clicks over Clarity; plain scroll over it. *Correct:* +3 (one undo step after
   silence); plain scroll scrolls the column.
6. Grab thumb, ⇧ mid-drag, release ⇧ mid-drag. *Correct:* no jump at either transition.
7. Drag Exposure and switch photo with ⌘→ mid-drag. *Correct:* the edit stays on the original
   photo; focus/readout fields don't follow to the next frame.
8. Drag, ⌘Z mid-drag (other hand). *Correct:* defined; no corrupt history (gesture epoch).
9. Rapid alternate drags on two sliders within 1.2 s. *Correct:* two undo steps (one per
   control).
10. Drag the grade wheel puck in circles for 10 s, ⌘Z once. *Correct:* one step (docs/38).
11. Haptic crossing default on a Force Touch trackpad (manual note if driver can't sense).
12. Measure: slider drag → draft ≤16.7 ms; settle ≤200 ms; with 1, 10, 50 photos selected.

**Known**: not built: ⌘-double-click auto, ⇧⌥-drag to hard limit, hold-to-sweep; three slider
precision-floor expected failures in CI (CURRENT-STATE).

---

## 12. White balance

**Files**: `App/BasicPanel.swift` (`whiteBalanceRows`, `presetRow`, `applyAsShot`),
`App/ViewerOverlays.swift` (`NeutralPickerOverlay`), `App/AppState.swift` (`beginPick`,
`cancelPick`, `pickTarget`), `Core/Engine/WhiteBalanceEngine.swift`, `Core/Color/DNGTemperature.swift`.

**Controls**
- Preset menu: **As Shot** (detail shows as-shot K), Daylight 5500/+10, Cloudy 6500/+10, Shade
  7500/+10, Tungsten 2850/0, Fluorescent 3800/+21, Flash 5500/0; title reads **Custom** after
  any manual move. No Auto entry by design.
- Eyedropper button (and **W**, View ▸ White Balance Picker): click a neutral; press again or
  Esc cancels.
- **Temp** 2000–50000 K, reciprocal (mired) scale, step 50, default = as-shot, track blue→amber.
- **Tint** soft −150…150, hard −300…300, step 1, default = as-shot tint; caption "Magenta is
  bounded by physics at +N for K — the render uses that value." when bounded.
- Rows disabled while as-shot neutral is unknown (tooltip "Reading the file's as-shot
  neutral…"). Rendered files: relative to 5500 K reference.

**Journeys**
1. W, click a grey card; W, click a saturated red. *Correct:* grey → neutral; red → large,
   bounded move, no inverted picture.
2. Drag Temp across 2000→50000 slowly. *Correct:* even perceived change across travel; nothing
   "dead above 15 000".
3. Pick Tungsten, then double-click Temp label. *Correct:* back to As Shot (Temp/Tint nil);
   preset reads As Shot.
4. W armed then switch photo / press Esc / enter masking. *Correct:* pick cancelled, prompt
   gone.
5. Type Temp 3217 exactly. *Correct:* 3217 accepted (typing not snapped to 50).
6. Tint +150 on a warm (3000 K) frame. *Correct:* caption appears.
7. JPEG: As Shot detail absent; help says relative to delivery.
8. WB eyedropper while zoomed 1:1 and cropped. *Correct:* sample lands under cursor
   (unverified on hardware — high-value check).

**Known**: eyedropper click accuracy unverified by a human; mask Temp axis differs (Area 26).

---

## 13. Tone, Zones, Auto & exposure matching

**Files**: `App/BasicPanel.swift` (`toneRows`), `App/ZonesPanel.swift` (`ZonePivotStrip`),
`App/AppStateActions.swift` (`applyAutoTone`), `App/AppStateMatchExposure.swift`,
`App/HistogramView.swift` (zone drag), `Core/Engine/ToneEngine.swift`,
`Core/Engine/ExposureMatch.swift`, `Core/Model/ZoneWeights.swift`.

**Controls**
- **Exposure** soft −5…5, hard −10…10, step 0.01, grey ramp track.
- **Contrast** −100…100 (ramp track); **Pivot** −4…4 stops, step 0.01.
- **Highlights**, **Shadows**, **Whites**, **Blacks** −100…100.
- **Zones** disclosure: pivot strip (drag pivots; double-click resets a pivot), sliders
  **Darks, Shadows, Midtones, Lights, Brights** and **Global**, soft −3…3, hard −5…5 stops;
  "flattened" caption when pivots collapse.
- **Auto** (footer) / Photo ▸ Auto Tone ⇧⌘A ("Analysing…", "Auto could not read those files").
- Photo ▸ Match Total Exposures ⌥⇧⌘M ("Select two or more photos — exposures are matched to the
  active one", "Reading exposure settings…").
- Tone header Reset clears six sliders + Zones.

**Journeys**
1. Exposure +3 on a backlit portrait, Highlights −100, Whites −50. *Correct:* no hard clip
   introduced by Contrast (help claims Contrast cannot clip a highlight); smooth roll-off.
2. Contrast +100 with Pivot −4 and +4. *Correct:* hinge visibly moves.
3. Zones: drag Brights pivot onto Lights pivot. *Correct:* caption; no NaN; sliders still act.
4. Auto on one, then on 20 selected. *Correct:* per-photo values; one undo step per batch;
   Auto measures the full render (presence/locals included — past bug).
5. Match Total Exposures: 5 bracketed frames, active = middle. *Correct:* others' Exposure
   offset by EV difference; status explains.
6. Histogram zone drag (Area 29) moves exactly these sliders.
7. Extreme stack: Exposure +10 typed, Blacks −100, Whites +100. *Correct:* no colour inversion,
   no banding artefacts beyond expectation; export matches loupe.

**Known**: zone wheel/sat/falloff exist in recipes but no stage reads them (not shown);
Whites/Blacks inside a mask do nothing alone (Area 26).

---

## 14. Curve

**Files**: `App/CurveEditorView.swift`, `Core/Engine/CurveStack.swift`,
`Core/Model/{CurveEditing,MonotoneCubic}.swift`, `Core/Interaction/CurveAccessibility.swift`.

**Controls**
- Channel segmented: **Param**, **Point**, **R**, **G**, **B**, **Luma**.
- Plot: click adds point; drag moves; ⌥-click deletes; right-click menu **Delete Point**
  (disabled for endpoints), **Flatten <channel>**; drag a point out of the graph deletes it;
  "N pts" readout; Reset button.
- Parametric: sliders **Highlights**, **Lights**, **Darks**, **Shadows** (−100…100); split rail
  with three draggable triangles (double-click resets one); context menu **Reset Splits**,
  **Reset Regions**; read-only curve-limiter caption.
- Toggle **Preserve Luminance**.
- Histogram backdrop in the plot; VoiceOver point actions (Move input left/right).

**Journeys**
1. S-curve on Point, then switch to Luma, R, back. *Correct:* each channel keeps its own points;
   Point shows composite handles.
2. Add 20 points rapidly; drag one past its neighbour. *Correct:* ordering preserved, curve
   monotone where promised, no inversion.
3. Drag a point out of the plot; ⌥-click an endpoint. *Correct:* interior deleted; endpoint
   not deletable.
4. Parametric extremes + split triangles to edges. *Correct:* "cannot posterize, invert, or move
   black or white" holds.
5. Preserve Luminance on/off with a strong contrast curve. *Correct:* saturation boost only when
   off.
6. Curve edit then ⌘Z ×N. *Correct:* one step per placement/drag.

---

## 15. Presence & Saturation

**Files**: `App/BasicPanel.swift` (`presenceRows`, `saturationRows`),
`Core/Image/DetailEngine.swift`, `Core/Engine/ColorEngine.swift`, `Core/Recipe/Recipe.swift`
(`densityIsLive`).

**Controls**: **Texture**, **Clarity**, **Dehaze** (−100…100, Presence header Reset);
Saturation sub-section: **Vibrance**, **Saturation** (−100…100), **Density** (0…100, default
50, **only visible when Saturation > 0**), **Protect Skin** (0…100, default 70), its own Reset.

**Journeys**
1. Saturation +40 → Density appears; Saturation 0 → Density hides (animated); value retained?
2. Saturation −100. *Correct:* true B&W; a B&W mix (Area 17) survives negative saturation.
3. Vibrance +100 on a portrait with Protect Skin 70 vs 0. *Correct:* skin holds at 70.
4. Dehaze +100 on sky. *Correct:* no blow-out (past bug); GPU vs reference may strip slightly
   more haze (known).
5. Texture +100 on fine detail at fit vs 1:1 vs export. *Correct:* consistent strength.

**Known**: Texture still 1.8×–17× weaker than its spec reference (BUILDING); Dehaze sky guard
reference-only; Density hue rotation open (B1-05).

---

## 16. Detail: sharpening & noise reduction

**Files**: `App/DetailPanel.swift`, `App/DenoiseControlAvailability.swift`,
`Core/Image/{DetailEngine,DenoiseEngine}.swift`, `Core/Image/RawDenoise/*`,
`Core/Recipe/Recipe.swift` (`ISODefaults`), `Denoise/`.

**Controls**
- **Capture Sharpening**: toggle **Capture sharpening**; "Manual"/"Measured from the file";
  **Use measured values**; **Amount** 0…150 (default = measured stand-in); rendered files:
  "Already demosaiced — no capture stage to scale".
- **Sharpening**: **Amount** 0…150 (0), **Radius** 0.5…3.0 (1.0, step 0.1), **Detail** 0…100
  (25), **Masking** 0…100 (0), **Halo Damping** 0…100 (0); rendered-file hint "No capture
  stage — try 40 / 1.0 / 25 / 0" + **Apply**.
- **Noise Reduction** disclosure: mode **Off / Classic / AI (stand-in)** (AI hidden for
  rendered files); Classic: **Luminance**, **Detail**, **Contrast**, **Colour**, **Detail**,
  **Smoothness** (defaults from ISO), **Hot Pixels** 0…100 (0); AI: **Amount** 0…100 (50);
  rendered+AI note. ISO badge.
- Detail header Reset → photo's own ISO defaults.

**Journeys**
1. ISO 12800 RAW: open Detail, check NR defaults; set Colour 100. *Correct:* chroma noise down
   without colour edges bleeding (top half was harmful — now bounded).
2. Off vs Classic vs AI. *Correct:* Off removes all NR including hot pixels.
3. Sharpening Amount 150, Masking 0 vs 100 at 1:1 and export at full size. *Correct:* export
   strength matches what was judged (resolution-scaled).
4. JPEG: AI hidden; Apply classic sharpen hint works.
5. Multi-select ISO 100 + ISO 6400, Reset Detail. *Correct:* each gets its own profile.

**Known**: capture sharpening is Apple's demosaic sharpener scaled (RL deconvolution unused);
AI denoise model not shipped; Halo Damping has no test on any path; luminance NR gives error
back near noise-floor textures.

---

## 17. Colour: mixer, point colour, B&W

**Files**: `App/ColorPanel.swift` (`MixerHueRing`, `MixerBandRibbon`, swatches),
`Core/Engine/ColorEngine.swift`, `Core/Color/Perceptual.swift`.

**Controls**
- **Colour Mixer**: band eyedropper ("Click a colour in the photograph and the band grading it
  selects itself"); **Band / All bands** segmented; 8 band swatches (Red, Orange, Yellow, Mint,
  Aqua, Azure, Purple, Magenta); hue ring with 4 draggable handles per band (core start/end,
  feather start/end) + arc reset; ribbon; caption "<Band> — centred on X° in OKLCh…"; **Hue**,
  **Saturation**, **Luminance** (−100…100); **Even out hues** 0…100.
- **Point Colour**: up to 8 swatches; eyedropper add (arms a pick), click swatch = select/
  re-sample; − remove ringed; **Hue** −60…60, **Saturation**, **Luminance** (−100…100),
  **Range** 0…100 (50), **Variance** −100…100.
- **Black & White**: toggle **Black & white treatment**; 8 band sliders (−100…100).

**Journeys**
1. Band eyedropper on blue sky → Azure selects; Luminance −60. *Correct:* sky darkens, stays
   blue; skin unaffected.
2. All bands + Hue +50. *Correct:* spread preserved; caption changes.
3. Drag ring handles to overlap/extremes, reset arc. *Correct:* clamped; reset restores wedge.
4. Point colour: add 8 swatches, try a 9th. *Correct:* disabled; Range 0 vs 100 selects
   narrowly vs widely (not whole photo — fixed B1-01).
5. B&W on, set mix, B&W off, on. *Correct:* mix retained; Reset discards it.
6. Pick armed then Esc / photo switch.

**Known**: B1-04…08 colour-science group open (ring authority, band names up to 27° off, B&W
level normalisation); Even out hues works per-pixel (flattens fine texture at 100 — stated).

---

## 18. Grading

**Files**: `App/LookPanel.swift` (`wheelsSection`, `colorBalanceDisclosure`,
`printerLightsSection`, `PrinterLightRow`, `primariesSection`, `ZoneWeightStrip`),
`Core/Engine/GradeEngine.swift`, `Core/Engine/AppliedReadout.swift`.

**Controls**
- Zone weight strip with 2 draggable pivots (Shadow/midtone, Midtone/highlight).
- Zone segmented **Shadows / Midtones / Highlights / Global** (touched zones marked); one 150 pt
  wheel (hue/sat puck + "Luminance" bar); held-luminance caption.
- **Blending** 0…100 (50); **Balance** −100…100.
- **Colour balance** disclosure: **Hue shift** −180…180, **Vibrance** −100…100, axes
  **Chroma**, **Saturation**, **Brilliance** each with **Global/Shadows/Midtones/Highlights**
  −100…100; Brilliance warning past ±20.
- **Printer Lights**: rows Master (±48 pts), Red/Cyan, Green/Mag, Blue/Yellow (±24 pts) with
  −/+ steppers (1 pt = 1/12 stop), double-click value resets; keys `,` `.` master, ⌃, ⌃. red,
  ⌥, ⌥. green, ⇧, ⇧. blue — **only while the Printer Lights rows are on screen** (attached
  shortcuts).
- **Primaries**: Red/Green/Blue Hue & Purity, Shadow Tint, Tint Purity (−100…100).

**Journeys**
1. Push Shadows wheel teal, Highlights orange; switch zones; ⌘Z. *Correct:* each wheel drag
   one step; segmented marks touched zones.
2. `.` ×12 on Master. *Correct:* +12 pts = +1 stop visible; clamps at 48.
3. Press `,` with Grading collapsed or in Develop workspace. *Correct:* does nothing (not a
   global key) — report if it silently does something else.
4. Brilliance +60. *Correct:* warning caption; highlights flatten (stated).
5. Drag strip pivots to overlap; Balance ±100.

**Known**: printer-light quarter points not built.

---

## 19. Looks, LUT & display transform

**Files**: `App/LookPanel.swift` (`savedLooksSection`, `lutSection`, `transformSection`),
`App/AppState.swift` (`applyLook`, `saveLook`, `renameLook`, `deleteLook`,
`chooseCreativeLUT`), `App/FilmDisplayTransformAvailability.swift`,
`Core/Recipe/LookSubset.swift`, `Core/Engine/{CreativeLUT,DisplayTransform}.swift`,
`Core/Color/LUT.swift`.

**Controls**
- Saved looks: "Name this look" field + **Save**/**Replace** (first press on a taken name warns
  and offers **Save as “X 2” instead**, second press replaces); **Amount** (0…100, shown only
  when looks exist); each look row: click = apply to selection at Amount; ⋯ menu **Apply**,
  **Rename** (Return/Esc), **Delete** (inline **Keep**/**Delete**; not undoable).
- **Creative LUT** header action = choose .cube (replace); LUT name; **Remove**; **Display/Log**
  segmented; **Amount** 0…100 (100).
- **Display Transform** (badge names a replacing film stock; controls disabled/30% when a stock
  replaces it): **Preset** (Neutral, Soft, Punchy, Film Base, Linear), **Contrast** 0.1…10 (log),
  **Skew** −1…1, **Hue keep** 0…100, **Black target** 0…9; each slider double-click clears the
  override.

**Journeys**
1. Save look "Warm", apply to 50 photos at 40%. *Correct:* status names 40%; stock/B&W/preset
   arrive whole; one undo step.
2. Save over existing name; rename to an existing name; empty name.
3. Load a 17³, 33³, 65³ .cube; a malformed .cube; a non-cube file. *Correct:* valid ones apply;
   invalid ones refused with a message.
4. LUT Display vs Log on the same file.
5. Load a film stock then try the transform sliders. *Correct:* disabled with badge.
6. JPEG: Looks Reset returns to Linear (its starting transform), not Neutral.

**Known**: no hover preview; no swatches.

---

## 20. Film Lab & Effects

**Files**: `App/LookPanel.swift` (`filmLabSection`), `App/EffectsPanel.swift`
(`vignetteSection`, `grainSection`), `Core/Engine/FilmLab.swift`, `Core/Image/DetailEngine.swift`.

**Controls**
- **Stock** menu: None, Lumen Portra 400, Gold 200, Ektar 100, Tri-X 400, Velvia 50, Cine 250D.
- **Strength** 0…100 (100), **Film Exposure** −2…3 (step 0.25), **Push / Pull** −1…2 (0.25),
  **Halation** 0…100 (stock default; "This stock has no halation response."), **Halo Size**
  0.5…2.0, **Halo Redness** 0…100, **Grain** 0…100, **Grain size** 0.5…2.0.
- Effects › **Vignette**: **Amount** −4…2 (EV), **Feather** 0…100.
- Effects › **Grain**: with a stock loaded: "Stock" label, **Amount** 0…100, **Size** 0.5…2.0;
  without: **Amount**, **Size** 0…100 (50), **Roughness** 0…100 (50); note when stock not
  rendering.

**Journeys**
1. Each stock on the same frame; Strength 0 equals no stock.
2. Halation 100 near a light source; export at full size. *Correct:* glow matches loupe.
3. Grain 40 colour stock, export full-size, inspect flat mid-tone at 100%. *Correct:* grain,
   not coloured speckle (docs/38).
4. Vignette −4 on a cropped frame. *Correct:* centred on the crop.
5. Switch stock with grain set; Tri-X (B&W) then B&W panel.

**Known**: C1 film group remainder; grain not in GPU golden suite; Halation amount scaled by raw
bounce sum (N-006); BUILDING claims film exposure/halo size unwired — stale.

---

## 21. Crop & geometry

**Files**: `App/CropPanel.swift` (`CropSection`, `CropTool`, aspect lock), `App/CropAspectEdit.swift`,
`App/ViewerOverlays.swift` (`CropOverlayView` ~1382–2178, `StraightenOverlayView`),
`App/WorkspaceEntry.swift` (`toggleCropTool`), `App/EffectsPanel.swift` (lens rows),
`Core/Model/{CropGeometry,CropAspectConstraints,Straighten,BatchFraming}.swift`.

**Controls**
- Enter: **R**, ⌘3, rail Crop, View ▸ Crop; **R** again hides rectangle (stays in Crop);
  **R R** (double press) resets crop and stays; Esc reverts to framing at arming and leaves.
  Crop saves as you go (no Done/Revert).
- Canvas: 4 corner brackets, 4 edge handles (cursor changes), drag inside = move, drag
  outside = rotate (⇧ fine; angle ghost by cursor); dimmed outside; guides drawn while framing.
- Panel: **Aspect** row: lock button (hold/free), ratio menu **Original, 1:1, 5:4, 4:3, 3:2,
  7:5, 16:9, 16:10**, recent customs, **Custom…** (field + **Set**); ⇅ portrait/landscape;
  **Size** "W × H px"; **Angle** −45…45 (0.1); **Ruler** **Straighten by line**/"Drag a line…";
  **Guides** Off/Thirds/Grid/Golden/Diagonals (remembered, not in recipe); **Flip horizontal**.
- Crop header Reset clears crop, angle, flip. Lens section: **Built-in profile** toggle.

**Journeys**
1. R, drag corner with lock on/off, R R, Esc. *Correct:* Esc restores pre-arming framing.
2. 4:3 on a portrait then ⇅. *Correct:* rectangle measured against the real frame (not assumed
   3:2).
3. Rotate drag to ±45 then ⇧ fine. *Correct:* crop never shows empty corners (or documented).
4. Straighten by line on a horizon; then with Flip on. *Correct:* first drag levels, second
   doesn't overcorrect.
5. Crop while zoomed 1:1 → R. *Correct:* canvas is fit-only; zoom not changed invisibly.
6. Crop then mask/heal/WB pick. *Correct:* masks/spots stay on their pixels (source coords).
7. Custom ratio "2.39:1", "0", "abc", "1:0".
8. Crop with 10 photos selected (batch framing) — check each gets its own fitted rect.
9. Switch photo with crop armed. *Correct:* lock is per photo; tool state not carried wrongly.

**Known**: auto-straighten, perspective/Upright, CA removal not built; ⌘-drag straighten spec
replaced by button; Lens profile applies at RAW decode only (JPEG: no effect, stated).

---

## 22. Heal & clone

**Files**: `App/HealCanvas.swift` (`HealTool`, bar ~550–649), `App/LoupeView.swift`
(SpotVisualizationView), `App/ViewerOverlays.swift`, `App/AppState.swift` (`toggleHealTool`,
`repickSelectedSpotSource`, `deleteSelectedSpot`, `updateSpot`),
`Core/Image/{SpotRetouch,SpotSourceSearch,SpotVisualization,StrokeHeal,StrokeSourceSearch}.swift`,
`Core/Interaction/{SpotHandles,StrokeHandles}.swift`.

**Controls**
- **Q** arm/disarm (exits masking & crop); Esc; **Done**; **Delete** / ⌫.
- **Spot / Brush** segmented; **Heal / Clone** segmented; **Size** 2…400 px (diameter in
  original pixels), **Feather** 0…100, **Opacity** 0…100; **Visualize Spots** checkbox +
  **Threshold** 0…100.
- Canvas: click = new spot with auto source; drag solid circle = move spot; drag dashed circle =
  move source; **/** re-pick source (cycles); Brush mode: drag paints a heal stroke (click =
  dab); click on stroke in Spot mode selects it.
- Edit ▸ Paste Includes Spot Removal governs whether spots paste.

**Journeys**
1. 30 dust spots on a sky, `/` ×5 on one. *Correct:* source cycles through distinct candidates
   back to first.
2. Change Size with a spot selected vs none. *Correct:* selected spot edits; else next spot.
3. Heal on a cropped/rotated frame, then change crop. *Correct:* spots stay on blemishes.
4. Spots with 10 photos selected. *Correct:* only the primary photo gets spots.
5. Paste settings to another photo with toggle off/on.
6. Visualize Spots, export. *Correct:* visualisation not exported.
7. Heal stroke along a wire at 1:1 zoom.

**Known**: strokes have no source drag/re-pick; Remove/dust auto-detect/one-click dust removal
not built; real-photo stroke quality unqualified.

---

## 23. Masking A: entering, list, groups & overlay

**Files**: `App/MaskPanel.swift` (list ~340–1450), `App/MaskFloatingPanel.swift`,
`App/DevelopColumn.swift` (`MaskingReturnBar`, `MaskEditor`), `App/WorkspaceEntry.swift`
(`toggleMasking`, `enterMasking`), `App/AppState.swift` (`maskOverlay*`, `flashMaskOverlay`,
`hoverMaskOverlay`, `deleteActiveMask`, `invertActiveMaskComponent`),
`App/ViewerOverlays.swift` (`MaskOverlayView`), `Core/Interaction/{MaskOverlayRule,MaskSelection}.swift`,
`Core/Model/{MaskAlgebra,MaskDependency,GroupMove}.swift`, `Core/Image/MaskRaster.swift` (`MaskOverlay`).

**Controls**
- Enter: **M**, rail **Masks** door, O-keys; leave: M, door, Esc, "‹ <Workspace>" back button.
- Column bar: **Masks N** chip toggles the floating box.
- Floating **Masks** box (top-right of pane, draggable, clamped): title + count, minimize
  (rail of thumbnails), ✕ close, **+** "Create a new mask — every kind, on one board".
- Mask list: **Filter** search field (× "Show every mask again"); "No masks on this photograph
  yet." + **Add a mask** board; each row: thumbnail, eye (render on/off), name (click selects;
  rename), **Invert** chip, ⋯ menu: **Rename**, **Stop inverting**/invert, **Duplicate**,
  **Duplicate and invert**, **Delete** (inline Keep/Delete), Order **Move up/Move down**, Group
  **New group**, **Group**, **Leave the group**; group row menu: Strength %, **Ungroup**.
- Hover a row = preview overlay (120 ms intent hold).
- Overlay strip: **Overlay** toggle; menu "How it draws" (Colour Overlay, Colour on B&W, Image on
  B&W, Image on Black, Image on White, Matte) and "Colour" (red/green/white/black).
- Keys: **O** toggle overlay, **⇧O** cycle tint, **⌥O** cycle mode, **'** invert selected
  component, ⌫ delete mask.

**Journeys**
1. M from grid. *Correct:* loupe shows, column becomes mask editor, crop/heal disarmed; M again
   returns to the same workspace and expanded sections.
2. Create a brush mask, paint. *Correct:* overlay persistent from creation until first Effect
   slider press, hover-only after; O overrides (docs/37 rule).
3. "Keep it hidden" then try hover — overlay must still work (past pin bug).
4. 15 masks: filter, reorder, group 3, set group strength, ungroup, duplicate and invert.
   *Correct:* list doesn't scroll away; thumbnails refresh without stalling the UI.
5. Drag the box off-screen edges; resize window. *Correct:* always reachable.
6. ⌫ with no mask; Esc order with pick armed inside masking.
7. Switch photo while masking. *Correct:* active mask resets sensibly; no strokes painted onto
   the wrong photo.

**Known**: no next/previous-mask key; no solo; brush masks have no pin; navigator split not
built; mask named "Brush 1" not auto-named (docs/37 §5).

---

## 24. Masking B: drawn components (Brush, Linear, Radial, Outline)

**Files**: `App/MaskCanvas.swift` (`MaskBrushStore`, gestures), `App/MaskPanel.swift`
(brush zone ~1700–1770), `Core/Interaction/{MaskHandles,BrushStabilizer,StrokeHandles}.swift`,
`Core/Model/BrushStroke.swift`.

**Controls**
- Brush zone: **Size** 0.002…0.5 (fraction of long edge), **Feather** 0…100 (50), **Flow**
  1…100 (100), **Ceiling** 0…100 (100), **Steadiness** 0…100 (0), **Eraser**, **Stay inside
  edges** (Automask). Keys (brush selected): `[`/`]` size, ⇧`[`/`]` feather, 1–9/0 flow 10–100%,
  A automask; ⌥ held at stroke start = erase. Pressure from tablet.
- Radial: inside = move, rim = resize axis, just outside = rotate, clear space = new; panel
  **Feather**, **Rotation** −90…90.
- Linear: strip = move, band line = falloff, endpoint = swing, outside = rotate, clear = new.
- Both: ⌘ at press = new shape anywhere; ⇧ snaps 15°; ⌥ at press draws from centre.
- Outline (polygon/lasso): drag traces lasso; click adds corner; drag a vertex; panel
  **Feather**.
- Other masks' pins clickable to select.

**Journeys**
1. Paint 3 strokes, ⌘Z once. *Correct:* one stroke undone; earlier strokes intact (past bug
   replaced all strokes).
2. Paint on a left-half crop at 1:1 zoom. *Correct:* stroke lands under cursor ring; width
   matches ring.
3. A long painting (thousands of points), quit, reopen. *Correct:* all there.
4. Radial: press just off-centre and drag. *Correct:* moves, doesn't redraw.
5. Linear ⇧ rotate; ⌘-press inside existing → new one.
6. Lasso a complex shape; click-polygon 4 corners; drag vertex.
7. Press 5 with a brush selected → Flow 50 (not 5★). Press 5 with a radial selected → rating.
8. Paint with 5 photos selected. *Correct:* only the primary receives strokes.

**Known**: tiny-brush resolution boundary; F1-02…06 canvas group.

---

## 25. Masking C: range & AI components, algebra & edge

**Files**: `App/MaskPanel.swift` (component params ~1530–1700, kind board ~3100–3360, Edge
~2060), `Core/Image/MaskRaster.swift`, `Core/Recipe/RecipeMasks.swift` (`MaskKind`,
`matteProvider`), `Core/Recipe/MaskIdentityRepair.swift`, App `VisionMattes`.

**Controls**
- Kind board: Drawn (Brush, Linear Gradient, Radial Gradient, Outline); Range (Brightness Range,
  Luminosity, Colour Range, Colour Pick, Colour Along a Line); AI on this Mac (Subject,
  Background, People); **Another Mask** (only with >1 mask).
- Brightness Range: "Measures" channel menu, **From**/**To** −10…4 EV, **Smooth**.
- Luminosity: Lights/Darks/Midtones segmented, **Level** 1…5 / **Reach** 1…100 (15).
- Colour Range / Colour Pick: samples (add up to 8 via eyedropper, remove last), **Tolerance**
  0…100, **Colour**/**Brightness** weights; Colour Along a Line: line + samples.
- People: "Entire Person, for everyone in the frame."; status for no subject found.
- Another Mask: "Points at" mask menu.
- Component stack: rows with menu (Move up/down, Remove); **Add**/**Subtract** board (⌥ makes
  Add → Intersect); per component **Add/Subtract/Intersect**, **Invert this**, **Contribution**
  0…100.
- **Edge** zone: **Follow** 0…100, **Expand** −50…50, **Soften** 0…100, **Ramp from**, **Ramp
  to** 0…100, **Ramp shape** 0.2…5 (log); behaviour glyphs.

**Journeys**
1. Subject mask on portrait and landscape (rotated orientation). *Correct:* matte not mirrored
   (unverified — high value).
2. Subject minus Brightness Range highlights; intersect with radial. *Correct:* algebra matches
   overlay.
3. Colour Pick on sky, Tolerance sweep; exposure changes don't move the selection.
4. Another Mask referencing a mask, then delete the referenced mask. *Correct:* no crash; clear
   state.
5. Edge Expand ±50 and Soften 100 with overlay forced on during edge drag.
6. Hold ⌥ and release before clicking Add. *Correct:* label and op agree (F4-03).

**Known**: Sky/Object/Landscape/Depth Range absent (no model); AI matte orientation unverified;
mask colour table 33³ even on export.

---

## 26. Masking D: local adjustments

**Files**: `App/MaskPanel.swift` (~2140–3060), `Core/Recipe/RecipeMasks.swift` (`LocalAdjust`),
`Core/Engine/*` (local stages).

**Controls**: **Strength** 0…200 (100; group×member capped 200%); **Applies** menu Normal /
Brightness only / Colour only; **Light**: Exposure −4…4, Contrast, Highlights, Shadows,
Whites, Blacks; **Colour**: White balance **Shift/Kelvin** segmented with **Temp**/**Tint**
(Kelvin 2000…50000 step 50 / Shift −100…100), **Hue** −180…180, **Saturation**, **Vibrance**,
**Colorize** toggle + "Colorize to" swatch + **Colorize amount**; **Curve** (local point
curve); **Grading** toggle **Local grading wheels** + wheel; **Point Colour** (Add/Remove
swatches, Hue −60…60, Saturation, Luminance, Range, Variance); **Presence & Detail**: Texture,
Clarity, Dehaze, Sharpness.

**Journeys**
1. Radial on a face: Exposure +1, Strength 200 vs 0. *Correct:* scales linearly.
2. Whites +100 alone in a mask. *Correct:* little/no effect (stated in panel).
3. Kelvin vs Shift on the same mask. *Correct:* consistent; switching mode doesn't jump the
   picture.
4. Colorize to a swatch at 100.
5. Local curve + local wheels; export matches loupe.
6. Each local control: verify it changes the render (BUILDING claims tested).

**Known**: local noise/moiré/defringe/grain unwired (absent); mask Exposure/Contrast lack
coloured tracks; no modified dot/Reset on Light and Colour.

---

## 27. History, undo/redo, snapshots & reset

**Files**: `App/HistoryStack.swift`, `App/HistoryPanel.swift`, `App/PhotoSnapshotsView.swift`,
`App/AppStatePhotoSnapshots.swift`, `App/EditRevision.swift`, `App/CommandState.swift`,
`App/AppState.swift` (`undo`, `redo`, `resetToImported`), `Core/Interaction/HistoryCoalescing.swift`,
`Core/Catalog/PhotoSnapshotDependencies.swift`, `Core/Recipe/RecipeReset.swift`.

**Controls**: ⌘Z/⇧⌘Z (menu labels "Undo <step>"), footer Undo/Redo; **History** card (newest
first, current marked, click row = move cursor without destroying redo, last 40 rows with
**Show all N steps**/**Show the last 40**; caption that history is session-only); **Named
snapshots**: "Snapshot name" field + **Save**, row click = restore (undoable), trash →
confirmation **Delete snapshot**; footer **Reset**, Edit ▸ Reset Settings ⇧⌘R, ⌘K Reset,
section header Resets.

**Journeys**
1. 50 edits, click a row 20 back, then a row 10 forward. *Correct:* both moves work; nothing
   lost until a new edit.
2. Edit after jumping back. *Correct:* redo tail truncated (spec wants a confirm when >5 states
   would be discarded — check, likely not built).
3. Undo across tools: crop, mask stroke, WB pick, rating, look apply. *Correct:* each undone in
   order, overlays/thumbnails refresh, Vision mattes re-requested.
4. 400+ steps. *Correct:* oldest trimmed, no crash.
5. Snapshot, edit, restore, quit, relaunch. *Correct:* snapshot persists; history gone.
6. Reset on a JPEG returns to Linear transform (not Neutral).
7. Interrupted gesture then Reset (CURRENT-STATE: "interrupted-gesture Reset undo").
8. Folder switch then ⌘Z. *Correct:* nothing from the previous folder.

**Known**: no hover preview; history not persisted; coalescing 1.2 s vs spec 2 s; jump of n rows
= n catalog writes.

---

## 28. Copy/paste, sync, presets & looks transfer

**Files**: `App/AppState.swift` (`copySettings`, `pasteSettings*`, `pasteMasks`,
`syncSettings`, `pasteFromPrevious`, `copyLook/pasteLook`), `App/SettingsSubsetSheet.swift`,
`App/AppStateSelectiveSettings.swift`, `App/DevelopPresetSheets.swift`,
`App/AppStateDevelopPresets.swift`, `Core/Recipe/{PasteSettings,SettingsSubset,DevelopPreset,DevelopPresetLibrary,LookSubset}.swift`.

**Controls**: ⌘C, ⌘V, ⇧⌘V (Without Masks), Paste Masks, Paste Includes Spot Removal, ⇧⌘C
Copy Settings… sheet (groups: White Balance, Exposure & Tone, Presence, Tone Curve, Colour Mixer
& Grading, Display Transform & LUT, Detail & Sharpening, Noise Reduction, Lens Corrections, Crop
& Straighten, Effects & Film, Masks, Spot Removal; "THIS FRAME'S OWN" heading for per-frame
groups; **All/None/Cancel/Copy**), ⇧⌘S Sync Settings…, ⌥⇧⌘S Sync without dialog, ⌃⌘V Paste from
Previous, ⌥⌘C/⌥⌘V Copy/Paste Look, footer Copy/Paste/Copy Look/Paste Look; ⇧⌘N New Develop
Preset sheet (name field "Preset name, e.g. Soccer ISO 6400", groups, Save/Replace, note "Crop,
masks and spot removal belong to one frame and are never saved."); Manage Presets sheet
(Import…, Export All…, Apply, Rename, Export…, Delete…, Done); Photo ▸ Develop Presets ▸
<name>; ⌘K "Apply Preset: <name>".

**Journeys**
1. ⌘C on A, select 40, ⌘V. *Correct:* one undo step; masks pasted (geometry in source coords may
   land wrongly — expected); ⇧⌘V leaves targets' masks.
2. Copy Settings… with only WB + NR ticked, paste across ISO-mixed set.
3. ⌘C/⌘V inside a text field. *Correct:* text, not settings.
4. Paste from Previous after paging.
5. Preset round-trip: save, export, delete, import, apply to 100 photos.
6. Paste Look onto photos with their own crops/masks. *Correct:* develop corrections untouched.

**Known**: masks pasted by geometry don't follow subjects (by design).

---

## 29. Histogram, scopes & raw truth

**Files**: `App/HistogramView.swift`, `App/ScopesView.swift`, `App/ScopeData.swift`,
`App/RawTruthPanel.swift`, `App/RawTruthFeed.swift`, `Core/Image/{Scopes,ScopeReadout,RawTruth}.swift`.

**Controls**: **H** histogram (default on), **S** scopes (Waveform / Parade / Vector; skin line),
**⇧H** clipping panel ("Clipping", "Measuring…", close ✕); histogram: 5 draggable zones
(Blacks, Shadows, Exposure, Highlights, Whites), two clipping triangles (hover peeks overlay,
click locks; locked = outline), readout-space label click cycles (Working %, sRGB 255, Output),
right-click "Readout space" picker, "No histogram yet".

**Journeys**
1. Drag the Exposure zone; ⌘Z. *Correct:* Exposure slider moves; one step.
2. Lock highlight triangle, press J. *Correct:* J clears it.
3. ⇧H on a blown frame vs histogram percentages. *Correct:* labelled "Scene-linear
   (post-demosaic)"; values plausible; `[`/`]` hint text.
4. Scopes on during slider drag. *Correct:* scope updates on release, not per event (by design).
5. Readout space cycle vs loupe hover pill. *Correct:* agree.
6. Waveform on a very narrow crop. *Correct:* blank columns possible (known).

**Known**: ⇧H is post-demosaic, 2048 px proxy (isolated pixels under-read), measures only on
demand.

---

## 30. Deliver: soft proof & export

**Files**: `App/EffectsPanel.swift` (`proofRows`), `App/ExportSheet.swift`,
`App/AppStateQuickExport.swift`, `App/AppStateOperationReports.swift`,
`Core/Export/{ExportRecipe,ExportNaming,ExportSizingNaming,Dither,ExclusivePublish,QuickExport,SoftProofTransform}.swift`.

**Controls**
- Soft proof: **⇧S** / toggle **Soft proof**; **Destination** sRGB/Display P3/Adobe RGB/Rec.2020/
  ProPhoto; **Intent** Perceptual/Relative; **Gamut warning**; **Simulate paper & ink**; header
  Reset restores all.
- Export sheet (⌘E, disabled without selection; **Open Export…** in Deliver): title + source
  summary, **Close** (Esc); Recipes list (checkbox per recipe, + new, duplicate, − delete);
  Recipe: Name; **Format** JPEG/HEIC/TIFF/PNG, **Quality** 0…100, **Colour** space, bit depth
  8/16 or 8/10; **Size**: Resize mode (Don't resize, Long edge, Short edge, Width, Height,
  Width & height, Dimensions, Megapixels, Percentage) with Megapixels 0.5…100, Percent 5…200,
  Width/Height/Pixels 320…8000, **Don't enlarge**, **Resolution** 72…600 ppi; **Output
  sharpening** Off/Screen/Matte/Glossy × Low/Standard/High; **Naming**: Filename `{name}`,
  Custom text, Subfolder, **If it exists** Rename/Overwrite/Skip, **Start at** 1…999, Preview;
  **Metadata**: Strip GPS, EXIF, Camera serial, Keywords, Copyright, Contact; **Watermark**:
  toggle, Text, Position BL/BR/TL/TR/Mid, Opacity, Size, Inset; **HDR gain map**: Emit gain map,
  Headroom, Map size Full/Half/Quarter, Deliberate SDR base; footer file count, **Recent
  results**, **Export…** (chooses destination), **Fix Contact in “X”**; cancel "Stop".
- ⌥⇧⌘E Export with Previous; Export ▸ Show Last Export in Finder.

**Journeys**
1. Two recipes (JPEG long-edge 2048 sRGB + 16-bit TIFF ProPhoto) on 20 photos. *Correct:*
   determinate progress in status bar, app stays usable, 40 files, report saved.
2. Re-export with Rename / Overwrite / Skip. *Correct:* no silent overwrite under Rename.
3. Tokens `{date}`, `{seq:3}`, `{whatever}`. *Correct:* capture date; unknown token kept literal.
4. Stop mid-batch. *Correct:* finishes current file.
5. Compare exported pixels with loupe at the same size (texture, sharpening, grain, halation,
   vignette, masks, heal).
6. Copyright set, export, read metadata (unverified additive half).
7. Soft proof sRGB with gamut warning on a saturated flower; loupe only.
8. Export with Previous with no previous folder; with deleted folder. *Correct:* falls back to
   sheet with reason.
9. Press X while the sheet is open. *Correct:* nothing.

**Known**: gain map not written (toggle inert); additive metadata unverified; missing
non-core kernel degrades export silently; no persistent queue; compare panes don't proof;
loupe proofs through sRGB CGImage.

---

## Coverage index

Format: `- [ ] <control or shortcut> — A<area>`.

### Keys (dispatcher)
- [ ] G grid — A7/A10
- [ ] E loupe — A7
- [ ] C compare — A9
- [ ] N survey — A9
- [ ] Space hold (grid) / fit↔1:1 (loupe) — A5/A7
- [ ] Esc layered exit — A10/A11/A12/A21/A22/A23
- [ ] ? reference — A10
- [ ] Tab / ⇧Tab panels — A10
- [ ] P / X / U — A6
- [ ] ⌫ reject / delete mask / delete spot — A6/A22/A23
- [ ] 1–5 rating, 0 clear — A6
- [ ] 6 7 8 9 labels — A6
- [ ] - purple / zoom out — A6/A7
- [ ] ⇧+decision / Caps Lock forced advance — A6
- [ ] A auto-advance / automask — A6/A24
- [ ] B target album — A3/A6
- [ ] ← → ↑ ↓ navigation / pan / nudge — A5/A7/A11
- [ ] ⌘← ⌘→ paging — A7
- [ ] D detail — A10/A16
- [ ] W WB eyedropper — A12
- [ ] J clipping overlay — A8
- [ ] M masking — A23
- [ ] O / ⇧O / ⌥O overlay — A23
- [ ] ' invert component — A23
- [ ] R / R R crop — A21
- [ ] Q heal — A22
- [ ] / re-pick spot source — A22
- [ ] ⇧S soft proof — A30
- [ ] \ before/after — A9
- [ ] Y / ⇧Y / ⌥Y — A9
- [ ] H histogram — A29
- [ ] ⇧H clipping panel — A29
- [ ] S scopes — A29
- [ ] , . printer lights master; ⌃ ⌥ ⇧ variants — A18
- [ ] Z zoom — A7
- [ ] + = zoom in — A7
- [ ] I info overlay — A8
- [ ] [ ] thumbnails / holds / brush size — A5/A8/A24
- [ ] ⇧[ ⇧] brush feather — A24
- [ ] 0–9 brush flow — A24
- [ ] F filmstrip — A5
- [ ] ⇧F focus peaking — A8
- [ ] L lights out — A8
- [ ] ⌃N/⌃P/⌃A/⌃E/⌃H do nothing — A10

### Menu chords and items
- [ ] Check for Updates… — A10
- [ ] ⌘O Open… — A1
- [ ] ⇧⌘I Ingest from Card… — A2
- [ ] Relink Missing Original… — A1
- [ ] Back Up Catalog — A1
- [ ] ⌘1–⌘5 workspaces — A10
- [ ] ⌘K Go to a Control… — A10
- [ ] ⌥⌘S sidebar — A3/A10
- [ ] View ▸ Grid/Loupe/Compare/Survey items — A10
- [ ] View ▸ Filmstrip/Histogram/Scopes/Lights Out items — A10
- [ ] ⌘B Assessment Surround — A8
- [ ] View ▸ HDR Preview — A8
- [ ] ⌘= / ⌘− zoom & thumbnails — A5/A7
- [ ] View ▸ Info Overlay / Clipping Overlay / WB Picker / Panels / Prev / Next — A10
- [ ] ⌥⌘L Latency HUD — A10
- [ ] ⌘Z / ⇧⌘Z — A27
- [ ] ⌘X Cut (text only) — A4
- [ ] ⌘C / ⌘V settings (text carve-out) — A28/A4
- [ ] ⇧⌘V Paste Without Masks — A28
- [ ] Paste Masks — A28
- [ ] Paste Includes Spot Removal — A28/A22
- [ ] ⇧⌘C Copy Settings… — A28
- [ ] ⇧⌘S Sync Settings… — A28
- [ ] ⌥⇧⌘S Sync Without Dialog — A28
- [ ] ⌃⌘V Paste from Previous — A28
- [ ] ⌥⌘C / ⌥⌘V Copy/Paste Look — A28
- [ ] ⇧⌘R Reset Settings — A27
- [ ] ⌘A / ⌘D Select All / None — A5
- [ ] Invert Selection, Select Rejects, Select Unflagged, Select by Rating ▸ — A5
- [ ] ⌥⌘A Select Picks — A5
- [ ] ⌥⇧⌘D Deselect Unpicked — A5
- [ ] Photo ▸ Pick/Reject/Unflag/Rating 1–5/Clear Rating — A6
- [ ] ⇧⌘A Auto Tone — A13
- [ ] ⌥⇧⌘M Match Total Exposures — A13
- [ ] ⌘G Stack / ⇧⌘G Unstack — A3/A6
- [ ] Stack Bursts in Folder — A6
- [ ] ⇧⌘K Keyword the Selection… — A3
- [ ] ⌘⌫ Move Rejected Photos… — A6
- [ ] Remove Rejected from Catalog… — A6
- [ ] ⇧⌘N New Develop Preset… — A28
- [ ] Develop Presets ▸ Manage / Import / <preset> — A28
- [ ] ⌘L Filters On/Off — A4
- [ ] ⌥⌘P / ⌥⌘U / ⌥⌘X — A4
- [ ] ⌃⌘1–⌃⌘5 — A4
- [ ] Pick Sharpest in Each Burst… — A6
- [ ] ⌘E Export… — A30
- [ ] ⌥⇧⌘E Export with Previous — A30
- [ ] Show Last Export in Finder — A30
- [ ] ⌘/ Keyboard Reference — A10
- [ ] ⌘\ Clear filter (on the Clear button; only while a filter is active) — A4

### Window chrome & navigation
- [ ] Empty state Open… — A1
- [ ] Window drag-and-drop — A1
- [ ] Rail tabs ×5 + Masks door — A10/A23
- [ ] Column resizer — A10
- [ ] Section header click / ⌥-click / Reset — A10
- [ ] History card fold — A27
- [ ] Footer Auto/Reset/Undo/Redo/Copy/Paste/Copy Look/Paste Look — A10/A13/A27/A28
- [ ] Develop header "N photos" badge — A10
- [ ] Status bar film button — A5
- [ ] Palette field, ↑↓, Return, Esc, scrim — A10
- [ ] Reference sheet Done — A10
- [ ] Updater alert Relaunch Now / Later — A10

### Sidebar
- [ ] Folder header menu: Recent folders, Open Folder…, Show in Finder — A3
- [ ] Folder header context: Reveal in Finder, Copy Path, Open… — A3
- [ ] All photos / Picked / Unflagged / Rejected rows — A3
- [ ] Whole folder / Return to folder row — A3
- [ ] Save Filter as Smart Album — A3
- [ ] New album field — A3
- [ ] Album: Make Target, Remove Selection, Rename…, Delete Album… (Keep/Delete) — A3
- [ ] Smart album: Change Scope…, Update to Current Filter, Rename…, Delete — A3
- [ ] Add keyword field, chip ×, Add Synonym… — A3
- [ ] Expand/Collapse Stack, Promote to Pick, Unstack — A3

### Filter bar
- [ ] Text filter + × — A4
- [ ] Filter popover: Pick/Reject/Unflagged chips — A4
- [ ] Rating ≥ stars — A4
- [ ] Label chips + Unlabelled — A4
- [ ] RAW only, Edited chip — A4
- [ ] Metadata menu: Camera, Lens, ISO bands, Keyword, Stacks, Soft focus, Eyes closed, Bursts — A4
- [ ] All/Any — A4
- [ ] Clear — A4
- [ ] Sort menu (12 orders) + direction — A4
- [ ] Auto-advance toggle — A4/A6
- [ ] Thumbnail size slider — A4/A5

### Grid / filmstrip / compare
- [ ] Cell click / ⌘-click / ⇧-click / double-click — A5
- [ ] Cell star buttons, attention dot — A5
- [ ] Filmstrip grid button, 3 height steps — A5
- [ ] Compare click-zoom, drag-pan, double-click cursor — A9
- [ ] Survey tile click, ✕ remove — A9
- [ ] Pane badge strip Pick/Reject/stars — A6/A9
- [ ] Split divider drag — A9

### Loupe & instruments
- [ ] Double-click zoom, wheel, ⌥-scroll, pinch, drag pan, two-finger pan — A7
- [ ] Hover readout pill — A7/A29
- [ ] Badges (EMBEDDED PREVIEW, BEFORE, MASK, CLIPPING, PROXY) — A7
- [ ] Peaking HUD colour / sensitivity / ✕ — A8

### Develop: White balance (A12)
- [ ] WB preset menu (As Shot + 6) — A12
- [ ] WB eyedropper button — A12
- [ ] Temp — A12
- [ ] Tint — A12

### Develop: Tone & Zones (A13)
- [ ] Exposure, Contrast, Pivot, Highlights, Shadows, Whites, Blacks — A13
- [ ] Zones disclosure, pivot strip drag/double-click — A13
- [ ] Darks, Shadows, Midtones, Lights, Brights, Global — A13

### Curve (A14)
- [ ] Param/Point/R/G/B/Luma — A14
- [ ] Add / drag / ⌥-click / drag-out delete — A14
- [ ] Delete Point, Flatten, Reset Splits, Reset Regions — A14
- [ ] Highlights, Lights, Darks, Shadows (parametric) — A14
- [ ] Split triangles drag / double-click — A14
- [ ] Preserve Luminance — A14
- [ ] Curve Reset button — A14

### Presence (A15)
- [ ] Texture, Clarity, Dehaze — A15
- [ ] Vibrance, Saturation, Density, Protect Skin — A15

### Detail (A16)
- [ ] Capture sharpening toggle, Use measured values, Amount — A16
- [ ] Sharpening Amount, Radius, Detail, Masking, Halo Damping, Apply hint — A16
- [ ] NR mode Off/Classic/AI — A16
- [ ] Luminance, Detail, Contrast, Colour, Detail, Smoothness, Hot Pixels — A16
- [ ] AI Amount — A16

### Colour (A17)
- [ ] Band eyedropper, Band/All bands, 8 band swatches — A17
- [ ] Hue ring handles ×4 + arc reset — A17
- [ ] Mixer Hue, Saturation, Luminance, Even out hues — A17
- [ ] Point Colour eyedropper add, swatch select/re-sample, − remove — A17
- [ ] Point Hue, Saturation, Luminance, Range, Variance — A17
- [ ] B&W treatment toggle + 8 band sliders — A17

### Grading (A18)
- [ ] Zone strip pivots — A18
- [ ] Shadows/Midtones/Highlights/Global segmented — A18
- [ ] Grade wheel puck + Luminance bar — A18
- [ ] Blending, Balance — A18
- [ ] Hue shift, Vibrance (colour balance) — A18
- [ ] Chroma / Saturation / Brilliance × Global/Shadows/Midtones/Highlights — A18
- [ ] Printer Lights Master, Red/Cyan, Green/Mag, Blue/Yellow steppers + double-click — A18
- [ ] Red/Green/Blue Hue & Purity, Shadow Tint, Tint Purity — A18

### Looks (A19)
- [ ] Name this look + Save/Replace, Save as … instead — A19
- [ ] Look Amount — A19
- [ ] Look row apply, ⋯ Apply/Rename/Delete, Keep/Delete — A19
- [ ] Creative LUT choose / Remove / Display-Log / Amount — A19
- [ ] Display Transform Preset, Contrast, Skew, Hue keep, Black target — A19

### Film & Effects (A20)
- [ ] Stock menu (None + 6) — A20
- [ ] Strength, Film Exposure, Push/Pull, Halation, Halo Size, Halo Redness, Grain, Grain size — A20
- [ ] Vignette Amount, Feather — A20
- [ ] Grain Amount, Size, Roughness (no stock) / Amount, Size (stock) — A20

### Crop (A21)
- [ ] Crop corners ×4, edges ×4, move, rotate drag (⇧ fine) — A21
- [ ] Aspect lock, ratio menu ×8, Custom… + Set, ⇅ orientation — A21
- [ ] Size readout — A21
- [ ] Angle — A21
- [ ] Straighten by line — A21
- [ ] Guides Off/Thirds/Grid/Golden/Diagonals — A21
- [ ] Flip horizontal — A21
- [ ] Built-in profile (lens) — A21

### Heal (A22)
- [ ] Spot/Brush, Heal/Clone — A22
- [ ] Size, Feather, Opacity — A22
- [ ] Visualize Spots + Threshold — A22
- [ ] Done, Delete — A22
- [ ] Spot click, drag spot, drag source, stroke paint — A22

### Masking (A23–A26)
- [ ] Masks chip, floating box drag/minimize/close/+ — A23
- [ ] Mask Filter field + × — A23
- [ ] Add a mask board — A23/A25
- [ ] Row eye, name/rename, Invert chip — A23
- [ ] Row menu: Rename, Stop inverting, Duplicate, Duplicate and invert, Delete, Move up/down, New group, Group, Leave the group — A23
- [ ] Group menu: Strength %, Ungroup — A23
- [ ] Overlay toggle, 6 modes, 4 tints — A23
- [ ] Row hover preview — A23
- [ ] Back button "‹ <Workspace>" — A23
- [ ] Brush Size, Feather, Flow, Ceiling, Steadiness, Eraser, Stay inside edges — A24
- [ ] ⌥-erase stroke; pressure — A24
- [ ] Radial move/resize/rotate, Feather, Rotation — A24
- [ ] Linear move/falloff/swing/rotate — A24
- [ ] ⌘ new / ⇧ 15° / ⌥ from centre — A24
- [ ] Outline lasso / corners / vertex drag, Feather — A24
- [ ] Brightness Range Measures, From, To, Smooth — A25
- [ ] Luminosity Lights/Darks/Midtones, Level/Reach — A25
- [ ] Colour Range / Pick samples add/remove, Tolerance, Colour, Brightness — A25
- [ ] Colour Along a Line — A25
- [ ] Subject, Background, People — A25
- [ ] Another Mask "Points at" — A25
- [ ] Component row menu Move up/down, Remove — A25
- [ ] Add / Subtract board, ⌥ → Intersect — A25
- [ ] Add/Subtract/Intersect segmented, Invert this, Contribution — A25
- [ ] Follow, Expand, Soften, Ramp from, Ramp to, Ramp shape — A25
- [ ] Strength, Applies menu — A26
- [ ] Light: Exposure, Contrast, Highlights, Shadows, Whites, Blacks — A26
- [ ] Colour: Shift/Kelvin, Temp, Tint, Hue, Saturation, Vibrance, Colorize, Colorize to, Colorize amount — A26
- [ ] Local Curve — A26
- [ ] Local grading wheels toggle + wheel — A26
- [ ] Local Point Colour Add/Remove, Hue, Saturation, Luminance, Range, Variance — A26
- [ ] Texture, Clarity, Dehaze, Sharpness (local) — A26

### History (A27)
- [ ] History row click, Show all / Show the last 40 — A27
- [ ] Snapshot name + Save, restore, trash + Delete snapshot — A27

### Copy/paste & presets (A28)
- [ ] Settings subset sheet: 13 group checkboxes, All, None, Cancel, confirm — A28
- [ ] Preset sheet name field, groups, Save/Replace — A28
- [ ] Manage presets: Import…, Export All…, Apply, Rename, Export…, Delete…, Done — A28

### Scopes (A29)
- [ ] Histogram zones ×5 drag — A29
- [ ] Clipping triangles hover/click lock — A29
- [ ] Readout space label cycle + right-click picker — A29
- [ ] Scopes Waveform/Parade/Vector — A29
- [ ] Clipping panel close ✕ — A29

### Deliver (A30)
- [ ] Soft proof toggle, Destination, Intent, Gamut warning, Simulate paper & ink — A30
- [ ] Export Close, recipe checkboxes, +, duplicate, − — A30
- [ ] Name, Format, Quality, Colour, bit depth — A30
- [ ] Resize mode (9), Megapixels, Percent, Width, Height, Pixels, Don't enlarge, Resolution — A30
- [ ] Output sharpening medium × amount — A30
- [ ] Filename, Custom text, Subfolder, If it exists, Start at, Preview — A30
- [ ] Strip GPS, EXIF, Camera serial, Keywords, Copyright, Contact — A30
- [ ] Watermark toggle, Text, Position, Opacity, Size, Inset — A30
- [ ] Emit gain map, Headroom, Map size, Deliberate SDR base — A30
- [ ] Export…, Fix Contact, Recent results, Stop — A30

### Ingest (A2)
- [ ] Close, Source menu (volumes, Rescan, Choose Folder…) — A2
- [ ] Primary Choose…, Backup copy + Choose… — A2
- [ ] Job, Folder template, Rename files + template, Rewrite repair — A2
- [ ] Verify every copy, Eject when done — A2
- [ ] Stop, Recent results, Ingest — A2
