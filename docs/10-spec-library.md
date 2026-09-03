# 10 — Library, Culling & Ingest

The library is where Lumen's one-line thesis (docs/00-vision.md, D1) is won or lost. The plan in one
sentence: **Photo Mechanic's paging speed and three architectural refusals, FastRawViewer's raw truth,
Narrative Select's face-evidence panel, and Lightroom's culling keystroke grammar — in the same window
as a full develop module, local-only.** No product on the market combines even three of these: PM has
speed but no truth and no develop; FRV has truth but no grouping and no develop; Narrative and
Aftershoot have AI assists but no develop; LrC 15.5 and C1 16.8.4 have develop plus everything else,
but slow paging and a distrusted first-generation AI. The whole ingredient list is buildable from OS
APIs plus the preview cache already specified in docs/15-catalog.md.

The engineering doctrine of this doc is Photo Mechanic's, adopted wholesale (D34). Three refusals:

1. **Never decode RAW on the browse path.** Grid and first loupe page render the camera's embedded
   JPEG — hardware-decoded in milliseconds, cost independent of RAW complexity.
2. **No import ceremony.** Opening a folder or card *is* the workflow. Nothing requires a database
   transaction, a preview build, or a modal dialog before you can see your pictures.
3. **Direction-aware prefetch.** The next keypress swaps in an already-decoded image. Paging is gated
   only by key repeat, budget <50 ms (D43).

And the failure model to beat is Lightroom Classic's library, whose **five slownesses** are documented
in docs/02-research-lightroom.md and named here so every section below can say which one it kills:

| # | LrC slowness | Evidence | Killed by |
|---|---|---|---|
| S1 | Import-before-browse: the preview-build wall | "Embedded & Sidecar" is the community's #1 speed trick ("slash import time by 90%") — i.e. the fast path exists but is an opt-in buried in a dialog | §10.1 — the fast path is the only path |
| S2 | Loupe paging latency ("Loading…") | PM's defining win, LR's defining culling failure | §10.3 prefetch spec |
| S3 | Grid scroll / folder-switch hitching on large catalogs | "permanent background grumble even in 15.x" | §10.2 scroll budget |
| S4 | Synchronous metadata/catalog work: XMP write stalls (pre-14.4), Optimize Catalog ritual, backup prompts | Adobe had to batch Auto-XMP in 14.4 because per-edit writes were "a measurable performance drag" | §10.4 async writes, §10.10 invisible hygiene |
| S5 | ML bolted into a heavy loop: 15.4's AI-culling memory leaks/freezes on Mac; multi-second Develop switches with AI masks | LrC 15.4 release notes + perf threads | §10.6 run policy: background QoS, bounded, cancelable, never on the paging path |

Keyboard access and latency budgets in this doc live inside the global system owned by
docs/12-spec-ux.md (one-frame rule ≤16.7 ms continuous, ≤100 ms discrete, cull paging <50 ms — D43).
Storage mechanics (schema, sidecars, preview-cache levels) are owned by docs/15-catalog.md. AI model
licensing lives in docs/17-appendix.md.

---

## 10.1 The browse model

### Folders are the library

**What it is.** Lumen has no import step. You point it at folders (or a mounted card); a contact
sheet appears at directory-listing speed; everything else — EXIF, previews, AI assists — arrives
asynchronously behind it. An optional verified-copy ingest exists (§10.7) for getting files *off
cards*, never as a precondition for seeing them.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Add folder | folder picker / drag-in | — | Registers a watched root; security-scoped bookmark stored |
| Browse card | automatic on mount | on | DCIM heuristic opens a contact sheet immediately; ingest offered, not forced |
| Folder tree | sidebar, mirrors disk | shown | Drag between folders = real filesystem move, with honest warning |
| Sync folder | automatic (FSEvents) | on | External adds/deletes/renames reconciled continuously; no "Synchronize Folder" menu ritual |

**How it works.** The filesystem is the source of truth; the catalog (docs/15-catalog.md) is an index
over it, never a gatekeeper. Opening a folder: (1) directory listing → grid skeleton with file-count
and placeholder cells, target <1 s for 2,000 files; (2) a parallel scan pipeline reads EXIF via
`CGImageSource` (no pixel decode, ~1–3 ms/file) and extracts embedded previews (below); (3) catalog
rows are upserted keyed on `(folder, filename, mtime, size)` with an xxHash content fingerprint for
move/duplicate detection. An `FSEventStream` watcher per root keeps the index live. Nothing in steps
2–3 blocks step 1: the grid is scrollable and cullable while the scan runs, cells filling in as they
land. Ratings, flags, and recipes mirror to XMP sidecars (debounced ~2 s, async — docs/15-catalog.md
owns the format), so the folder tree remains portable and greppable: catalog loss costs bookkeeping,
never edits. This is the Exposure X7 / FRV persistence model, adopted because the Aperture
post-mortem (docs/03-research-competitors.md) proved that archives locked inside an app's database
die with the app.

**How it feels.** Launch → last-viewed folder's grid in under a second. Insert a card → contact
sheet appears without a dialog; a non-modal banner offers "Ingest…". There is no Library/Develop
module wall: the develop panels are one keystroke away on any photo (docs/12-spec-ux.md owns the
layout). Missing volumes show grayed cells with an offline badge; nothing errors.

**Vs. the field.** **Better than LrC 15.5 because** LR's import dialog (Copy/Move/Add, four preview
tiers, Smart Previews, duplicate options, destination trees) is the most-resented tax in its
ecosystem, and its fast path (Embedded & Sidecar) is an expert setting; Lumen's fast path is the only
path (kills S1). **Equal to Photo Mechanic 6/Plus because** this is PM's architecture verbatim —
folders-as-library, browse-before-ingest — which has been the speed benchmark since 1998; we add a
catalog index *behind* it (search, smart albums, edit storage) without ever putting it in front.

### The embedded-preview fast path and the fallback ladder

**What it is.** Every grid thumbnail and first loupe page comes from the JPEG the camera already
embedded in the RAW. Lumen's own renders replace them opportunistically in the background. When the
embedded preview is inadequate (the Sony case), a fallback ladder degrades gracefully — it never
blocks paging.

**Controls.** None. This is policy, not preference (LR's four preview types × quality × discard
windows is the named anti-pattern — one automatic pipeline, invisible).

**How it works.** Extraction reads the embedded JPEG via ImageIO/`CGImageSource` (LibRaw thumbnail
unpacking as cross-check/fallback), costing a file read plus a hardware JPEG decode. Orientation is
taken from the RAW **container's** primary EXIF orientation tag, never the preview JPEG's own header
— bodies write inconsistent orientation between thumbnail, preview, and main IFD, and this is the
classic sideways-portrait bug. Preview reality by mount (per-model table to be built during
implementation, not assumed): Canon CR2/CR3, Nikon NEF, Fuji RAF embed full-resolution JPEGs; many
Sony A7-era bodies embed only ~1616×1080; Adobe DNG embeds whatever the converter was told to.

The ladder, per photo:

```
1. Full-size embedded JPEG        → grid + loupe fit + 1:1 checks. Done.
2. Small embedded only (Sony)     → grid + loupe fit from it anyway (paging never blocks);
                                    background-render a Lumen fit/1:1 preview (draft-mode
                                    CIRAWFilter decode, docs/14-pipeline.md) with the Sony
                                    frames prioritized ahead of ladder-1 re-renders;
                                    zoom >~60% before it lands shows an honest "rendering
                                    full preview…" shimmer, never a spinner on the paging path.
3. No usable preview (rare/corrupt) → thumbnail-size render at scan; badge as degraded.
```

Cache levels (thumb 256 / grid 1024 / fit ~2560 / 1:1 tiles) and their lifecycle live in
docs/15-catalog.md. Budget: full-size embedded extraction ~10–30 ms/file across 8 parallel workers →
a 2,000-frame card fully previewed in ~10–20 s of background work, first screenful <1 s.

**How it feels.** A just-shot 128 GB card is browsable in seconds — the "spinning beachball while
previews build" phase that defines LR import does not exist. Sony shooters see the same instant grid,
and their 100% checks go through Lumen renders that were already prioritized in the background.

**Vs. the field.** **Better than LrC 15.5 because** LR makes this an import-dialog choice and then
still renders Standard previews on a schedule the user must configure; Lumen's ladder is automatic
and per-file. **Better than Photo Mechanic 6/Plus because** PM stops at the embedded JPEG — on
small-preview Sony bodies, PM users famously cannot focus-check at all; Lumen's ladder backfills real
renders because, unlike PM, it *has* a RAW pipeline. **Better than FastRawViewer 2.0 because** FRV
pages on its own raw decode (truth at the cost of paging weight); Lumen pages on JPEG and delivers
truth through cached raw statistics instead (§10.5).

### The camera-render handoff (honesty badge)

**What it is.** The embedded preview shows the *camera's* rendering — picture style, camera WB, camera
tone curve. Lumen's neutral render will differ. Every image still showing a camera render carries a
small badge, and the swap to Lumen's render is scheduled so the jump is never seen mid-glance.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Camera-preview badge | on/off | on | Small camera glyph, grid cell corner + loupe status bar |
| Render neutral previews | background policy | on, idle-priority | Newest folders first; Sony-ladder frames first of all |

**How it works.** The background render queue replaces embedded previews with Lumen-rendered ones
(default recipe + ISO-adaptive defaults, docs/07-spec-denoise.md D27). The swap is applied only when
the photo is next brought on screen — never crossfaded under the user's eyes during a cull pass — and
the badge disappears with it. Opening a photo in Develop forces the render immediately, with the
progression visible (embedded → draft → full), so the tone jump happens exactly once, at a moment the
user initiated.

**How it feels.** You always know which rendering you are judging. The infamous "Lightroom changed my
photos after import!" complaint is a handoff-honesty failure, not a rendering bug — LR badges
embedded previews too, but swaps on its own schedule and still generates the complaint. Lumen's rule:
the jump happens before you are editing, never during, and always labeled.

**Vs. the field.** **Better than LrC 15.5 because** the swap timing is deterministic and user-visible
rather than whenever the preview queue gets there. **Better than Photo Mechanic 6/Plus because** PM
never renders its own preview at all, so PM users make every exposure judgment on a rendering their
editor will not reproduce; Lumen tells you which regime you're in and migrates you to the truthful
one automatically.

---

## 10.2 The grid

### Grid view and the scroll budget

**What it is.** The contact sheet: a virtualized thumbnail grid over the current source (folder,
album, filter result), with a sacred performance contract — zero dropped frames at 120 Hz, ever.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Thumbnail size | 96–512 px, slider + `Cmd±` | 192 px | Continuous; snaps at cache levels |
| Cell style | minimal / badged / expanded, `J` cycles | badged | Expanded adds filename, capture time, EXIF line |
| Info overlay | off / basic / full, `I` cycles | off | Loupe and grid share the cycle |
| Selection | click / drag-band / arrows / `Cmd+A` | — | Anchor+extend semantics per macOS convention |

**How it works.** Cells are recycled views drawing GPU textures; thumbnails upload asynchronously
and live in a texture atlas alongside pre-composited badge glyphs, so a fully badged cell is one quad
draw. The scroll path performs no decode, no SQL, and no allocation: visible-range changes enqueue
requests to a priority decode queue (visible > scroll-direction lookahead > rest), and results paint
on arrival with a 120 ms fade on first-ever appearance only — never a white flash, never a relayout.
Budget: 8.3 ms/frame at 120 Hz with 5,000 cells in the source, enforced in CI as one of the five
release-gate loops (docs/12-spec-ux.md, D47). Sort and filter changes rebuild the index array off the
main thread and swap it in one transaction.

**How it feels.** Flick-scrolling a 20,000-photo year rides at full frame rate with thumbnails
resolving in place. Arrow keys move selection with the grid auto-scrolling to keep it visible;
`G` returns here from anywhere (D35).

**Vs. the field.** **Better than LrC 15.5 because** big-catalog grid scrolling and folder switching
remain a permanent LR grumble (S3) — LR draws cells on the CPU with synchronous catalog touches;
Lumen's grid is a GPU scene with an async index. **Equal to Photo Mechanic 6/Plus because** PM's
contact sheet already scrolls at native speed; we match it and add live badges PM doesn't have
(edit state, stack counts, AI evidence chips).

### Cell badges

**What it is.** At-a-glance state on every cell, drawn from the atlas at zero scroll cost.

**Controls.** Badge set fixed; visibility follows cell style (`J`).

| Badge | Meaning |
|---|---|
| Flag ▲ / ▼ | pick / reject (white/red) |
| ★1–5 | rating |
| Color chip | label (red/yellow/green/blue) |
| Camera glyph | still showing camera-rendered preview (§10.1 honesty badge) |
| Stack `N` | collapsed stack with N members (§10.2 Stacks) |
| Version `N` | photo has N virtual copies (§10.9) |
| Pencil | recipe differs from default (edited) |
| Attention dot | AI evidence present: closed eyes / soft focus / junk candidate (§10.6) — a pointer to evidence, never a verdict |
| Cloud-slash | volume offline |

**How it works / feels.** Badges are state reads from the in-memory index, invalidated by catalog
observation (GRDB value observation → per-cell dirty marks). The attention dot is deliberately
information-poor: one neutral dot, same size as a label chip. The evidence itself lives in the loupe
strip and filter bar, because a grid full of red warnings would be the AI shouting verdicts (D37's
contract forbids exactly that).

**Vs. the field.** **Better than LrC 15.5 because** LR's badge set is comparable but its cells cost
scroll frames, and its AI culling state is a separate panel with no grid presence at all. **Better
than Narrative Select because** Narrative shows assessments only in its own panel; Lumen's dot routes
attention from the grid without pre-judging.

### Sort orders

**What it is.** The ordering dropdown, per-source memory, plus two AI-derived sorts that are
deliberately sort-only.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Sort key | capture time / added order / edit time / rating / flag / label / filename / file type / aspect ratio / user order / sharpness score / aesthetic score | capture time | User order only in albums (drag to reorder) |
| Direction | asc / desc | asc | Persisted per source |

**How it works.** All sorts are index-backed SQL over the catalog; AI scores come from §10.6's
background pass and sort unscored items last, unlabeled. Aesthetic sort exists *only* here — per D37
it never flags, filters, or rejects; it is an ordering suggestion (`VNCalculateImageAestheticsScores
Request`, macOS 15+) for "show me my probable best first" browsing.

**Vs. the field.** **Equal to LrC 15.5 because** the classic sort roster matches LR's per-folder
memory feature-for-feature. **Better because** LR has no quality-ordered sort at all — its Assisted
Culling scores can filter but not order; sort-by-evidence is the gentlest possible use of an
aesthetics model and no shipping competitor offers it.

### Stacks

**What it is.** Burst/bracket grouping — automatic from capture data, manual by keystroke — with a
pick on top, Aperture-style.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Auto-stack bursts | on/off | on | Capture-gap ≤2 s AND FeaturePrint distance below threshold (§10.6) |
| Stack / Unstack | `Cmd+G` / `Cmd+Shift+G` | — | Manual grouping |
| Collapse/expand | `S`, or click badge | collapsed | Per-stack; expand-all in menu |
| Promote pick | `Shift+S` on selected member | first frame | Stack thumbnail = pick |

**How it works.** Stacks are catalog rows (group id + order + pick), computed by the same
burst-grouping pass as §10.6 so auto-stacks and compare groups are one concept. Virtual copies
auto-stack with their master. Filters can match stack state (any / collapsed tops only / unstacked).
Collapsing 3,000 frames of bursts into 400 stacks is a pure index operation — no re-render.

**How it feels.** An event card auto-organizes into decision units: each stack is one *choice*, and
`N` (survey) or `C` (compare) on a collapsed stack opens exactly its members (§10.4). This is
Aperture's stack ergonomics — the piece of Aperture event shooters still mourn — fused with the AI
grouping LrC only reached in 15.4.

**Vs. the field.** **Better than LrC 15.5 because** LR's 15.0 auto-stacking (time/similarity) exists
but is a separate command with separate results from its 15.4 duplicate detection; Lumen has one
grouping engine feeding stacks, compare sets, and best-of-burst evidence. **Equal to Aperture 3
because** stack semantics (pick-on-top, collapse, promote) are copied from the app that defined them.

---

## 10.3 Loupe and navigation

### Paging and direction-aware prefetch

**What it is.** The single-image view (`E`) and the guarantee that makes culling feel like flipping
prints: the next photo is always already decoded.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Page | ←/→ (and filmstrip click) | — | Auto-advance (§10.4) also pages |
| Prefetch depth | fixed policy | N=8 ahead / M=2 behind | At fit size; not a preference |
| 1:1 prefetch | fixed policy | current ±1 | Full-res tiles for instant zoom |

**How it works.** A ring cache of decoded fit-size textures follows the cursor: 8 ahead in the
current navigation direction, 2 behind (D34). Direction flips re-aim the window; the decode queue
drains newest-request-first so a direction change costs at most one page of latency. The 1:1 tile
set for the current image and its two neighbors decodes in parallel so a sharpness check is also
instant. Memory: fit-size RGBA8 at ~2560 px ≈ 17.5 MB → an 11-image window ≈ 190 MB, capped inside a
512 MB texture budget shared with the grid atlas. Paging budget: **<50 ms worst case, one frame
typical** — the swap is a texture bind, and every write triggered by the previous keystroke
(rating, XMP, prefetch bookkeeping) is already off the input path. Measured in CI as the photo-switch
loop (D47).

**How it feels.** Hold the arrow key and images stream at key-repeat rate — PM's signature feel. The
moment "next" would ever show a spinner, flow dies; that moment is designed out, not optimized out.

**Vs. the field.** **Better than LrC 15.5 because** loupe paging on fresh imports is LR's defining
culling failure (S2, "Loading…"), fixable only by pre-building previews — the ceremony we deleted.
**Equal to Photo Mechanic 6/Plus because** this is PM's lookahead cache with the parameters written
down; PM feels gated by key repeat and so does Lumen, on the same files.

### Hold-key Loupe

**What it is.** Aperture's beloved floating magnifier: hold `` ` `` (backtick) and a loupe follows
the cursor showing 100% detail — over grid thumbnails or the loupe view — without changing zoom, view
mode, or selection.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Loupe | hold `` ` ``; tap to pin/unpin | hold | Works in grid, loupe, survey, compare |
| Loupe zoom | 50–400% via scroll while held | 100% | Diameter ~360 pt, resizable |

**How it works.** The loupe samples the 1:1 tile cache; over grid cells it triggers a targeted 1:1
decode of just the tile under the cursor (embedded-preview resolution permitting; on the Sony ladder
it shows the best available and the shimmer badge). Render is a masked quad over the existing scene —
no view-controller transition, ≤16.7 ms tracking.

**How it feels.** The second-most-used cull gesture after advance: "is it sharp?" answered without
leaving context. No mainstream tool replicated Aperture's loupe well; it is cheap differentiation
with daily payoff.

**Vs. the field.** **Better than LrC 15.5 because** LR's only equivalents are full zoom toggles that
lose composition context. **Better than Photo Mechanic 6/Plus because** PM's click-zoom changes the
view; the loupe inspects without navigation. **Equal to Aperture 3 because** it is Aperture's design,
revived on hardware that can actually keep it at 120 Hz.

### Zoom behavior

**What it is.** Deterministic zoom with pre-decoded levels.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Toggle zoom | `Z`, `Space`, or click | fit ↔ 100% | Centers on cursor/click point |
| Zoom steps | fit / fill / 25 / 50 / 100 / 200% | fit | Pinch is continuous; `Cmd±` steps |
| Return zoom | remembered per session | 100% | The `Z` target when not fit |
| Pan | drag / two-finger scroll | — | Synced in compare (§10.4) |

**How it works.** 1:1 is served from the tile cache (current ±1 pre-decoded). Zoom is a transform on
existing textures — never a re-decode on the input path; tiles outside the cache stream in
progressively (visible shimmer, no blur-up lie about sharpness: unsharp regions render at reduced
opacity rather than fake-sharp upsampling, because a culling zoom exists to judge focus).

**Vs. the field.** **Equal to LrC 15.5 because** the gesture set matches (Z/space/click, scrubby
pan). **Better because** first-zoom is instant on fresh files (LR renders 1:1 on demand unless you
pre-built 1:1 previews at import — the ceremony again), and the no-fake-sharp rule means zoom never
misleads a focus judgment.

### Focus peaking

**What it is.** FRV-style edge-contrast overlay marking in-focus, high-detail areas — a sharpness
read without zooming.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Peaking | `F` toggle | off | Loupe, survey, compare; state persists per session |
| Sensitivity | low / normal / fine-detail | normal | Fine-detail mode for landscape texture |
| Color | red / green / white | green | Drawn as thin outlines, not fills |

**How it works.** A Metal kernel over the displayed texture: high-pass energy (3×3 Laplacian
magnitude, normalized by local luminance) thresholded by sensitivity, drawn as outline overlay.
Computed on the *best available* representation and re-run when the Sony ladder upgrades the preview
— peaking on a 1616×1080 preview is labeled with the shimmer badge because it cannot be trusted at
pixel level. Cost ≤2 ms at fit size; live during paging.

**Vs. the field.** **Better than LrC 15.5 because** LR has no focus peaking anywhere — sharpness
checking is zoom-only. **Equal to FastRawViewer 2.0 because** the feature is FRV's, absorbed; **better
because** it lives in the same loop as flags, stacks, and develop, so the answer becomes an action
without switching apps.

---

## 10.4 Culling grammar

### Flags, stars, labels, and auto-advance

**What it is.** LR-keystroke-compatible decision marks (D35): pick/reject/unflag, stars, color
labels — three orthogonal axes, one keypress each, with auto-advance on by default and visible.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Pick / Reject / Unflag | `P` / `X` / `U` | unflagged | The one-bit first pass (PM's tag lesson: binary first, scales second) |
| Stars | `1–5`, `0` clears | 0 | |
| Labels | `6–9` = red/yellow/green/blue | none | Editable names; purple assignable in prefs |
| Auto-advance | visible toolbar toggle + menu | **on** | Any decision key advances; `Shift+key` always advances even when off |
| Views | `G` grid / `E` loupe / `C` compare / `N` survey | — | LR-compatible (D35) |
| Delete rejects | `Cmd+Delete` | — | Moves files to a `_Rejected` subfolder (FRV pattern), reversible; Finder-trash only from there |

**How it works.** A decision is an in-memory index write + async catalog transaction + debounced XMP
mirror — the next keystroke never waits on I/O (kills S4). Auto-advance is a first-class visible
state, not LR's Caps-Lock easter egg; Caps Lock is *also* honored for muscle-memory compatibility,
but the toggle is the truth and the HUD shows it. Reject-delete goes through the `_Rejected`
subfolder stage because filesystem-as-database is inspectable and zero-lock-in: a mistake is a drag
back, not a Trash dig.

**How it feels.** Arrow, key, arrow, key — the complete loop. The cull HUD (thin strip, toggleable)
shows counts: total / picks / rejects / unrated, auto-advance state, and active filter. A 2,000-frame
first pass is P/X at key-repeat speed; LR users' hands work unchanged from minute one
("Caps-Lock + P/X/U saves ~50 min per 2,000 photos" is the community's own arithmetic — we keep the
keys and delete the latency).

**Vs. the field.** **Equal to LrC 15.5 because** keystroke-for-keystroke compatible, deliberately.
**Better because** auto-advance is visible and default-on, decisions are always async (LR historically
stalled on XMP writes), and paging under the decisions is <50 ms. **Better than Photo Mechanic
6/Plus because** PM's three axes (tag/stars/classes) are matched by flag/stars/labels, and Lumen adds
what PM refuses to have: the develop module the survivors flow into.

### Survey and Compare

**What it is.** Choosing among survivors: `N` tiles a selection (survey), `C` pits select vs
candidate (compare) with synchronized zoom and pan.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Survey | `N` on a selection or stack | — | 2–12 tiles; click a tile's ✕ (or `X`) to drop it from consideration |
| Compare | `C` | — | Select (left) fixed, candidate (right) cycles with ←/→; `↑` promotes candidate to select |
| Sync zoom/pan | lock toggle in HUD | on | Zoom/pan gestures mirror across panes; unlock for asymmetric checks |
| Decision keys | P/X/U, 1–5, 6–9 | — | Act on the focused pane; auto-advance cycles candidates |

**How it works.** Both views draw from the same fit/1:1 caches as loupe; a synced zoom is one shared
transform applied to N textures. Opening survey/compare on a collapsed stack seeds it with the stack
members ordered by the best-of-burst score (§10.6) — the AI's ordering is the *starting arrangement*,
the human's keys are the decision. Dropping a tile in survey does not reject the photo; it narrows
the working set (rejection stays an explicit `X`).

**How it feels.** The near-duplicate endgame: expand a 6-shot burst into survey, loupe-hover the
faces, drop to two, `C`, synced 100% on the eyes, `↑`, `P`. Fifteen seconds per group, no view-mode
friction.

**Vs. the field.** **Equal to LrC 15.5 because** Survey/Compare semantics and keys match (Select vs
Candidate, synced zoom with lock). **Better because** compare sets auto-seed from burst groups with
evidence ordering — LR's Compare has no relationship to its own 15.4 duplicate detection — and
because every pane honors the raw-truth holds (§10.5) and loupe. **Better than Photo Mechanic 6/Plus
because** PM's multi-image preview has no synced zoom contract and no grouping intelligence.

### Painter-style bulk operations

**What it is.** LR's spray-can, kept: pick a payload once, then click-drag it across grid cells.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Painter | toolbar spray icon / `Cmd+Opt+K` | off | Esc exits |
| Payload | rating / flag / label / keyword / album membership / develop preset (incl. Look, D4) | last used | One payload active at a time |
| Erase | hover a painted cell → cursor flips | — | Removes the same payload |

**How it works.** Each swept cell enqueues the same async decision write as §10.4; painting a develop
preset enqueues recipe merges plus background preview re-renders (viewing-priority scheduling,
docs/07-spec-denoise.md pattern). Painting 800 cells is one SQL transaction batch + a render queue,
never a UI stall.

**Vs. the field.** **Equal to LrC 15.5 because** the Painter tool is LR's own good idea with the same
payload roster. **Better because** payloads include Look presets (the Develop/Look split, D4) so
"paint this grade across the reception set" is one sweep, and applying never blocks the grid (LR's
Auto-Sync stalls on large selections are documented in docs/02-research-lightroom.md).

---

## 10.5 Raw truth at cull time (FastRawViewer, absorbed)

> **What is built, as of this pass — read before the spec below.** The instrument ships
> and it is **not** the sensor histogram this section specifies. It measures the
> **decoded scene-linear frame**: `CIRAWFilter` at Lumen's flat settings (Apple's tone
> curve, shadow boost, local tone mapping, gamut mapping and contrast all off, extended
> range kept), read before every Lumen stage and before the display transform.
>
> · **Scene-referred and unclipped by the display transform**, which is the whole
>   difference from the develop histogram and is what makes it answer "is this highlight
>   recoverable". · **Post-demosaic**, which is the whole difference from what is
>   specified below: no CFA or LibRaw reader exists in the pipeline and Apple's RAW API
>   does not expose the mosaic, so where Apple's highlight reconstruction has rebuilt a
>   saturated channel these numbers read the reconstruction. Which direction that moves
>   a percentage is not something this build has measured, and the panel says so rather
>   than guessing. · Consequently there is **no G2 channel**: slot 4 carries luminance,
>   because the two greens were averaged by the demosaic before this instrument saw them.
> · The measurement runs on a 2048 px proxy of the decode, so a large blown region reads
>   true and an isolated clipped pixel is averaged down; the row records the site stride
>   and the panel prints it. · Measurement is **on demand** — `⇧H` on an unmeasured frame
>   measures it and caches it; the background sweep described below has a queue
>   (`CatalogStore.photosMissingRawStatistics`) and no driver yet. · The `O` raw-clipping
>   overlay is **not built**.
>
> The UI is named for what it is — the panel header prints *Scene-linear
> (post-demosaic)* — and `RawStatistics.Provenance` carries that name into the cached
> row, gates the cache read, and is enforced by a source scan that fails if any call
> site labels a measurement as the sensor's. The rest of this section is the target.

### True raw histogram and clipped-percent readout

**What it is.** A histogram computed from actual raw sensor values — per-channel R/G/G2/B, EV-scaled
— with per-channel clipped-pixel percentages, available on any photo during culling. The embedded
JPEG's histogram is post-WB, post-tone-curve, post-picture-style and *lies*: typically 0.3–2 EV of
real highlight headroom exists beyond where it shows clipping (D36; the full argument is
FastRawViewer's founding thesis, docs/03-research-competitors.md).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Raw histogram | toggle in cull HUD / `Shift+H` panel | off | Per-channel R/G/G2/B, EV grid, log-scale option |
| Clipped % readout | shown with histogram | on | Per channel: % at saturation and % within 0.25 EV of it; same for black-level floor |
| Raw clipping overlay | `O` toggle | off | Paints truly clipped areas per channel on the image |

**How it works.** A background worker (LibRaw unpack via the `RawSource` escape hatch,
docs/14-pipeline.md) reads CFA values without demosaic, subtracts black level, subsamples 1/16 of
sites, and bins per-channel histograms against the per-channel saturation level from metadata.
Cost ~150–400 ms per 45 MP file on one performance core; results (~4 KB: 128 EV-spaced bins × 4
channels + stats) cache in the catalog forever (raw data never changes). The worker runs at
background QoS after scan, newest-first, and also feeds junk detection (§10.6). On-demand requests
(user opens the panel on an uncomputed frame) jump the queue and land ≤400 ms; thereafter instant.
The develop-side histogram and its readout spaces are owned by docs/04-spec-tone.md (D12); this
entry is its cull-time face.

**How it feels.** The sunset question — "is that red channel actually gone?" — answered numerically
(`R 2.1% clipped, G 0.0, B 0.0`) without opening Develop or a second app. ETTR shooters get their
exposure verdict at cull speed.

**Vs. the field.** **Better than FastRawViewer 2.0 because** FRV's entire reason to exist — it is
the only mainstream tool computing raw histograms — is absorbed here *plus* grouping, develop, and
PM-class paging around it; FRV pages on raw decodes, Lumen pages on JPEG and serves truth from cache.
**Better than LrC 15.5 because** LR has no raw histogram at all — its histogram reflects the current
rendering, so cull-time keep/kill exposure judgments are made on processed data; this is a
fifteen-year-old gap LR never closed.

### Shadow-boost and highlight-inspect holds

**What it is.** Two momentary overlays answering the remaining cull-time questions: is there anything
in the shadows, and does highlight structure survive? Held, not applied — inspection, never an edit.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Shadow Boost | hold `[` | +3 EV | Mnemonic: left end of the histogram. Configurable +2/+3/+4 EV |
| Highlight Inspect | hold `]` | −3 EV | Right end of the histogram; reveals surviving highlight structure |
| Applies in | loupe, survey, compare | — | Releases on key-up; never writes to the recipe |

**How it works.** A pure display-transform gain applied to the current texture in linear light
(≤16.7 ms, one uniform change) — on camera-preview frames it is approximate and says so (shimmer
badge rule); on Lumen-rendered previews it is exact. Because it is a display op, it works mid-paging
with zero cost. FRV's equivalent tools write a chosen EV correction to XMP; Lumen doesn't need the
handoff — the develop module is already here, so the *decision* ("keeper, needs +2 EV") becomes a
recipe edit one keystroke later.

**How it feels.** Hold `[`: the shadows lift, the noise floor is visible, the keep/kill call is
informed. Release: the image snaps back. Two keys, zero state.

**Vs. the field.** **Equal to FastRawViewer 2.0 because** Shadow Boost and Highlight Inspection are
FRV's tools, folded in. **Better than LrC 15.5 and Photo Mechanic 6/Plus because** neither has any
momentary-inspection concept at all — LR requires dragging real sliders (an edit), PM shows only the
camera JPEG. No competitor has PM speed + FRV truth in one loop; that combination is this section's
entire point (D36).

---

## 10.6 AI culling assists (evidence, not verdicts)

The market verdict is unanimous (docs/03-research-competitors.md): every serious player converged on
the same four detectors — blink, focus, duplicate grouping, best-of-group — and the loved UIs
(Narrative's face strip, LrC 15.4's Faces panel) surface per-face evidence while the distrusted UX
auto-rejects. "Don't trust it yet" is universal even among fans. Lumen's contract (D37, D5):
**all local, all evidence, never a verdict.** AI groups, orders, badges, and flags; only the user's
keystroke rejects. Master off-switch in Settings. Strictness tunes what gets *flagged*, never what
gets *removed*.

### The assist engine and its OS mapping

**What it is.** A background analysis pass over each new folder producing burst groups, per-face
evidence, sharpness scores, and junk candidates — built almost entirely from Apple Vision APIs, no
bundled models.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| AI assists | master on/off | on | Off = no analysis runs, no evidence UI anywhere (D5) |
| Strictness | 0–100 | 50 | Threshold for attention-dot flagging only |
| Run policy | fixed | after scan, background QoS | Bounded memory, cancelable, never on the paging path |

**How it works.** The detector-to-API mapping (verified against the Vision framework; the
best-of-burst primitive is *designed* for this use):

| Assist | Mechanism | API / technique | Cost & notes |
|---|---|---|---|
| Burst/duplicate grouping | capture-time proximity (≤2 s) + embedding distance | `VNGenerateImageFeaturePrintRequest` → `computeDistance` on grid-size previews | Cheap; runs at scan; groups become stacks (§10.2) + compare seeds (§10.4) |
| Eyes open / blink | 76-pt landmarks → eye-aspect-ratio per face | `VNDetectFaceLandmarksRequest` | Per-face badge; EAR threshold behind Strictness |
| Best-of-burst face quality | Apple's per-face capture-quality score, 0–1, comparable within the same subject/burst | `VNDetectFaceCaptureQualityRequest` | Orders stack members; suggested pick, never auto-pick |
| Focus/sharpness score | variance-of-Laplacian on face regions (whole frame fallback), largest available preview | vImage/Metal kernel; rects from `VNDetectFaceRectanglesRequest` | Per-face badge + frame score; feeds sharpness sort (§10.2) |
| Junk detection | black frames, gross under/over-exposure | own raw statistics (§10.5 worker) | Mirrors C1 16.8 Assisted Review's black-frame filter; flag only |
| Aesthetic triage | overall score + `isUtility` flag | `VNCalculateImageAestheticsScoresRequest` (macOS 15+) | **Sort-only** (§10.2); never flags, never filters by default |

Analysis runs on grid-size previews (fast, and FeaturePrint is resolution-tolerant), throttled to
efficiency cores, memory-bounded, checkpointed per folder, and cancelable the instant the user
scrolls or pages — LrC 15.4's Mac memory-leak freezes came from running heavy ML inside the library
loop (S5); Lumen's pass is structurally outside it. Scores and rects persist in the catalog; nothing
recomputes on browse.

**How it feels.** Nothing, at first — the grid grows attention dots and stacks quietly tighten. All
UI weight lives in the next entry.

**Vs. the field.** **Better than LrC 15.5 because** the detector set matches Assisted Culling +
15.4's Faces/duplicates, but runs strictly out-of-loop (no 15.4-style freezes) and feeds one grouping
engine instead of three disconnected features. **Equal to Aftershoot on detection scope because** the
four detectors are the complete useful set the market converged on; **better on trust model because**
Aftershoot is a subscription app that pre-selects — Lumen is local, free of tiers, and never selects.

### The face strip (evidence UI)

**What it is.** Narrative Select's signature, adopted: a strip of face crops for every face in the
current frame, each badged with eyes-open state and focus quality — a 12-person group shot judged
without zooming.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Face strip | `V` toggle, loupe/survey/compare | off (auto-suggests when >2 faces) | Docked below the image |
| Per-face badges | eyes ●/◐/○, focus ●/◐/○ | — | Green/amber/red thresholds follow Strictness |
| Click a crop | zooms the main view to that face | — | Loupe-hold on a crop shows 100% |
| Suggested pick | outlined crop in stack context | — | From capture-quality ordering; accept = your keystroke |

**How it works.** Crops come from `VNDetectFaceRectanglesRequest` rects over the current preview;
badges read the cached per-face EAR, capture-quality, and Laplacian scores. Hovering a badge shows
the number behind it (EAR 0.14, focus 62) — show me why, let me decide. In compare/survey, strips
align under each pane so the eyes-open comparison across a burst is one glance.

**How it feels.** Group-shot culling stops being zoom-pan-zoom-pan: the strip answers "everyone
sharp, everyone open?" in one look, and clicking the one amber face confirms it at 100%.

**Vs. the field.** **Equal to Narrative Select because** this is its assessments panel, matched
feature-for-feature (crops, eye/focus badges, click-to-zoom). **Better because** it lives beside raw
truth (§10.5) and a develop module, all local with no Pro-tier volume caps. **Better than LrC 15.5
because** LR's 15.4 Faces panel shows scores but is bolted to a scoring workflow users must opt into
per-import; Lumen's strip is ambient evidence on any photo, any time.

### Never auto-reject (the negative spec)

**What it is.** The behaviors Lumen refuses to ship, recorded as spec so no future session "improves"
them in: no auto-rejection, no auto-deletion, no auto-flagging as reject, no hidden composite score
deciding anything, no expression/style-preference models, no cloud (D5, D37).

**How it works / feels.** AI writes only to its own evidence tables — never to `flag`. The junk
detector's output is a *filter chip* ("junk candidates: 34") the user can review and mass-reject
with one explicit keystroke. Aesthetics is sort-only. Strictness moves badge thresholds. The system
degrades to silence, not to wrong verdicts.

**Vs. the field.** **Better than Aftershoot because** Aftershoot's value ("kills the obvious 60–80%")
is preserved — junk chip + evidence ordering achieve the same first-pass triage — while the failure
mode its users hedge against (trusting the AI's taste) is structurally impossible. **Consciously
"worse" than Aftershoot on automation because** Lumen will never finish a cull for you; that is the
point, and the wedding-forum consensus ("first pass, not a decider") says the market agrees.

---

## 10.7 Ingest

### The one-screen verified ingest

**What it is.** The optional copy-off-card step (D38): card auto-detect, verified copy to primary +
backup, rename/folder templates, incremental re-ingest, and culling that starts while the copy runs.
One sheet, no wizard.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Source | auto-detected cards (multiple) / any folder | newest card | DCIM heuristic on mount |
| Primary destination | folder + template preview | last used | Live example filename/path shown |
| Backup destination | optional second volume | off (sticky) | Written in the same pass |
| Folder template | token string | `{year}/{date} {job}` | |
| Rename template | token string | `{date}-{seq4}-{orig}` | Off = keep camera names |
| Job name | free text | empty | Feeds `{job}` |
| Apply at ingest | metadata preset (copyright/creator) + optional develop preset | copyright on | ISO-adaptive defaults (docs/07-spec-denoise.md D27) apply regardless |
| Verify | fixed on | on | Not a checkbox — unverified copy isn't offered |
| Eject when done | checkbox | on | Enabled only after all destinations verify |

Token set — twelve, not Photo Mechanic's 100+ (a solo shooter's scope): `{orig}` `{frame}` `{seq}`
`{seq4}` `{date}` `{time}` `{year}` `{month}` `{day}` `{camera}` `{serial}` `{job}`. Templates save
as named presets. Schema reserves room for GPS tokens later (owner shoots travel; not v1).

**How it works.** Copy streams each file computing xxHash64 in-flight (~30 GB/s on Apple Silicon —
hashing never gates the ~90–900 MB/s card read), then re-reads the destination and re-hashes; only a
matching re-read marks the frame verified in the catalog. Backup destination verifies independently.
Eject is offered only when every frame verifies on every destination — pro paranoia converted into a
mechanical guarantee (PM doesn't checksum; its culture is "format in camera after both copies
confirmed" — Lumen makes the confirmation real). **Incremental re-ingest**: per-card identity =
volume UUID + camera serial + a ledger of ingested filename/size/hash triples; re-inserting a
half-shot card selects only new frames, pre-checked. **Cull-while-copying**: the destination contact
sheet opens immediately and populates as frames verify; embedded previews extract right behind the
copy, so flagging starts within seconds of the first frame landing while the card is still draining.

**How it feels.** Insert card → sheet slides up with everything remembered → Return → grid culling
in under ten seconds while the progress bar works in the corner. Skipped deliberately: FTP/agency
uploaders, IPTC broadcast stationery, code replacements, multi-card parallel ingest stations, card
erase — PM's agency machinery a solo photographer never touches.

**Vs. the field.** **Better than Photo Mechanic 6/Plus because** PM's reference feature set
(dual-destination, incremental, templates, live ingest) is matched where it matters and exceeded on
the one thing PM omits: checksum verification. **Better than LrC 15.5 because** LR's import dialog is
the sprawl anti-pattern (S1) — modes × preview tiers × smart previews × second-copy (unverified) ×
destination trees; Lumen is one screen, verification always on, and browsing never waited on it.

---

## 10.8 Filters and search

### The filter bar

**What it is.** Instant, composable narrowing of any source — the iterative collapse (all → keepers
→ portfolio) that culling actually is — with the boolean power LR refuses: OR across criteria (D39).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Filter bar | `\` toggles | hidden | Chips row above the grid |
| Attribute chips | flag, rating (≥/=/≤), label, edited, stack state, file type, version kind | — | Multi-value within a chip = OR |
| Metadata chips | camera, lens, ISO range, aperture, date range, keyword | — | Values enumerated with live counts |
| Evidence chips | junk candidates, closed-eyes flagged, soft-focus flagged, camera-preview-only | — | §10.6 output as reviewable sets |
| Text | filename, keyword, job, any indexed field | — | Tokenized contains/prefix |
| Match | **All / Any** toggle, plus per-group | All | Any = OR across different criteria |
| Clear | `Cmd+\` | — | One key back to everything |

**How it works.** Every chip compiles to an indexed SQL predicate over the catalog; the bar state is
a serializable query tree (chips AND/OR-composed per the Match toggle, groups nestable one level).
Query ≤50 ms on a 100k-photo catalog; the grid swap rides the standard ≤100 ms discrete budget with
no re-render of unaffected cells. Chip values show live counts (`★≥3 (142)`, `Sony A7 IV (1,203)`)
computed from the same indexes — PM's instant-collapse culture, with numbers.

**How it feels.** "Picks OR ★≥4, minus junk candidates, ISO ≥6400" is four chips and a toggle —
a query LR literally cannot express (its Metadata columns OR within a column but hard-AND across
criteria; the third-party "Any Filter" plugin exists precisely to patch this). Filters are free, so
narrowing becomes reflexive.

**Vs. the field.** **Better than LrC 15.5 because** OR-across-criteria is native, evidence sets are
filterable, and counts are live; LR's filter bar is its "old Lightroom" — functional, AND-only,
plugin-patched. **Better than Photo Mechanic 6/Plus because** PM filters its three axes instantly but
has no metadata query language at all beyond them.

### Saved filters and smart albums

**What it is.** A filter-bar state saved by name; a smart album is the same saved query pinned into
the sidebar with a scope (D39: smart albums *are* saved queries — one engine, two entry points).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Save filter | name + save from bar | — | Appears in bar's preset menu |
| Smart album | saved query + scope (everywhere / a folder subtree / an album) | everywhere | Lives in sidebar; live-updating |
| Edit | reopens the bar populated | — | Query tree is the single format |

**How it works.** Stored as the serialized query tree in the catalog; smart albums re-evaluate via
GRDB observation on the tables they touch, so membership updates live as ratings change mid-cull.
Default set ships: Picks, ★≥4, Unrated, Edited, Junk candidates, Camera-preview-only.

**Vs. the field.** **Equal to LrC 15.5's Smart Collections because** the rule engine covers the same
criteria space (attributes, EXIF, dates incl. relative, keywords, edit state) with Match All/Any and
one level of nested groups. **Better because** filter bar and smart albums are one grammar — in LR
they are two different engines with different capabilities — and because rules can include evidence
and preview-state criteria no competitor exposes.

---

## 10.9 Albums, versions, and batch adjustments

### Albums and the target album

**What it is.** Manual groupings independent of folders: albums (membership lists), album sets, and
a one-key target album for gathering while culling.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| New album / set | sidebar `+` | — | Sets nest one level |
| Add to target | `B` toggle | target = "Tray" | Any album designatable as target |
| Reorder | drag (User Order sort) | capture time | Sequencing for delivery/portfolio |

**How it works / feels.** Membership rows in the catalog; `B` is the same async write path as flags.
The Tray is the scratch pad (LR's Quick Collection, renamed for honesty). Albums feed export (docs/
11-spec-output.md) and Look application set-wide (D4).

**Vs. the field.** **Equal to LrC 15.5 because** collections/sets/target-collection semantics map
one-to-one (`B` included). **Consciously worse than Aperture 3 because** no Light Table freeform
canvas — delightful but a v2+ luxury (docs/16-roadmap.md); drag-reorder in albums covers sequencing.

### Virtual copies (versions)

**What it is.** Parametric duplicates — a color grade and a B&W of one raw — at near-zero cost.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| New version | `Cmd+'` | — | Copies current recipe; names "Version 2…" |
| Stacking | auto-stacks with master | on | Version badge shows count (§10.2) |
| Filter | version kind chip | — | Masters / versions / all |

**How it works.** A version is one extra recipe row (docs/15-catalog.md `edit` table) sharing the
photo's originals and caches below the recipe divergence point (docs/14-pipeline.md prefix cache,
D49) — a B&W version of a denoised master reuses the denoise splice for free.

**Vs. the field.** **Equal to LrC 15.5 and Aperture 3 because** virtual-copy/version semantics are
theirs; **better because** cache sharing makes versions render-cheap, and versions export as recipe
variants in one multi-recipe export pass (docs/11-spec-output.md, D40).

### Relative batch adjustments

**What it is.** LR Quick Develop's one genuinely irreplaceable idea, modernized: *relative* deltas
applied across a selection — each photo moves from where it is, unlike Sync's absolute overwrite.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Exposure | ±1/3 EV, ±1 EV steppers | — | Clamped at slider bounds per photo |
| WB warmer/cooler | ±250 K, ±1000 K steppers | — | |
| Highlights / Shadows | ±5, ±20 steppers | — | |
| Apply Look | preset menu | — | The set-wide grade path (D4) |
| Auto (relative) | button | — | Runs per-photo Auto (docs/04-spec-tone.md D11), each frame individually |

**How it works.** A delta transaction over N recipes (each clamped independently) + background
preview re-renders at viewing priority. Lives in a compact panel on the grid's right rail — visible
where batch work happens, not hidden in a Library-module-only rail like LR's.

**How it feels.** Select the 40 frames from the dim chapel, tap +2/3 EV twice, done — every frame
keeps its own relative exposure relationships. Speed Edit (docs/12-spec-ux.md, D44) covers the same
need fluidly on smaller selections; the steppers are its discrete, grid-native sibling.

**Vs. the field.** **Better than LrC 15.5 because** the concept is LR's own Quick Develop — widely
unknown, visually fossilized, Library-only — kept, surfaced, and joined to the Look system; C1 16.8.4
has no relative-batch equivalent at all (its Adjustments Copy is absolute).

---

## 10.10 Catalog hygiene (invisible)

### Automatic backup, vacuum, and preview lifecycle

**What it is.** Everything LrC makes the user schedule, confirm, or ritually run — backups,
integrity tests, Optimize Catalog, preview discard windows — done automatically and silently (D39).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| — | — | — | No user-facing controls. A Settings > Storage pane *reports* (cache size, last backup, last check) and offers one "Reveal backups" button |
| Preview cache budget | 5–100 GB | 20 GB | The single knob, with live usage shown |

**How it works.** On quit when dirty (and at most daily): `VACUUM INTO` a dated backup, keep last 10
dailies + 4 weeklies, prune automatically. `PRAGMA quick_check` weekly at idle; a failed check
restores the newest good backup with a plain-language notice — never a "catalog corrupt" dead end.
Incremental auto-vacuum keeps the DB compact; there is no Optimize menu item because there is no
ritual to perform (kills S4). Preview lifecycle: LRU eviction within the budget; 1:1 tiles evicted
after 30 days unused; embedded previews superseded by Lumen renders are dropped; orphans swept on
scan. AI artifact caches are versioned and self-healing (D52 — a corrupt cache regenerates silently;
LrC's "delete `.lrcat-data` and let it rebuild" folklore is the named anti-pattern). Schema and file
layout: docs/15-catalog.md.

**How it feels.** Nothing. That is the spec. The catalog is plumbing; the user thinks about
photographs.

**Vs. the field.** **Better than LrC 15.5 because** LR ships six backup-frequency choices, two
checkbox rituals, a manual Optimize command, four preview types with a discard preference, and
folklore-driven sidecar surgery; every one of those is a decision Lumen's user never makes. **Better
than Photo Mechanic Plus because** PM Plus's optional catalog is a bolt-on users distrust; Lumen's is
invisible enough to be trusted by default — and the XMP sidecar mirror (§10.1) means even total
catalog loss costs bookkeeping, not work.

---

## 10.11 Second window / dual display

### The pinnable viewer window

**What it is.** A second window (`Cmd+F11` — LR-compatible) showing a loupe of the current selection
on another display — or pinned to one reference image — with keyboard focus rules that never break
the cull.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Second window | `Cmd+F11` toggle | off | Full-screens independently on its display (system full screen, D46) |
| Mode | follow selection / pinned | follow | Pin (`Shift+F11` or pin button) locks the current image as reference |
| View | loupe / survey mirror | loupe | Zoom/pan independent of main window |
| Info overlay | `I` cycle, independent state | off | |

**How it works.** The viewer renders from the same texture caches (no duplicate decodes) and follows
the selection via catalog observation. **The keyboard rule: keys follow the cull, not the mouse.**
Cull keys (P/X/U, digits, arrows, view keys, holds) route to the browse controller regardless of
which window is frontmost; the viewer window never captures them — it accepts only its own zoom/pan
gestures and explicit text fields. This kills the documented LR annoyance where the secondary window
steals focus and shortcuts silently die.

**How it feels.** Classic two-display culling: grid on the laptop, full-screen loupe on the
reference display — or pin the client's mood-board frame on screen two while grading the set on
screen one. Hands never leave the cull keys; the second display never eats a keystroke.

**Vs. the field.** **Better than LrC 15.5 because** LR's second window is feature-equivalent but its
focus-stealing is a standing community complaint Lumen fixes by routing rule, and LR has no pin mode.
**Equal to Aperture 3 because** true dual-display culling (viewer + browser) was Aperture's; this is
that, with modern focus discipline.

---

## 10.12 The field, summarized

Every verdict above, against the four benchmarks this doc was scored on:

| Benchmark | What it owns | Lumen's position |
|---|---|---|
| Photo Mechanic 6/Plus | Paging speed, ingest reference, three refusals | **Match** speed (same architecture, parameters written down: N=8/M=2, <50 ms) and **add** what PM refuses: raw truth, verified copy, AI evidence, and the develop module the survivors flow into |
| Lightroom Classic 15.5 | Culling grammar, filter/collection machinery, the workflow standard | **Keystroke-compatible** where its grammar is right (P/X/U, 1–5/6–9, G/E/C/N/B, Painter, Quick-Develop-relative), **beat the five slownesses** (S1–S5) that make its library the part users resent |
| FastRawViewer 2.0 | Raw histograms, clipped stats, boost/inspect holds, peaking | **Absorbed** — every truth instrument, in the cull loop instead of a second app, served from cache instead of per-page raw decodes |
| Aftershoot / Narrative Select | AI culling assists, face evidence UI | **Local evidence model** — Narrative's face strip and Aftershoot's triage value, from OS APIs, no subscription, no upload, structurally incapable of auto-rejecting |

The one-window combination — PM-class paging, FRV-class truth, Narrative-class evidence, LR-class
grammar, beside a full develop module — exists nowhere else. Each ingredient is proven; the product
is the union.

Phasing: the browse skeleton (grid, loupe, prefetch — the first-browse and photo-switch release
gates, D47) is Phase 1; the catalog, culling grammar, raw-truth instruments, stacks, filters, and
verified ingest are Phase 2; AI assists, smart albums, and the second window land in the dailies —
docs/16-roadmap.md owns the schedule and exit tests.
