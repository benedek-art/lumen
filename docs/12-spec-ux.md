# 12 — UI & Interaction

Interaction is not styling. This document specifies Lumen's interaction layer the way
docs/14-pipeline.md specifies the render graph: as an engineered subsystem with numeric budgets, a
complete keyboard grammar, and named research behind every rule. The 22 UX laws distilled in the
research sweep (digest r12) are adopted wholesale (D43–D47); this doc turns them into buildable
specification. Feature-specific interactions live with their features (mask overlays in
docs/08-spec-masking.md, culling grammar in docs/10-spec-library.md, histogram instrumentation in
docs/04-spec-tone.md); this doc owns the systems those docs plug into: layout, latency contract,
the canonical keymap, sliders, chrome, compare, history, disclosure, and platform behavior.

Two convictions organize everything below. First: **users experience five different latencies but
assign them one brand.** Lightroom's slowness is five separate engineering failures — import/preview
build, grid scroll, develop-slider lag, AI waits, catalog rituals — and its users call all five
"Lightroom is slow." Lumen wins the perception war only by winning all five loops, so the loops are
release gates, not aspirations (§12.2). Second: **muscle memory is an inheritance, not an
implementation detail.** Fifteen years of Lightroom tutorials trained the market's hands
(P/X/U, `\`, double-click-reset, Alt-drag diagnostics). Lumen adopts that grammar
keystroke-for-keystroke wherever it is good, and deviates only where the deviation is the product.

---

## 12.1 Layout: one context, three panes

### The module-less window

**What it is.** One window, three panes, no modules. Grid, loupe, compare, and survey are *views*
of a single context in which every panel and tool is always available. There is no Library/Develop
wall to cross.

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Toolbar (customizable center, HIG)                        [workspaces ▾] │
├───────────┬───────────────────────────────────────────────┬──────────────┤
│ Sources   │                                               │ Histogram    │
│  Folders  │                                               ├──────────────┤
│  Albums   │              Canvas                           │ DEVELOP      │
│  Filters  │        (grid / loupe / compare /              │  WB           │
│  ─────    │         survey — G/E/C/N)                     │  Tone         │
│ History   │                                               │  Render       │
│ Snapshots │                                               │  Curve        │
│           │                                               │  Presence     │
│           │                                               │  Detail/NR    │
│           │                                               │  Optics       │
│           │                                               │ LOOK         │
│           │                                               │  Looks        │
│           │                                               │  Color        │
│           │                                               │  Grading      │
│           │                                               │  Film Lab     │
│           │                                               │  B&W          │
│           │                                               │  Effects      │
├───────────┴───────────────────────────────────────────────┴──────────────┤
│ Filmstrip (always available, `Shift+Tab` hides with the rest)            │
└──────────────────────────────────────────────────────────────────────────┘
```

**How it works.** Left pane: sources (folders are the library, docs/10-spec-library.md), saved
filters and albums, and — LR's one good left-rail idea — the History and Snapshots panels (§12.10).
Right pane: the panel stack in canonical order (below). Bottom: the filmstrip, a one-row grid
backed by the same thumbnail cache as the grid view — no second preview system. `Tab` collapses
the side rails; `Shift+Tab` collapses everything but the canvas. Tools that take over the canvas
(crop `R`, heal `Q`, masking `Shift+W`) are toolbar tools within the same context, not
destinations. In grid view the panel stack operates on the selection — dragging Exposure with 40
frames selected is a relative batch edit (semantics in docs/10-spec-library.md §10.9). That is
only possible because grid and develop are one context.

**Why no modules — the argument.** Lightroom's module wall is 2007 architecture that costs users
daily: entering Develop takes multi-second delays when AI masks exist (0.5–10 s freezes reported
on Ryzen 7/RTX-class hardware, the 15.0 regression that drove rollbacks to 14.5.2); Library and
Develop maintain *separate preview systems* (Library previews vs Camera Raw renders), which is the
root of the "my photos changed!" import jump; and half the keyboard means different things on each
side of the wall as a side effect rather than a design. Meanwhile every editor praised for feel —
Photo Mechanic, Capture One (tool tabs, one context), Aperture (one library, viewer modes),
Photomator — is module-less. The counter-argument for modules is focus: a culling surface without
edit clutter. Lumen gets that from *views plus workspaces* (§12.12): the Cull workspace hides the
panel stack entirely, giving Photo Mechanic's emptiness without an architectural wall behind it.

**Vs. the field.** **Better than LrC 15.5 because** the module boundary is LR's largest structural
tax — duplicated previews, module-switch latency, split keymap — and Lumen simply doesn't build
it. **Equal to Capture One 16.8.4 because** C1's single-context tool-tab model proves the design
at pro scale; Lumen adds what C1 lacks: a keystroke-compatible LR grammar inside that single
context.

### Panel order: the canonical workflow order, encoded

**What it is.** The right-rail order is not alphabetical and not historical accident — it is the
canonical order of operations that four independent traditions converge on (Hullfish's colorists,
Margulis's PPW, Kelby's 7-Point, Freeman; the convergence table lives in
docs/01-research-literature.md Part VII): base rendering → balance → tone → global color → local →
detail. Tone above color, global above masking, detail after color, output at export.

| # | Panel | Group | Owner | Canonical step |
|---|---|---|---|---|
| 0 | Histogram (pinned, always visible) | instrument | docs/04-spec-tone.md | — |
| 1 | White Balance | Develop | docs/04-spec-tone.md | Cast/balance |
| 2 | Tone (six sliders; Zones behind disclosure) | Develop | docs/04-spec-tone.md | Tone & contrast |
| 3 | Render (display-transform preset + contrast/skew) | Develop | docs/04-spec-tone.md | Base rendering |
| 4 | Curve (parametric/point/RGB/Luma) | Develop | docs/04-spec-tone.md | Tone & contrast |
| 5 | Presence (Texture/Clarity/Dehaze) | Develop | docs/06-spec-detail.md | Tone (local contrast) |
| 6 | Detail (Sharpen) / Denoise | Develop | docs/06, docs/07 | Detail (capture pass automated at import) |
| 7 | Optics (lens corrections, defringe) | Develop | docs/09-spec-geometry.md | Normalization |
| 8 | Looks (browser, §12.9) | Look | this doc + docs/05 | Global color entry point |
| 9 | Color (Mixer, Point Color) | Look | docs/05-spec-color.md | Global color |
| 10 | Grading (wheels, printer lights) | Look | docs/05-spec-color.md | Global color |
| 11 | Film Lab | Look | docs/05-spec-color.md | Global color |
| 12 | B&W | Look | docs/05-spec-color.md | Global color |
| 13 | Effects (grain, vignette) | Look | docs/06-spec-detail.md | Look finishing |
| — | Masks (floating/docked via `Shift+W`) | local | docs/08-spec-masking.md | Local/secondaries |
| — | Export (recipe sheet, not a panel) | output | docs/11-spec-output.md | Output |

The Develop/Look group headers are visible and load-bearing: they are the seam of D4's
Develop/Look split (docs/00-vision.md §4), so the panel stack itself teaches the product's central
idea. Three deviations from the literature's order are deliberate and inherited from it: capture
sharpening/profiled NR run at import, not as a workflow step (Fraser); output sharpening is an
export-recipe field, not a panel (PhotoKit precedent); and **the order is a default, never a gate**
— every panel works in any order (Hullfish's tool-agnosticism), the layout merely makes the
canonical path the path of least resistance.

**Vs. the field.** **Better than LrC 15.5 because** LR's panel order (Basic → Tone Curve → HSL →
Color Grading → Detail → Optics → Effects) buries detail *below* color yet runs sharpening
conceptually first, and offers no visible normalize-vs-look seam. **Better than darktable 5.6
because** dt's pixelpipe-order-as-module-order is honest but demands the user already understand
the pipeline; Lumen encodes the workflow, not the DAG.

---

## 12.2 The latency contract (D43, D47)

### The perceptual basis

The budgets are not taste; they are measured human thresholds:

- **Direct manipulation:** Deber, Jota, Forlines & Wigdor (CHI 2015, "How Much Faster is Fast
  Enough?") measured perceivability floors of **~11 ms for direct dragging**, ~55 ms for indirect
  (mouse/trackpad-class) dragging, and ~64–96 ms for tapping. Ng, Wigdor, Dietz et al. (UIST 2012,
  the 1 ms touchscreen) found a dragging JND near ~2 ms and showed that at ~100 ms a dragged
  object visibly trails the pointer "like it is attached by a rubber band." Jota et al. (CHI 2013)
  found task *performance* in dragging degrades above ~25 ms even when users cannot articulate why.
- **Discrete actions:** Card, Robertson & Mackinlay (1991), popularized as Nielsen's three limits
  (1993): **0.1 s** reads as instantaneous; **1 s** preserves flow but the delay is noticed and the
  feeling of operating directly on the object is lost; **10 s** is the attention limit, beyond
  which determinate progress and cancel are mandatory.
- **Frames:** 16.7 ms at 60 Hz, 8.3 ms at 120 Hz ProMotion. The budget is the whole input→photon
  path — event delivery, pipeline, compositor, scanout — not the kernel time alone.
- **Scrolling:** smoothness is judged by frame-time *consistency*, not average fps; a single
  dropped frame mid-flick is visible. Apple's Instruments treats hitch-rate as the scroll KPI,
  and so does Lumen.

Translation: one frame reads as "attached," ~50 ms reads as "fast app," 100+ ms reads as "laggy
Lightroom." Adobe's own patch notes concede the territory — 15.0 "everyday editing gets faster,"
15.3 "interactive-slider performance," 15.4 "brush responsiveness" — every fix a
move-work-off-the-input-path fix, years late.

### The budget table

| Interaction | Budget | Mechanism |
|---|---|---|
| Slider / wheel / brush / pan / crop drag | ≤16.7 ms to a visible, honest change (target ≤8.3 ms on ProMotion) | Proxy-resolution pass first; pipeline-prefix cache, downstream-only recompute (D49) |
| Progressive refine to full quality | ≤200 ms after drag pause | Full-res tile pass replaces the approximation; no visible reflow, no flicker |
| Discrete action: photo switch, panel open/close, rating write, filter collapse, view switch | ≤100 ms perceived | Nothing synchronous on the input path; metadata/XMP writes async (LR's per-edit XMP flush, fixed only in 14.4, is the anti-pattern) |
| Cull paging | <50 ms, gated only by key repeat | Direction-aware prefetch, embedded-first decode (D34, docs/10-spec-library.md) |
| Grid scroll | zero hitches at 120 Hz with 10k thumbnails | Decode, badge layout, and DB reads all off the scroll path |
| Looks hover-preview first paint | ≤100 ms | Precomputed proxy renders (§12.9) |
| AI denoise | ≤10 s at 45 MP | ANE tiling, background lane (docs/07-spec-denoise.md) |
| AI mask proposal, undo/redo, history time-travel | ≤100 ms to visible state | Cached rasters (D30); recipes are cheap state |

**Nothing synchronous on the input path, ever** is the one-sentence architecture law behind the
table. Every one of LR's five slow loops traces to a violation: synchronous mask re-evaluation,
per-edit XMP flushes, blocking preview builds, synchronous AI-mask recompute on batch sync (15.0).
And the Ansel rewrite quantifies what obeying the law is worth against darktable 5.0: parameter
changes 5.4–40× faster from downstream-only recompute, scrolling 7×, view switching 6×, export
1.27–100× from reusing the interactive cache prefix. Cache-prefix reuse plus downstream-only
invalidation is the single highest-leverage engine decision for perceived speed; it is canon in
docs/13-architecture.md and docs/14-pipeline.md.

### Progressive refine and the progress ladder

Perceived ≠ measured. Showing *something honest* within one frame — the proxy render of the new
slider value — buys the instant feel while the full-quality pass completes. The refine pass must
be visually monotone (quality only improves, never pops brighter/darker), which is why proxy and
full passes share one pipeline at two resolutions rather than two algorithms (docs/14-pipeline.md).

For anything longer than a frame, the **progress ladder** (Nielsen's limits + HIG "passive status
near the item"):

| Duration | UI |
|---|---|
| <1 s | Nothing. No spinner, no flash. |
| 1–10 s | Inline, in-place activity indicator on the affected item (panel row, thumbnail badge); result lands in place |
| >10 s | Determinate progress + cancel + automatic background mode: a badge, per-image ETA on batches, notification chip on completion |
| Always | **Never a modal progress dialog for AI or export.** The app remains fully interactive; the queue is inspectable |

### The five-loop release gate

D47: five loops are measured in CI on the owner's actual hardware, per release, with hard numbers:

1. **First browse** — mount a card / open a folder → complete scrollable contact sheet (budget in
   docs/10-spec-library.md; the Photo Mechanic loop).
2. **Grid scroll** — zero hitches at 120 Hz, 10k-image folder.
3. **Slider drag** — ≤16.7 ms visible change, ≤200 ms refine, measured input→photon.
4. **Photo switch** — <50 ms cull paging; ≤100 ms with full recipe render in develop.
5. **AI round-trip** — denoise ≤10 s/45 MP; mask proposal to visible overlay within its budget.

**A feature that busts its loop does not ship** — it goes back for async restructuring or dies.
This is a product law, not a QA preference: ON1 and Luminar prove that feature count without a
performance budget becomes the brand ("feature-rich and slow"); LrC 15.4 — *pulled* for Denoise
posterization and AI-culling memory leaks that froze Macs — proves stability is UX and taught
working photographers "never update mid-season." Lumen ships to its owner weekly
(docs/16-roadmap.md); golden-image plus latency regression suites are what make that safe.

**Vs. the field.** **Better than every competitor because no competitor publishes or enforces
latency budgets at all** — the entire category ships by feel, and the feel is measurably bad
(LrC 15.x patch-note archaeology; C1's launch-slow Enhanced Denoise; ON1's beachballs). The gate
is Lumen's structural moat: architecture can be copied, discipline apparently can't.

---

## 12.3 The keyboard system

### The grammar

Flat keys, no modes. Vim's lesson: composable modal grammars reward daily mastery and terrify
everyone else, so every keyboard-loved photo tool (PM, LR, C1, Resolve's grading keys) chose flat
single keys plus modifiers — Lumen too. Keys are **view-scoped, never mode-scoped**: a key may
mean different things in grid vs. loupe vs. an active canvas tool, but the scope is always the
thing you are looking at, never hidden state. Two laws bind the whole table (Apple HIG,
generalized): **every action has a key, and every key action has a menu item** — no keyboard-only
secrets (LR's Caps-Lock auto-advance folklore is the anti-pattern; Lumen's auto-advance is a
visible toolbar toggle), and no pointer-only paths. All bindings are remappable; the defaults
below are the contract.

**Global (any view).**

| Key | Action | Menu |
|---|---|---|
| `Cmd+Z` / `Shift+Cmd+Z` | Undo / Redo (labeled: "Undo Exposure") | Edit |
| `Space` | Toggle fit ↔ 100%, centered on cursor | View ▸ Zoom |
| `` ` `` (hold) | Loupe magnifier (docs/10-spec-library.md) | View ▸ Loupe |
| `Tab` / `Shift+Tab` | Hide side rails / hide all chrome | Window |
| `I` | Info overlay cycle (EXIF strip: focal/ISO/f/shutter always one tap away) | View ▸ Info |
| `J` | Clipping overlay (docs/04-spec-tone.md) | View ▸ Clipping |
| `F` | Focus peaking (docs/10-spec-library.md) | View ▸ Peaking |
| `L` | Lights-out cycle (§12.7) | View ▸ Lights Out |
| `Cmd+B` | Assessment surround, ISO 12646 (§12.7) | View ▸ Assessment |
| `Ctrl+Cmd+F` | System full screen | View |
| `Cmd+F11` / `Shift+F11` | Second window / pin reference (docs/10-spec-library.md §10.11) | Window |
| `Cmd+Shift+C` / `Cmd+Shift+V` | Copy / paste settings (with scope sheet) | Settings |
| `Cmd+Shift+E` | Export (recipe sheet, docs/11-spec-output.md) | File |
| `Cmd+'` | New snapshot (§12.10) | Photo |

**Culling and views** (semantics owned by docs/10-spec-library.md; listed here as the canonical
inventory — LR keystroke-compatible per D35):

| Key | Action |
|---|---|
| `P` / `X` / `U` | Pick / Reject / Unflag (auto-advance default-on, visible) |
| `1–5`, `0` | Stars; clear |
| `6–9` | Color labels |
| `G` / `E` / `C` / `N` | Grid / Loupe / Compare / Survey |
| `B` | Add to target album |
| `S` / `Shift+S` | Collapse-expand stack / promote pick; `Cmd+G` stack, `Cmd+Shift+G` unstack |
| hold `[` / hold `]` | Shadow Boost +3 EV / Highlight Inspect −3 EV (cull views) |
| `V` | Face strip toggle |
| `\` | Filter bar (grid scope) |
| `Cmd+Delete` | Delete rejects (to `_Rejected`, reversible) |

**Develop (loupe scope).**

| Key | Action |
|---|---|
| `\` | Before/After (§12.8) |
| `Y` / `Alt+Y` / `Shift+Y` | Side-by-side / top-bottom / split compare |
| `Shift+R` | Reference view (§12.8) |
| `W` | WB eyedropper (docs/04-spec-tone.md) |
| `T` | Targeted Adjustment Tool (§12.6) |
| `R` | Crop (docs/09-spec-geometry.md; `O`/`Shift+O` overlays, `X` flip inside the tool) |
| `Q` | Heal/Clone/Remove (docs/09-spec-geometry.md; `/` re-rolls source) |
| `Cmd+U` / `Cmd+Shift+U` | Auto settings / Auto WB |
| `.` / `,` | Step through pins/spots (review skim) |

**Masking (`Shift+W` scope)** — full semantics in docs/08-spec-masking.md §8.6: `K` brush, `M` /
`Shift+M` linear/radial, `O` / `Shift+O` / `Alt+O` overlay toggle/color/mode, `'` invert, `[` `]`
size, `Shift+[` `]` feather, digits = flow, `A` automask, hold-`Alt` erase.

**How it works.** One dispatch table per view scope, resolved before any other event handling;
key-repeat drives paging directly (PM's gating trick). The menu bar is generated from the same
command table as the dispatcher, so key↔menu parity is structural, not a checklist — a command
without a menu item fails a unit test. Remapping edits the same table; a conflict inspector
(darktable's visual mapping, simplified) shows collisions per scope.

**Vs. the field.** **Equal to LrC 15.5 on the culling and compare grammar because** compatibility
*is* the feature — fifteen years of tutorials transfer on day one. **Better than LrC because**
every binding is remappable, every action is in a menu, and nothing (auto-advance included) hides
behind folklore. **Better than Photo Mechanic 6/Plus because** PM's speed grammar exists here
inside a full editor. **Consciously worse than darktable 5.6's map-any-key-to-any-widget because**
Lumen curates a smaller remappable set; dt's total freedom is also total configuration burden.

---

## 12.4 Speed Edit (D44)

**What it is.** Capture One's best ergonomic idea, shipped with curated defaults: hold a mapped
key and drag, scroll, or arrow-key **anywhere** — the slider never needs to be visible or clicked.
Reception in C1 was universal ("rather genius," "second nature within a few minutes," "a serious
timesaver… especially if you edit hundreds of files"); darktable's visual shortcut mapping proves
the mechanism generalizes.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Hold `E` | Exposure | mapped | All holds fully remappable, Settings ▸ Speed Edit |
| Hold `C` | Contrast | mapped | |
| Hold `H` / `S` | Highlights / Shadows | mapped | |
| Hold `W` / `T` | Temperature / Tint | mapped | Tap `W` remains the eyedropper; tap `T` the TAT |
| Hold `K` | Look Amount (active Look layer) | mapped | Outside masking scope |
| Hold `M` | Active mask Amount | mapped | When a mask is selected |
| Drag / scroll / arrows while held | full slider range | — | Same step grammar as the slider contract: `Shift` ×10, `Alt` fine |
| Tap-vs-hold threshold | 150 ms or any pointer/scroll movement | — | Plain tap fires the key's tap action; hold+input engages Speed Edit |
| Ghost readout | on-image HUD pill | always | Slider name, value, delta; at cursor |
| Scope | all selected images | — | Relative application across the selection (batch semantics: docs/10-spec-library.md §10.9) |

**How it works.** The hold routes input to the mapped parameter through the same recipe-edit path
as the slider — one code path, so budgets, coalesced undo (§12.10), and batch semantics are
inherited, not reimplemented. Tap/hold discrimination is what lets Speed Edit share letters with
tap commands without modes: `E` tapped is loupe view, `E` held with a scroll is Exposure. The
ghost readout is the discoverability answer to C1's one weakness (buried defaults) and dt's
(mapping-mode ceremony): the mapping is *visible at the moment of use*, and Settings ▸ Speed Edit
shows the full map on one screen.

**How it feels.** Eyes never leave the image; the pointing cost of editing (the Fitts tax of
acquiring a 200-px slider row) drops to zero. In full-screen review with 300 selected frames,
hold-`E`-scroll is set-wide exposure matching at the speed of thought — this plus printer lights
(docs/05-spec-color.md) is Lumen's shot-matching story.

**Vs. the field.** **Equal to Capture One 16.8.4 on the core mechanism because** it is C1's
design, adopted with gratitude. **Better because** of the ghost readout, tap/hold sharing (C1
reserves its keys), and mask/Look Amount targets C1 doesn't map. **Better than LrC 15.5 because**
LR has nothing in this category at all — every edit requires pointing at a slider.

---

## 12.5 The slider contract (D45)

**What it is.** One interaction contract for every slider in the app — tone, color, detail, mask,
export. A slider is Lumen's most-used control; its ergonomics are specified once, inherited
everywhere, and tested as a component.

**Controls (the full inventory — every row applies to every slider).**

| Behavior | Spec | Source |
|---|---|---|
| Click/drag anywhere on the row | Whole row height including label is the hit target | darktable's five-way slider |
| Scrubby number | Drag the value readout for fine control | LR convention |
| Typed entry | Click or `Return` on focus; accepts arithmetic (`x/2+0.5`, `+1.3`) | darktable |
| Arrow nudge | `↑`/`↓` when focused or hovered; `Shift` = ×10, `Alt` = fine (÷10) | LR + dt step scaling |
| Double-click | Reset to default | LR/dt/Pixelmator; RapidRAW #26 asked for it by name |
| `Cmd`+double-click | Reset to auto / applied-preset value | dt's Ctrl-double-click |
| Per-slider Auto | Visible affordance (small `A` button on hover), never Shift-double-click folklore | fixes LR's hidden convention |
| Soft/hard limits | Drag stops at soft limit; typed entry and `Shift+Alt` drag reach hard limit | dt (e.g. Exposure soft −5..+5 EV, hard wider — per-slider in owning docs) |
| Wheel adjust | **`Alt+scroll` only; bare scroll never edits** | resolves the dt-vs-LR debate: dt's bare-wheel editing causes accidental edits while scrolling the panel stack; LR's no-wheel loses a fast path |
| Haptic detent | Optional Force Touch "Alignment" tick at default value and range ends | Apple HIG playing-haptics — sanctioned for exactly this |
| Alt-drag diagnostics | Threshold/clipping visualization where the owning doc defines one (tone, sharpening) | LR's beloved Alt-views |
| Default tick | Small mark at the default position; value readout always visible | HIG sliders |

**How it works.** One SwiftUI/AppKit component; every parameter binds through it. Drag events
feed the recipe engine at input rate; renders are frame-coalesced (last value wins per frame) so a
fast drag never queues stale renders. Undo coalescing is the component's job (§12.10), not each
panel's.

**How it feels.** The contract is deliberately boring: hands learn one slider, know every slider.
The LrC 15 double-click-reset regression — which generated instant complaint threads — is the
proof that these micro-conventions are muscle memory, i.e., load-bearing. They get regression
tests accordingly.

**Vs. the field.** **Better than LrC 15.5 because** LR lacks arithmetic entry, soft/hard limits,
visible per-slider auto, and wheel adjustment, and just shipped a reset regression Lumen's test
suite makes impossible. **Better than darktable 5.6 because** Lumen keeps dt's full power
(arithmetic, limits, precision stepping) while fixing its accidental-scroll-edit flaw and dropping
the right-click precision popup for plain `Alt` stepping. **Better than Capture One 16.8.4
because** C1's sliders meet none of the dt-grade power features; its ergonomic depth lives in
Speed Edit alone, which Lumen also has.

---

## 12.6 Direct-on-image manipulation

The doctrine, distilled from the U-Point/PhotoLab history: **direct manipulation everywhere it is
cheap, never as the only path.** Nik's on-canvas equalizer was fast and in-context but cramped;
DxO moved it to a docked palette in PL7 and reviewers approved the scale while mourning the
directness. The lesson is that these are not alternatives: every on-image gesture in Lumen is
mirrored by a panel control, and every in-context HUD obeys the **≤3 controls rule** — at most
three controls float near the canvas object (HIG-sanctioned dark HUD panel); the full inspector
always holds the complete set.

### Targeted Adjustment Tool

**What it is.** `T`: drag up/down on the photo to drive the active curve or color-mixer band —
LR's "right interaction," which hides the 8-band decomposition behind pointing at the thing you
mean.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Drag ↑/↓ on image | target parameter range | — | Curve (parametric or point), Mixer H/S/L, B&W mix — target chosen by active panel |
| `Alt` while dragging | fine sensitivity | — | LR convention |
| Hover + arrows | nudge the sampled band | — | |
| Readout | ghost pill: band + value | always | Same HUD component as Speed Edit |

**How it works.** Cursor position samples the pre-Look pipeline value (hue/luma under cursor),
maps to the owning control's band weights, and edits the recipe through the standard slider path —
budgets and undo inherited. **Vs. the field:** **equal to LrC 15.5** (its TAT, cloned, with the
ghost readout added); **better than Capture One 16.8.4 and darktable 5.6**, which have no
general-purpose TAT.

### Draggable histogram and scroll-to-dodge

The histogram's five draggable zones (Blacks/Shadows/Exposure/Highlights/Whites) and clipping
interactions are specified in docs/04-spec-tone.md; this doc supplies the law that they exist as
*input devices*, not just instruments. The Zones panel adds darktable's best gesture, the
tone-equalizer cursor: with Zones active, **hover any image region and scroll** to lift or darken
the EV zone under the cursor — dodge and burn as a scroll, mirrored live by the zone sliders and
the histogram pivots. Budget: one frame, like any slider (the zone weights are a cached
guided-filter mask, docs/04-spec-tone.md). **Vs. the field:** **equal to darktable 5.6** (its
gesture, adopted) and **better than LrC 15.5**, which has draggable histogram zones but no
spatial scroll-to-dodge.

### Mask-pin scrub and the HUD rule

Every mask pin supports `Alt`-drag to scrub that mask's Amount (0–200) in place — LR's gesture,
kept — and selecting a pin raises the in-context HUD: Amount, Feather, and the one
component-specific control (≤3 total), with the full mask inspector one glance away in the panel
(docs/08-spec-masking.md). **Vs. the field:** **equal to LrC 15.5 on the scrub, better on the
HUD** — LR has no in-context mask controls at all; **better than DxO PhotoLab 8, consciously
learning from it** — PL7's equalizer removal showed in-context and docked "are not mutually
exclusive," so Lumen ships both.

---

## 12.7 Chrome & viewing conditions (D46)

### Neutral gray chrome

**What it is.** The chrome is achromatic dark gray in the 18–25% reflectance-equivalent zone —
zero chroma, no accent-color tinting, ever.

**How it works / why.** Viewing conditions are part of the imaging pipeline (Fairchild's
appearance phenomena, docs/01-research-literature.md): a too-dark surround makes the image look
brighter (Adelson checker-shadow), less saturated (Hunt effect), and flatter (Bartleson–Breneman),
so users over-cook contrast and saturation and deliver too-dark prints. darktable's manual states
it outright — "a low user interface brightness causes all kinds of illusions… can lead to
excessive retouching" — and its default theme sits at middle gray, darkened only slightly for
text contrast. Colored chrome adds chromatic-adaptation and simultaneous-contrast errors on top,
which is why Lumen's grays are semantic but never inherit the macOS accent color. Apple's HIG
explicitly blesses a dark-only appearance for "an app that supports immersive media viewing…
that lets the UI recede"; text contrast stays ≥4.5:1 (target 7:1). Lumen ships one appearance —
this one — and no theme gallery: themes are viewing-condition liabilities in a color-critical
tool.

**Controls / feels.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Canvas surround | white · light gray · mid gray · dark gray · black | dark gray | Per-view (grid/loupe), right-click the canvas — LR's convention |
| Lights Out | `L` cycles normal → dim chrome → black-out | normal | Chrome dims to near-black; image untouched |
| Assessment mode | `Cmd+B` | off | Below |

### Assessment mode (ISO 12646)

**What it is.** One key, `Cmd+B`: the image is surrounded by a mid-gray border with a thin white
frame — the ISO 12646 soft-proof surround — for final tonal judgment before export or print.

**How it works.** Pure compositor change: canvas surround forced to mid gray (the working
display transform's mid-gray, docs/04-spec-tone.md), thin white strip at the image edge as the
diffuse-white anchor, chrome dimmed. Zero pipeline cost; instant toggle. It exists because the
three illusions above are strongest exactly when it matters most — the last look before delivery.

**Vs. the field.** **Equal to darktable 5.6 because** this is dt's color-assessment mode, adopted
with its rationale. **Better than LrC 15.5 and Capture One 16.8.4 because** neither has any
assessment mode; LR's Lights Out dims to black, which is the *wrong* surround for judging tone.
On chrome neutrality all serious editors already agree (LR, C1, dt are all neutral gray); Lumen is
equal there and merely refuses the theming escape hatches.

---

## 12.8 Before/after & compare

### Before/After

**What it is.** LR's compare grammar, keystroke-compatible, with a configurable "before" state.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Toggle | `\` | — | Full-view flip; badge shows "Before" |
| Side-by-side / top-bottom / split | `Y` / `Alt+Y` / `Shift+Y` | — | Split draws a draggable divider |
| Before state | Original · Import default · any Snapshot · custom pin | Import default | LR hardwires "before" to import; pinning any history state is the upgrade |
| Panel peek | eye icon per panel: hold = bypass, `Alt`-click = latch | — | LR's per-panel switches, kept |

**How it works.** "Before" is just another recipe evaluated through the same pipeline; both sides
render from the shared tile cache, so the flip is a compositor swap within one frame. Split view
renders both recipes on the same tiles with a scissor — cost is one extra pass on visible tiles
only.

**How it feels.** `\` is the hundred-times-a-day key; it must feel like flipping a print over,
which is why the budget is one frame, not 100 ms. RapidRAW's tracker showed the demand ladder in
the wild: users given only a toggle immediately asked for side-by-side ("difficult to remember
every detail").

### Reference view and instant A/B

`Shift+R` locks any frame as a reference beside the active photo — shoot-matching across a set —
with **Sync**: one click pushes the active Develop deltas (or the Look layer, D4's real answer)
to the compared frame. And the library loop keeps **neighbors cached at full resolution**
(current ±1 at 1:1, docs/10-spec-library.md), so flipping between two *different* candidate
photos is instant — the RapidRAW #26 ask ("keep the last few photos in cache in full resolution")
served by the prefetch architecture that already exists for culling.

**Vs. the field.** **Equal to LrC 15.5 on grammar because** `\`/`Y`-variants/Reference are LR's
and transfer untouched. **Better because** the before-state is pinnable (LR's is fixed),
snapshots hover-preview from cache rather than re-render, and neighbor full-res caching makes
cross-photo A/B instant where LR re-renders. **Better than darktable 5.6 because** dt's
snapshots-with-slider compare is equivalent power with worse ergonomics (no single-key flip
culture); dt's second-window pin survives in Lumen's pinnable viewer
(docs/10-spec-library.md §10.11).

---

## 12.9 Looks browsing

**What it is.** One browser for every look — camera-matching base looks, Film Lab stocks, user
presets — implementing the five-part pattern the field converged on but no one ships complete:
**thumbnail grid + hover-preview on the real photo + one-click apply + always-scalable Amount +
look-on-a-maskable-layer.**

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Browser grid | thumbnail cards, folder groups, type-to-filter | — | Cards render *this photo*, not a stock swatch |
| Hover | live full-canvas preview; `Alt`-hover = before | on | First paint ≤100 ms (budgeted, see below) |
| Apply | click, or `Return` on focused card | — | Lands as a Look layer |
| Amount | 0–200% | 100 | **Always available — including camera-matching looks** |
| Favorite | star on card; favorites row on top | — | LR profile-browser convention |
| Look layer | opacity, maskable, re-orderable | — | C1's style-on-a-layer, unified with D4 |

**How it works.** Hover previews are rendered through the full pipeline at proxy resolution
(~1 MP) and cached per photo × look; the first dozen likely looks precompute in the background
lane when the browser opens. darktable's "hide preview… on slower computers" escape hatch is the
cautionary tale — hover-preview must be *budgeted*, not assumed, so it rides the same proxy
pipeline as slider drags. Applying creates or replaces the photo's Look layer (D4): a look is
recipe state on the portable creative layer, which is why it can be masked, opacity-scaled,
synced set-wide, and inspected — never an opaque profile blob.

**How it feels.** Browse with arrows, watch the actual photo change, tap `Return`, scrub Amount.
The most-loved parts of three products in one panel, minus their arbitrary limits.

**Vs. the field.** **Better than LrC 15.5 because** LR's Amount is infamously grayed out for
Adobe Raw and camera-matching profiles ("let me scale my Fuji sim" is a standing complaint —
Fuji shooters chose the camera *for* those colors), its preset-Amount is a confusing opt-in
checkbox, and its Adaptive Profiles hide corrections at slider-zero. Lumen: every look scalable,
every look inspectable. **Better than Capture One 16.8.4 because** C1 has the layer half
(style-on-layer, opacity-as-intensity) but no Amount semantics beyond opacity and a weaker
browser. **Equal to darktable 5.6 on hover mechanics, better on budget** — dt documents its own
previews as too slow for some machines; Lumen's are gated by CI.

---

## 12.10 History, undo, snapshots

**What it is.** A persistent, legible, linear per-photo history with named snapshots — and a
deliberate refusal to build branching.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Undo / Redo | `Cmd+Z` / `Shift+Cmd+Z`, unlimited | — | Menu-labeled: "Undo Exposure," "Undo Apply Look" |
| History panel | chronological, click = time-travel, hover = live preview | left rail | Preview from cache, ≤100 ms |
| Entry tooltip | diff: control, old → new value | on | darktable's legibility win, adopted |
| Coalescing | one drag = one entry; N nudges of one slider within 2 s = one entry | on | Apple HIG: "revert multiple changes at once — like incremental adjustments to a single property" |
| Persistence | survives quit/restart, stored in catalog | always | LR/dt precedent; users treat history as insurance |
| Snapshots | named states, `Cmd+'`, hover preview | — | The branch escape hatch |
| Clear / compress | menu commands with confirm | — | Never automatic |

**How it works.** Recipes make history nearly free: each entry is a small recipe diff
(docs/15-catalog.md), and time-travel is a recipe swap rendered through the prefix cache —
which is why hover-preview of old states costs ≤100 ms where LR needed until 15.0 to make it
"fast." Editing above a selected state truncates forward states, exactly like LR and dt — users
know and accept the model, and snapshots are the escape hatch. **No branching**: no shipping
editor has it, no user community asks for it, and virtual copies (docs/10-spec-library.md §10.9)
already cover "two serious directions." Undo scope follows focus honestly: image edits undo on
the photo's timeline; library operations (ratings, moves, album edits) undo on the library
timeline; `Cmd+Z` always undoes the last thing *you did*, and the menu label says what that was.

**Vs. the field.** **Better than LrC 15.5 because** LR's history lacks diff tooltips (entries
like "Exposure" with no values), coalesces inconsistently, and separates UI-undo from history in
ways users must simply learn. **Better than darktable 5.6 because** dt has the diffs but warns
users about its own data-loss edges in the manual; Lumen's truncation confirms when it would
discard >5 states. **Better than Photoshop because** session-only 50-state history is the
category's floor, not its ceiling.

---

## 12.11 The AI-assist surface (D5)

**What it is.** One presentation contract for every AI feature: **AI proposes with evidence; the
user disposes; results land as inspectable, editable state.** Local-only, no cloud, no credits, a
master off-switch.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Proposal chips | non-modal tray, bottom-right of canvas | on | e.g. "Auto settings ready" · "14 dust spots" · "Subject mask" · "3 frames flagged soft" |
| Preview | hover or hold `Space` on focused chip | — | Applies temporarily, exactly like a look hover |
| Accept / Reject | `Return` / `Delete` on focused chip; `Shift+Return` accepts for whole selection | — | Tray focus via click or `Ctrl+A`; chips are also plain buttons |
| Evidence | per-chip disclosure: face crops with eye/focus badges, mask overlay, spot pins, proposed slider deltas listed | always | Never a verdict without its why |
| Background lane | all AI computes off the input path; per-image ETA on batches; completion badge | always | Progress ladder, §12.2 |
| Master switch | Settings ▸ Assist ▸ off | on | Off means computed-nothing, not hidden-results |

**How it works.** Every acceptance materializes as ordinary state: Auto lands as visible slider
values (then tunable — LR Auto's one correct decision), a mask proposal lands as mask components
(docs/08-spec-masking.md), dust removal lands as reviewable pins (docs/09-spec-geometry.md),
culling assists land as filterable flags (docs/10-spec-library.md §10.6 — never auto-reject).
History records "Accepted: Auto settings," undoable as one step. Batch sync auto-recomputes
image-adaptive pieces in the background queue — LrC 15.0's regression, where each synced photo
demanded a manual "Update AI Settings" click and "made batch editing impractical," is the named
failure this rule exists to prevent.

**Honest errors, honest waits.** Errors name the cause and the remedy: "Denoise model not
downloaded (120 MB) — Download," "Running on GPU fallback — about 3× slower," "This model needs
macOS 27." Never LR's despised "Something went wrong." Waits show per-image ETAs.

**Vs. the field.** **Better than Topaz Photo AI because** Autopilot's silent auto-apply is the
category's cautionary tale — "genuinely fast triage" but "unpredictable and over-processing,"
"Autopilot decided my sky was a subject," power users flee to manual. Proposal chips keep the
speed and return the authority. **Better than LrC 15.5 because** LR splits the difference
incoherently: Auto is transparent but crop-blind, Adaptive Profiles hide their correction at
slider-zero (maximal quality, minimal legibility), Generative Remove bills cloud credits
(25/month base — the anxiety is the UX). **Equal to darktable 5.6 on doctrine because** "fix
defects, never change scene content," local ONNX, and opt-in are dt's published policy; Lumen
matches it with a dramatically better surface.

---

## 12.12 Progressive disclosure (D3)

**What it is.** Two registers, one tool. The **Simple register** — the default — shows what a
Fuji-shooting event photographer needs in minute one: WB, Tone's six sliders, Looks, Crop, Masks,
Export. The **Full register** shows every panel in §12.1's table. The toggle is a visible control
in the toolbar, not a preferences flag; switching is instant and non-destructive (hidden panels'
adjustments keep applying, with a "3 hidden panels active" indicator so state never becomes
secret).

**How it works — the three proven shapes, combined.**

1. **Registers** (darktable's `workflow: beginner` module-group, generalized): the Simple register
   is a curated starting set, and the reason dt still intimidates despite having this exact
   feature is that dt *defaults* to the full set — defaults, not options, set perceived
   complexity. Lumen defaults to Simple.
2. **Per-control disclosure** (Pixelmator's pattern): every panel leads with its one-click/auto
   entry point — Auto in Tone, stock cards in Film Lab, Auto-suggest in B&W — with full manual
   controls beneath, and deeper machinery (Zones under Tone, primaries under Render, per-channel
   under Curve) exactly one disclosure triangle away. Never two parallel tools for one intent;
   never a hidden config flag for layout.
3. **Workspaces** (Capture One): named layouts — **Cull** (no panels, filmstrip + badges),
   **Develop** (default), **Grade** (Look panels + scopes per docs/05-spec-color.md §Scopes),
   **Deliver** (soft-proof + recipes) — switchable from the toolbar, plus a dt-style Quick
   Access favorites panel aggregating any controls the owner stars.

The FCPX-vs-Premiere parable sets the failure bounds: FCPX proved radical default simplification
wins speed loyalty, and its 2011 revolt proved depth must be *visibly* reachable or pros call the
tool a toy. The register toggle sitting in plain sight — with the Full register one click away —
is the answer to both.

**Vs. the field.** **Better than darktable 5.6 because** dt built the deepest disclosure system
in any editor and then defaulted to the deep end. **Better than LrC 15.5 because** LR's only
disclosure is hiding panels and solo mode — its panel set is fixed. **Better than ON1/Luminar
because** their kitchen-sink surfaces are the anti-pattern the register system exists to avoid.
**Equal to Capture One 16.8.4 on workspaces because** they are C1's, adopted.

---

## 12.13 Mac-nativeness

**What it is.** Lumen behaves like a first-party Mac app, because the HIG behaviors are free
ergonomics and their absence reads instantly as foreign (Darkroom's Catalyst Mac app is the
named lesson; stack decision in docs/13-architecture.md).

The contract, from the HIG pages read in research:

| Behavior | Spec |
|---|---|
| Menu bar completeness | Every command in the menu bar, searchable via Help; menus generated from the command table (§12.3), so parity is structural |
| Toolbar | Leading-edge items fixed, center fully user-customizable, SF Symbols; every toolbar item also a menu command (HIG toolbar law) |
| Full screen | System full-screen API (`Ctrl+Cmd+F`), camera-housing safe; chrome hides, cursor-to-top restores; culling and Speed Edit fully functional in full screen |
| Gestures | Pinch zoom, two-finger pan, double-tap zoom — "handle gestures as responsively as possible": gestures ride the same ≤16.7 ms path as sliders; every gesture has a non-gesture path |
| Haptics | Force Touch **Alignment** pattern at slider defaults/range ends and crop snap angles — Apple's sanctioned use case, optional, off-able |
| Windows | Second pinnable viewer window with keys-follow-the-cull focus routing (spec in docs/10-spec-library.md §10.11; LR's focus-stealing bug is the anti-case) |
| Panels | Inspectors auto-update with selection; dark translucent HUD panels only for the ≤3-control in-context cases (§12.6) — HIG sanctions them "for media-oriented apps" |
| Automation | Shortcuts actions + AppleScript surface for export/ingest verbs (Pixelmator precedent); no plugin marketplace (docs/00-vision.md refusals) |
| Appearance | Dark-only, HIG-sanctioned for immersive media apps (§12.7); ≥4.5:1 text contrast |

**Vs. the field.** **Better than LrC 15.5 and Capture One 16.8.4 because** both are
cross-platform frameworks wearing macOS trim — non-native full screen, partial gesture support,
no haptics, LR's second-window focus bug shipping for years. **Better than Darkroom because**
AppKit/SwiftUI-native beats Catalyst on exactly the keyboard/multi-window ergonomics this doc is
about. **Equal to Pixelmator Pro because** Pixelmator is the standard Lumen is matching — and it
is in caretaker mode at Apple, which is the market opening (D2).

---

## 12.14 Onboarding-free defaults

**What it is.** Lumen has no tour, no wizard, no import ceremony. The out-of-box render and the
defaults *are* the onboarding: the first photo must look good and every unit must be honest
before the user touches anything.

The default set, each grounded:

| Default | Value | Grounding |
|---|---|---|
| Per-camera base look | Curated look per body, applied as the Look layer, **with Amount 0–200** | C1's most-cited advantage is per-camera profiles + Film Standard ("files need less work than in LR"); Fuji shooters' film-sim attachment; fixes LR's grayed-out Amount (docs/05-spec-color.md owns the looks; docs/04-spec-tone.md the default rendering) |
| Pictorial brightening | Documented inside the base look, never hidden | darktable silently applies +0.7 EV in a preferences doc — right instinct, wrong disclosure. Lumen's base look states what it does |
| Flat/linear escape hatch | One click in Render presets | D8; Radiant Photo's warning: opinionated defaults you can't neutralize breed distrust |
| Auto | Proposes visibly, crop-aware, scalable, never silent | LR Auto's transparency kept, its crop-blindness fixed (D11); RapidRAW #568 ("Auto Adjust too aggressive" on RAF) — bad auto is worse than none, so Auto is a proposal chip, never an import action |
| Crop aspect | **Original ratio** | D31; RapidRAW #26 asked in as many words |
| Units | Kelvin for WB (2000–50000 K), stops for exposure and zones, EV-denominated vignette | D9, D7; RapidRAW #26/#106 ("Kelvin instead of ±100") — honest units are a felt-quality item |
| EXIF strip | Focal/ISO/aperture/shutter one `I` tap away in every view | RapidRAW #26 — "visible outside the metadata panel" |
| Zoom | `Space` centers on cursor | RapidRAW #26, verbatim ask |
| Auto-advance | On, visible toolbar toggle | D35 — no Caps-Lock folklore |
| First launch | Point at a folder; contact sheet appears | D34 — the anti-import-ceremony is itself the first impression |

**Vs. the field.** **Better than LrC 15.5 because** Adobe Color is one curve for every camera,
Auto is import-blind to crop, and the first hour is an import dialog with four preview options
("LrC's most confusing subsystem"). **Equal to Capture One 16.8.4 on per-camera color because**
that is C1's crown, adopted as a pillar — **better because** the base look is scalable and
inspectable Look-layer state, not an ICC black box. **Better than RapidRAW 1.6.1 because** the
LR-refugee wishlist that project's tracker documents is, item by item, this table.

---

## 12.15 Scorecard

| System | Verdict vs. LrC 15.5 | Verdict vs. best-in-class |
|---|---|---|
| Module-less layout | better (no module wall) | equal (C1's single context) + LR grammar |
| Latency contract | better (LR's five loops are the negative spec) | better than all — nobody else has budgets in CI |
| Keyboard system | equal grammar, better completeness | consciously below dt's total remappability |
| Speed Edit | better (LR has nothing) | equal-plus vs. C1 (ghost readout, more targets) |
| Slider contract | better (regression-proofed conventions + power) | better than dt (keeps power, fixes wheel flaw) |
| Direct-on-image | better (HUD rule, scroll-to-dodge) | equal to dt's cursor, learned from DxO's mistake |
| Chrome & assessment | better (ISO 12646 mode; LR dims to black) | equal to dt, whose doctrine this is |
| Compare | equal grammar, better cache (instant cross-photo A/B) | better than dt ergonomics |
| Looks browsing | better (Amount never grayed, looks-as-state) | first to ship all five parts of the settled pattern |
| History | better (diffs, coalescing, honest scope) | better than dt's edges, Photoshop's session limit |
| AI surface | better (chips + evidence vs. credits + opacity) | equal to dt doctrine, far better surface |
| Disclosure | better (registers; LR has hide-panels) | equal to C1 workspaces + dt QAP, defaulted correctly |
| Mac-nativeness | better (native vs. cross-platform trim) | equal to Pixelmator Pro, which stopped evolving |
| Defaults | better (honest units, scalable base look) | equal to C1 color defaults, more inspectable |

The through-line: almost nothing in this document is invented. It is the field's best-received
interaction ideas — C1's Speed Edit and workspaces, LR's grammar and TAT, darktable's sliders,
scroll-to-dodge, and viewing-condition doctrine, Aperture's loupe and dual display, Photo
Mechanic's key-repeat paging, Pixelmator's disclosure, Apple's HIG — assembled behind one latency
contract that none of those products ever enforced. The assembly plus the contract is the
product.
