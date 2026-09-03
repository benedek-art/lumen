# 33 — Speed, crop, and a post-mortem on the blur

Written to be read COLD. Three pieces of work the owner asked for after testing the
fourth pass, plus the one thing that must be understood before any of it: why the blur
took four rounds to kill, so the fifth round does not repeat the shape.

**Base:** branch `claude/photo-editor-design-plan-8ahzmm`, at or after the commit that
sets `DraftLadder.maxUpscale` to 1.
**Context:** `docs/32-fourth-pass.md` §0 (ground rules — they still apply verbatim),
`docs/31-defect-audit.md` (traced defects), `docs/23-master-plan.md` (the proof harness).

The owner's verdict on the fourth pass, so tone is understood: the crop stretch, the mask
handles and the zoomed blur are fixed and he is pleased. What follows is not a rebuild.
It is one bug hunt, one measurement project, and one design piece he explicitly wants
copied from a competitor rather than invented.

---

## 0. GROUND RULES

`docs/32` §0 applies unchanged and is not repeated. Two additions paid for since:

1. **The sandbox rewound four times in one session**, each time reverting the checkout to
   an old commit and reinstating five unrelated modified files from the docs/23 round.
   Trust ONLY `origin`. Work in a detached worktree made from
   `origin/claude/photo-editor-design-plan-8ahzmm`. If `/home/user/lumen` is dirty with
   `PlanTableCache.swift`, `RenderPlan.swift`, `PipelineRenderer.swift`,
   `PlanTableCacheTests.swift`, `docs/23-master-plan.md`, those are NOT your work:
   `git stash push -u` then `git merge --ff-only origin/<branch>`. Committing them
   reverts real work.
2. **Long measurements must commit themselves.** `ControlProofTests` needs the better
   part of an hour in a debug build and was destroyed four times before it landed. Write
   such a run as a detached script that measures, GUARDS what may change, commits and
   pushes without a live session — the guard is how a review survives being automated.

---

## 1. POST-MORTEM: why the blur survived four rounds

Read this first. It is the most expensive lesson in the project's history and every
stream below can repeat it.

The owner reported "everything goes blurry while I edit" in four consecutive rounds. Each
round found a real mechanism, fixed it, and shipped — and each time he came back saying
it was still there. The mechanisms were all genuine:

| Round | Mechanism found | Why it did not finish the job |
|---|---|---|
| 1 | Draft was hard-capped at half the settle's resolution, forever | Real, but only one of the sources |
| 2 | Draft ladder had no floor and walked to its 576 px rung | Floor added — at **4.1×** magnification |
| 3 | Zoom was denominated in proxy pixels, so "1:1" meant a 4096 proxy of a 7008 px file | Fixed the *settle*, left the *draft* |
| 4 | Every zoomed render paid for the whole frame, so the ladder stepped down exactly when magnification made it unwatchable | Fixed **zoomed** only; fit still ran the ladder |
| 5 | The floor itself was set at **2×** — visibly soft, by its own comment | The fix: `maxUpscale = 1` |

**The pattern, and it is the lesson.** Four times, a session found a real mechanism,
verified it in isolation, and declared the class fixed. The class was never fixed because
nobody asked *"is this the only path that can put a soft pixel on screen?"* Round 5's
comment is the indictment: it wrote down that 2× would be "visibly soft" and shipped it
anyway, trading the owner's stated top priority for frame rate he had not asked for.

**Three rules that follow, for anyone touching the render path:**

1. **A defect a comment predicts is not a trade-off. It is a defect with an alibi.** If
   you find yourself writing "this will be slightly visible, but", stop. The owner has
   rejected soft-while-dragging five times.
2. **Enumerate the paths, not the causes.** Sharpness on screen is decided by: the
   *ask* (`requestedLongEdge`), the *ladder* (`DraftLadder.longEdge`), the *region*
   (`ZoomRegion`), the *decode scale* (`AppleRawSource`), and the *draw* 
   (`ProxyResampling`). A fix to one is a fix to one. Before claiming a class is closed,
   walk all five for both fit and zoomed.
3. **Sharpness is not a budget line.** The settled policy is now explicit: when the
   machine cannot keep up, drop FRAMES, never PIXELS. A sharp picture that updates in
   steps reads as the app working; a smooth blurry one reads as the app broken.

---

## 2. STREAM A — the zoom stalls (a bug hunt, do this first)

The owner: *"I often get a rainbow spinny from Mac, which is kind of a frozen screen…
Trying to zoom in is a pain… the scroll wheel zoom is really slow, as well as often it
gets stuck at kind of rendering only one part of the page."*

Three distinct symptoms; treat as three defects, not one slowness.

### A1. "Stuck rendering only one part of the page"

**Almost certainly a defect introduced by region rendering** (`ZoomRegion`,
`PipelineRenderer.renderPreviewDelivery`, `LoupeView.canvas`). The delivered image covers
`model.regionUnit` of the frame and is drawn at that sub-rectangle; everything outside it
is whatever was there before. Suspects, in order:

- A pan that leaves the rendered margin before the new region's render lands leaves stale
  pixels beside fresh ones, with no visual cue that half the frame is old.
- `regionUnit` is a plain `var` published only via `revision`; if a body pass reads it
  between an image swap and the revision bump, the geometry and the pixels disagree.
- Zooming OUT to fit while a region frame is on screen: `regionActive` goes false, but the
  frame showing is still a region until the whole-frame render returns.

**Acceptance:** pan and zoom continuously for 30 seconds at 400% on a 33 MP file; no
frame ever shows a sharp rectangle against a stale surround. Add a `LoupeView` test-mode
assertion (or a HUD line) that flags a drawn region whose `regionUnit` does not match the
current pan.

### A2. The beachball

A spinning wheel is the main thread blocked — a specific, findable bug. Instrument, do not
guess. Candidates: `PixelSampler.make` (a full-resolution draw, and `rebuildSampler` is
`await Task.detached` but the *result* is applied on the main actor), the mask raster
(`MaskRaster.combine`, CPU, and at zoom it runs at 11 MP), `InspectionGain.displayed`,
and any `CGImage` creation on the main actor. Use `os_signpost` and Instruments' Time
Profiler on the main thread specifically.

**Acceptance:** no main-thread block over 100 ms during a two-minute session of zooming,
panning and slider dragging on a 33 MP RAW.

### A3. Scroll-wheel zoom is slow

`LumenControls`/`LoupeView` wheel handling: check whether each wheel event is a discrete
ladder step with an animation, and whether events coalesce. A trackpad emits a high-rate
stream; if every event triggers a render key change, the render queue is the bottleneck
and the zoom feels like treacle. Consider: accumulate wheel delta and apply on the next
display refresh, and let zoom CHANGE the geometry immediately while the render follows.

**Acceptance:** wheel zoom from fit to 400% takes under a second of wrist movement and
the picture tracks the wheel without a queue behind it.

---

## 3. STREAM B — speed, measured (the project the owner asked for)

The owner: *"loading pictures isn't the fastest. It takes five to ten seconds sometimes…
We should definitely do a large project on speed."*

The fourth pass fixed five decode-path mechanisms (LRU, residency budget, lazy native
decodes, embedded-preview fallback, zoom-reset). It never measured the number the owner
experiences. **That is this stream's whole point: measure first.**

### B1. Instrument the path the owner actually feels

One number, end to end: grid click → first SHARP frame (not first pixels). Break it into
stages with timestamps, surfaced in the latency HUD and written to a log:

    selection → metadata → embedded preview shown → decode started → decode done
    → graph built → draft delivered → settle delivered

Nothing in this stream is designed until that table exists for a 33 MP ARW on the owner's
machine, cold and warm.

### B2. The three suspects already traced, unfixed

Recorded by the fourth pass so they are not re-derived:

1. **The region render still pays a whole-sensor decode.**
   `renderPreviewDelivery` decodes BEFORE it computes the raster rect, so a zoomed render
   saves the graph and not the demosaic. A region-aware decode ask is the fix; the risk is
   that keeping the decode lazy through the raster trades back the per-settle re-demosaic
   `DecodeMaterializer` exists to prevent. Measure both.
2. **A masked settle at zoom rasterizes an 11 MP mask on the CPU.**
   `maskRasterCeiling` caps at 4096 and `MaskRaster.combine` is CPU. Likely seconds per
   settle on masked photographs. Candidate fixes: raster the mask only over the rendered
   REGION, or move the combine to the GPU.
3. **Creative grain on export is laid before the resize.** One line in
   `PipelineRenderer.exportedImage` (`plan.grain`, not `plan.filmChain`), plus suppressing
   the creative fallback in `RenderGraph.build` when grain is deferred. Correctness, not
   speed, but it lives in the same file and should ride along.

### B3. Where to look that nobody has

- **Catalog and thumbnails on the main actor.** The grid click's first act is a selection
  write; trace what that synchronously triggers.
- **`PlanTableCache` bakes.** A settle bakes exact tables. How long, and how often is the
  bake avoidable?
- **Cold vs warm.** The owner's 5–10 s may be first-open only. If so the fix is prefetch,
  not decode.

**Acceptance:** grid click → sharp frame under 1.5 s warm and under 3 s cold on a 33 MP
ARW, with the stage table in the HUD to prove where the time went. Any stage that cannot
meet it gets a written reason, not a silent miss.

---

## 4. STREAM C — crop, rebuilt against Lightroom

The owner: *"for the crop, I would like to take a look at how Lightroom has it set up. I
think we should just copy that… right now this tab is pretty lame in terms of visuals. It
looks like it was made in 2007."*

He is explicitly asking for imitation. There is no prize for inventing crop interaction.

### C1. The commit-on-idle behaviour

Currently the crop stays uncommitted until the workspace is left, so the picture shows
uncropped while you frame — which he finds wrong. His description of Lightroom: a few
seconds after the rectangle stops moving, the crop applies; grabbing it again pops back
out to the framing view.

Implement as a state machine with the timing NAMED and in LumenCore where it is tested:
`framing` → (idle for `CropCommit.idleSeconds`) → `applied` → (pointer down inside the
frame) → `framing`. Do not hard-code a literal in the view.

Open question to settle by trying it, not by argument: whether the pop-out is any press
inside the picture or only on the rectangle's own handles.

### C2. The aspect-ratio bug

*"16 by 10 turns to five by eight for some reason. And some of the other ones as well.
Don't do the reverse of its number."*

16:10 reduced to lowest terms IS 8:5 — so the menu is almost certainly reducing the
fraction and then printing it in the wrong ORDER (5:8 rather than 8:5), i.e. losing the
orientation. Find where ratios are normalized (`CropGeometry`, `CropPanel`'s ratio menu)
and make the presented label carry both the canonical pair AND the orientation, rather
than deriving a label from a reduced fraction. Check every entry in the menu, both
orientations, on both portrait and landscape sources — the owner found this by accident
on one entry and says others are wrong too.

Note: he confirms the ratio + rotate-button flow already works. Do not redesign it.

### C3. The visual pass

- **The dropdowns.** He suspects they are stock AppKit; a previous round drew custom ones
  (`054da2a`, "Every dropdown in the app gets drawn"). Establish whether the crop panel's
  are the drawn ones or stragglers, and finish the job.
- **The panel's layout.** It is a form of label/control rows; Lightroom's is a tool with a
  visual hierarchy. Study theirs, and Capture One's, before drawing.
- Law 7 (docs/00) still binds: zero-chroma chrome, nothing that biases a colour judgement.

**Acceptance:** the owner opens crop and does not say it looks like 2007. Concretely: the
ratio menu is correct in both orientations for every entry, the crop commits on idle, and
no control in the panel is an undrawn AppKit default.

---

## 5. WHAT IS NOT IN THIS PLAN

Recorded so a later session does not think they were forgotten:

- **"Accuracy for the sliders."** Raised twice, never with a reproducible case. Ask for
  one control and one number before designing anything.
- **The mask control surface** (*"how much grading controls"*). He deferred it himself and
  wants Lightroom compared first. A design question, not a defect.
- **Grain's character beyond the rainbow fix.** Creative grain is now one luminance field.
  Whether its SIZE range is right at preview resolution is untested by eye — 56 µm at a
  36 mm gate is roughly 8 px on a laptop preview, which may read as noise rather than
  grain even in luminance. Get his verdict before tuning.

---

## 6. SEQUENCING

Stream A first: it is a defect introduced by the last round and it is making the app feel
broken in the way that most annoys him. Stream B second, and its first deliverable is the
measurement table, not a fix. Stream C last — it is the largest, it is design work, and it
is the one where copying a competitor means looking at the competitor before writing code.

Do not run A and B as parallel agents against the same files: both touch
`PipelineRenderer`, `RenderGraph` and `LoupeView`. C is disjoint (`CropPanel`,
`ViewerOverlays`, `CropGeometry`) and can run beside either.
