# 35 — The masking rebuild

**Commissioned 2026-08-31**, after the owner opened the Masks page on a real edit:

> "Right now, what we have for the masking isn't great … the UI of adding a mask is quite rough.
> It's simply a container inside of a container inside of a dropdown … Honestly, I feel like I need
> a degree in rocket science to use this a little bit. Invert. There are two inverts … I don't know
> how much of these is actually working … I want to know what Feather does, what Flow does, what
> Density does before I even click it … I want to make sure that I can grade and make masks that
> are absolutely stunning."

And, separately, one reproducible defect:

> "If I grab the radial thing and now quickly move it to the top left, the actual brightness still
> stays where the radial gradient was until around half a second after. It's like it has a tail."

This document is the audit, the design, and the order of work. Everything in §2 is a code reading
or a count taken from the repository, labelled as one. Everything in §5 names the measurement that
would falsify it, per `docs/34` rule 4.

An interactive prototype of §4 — the two columns side by side, the tail reproduced, and the
behaviour glyphs of §4.5 live — is at
<https://claude.ai/code/artifact/795e9858-c9b9-4bd5-a061-72bd3fa535cf>.

---

## 0. WHERE THIS SITS

`docs/08-spec-masking.md` is still the specification and nothing here contradicts it. `docs/30`
built the design system this rebuild spends — `lumenSurface`, the type scale, `lumenHoverable`,
the silence rule. `docs/34` set the performance discipline: measure first, and never pay a week
for a hypothesis a minute could have refuted.

What is new here is that masking has never been designed as an *interaction*. It has been
specified, implemented, audited for truthfulness (`docs/audit/mask.md`, 36 findings) and restyled.
It has not once been laid out as a thing a photographer picks up.

---

## 1. THE ONE DIAGNOSIS

> **The mask panel is a form over the data model, not a tool. Every field of `Mask`,
> `MaskComponent`, `MaskRefine` and `LocalAdjust` was given a row, in schema order, all at
> once — so the photographer reads the schema instead of using an instrument.**

That single fact generates almost every complaint in the brief. The two Inverts are two Inverts
because `Mask.invert` and `MaskComponent.invert` are two booleans. The three Feathers are three
Feathers because `BrushStroke.feather`, `MaskComponent.feather` and `MaskRefine.blur` are three
fields that happened to be spelled similarly. The panel is hard to read because it is not a
sentence; it is a table.

The corollary is the fix. **A tool is organised by the question the user is asking, not by the
struct the answer is stored in.** A mask asks exactly three questions, always in this order:

1. **What is selected?** (the component stack)
2. **How is the edge shaped?** (the refinement chain)
3. **What does it do to the picture?** (the local adjustments)

Today those three are three visually identical stacks of grey rows separated by three visually
identical headers. Nothing tells you they are different kinds of question.

---

## 2. THE EVIDENCE

### 2.1 Eighteen sliders stand between "Add a mask" and the tone curve

Counted from `MaskPanel.swift` at head, for the default case the owner screenshotted — one brush
mask, freshly created, nothing collapsed by hand:

| # | Slider | Section |
|---|---|---|
| 1 | Amount | mask list |
| 2 | Amount | component editor |
| 3–6 | Size · Feather · Flow · Density | brush |
| 7–12 | Refine · Grow / Shrink · Feather · Start · End · Curve | Refine |
| 13–18 | Exposure · Contrast · Highlights · Shadows · Whites · Blacks | Light |

Then the curve editor. Below it, five more in Colour, the grading toggle, and two sections that
start closed holding nine more. **Twenty-seven sliders, nine section headings, and about fifty
interactive controls in one scrolling column** — reached by one click on a mask type.

For comparison, the same click in Lightroom Classic yields a mask row, an overlay, and one
adjustment group.

### 2.2 Four of those eighteen names appear twice in the same column meaning different things

This is the "two inverts" complaint, and it is worse than the owner realised. Verbatim from
`MaskPanel.swift`:

| Word | First appearance | Second appearance | Actually |
|---|---|---|---|
| **Amount** | mask Amount, 0–200 | component Amount, 0–100 | a strength multiplier vs. a per-component contribution |
| **Feather** | brush Feather, 0–100 | Refine ▸ Feather, 0–100 | stamp hardness vs. a Gaussian blur of the finished alpha |
| **Refine** | the section heading | Colour Range ▸ Refine | a chain of four operations vs. one tolerance width |
| **Curve** | Refine ▸ Curve (`levelsGamma`) | the **Curve** section directly below it | a density gamma vs. the tone curve |
| **Invert** | component Invert | "Invert mask" | before the fold vs. after it |
| **Tint** | Colour ▸ Tint (green–magenta) | "Colour tint" toggle, "Tint colour", "Tint strength" | white balance vs. a colorize |

Six collisions. "Refine ▸ Curve" sitting immediately above a section called "Curve" is the one
that cannot be defended at all: the code comment explaining the rename ("Levels Lo/Hi/Gamma was a
histogram dialog from 1994") is correct about the old name and did not check what the new one
would land next to.

### 2.3 The moment of creation shows nothing

`MaskPanel.addMask` appends the mask, selects it, and returns. It does not turn on the overlay.
So the first second of every mask in this application looks like this:

- no red overlay on the photograph (`state.soloMaskOverlay` stays nil),
- no thumbnail of what is selected (mask rows carry a *count badge*, `LumenBadge(text: "\(mask.components.count)")`, and nothing else),
- no pin on the canvas (`MaskCanvas` draws only the selected component's handles, and only for brush/linear/radial),
- and for a brush, an `INCOMPLETE` badge, because `makeComponent(kind: .brush)` deliberately leaves `strokesRef` nil.

A new brush mask therefore greets you with an error-shaped badge and fifty controls, and gives no
indication that the next thing to do is drag on the photograph. Linear and Radial *do* carry that
instruction ("Drag on the image to set the gradient line…"). The brush — the one kind where the
gesture is the whole feature — does not.

Lightroom's opposite: the mask appears as a red overlay the instant it exists, the row carries a
live thumbnail of its own alpha, and hovering any row re-shows that overlay. The owner named this
exactly, and it is the cheapest comprehension win available.

### 2.4 Controls that cannot do what their name implies

**Brush Feather, Flow, Density and Automask do not apply to the stroke you already painted.**
`MaskBrushStore` is session state by design, and each stroke bakes its own parameters into the
blob as it is drawn (`MaskCanvas.swift`, `MaskBrushStore.stroke(points:)`). So the sequence
"paint a stroke → drag Feather → watch the picture" — which is precisely what the owner did — is
guaranteed to do nothing. The model is defensible (Lightroom does the same). The presentation is
not: these four sit inside a section headed **Components**, under a row naming *this* component,
formatted identically to the sliders above and below them that *do* retarget the current mask.

**The brush cursor draws one ring.** `brushDiameter` gives the size; there is no feather ring.
So the parameter that cannot be seen after the stroke also cannot be seen before it.

**The live stroke is a flat white line.** `drawBrush` strokes the in-flight points at constant
width and constant alpha. Flow, Density, Feather and Automask all have zero representation until
mouse-up, when the real rasterizer runs. You paint blind and find out afterwards.

**Similarity Point has no point.** `MaskComponent` carries no centre, radius or ± sign for
`.similarity` — only `samples`, `chromaSel`, `lumaSel`. `MaskRaster.similarityPlane` is marked
DEGRADED in its own source and evaluates the gate over the whole frame. What ships as "Colour
Pick" is a Gaussian colour range; the U-Point mechanic it is named after is *similarity within a
radius, with negative points*, and neither half of the spatial part exists. The scorecard row in
`docs/08 §8.11` ("Similarity point/line: yes") overstates.

**Five local sliders are absent because their engine has no caller.** Local Noise, chroma NR,
Moiré, Defringe and Grain are fields on `LocalAdjust` that round-trip the wire format and are read
by nothing. The panel is right to hide them. Lightroom ships all four of the first ones locally.

### 2.5 The canvas is nearly blank

Masking is a spatial task performed almost entirely in a 320pt column.

- **No pins.** Lightroom puts one pin per mask on the photograph; click selects, ⌥-drag scrubs its Amount. `docs/08 §8.1` clones this. Nothing draws one.
- **Only the selected component is visible.** Every other mask on the frame is invisible while you work.
- **No on-canvas creation.** You cannot drag out a new gradient without first choosing a type in the panel. (⌘-drag *replaces* the current one — a good rule, but only reachable once a component already exists.)
- **No brush keys.** `[` `]`, ⇧`[` `]`, digits for flow, `A` for automask, hold-⌥ to erase — the entire Lightroom brush grammar, spec'd in `docs/08 §8.6` — none of it is bound. `Keymap.swift` binds `M`, `O`, `⇧O`, `⌥O`, `'` and nothing else for masking.
- **The overlay is single-mask and manual.** `soloMaskOverlay` is one optional id. There is no hover preview, no auto-show on create, and no auto-hide while dragging an adjustment.

### 2.6 The tail: why a radial drags its shadow behind it

This is the owner's reproducible defect, and the mechanism is documented in the codebase's own
comments — it was a known, accepted trade, not a bug anybody hid.

**Reading 1 — every mask is rasterized on the CPU, in f64, into a `Plane`.** `MaskRaster` is the
whole rasterizer; the GPU has exactly one mask kernel, `lumenBlendMask`, and it only *composites*
a finished alpha. A radial gradient — a signed distance to an ellipse, the cheapest closed form in
the entire pipeline — takes the same road as a hair matte.

**Reading 2 — a drag frame is deliberately served a stale raster.** `MaskRasterCache`'s header
says so in as many words:

> "dragging Exposure, a luma-range mask's EDGE placement lags the tones by one gesture and snaps
> at the pause … Both beat the mask not being there at all, which is what shipped."

Every mouse event rewrites the component's geometry, which changes the cache key, which misses,
which serves *the previous raster* while the exact one bakes on a background queue. The picture is
therefore correct about the adjustment and one gesture behind about *where the adjustment lands*.
That is the tail, exactly as described.

**Reading 3 — with the overlay on, it is much worse.** `AppState.refreshMaskOverlay` fires on
every recipe change and calls `RenderCoordinator.maskAlpha` → `PipelineRenderer.renderMaskAlpha`,
which is a **second, uncached, full rasterization** — its own decode, its own `maskSource` stage
render, its own `MaskRaster.combine` — running on the *same serial actor* as the preview. Then
`MaskOverlayView.build` composites a preview-resolution `CGImage` on the CPU on top of that. So
looking at a mask while you move it costs two CPU rasterizations and a full-frame composite per
frame, serialized ahead of the picture.

`docs/23`'s probe (b) measured `MaskRaster.combine` at the 1024 px proxy in a release build:
**12.8 ms geometry-only, 105–190 ms through the guided refine chain.** A drag frame's budget is
~16.6 ms.

**Reading 4 — each mask costs a full-frame adjustment pass regardless of its size.**
`RenderGraph.applyLocal` loops the masks and calls `applyLocalAdjust` on the *whole frame* for
each, then composites through the alpha. A mask covering 2% of the picture pays 100% of a local
Laplacian for Clarity and 100% of a sharpen. Five masks is five full-frame passes.

**The minute-long experiment, before anybody writes a line** (`docs/34` rule 4): open the latency
HUD, which already prints `rasters Nh Nb Ns` from `MaskRasterCache.currentStats`. Drag a radial
with the overlay **off**, read the stale-serve rate; drag it again with the overlay **on**. If the
tail is present in both, Reading 2 is the cause. If it only appears with the overlay on,
Reading 3 is. My expectation is *both, with Reading 3 dominant*, but that is a prediction, and the
HUD settles it in sixty seconds.

### 2.7 The edge does not survive resolution — where it still matters

`MaskRaster.combine` now rasterizes at the render target's own size on settle and export
(`makeGraph`, the `deliveryCap` branch), which closed `MASK-21` for delivered files. But a
*draft* raster is still capped at 1024 px, and the refine chain — guided filter, EDT edge shift,
Gaussian — runs inside `combine` at whatever size it was given. So the mask edge you *judge* while
editing is computed at 1024 px and stretched, and the one you *ship* is computed fresh at up to
4096. They are not the same edge. For a hard-edged luminance band that is a visible difference at
100% zoom.

### 2.8 What is genuinely good, and must survive the rebuild

Stated because a rebuild that throws these away would be a regression:

- **Component algebra with Intersect as a visible button**, editable after creation, with reorder. This is better grammar than Lightroom's, which hides Intersect behind ⌥ at creation time only.
- **The local point curve and the local grading wheels.** Lightroom Classic 15.5 has neither. Ours are real on the shipping path, and the curve is covered by a GPU golden that fails if the call site is deleted.
- **`MaskHandles`** — the press grammar (inside → move, rim → resize, clear space → new, ⌘ → new anywhere, and "a press that took hold of the shape can never replace it") is the best-designed interaction in the app and needs no change.
- **Vector brush strokes** with Catmull-Rom smoothing and arc-length stamping, stored in source-normalized coordinates so crop and rotate re-rasterize instead of orphaning.
- **The six overlay modes**, composited from true alpha through the geometry inverse, tested mode by mode.
- **Honesty.** Kinds that cannot compute are absent from the picker rather than offered with an apology. That principle stays.

---

## 3. WHAT THE FIELD ACTUALLY DOES

`docs/02 §3` and `docs/03` already hold the feature teardown and it is current (LrC 15.5,
C1 16.8.4). What follows is only the *interaction* reading, which those documents did not take.

**Lightroom Classic.** The reason its masking feels approachable despite being the deepest in the
market is three decisions, none of them about capability:

1. **The roster is visible, not in a menu.** Clicking "Create New Mask" opens a panel of labelled icon tiles — every mask type on screen at once. You choose by recognition, not by reading a list.
2. **Every mask row is a picture of itself.** A live grayscale thumbnail of that mask's alpha, in the row. You never have to remember what "Mask 3" selects.
3. **The overlay is ambient.** Red on create, red on row-hover, gone while you drag a slider. Feedback arrives without being asked for, and gets out of the way when it would obstruct.

Its documented failures are the ones `docs/08 §8.7` already engineers against: synchronous mask
re-evaluation, brush lag with several masks present, 0.5–10 s freezes switching photos, and the
`.lrcat-data` folklore.

**Capture One.** Depth is its answer, not simplicity: nearly every tool works per-layer, including
curves and the Color Editor. Its Luma Range is the best *instrument* in the field — a live
histogram with four handles, two for the band and two for falloff, plus a "Display Mask" toggle
that previews while you drag. That is the shape our Brightness Range should have and does not.
Its own admission of mask-type sprawl was shipping "Combine Masks" in 16.7.0 to patch it.

**DxO.** U-Point is still the fastest manual selection anybody has shipped, and it is
*spatial* — a radius plus chroma and luma selectivity, with negative points. Two clicks replace a
minute of brushing. We named a component after it and shipped only the colour half.

**darktable.** The engineering reference, and the cautionary tale: guided-filter feathering is the
right primitive, and exposing it as a raw 0–10 000 parameter is why nobody can use it.

**The synthesis.** Nobody in this market has shipped masking that is simultaneously
Lightroom-broad, Capture-One-deep, and *legible*. Legibility is the open lane, and it is a
design problem, not a model problem.

---

## 4. THE REBUILD

Seven changes. Together they are the answer to "I want to know what it does before I touch it."

### 4.1 Three zones, visibly different

The panel becomes three surfaces with three different weights, in the order the questions are
asked. This is what `lumenSurface` was built for and the mask panel is the last place still
drawing nine identical headers.

```
┌─ WHAT ─────────────────────────────┐   the mask, and what it selects
│  ◉ Sky            [thumb]  ⌄       │   ← row IS a picture of its alpha
│    ∪ Sky            [thumb]        │   ← component chips, live thumbs
│    ∖ Brush          [thumb]        │
│    + add to this mask              │
├─ EDGE ─────────────────────────────┤   two sliders, three behind "More"
│  Snap to edges   ────●────   10     │
│  Soften edge     ●────────    0     │
│  ⌄ More: expand/contract, strength  │
├─ EFFECT ───────────────────────────┤   the adjustment set, unchanged
│  Strength        ────────●─  100    │
│  Light · Curve · Colour · Grading … │
└─────────────────────────────────────┘
```

Three moves make this work:

- **Mask Amount leaves the list and becomes "Strength" at the top of EFFECT**, where it belongs — it multiplies the adjustments, not the selection. Today it sits in the mask list, directly under the rows, where it reads as a property of the list.
- **Invert, Duplicate, Delete, rename and the overlay controls leave the column entirely** and become the mask row's own ⌄ menu. Six controls that today float unattached below the list become one affordance attached to the thing they act on.
- **The component editor stops being a separate block below the stack.** Selecting a chip expands *that chip in place*.

### 4.2 The picker becomes a board

Delete the dropdown. `kindMenu` becomes an always-visible tile grid, three across, grouped by the
question it answers rather than by our implementation:

```
   DRAW IT              FIND IT BY COLOUR        FIND IT FOR ME
   🖌 Brush             ◑ Brightness             ⬚ Subject
   ◧ Linear             🎨 Colour                ▨ Background
   ◎ Radial             💧 Colour Pick           👥 People
```

Group names are the user's mental model, not ours: "Range" and "AI — on this Mac" are engineering
categories. Each tile carries the glyph `kindSymbol` already defines and one line of what it is
*for* on hover — "paint the selection by hand", "everything this bright", "everything this
colour". Empty state: the board is the whole panel. Non-empty: a `+` opens the same board inline,
never a popup.

Cost: this is a layout change to one function. It is the highest ratio of felt improvement to
risk in the entire document.

### 4.3 Every row is a picture of its own mask

A 44×30 grayscale thumbnail of the mask's alpha in each mask row, and of the component's alpha in
each component chip. This is what makes a stack of three components readable at a glance —
the fold stops being an abstraction and becomes three pictures and a result.

Requires an alpha thumbnail at ~128 px, which is *free* once §5.1 lands (parametric kinds evaluate
in a shader) and cheap before it (a 128 px `MaskRaster.combine` is sub-millisecond).

### 4.4 The overlay becomes ambient

The rule, cloned from Lightroom because it is right and because fifteen years of muscle memory
transfer:

| Event | Overlay |
|---|---|
| Mask created | **on**, fading out after ~1.2 s |
| Mask row or component chip hovered | **on** while hovering |
| A geometry handle grabbed | **on** for the drag |
| An adjustment slider dragged | **off** — it obstructs the thing being judged |
| `O` | pinned on/off, overriding all of the above |

Plus the micro-interaction `docs/08 §8.5` specifies and we never shipped: **⌥-drag on any edge
slider shows the pure matte** while the drag lasts.

This is not achievable at acceptable cost on the current overlay path (§2.6, Reading 3). It falls
out for free on the new one (§5.2).

### 4.5 The behaviour glyph — the new idea

This is the direct answer to *"I want to know what Feather does, what Flow does, what Density does
before I even click it"*, and it is the piece worth prototyping first because if it works here it
works everywhere in the app.

`docs/30 §2.2` established that the answer cannot be words: nineteen explanatory paragraphs in
this very panel became nineteen rows reading "ⓘ How this works", which was worse. A tooltip you
have to hover to read is a control you have to already understand to look up.

**So: draw the parameter.** Every slider whose meaning is a *shape* gets a 44×14 glyph in its
label row that draws that shape, live, as the value changes.

| Slider | The glyph draws |
|---|---|
| **Feather** (brush) | a cross-section of one stamp — square at 0, bell at 100 |
| **Flow** | three overlapping passes, showing paint accumulating per pass |
| **Density** | the same three passes against a ceiling line they cannot cross |
| **Size** | a circle at true relative scale |
| **Snap to edges** | a soft alpha ramp pulling onto a hard image edge |
| **Soften edge** | a step becoming a ramp |
| **Expand / Contract** | a boundary moving out of / into a shape |
| **Smoothness** (ranges) | the trapezoid's shoulders opening |

Four properties make this worth building rather than cute:

1. **It is not text**, so it costs no words and obeys the silence rule.
2. **It is live**, so it is a readout as well as an explanation — it keeps earning its space after you have learned it.
3. **It is one component** (`LumenBehaviourGlyph`, a `Canvas` driven by a small enum) reused across the panel, not eight drawings.
4. **It generalises.** Highlights/Shadows, the tone curve's parametric regions, Clarity's radius, the vignette's midpoint — every one of these is a shape being described in words today.

### 4.6 The canvas gets its half of the job back

- **Pins.** One per mask, at the alpha's centroid. Click selects. ⌥-drag scrubs Strength with the Speed-Edit ghost readout. Hover shows that mask's overlay.
- **Every mask drawn, the selected one bright.** Unselected geometry at ~25% so you can see what else is on the frame.
- **The brush cursor draws two rings** — outer at Size, inner at `Size × (1 − Feather)` — so the parameter that cannot be judged after the stroke can be judged before it.
- **The live stroke previews honestly:** the in-flight polyline draws with the stamp's actual falloff and the current flow, not a flat white line.
- **The brush keyboard grammar,** entire, from `docs/08 §8.6`: `[` `]` size, ⇧`[` ⇧`]` feather, digits flow, `A` automask, hold-⌥ erase, `K` brush, `M` linear, ⇧`M` radial.
- **Drag-to-create:** with a mask selected and a gradient type chosen, dragging on empty canvas makes one — which `MaskHandles` already implements for ⌘-drag and needs only to be reachable at creation.

### 4.7 The vocabulary

Rename table. Every one of these is a label change with no engine consequence.

| Now | Becomes | Why |
|---|---|---|
| Amount *(mask)* | **Strength** | it scales the effect, and it moves to EFFECT |
| Amount *(component)* | **Contribution** | it scales this component's share of the selection |
| Refine *(chain)* | **Snap to edges** | says what the guided filter does |
| Feather *(chain)* | **Soften edge** | removes the collision with brush Feather |
| Grow / Shrink | **Expand / Contract** | same meaning, standard words |
| Start / End / Curve *(levels)* | **Strength curve**, one control behind "More" | three sliders for a density ramp is three sliders too many |
| Invert *(component)* | a `↔` toggle **on the chip** | stops being a labelled row, stops colliding |
| Invert mask | **Invert selection**, in the row's ⌄ menu | says what it inverts |
| Refine *(Colour Range)* | **Tolerance** | it is a width, not a refinement |
| Colour range / Brightness range *(similarity)* | **Colour tolerance / Brightness tolerance** | ditto, and they are not ranges |
| Automask | **Stay inside edges** | jargon → behaviour |
| Density | **Max strength** | the ceiling, which is what it is |
| Flow | *keep* — with a glyph | genuinely a term of art; the glyph does the teaching |
| Colour tint / Tint colour / Tint strength | **Colorize** + one swatch + **Amount** | four "tint"s in one section, next to white-balance Tint |

---

## 5. THE ENGINE

Three fixes. The first is the one that ends the tail and is also the one that makes §4.3 and §4.4
free.

### 5.1 Parametric components belong in a shader

**Claim.** `linear`, `radial`, `lumaRange`, `colorRange`, `similarity` and `similarityLine` are
closed-form per-pixel functions. They should be `CIKernel`s evaluated at render resolution and
never rasterized to a CPU `Plane` at all.

**What that buys.** A radial gradient stops touching the CPU, so it stops missing the raster
cache, so it stops being served stale — the tail ends by construction rather than by tuning a
cache. `maskSource`'s GPU→CPU readback (`Self.buffer(from: staged, context:)`, one per frame
whenever any range kind is present) disappears with it. And the mask edge is computed at render
resolution on every path, which closes the draft/settle edge discrepancy in §2.7.

**What it costs.** `MaskRaster` is the f64 reference the GPU is measured against
(`docs/14 §1.4`), and `Tests/…/maskalgebra.json` is the golden. Every kernel must hold parity
against the existing CPU function, which is exactly the discipline the other thirty-three kernels
already live under. `linear` and `radial` are twenty lines each and parity is testable to 1e-6.
The range kinds are harder only because they read the stage input — which on the GPU they already
have, as a `CIImage`, without the readback.

**Staging.** Ship `linear` + `radial` first, alone, behind their parity test. That is the owner's
reported defect fixed in the smallest change that can fix it. Then the range kinds. The refine
chain (guided filter, Gaussian, levels) is a third step; the EDT-based edge shift is the one piece
with no natural GPU form and may stay CPU-at-settle indefinitely, which is acceptable because it
is the one edge control nobody drags continuously.

**Brush and AI mattes stay rasters** — they *are* rasters — and keep the cache, which is what it
was built for.

**Falsification.** If the HUD's stale-serve rate during a radial drag is already ~0, this fix does
not address the reported tail and §5.2 is the whole cause. Run the §2.6 experiment first.

### 5.2 The overlay reads the render's alpha

Delete `renderMaskAlpha`, `AppState.refreshMaskOverlay`'s rasterization and
`MaskOverlayView.build`'s CPU composite. The alpha the renderer already computed for
`graph.maskImages` is the alpha the overlay should draw, and the composite is
`MaskOverlay.composite` as a kernel — six modes, one uniform, zero extra passes.

One source of truth for "what does this mask select", one rasterization per frame instead of two,
and the ambient overlay of §4.4 becomes affordable. This also removes a real correctness risk: two
independent rasterizations of the same mask can disagree, and today nothing tests that they don't.

### 5.3 A mask costs what it covers

`applyLocal` runs the full local adjustment set over the whole frame for every mask. Compute each
mask's bounding box from its alpha (with the refine chain's radius as padding), crop the expensive
spatial work — presence, sharpen — to that box, and composite. A vignette-sized radial then costs
a fraction of a frame instead of a whole one, and N masks stop being N full-frame local Laplacians.

Unmeasured, and stated as such: `docs/34 §5` lists "masked settles at zoom" as never profiled.
The measurement to take first is a settle with 1, 3 and 6 masks at fit and at 100%.

---

## 6. WHAT WE STILL OWE

Ranked by value per unit of cost. The first three need no model and no download.

1. **Similarity Point's missing half.** Add `center`, `radius` and a sign to `MaskComponent`, wire the canvas handles, gate the existing OKLab similarity by spatial falloff. This turns a component that is currently mis-named into the fastest selection tool in the app — and DxO's U-Point is the only comparable thing in the market, with no AI masks and no intersect to compose it with.
2. **The Brightness Range instrument.** A live luminance histogram with four handles (band + falloff), an eyedropper, and "show the luminance map". Capture One's version is the best-loved refinement in that application and we ship three plain sliders against it. The histogram machinery exists in `Scopes.swift`.
3. **Local Noise, Moiré, Defringe, Grain.** Five wire fields with no readers; `LocalNoiseAdjust` exists in `DenoiseEngine` with no caller. Lightroom ships all of them locally. This is render-stage work, not UI work — the panel is right to hide them until it is done.
4. **Depth Range on every photograph.** Depth Anything V2 **Small** (Apache-2.0; Base and Large are CC-BY-NC and prohibited). Lightroom's depth mask works only on iPhone-portrait HEIC. This is the clearest capability win over the market leader that a single bundled model buys.
5. **Sky**, then **Object** (SAM 2.1-small, cached encoder), then **People parts**. The order is by how often a photographer reaches for them.
6. **Copy/paste masks, and presets that carry them.** Neither exists. `docs/08 §8.10` claims adaptive presets as a headline.

None of §6 should start before §4 and §5.1 are done. A broader roster on an interaction nobody can
read is more of the problem, not less.

---

## 7. ORDER OF WORK

Sequenced by felt improvement per unit of risk, in the shape `docs/30` used, because it worked.

### Phase A — one afternoon, no new architecture

1. Run the §2.6 HUD experiment. Sixty seconds, and it decides the order of Phase C.
2. **The picker board** (§4.2). One function, no logic.
3. **The vocabulary** (§4.7). Label strings and one `⌄` menu.
4. **Overlay on create**, and on row hover. Two lines and a hover handler; it is the owner's stated ask and it lands before anything else is rebuilt.
5. **Two rings on the brush cursor**, and the brush's missing "drag on the image to paint" instruction.

### Phase B — the panel as three zones

6. The three surfaces, the moved Strength, the row `⌄` menu, in-place chip expansion (§4.1).
7. Mask and component thumbnails (§4.3).
8. `LumenBehaviourGlyph` and the eight glyphs (§4.5). **Prototype this one in isolation first** — it is the piece with a real chance of being wrong, and the piece most worth having if it is right.

### Phase C — the engine

9. `linear` + `radial` as kernels, behind parity tests (§5.1, stage one). Re-run the HUD.
10. The overlay on the render's alpha (§5.2). Ambient overlay and ⌥-drag matte become possible.
11. The range kinds as kernels (§5.1, stage two).
12. Bounding-box local adjust (§5.3), after measuring.

### Phase D — the canvas

13. Pins, all-masks-drawn, honest live stroke, drag-to-create.
14. The brush keyboard grammar, entire.

### Phase E — capability

15. §6, in order.

---

## 8. HOW WE WILL KNOW IT WORKED

Acceptance, written before the work so it cannot be moved afterwards.

| Claim | The test |
|---|---|
| The tail is gone | Drag a radial with Exposure +2 at fit. The bright region tracks the ellipse with no visible lag, and the HUD's stale-serve rate is 0. |
| A mask is legible | With three masks on a frame, a person who has not seen the panel can say what each one selects without clicking anything. The thumbnails are the whole answer. |
| The sliders teach | Same person can predict which direction Feather, Flow and Density move the picture, from the glyphs alone, before touching one. |
| Nothing regressed | `maskalgebra.json` golden green; the GPU/CPU mask parity test green; every kernel added has a test that fails when its call site is deleted. |
| The edge is real | Export at 6000 px with a hard luminance band and Snap-to-edges 50; the edge transition measures ~1 px, not the ~6 px an upsampled 1024 raster gives. |
| Words did not grow | The mask panel's word count goes **down**. It is **340 words across 48 sentences** today (counted over the file's user-facing strings of three words or more, comments excluded); the target is under 150, with the glyphs carrying what the sentences carried. |

---

## 9. THE ONE-LINE SUMMARY

Masking in Lumen has the deepest engine in the field — component algebra with visible Intersect, a
local point curve and local grading wheels that Lightroom Classic still does not have in 2026 —
wired to a form that asks the photographer to read its database schema, rasterized on a CPU path
that makes the picture arrive one gesture late. The engine is not the problem. **Rebuild the panel
as three questions, put the roster on a board, draw every mask as a picture of itself, draw every
parameter as the shape it is, and move the two cheapest components onto the GPU.** Everything
after that is roster.
