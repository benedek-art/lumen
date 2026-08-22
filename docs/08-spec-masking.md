# 08 — Masking

Masking is a Lumen flagship. The plan in one sentence: **Lightroom's mask semantics (the best UX
grammar in the business) on darktable's engineering (the best-documented open implementation), with
the two local tools Lightroom still refuses to ship — a point curve and grading wheels inside masks —
and a lifecycle that never blocks the UI, never demands a manual "Update AI Settings" click, and never
tells the user "Something went wrong."**

Three facts from the research drive every decision below:

1. **LrC 15.5's masking is the feature set to match.** Component stacks, the full AI roster
   (subject/sky/background/object/people-parts/landscape), range masks, per-mask Amount. Parity here
   is table stakes; the roster is enumerated component by component in this doc.
2. **LrC's masking is also its #1 performance and reliability complaint.** Brush lag, 0.5–10 s freezes
   switching photos with AI masks present, the 15.0 sync regression that turned batch editing into
   per-photo clicking, and the `.lrcat-data` corruption folklore ("delete the sidecar and let it
   regenerate") are documented, named anti-patterns. Reliability is a feature we ship (§8.7).
3. **Capture One is the local-adjustment depth reference.** Nearly every C1 tool works per-layer,
   including curves and the Color Editor. LrC still has neither a local tone curve nor local grading
   wheels in 2026 (masked point curves shipped in Camera Raw, not LrC; it is a top-voted request with
   C1 cited as the competitor that has it). Lumen ships both inside every mask from day 1 (§8.4).
   Per D29, this is the single clearest color-depth win available to us.

Pipeline placement: masks are evaluated at the local-adjustment stage (docs/14-pipeline.md owns stage
order). A mask is always computed from that stage's *input*, never from its own output — no feedback,
stable under the mask's own adjustments. Latency figures below live inside the global budgets of
docs/12-spec-ux.md (one-frame rule: ≤16.7 ms for continuous input; ≤100 ms for discrete actions).

---

## 8.1 The mask model

### Masks, components, and algebra

**What it is.** A photo has a list of **masks**. Each mask is a stack of **components** (any of the
14 types in §8.2–8.3) combined with **Add / Subtract / Intersect**, each component individually
invertible. Each mask carries one set of local adjustments (§8.4).

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Add / Subtract / Intersect | 3 visible buttons | Add | Per new component; all three always visible — no Alt-modifier easter egg |
| Component operation | ∪ / ∖ / ∩ dropdown | as created | Editable *after* creation on any component row |
| Invert component | toggle (`'`) | off | Per component |
| Invert mask | toggle | off | Whole-mask, after combine |
| Show/hide mask | eye toggle | shown | Disables render without deleting |
| Rename / Duplicate / Duplicate-and-Invert / Delete | ⋯ menu | — | LR-compatible operations |
| Overlay color | swatch | red | Per mask, feeds §8.6 |

**How it works.** Each component evaluates to a float [0,1] alpha buffer; the stack folds
deterministically top to bottom: `add = max(a, b)`, `subtract = min(a, 1−b)`,
`intersect = a × b`, `invert = 1−x`. Deterministic left-fold order is the ART lesson — mask algebra
must be predictable enough to debug by reading the list. The folded alpha then runs the refinement
chain (§8.5) and gates the mask's adjustment set:
`out = mix(base, adjusted(base, maskParams), alpha × amount)`.

```
component 1 ──┐  each → float [0,1] buffer at working resolution
component 2 ──┼─ fold (add=max, subtract=min(a,1−b), intersect=a×b, invert=1−x)
component 3 ──┘        ↓
              refinement chain (§8.5): edge-aware refine → edge shift → feather → levels
                       ↓
              alpha × Amount → gates the mask's local adjustment set (§8.4)
```

Vector components (brush, gradients, similarity points) are stored in source-image coordinates and
rasterized through the current geometry transform, so crop/rotate/lens changes reproject masks
automatically. ART documents this exact trap ("applying rotation after drawing masks will mess them
up") as a user precaution; darktable 5.6 solved it with a mask-distort framework. We solve it
structurally: geometry never invalidates a drawn mask, only re-rasterizes it.

The core design test case: "Sky ∩ Luminance 0.6–1.0, minus a brush stroke" must be three clicks and
must render live.

**How it feels.** `Shift+W` opens the Masks panel (floating or docked); pins on the canvas represent
masks. Every mask operation is a recipe mutation, so undo/history is free and complete. Component rows
show live grayscale thumbnails. Selecting a mask shows its adjustments; selecting a component shows
its own controls. Creating, toggling, and re-ordering components renders at ≤16.7 ms because the fold
is a trivial GPU pass over cached component buffers.

**Vs. the field.** **Better than LrC 15.5 because** the semantics are identical (deliberately — the
grammar users already know) but Intersect is a first-class visible button rather than an
Alt-modifier/⋯-menu secret that every tutorial has to explain, and a component's operation can be
changed after creation. **Better than Capture One 16.8.4 because** C1's 16-layer model needed
16.7.0's "Combine Masks" to patch its own mask-type sprawl; component algebra inside one mask is the
cleaner primitive, and C1's per-layer opacity is subsumed by our Amount system (next entry).

### Per-mask Amount and per-component Amount

**What it is.** Two multipliers Adobe ships one of: a per-mask **Amount** scaling all of the mask's
adjustments, and a per-component **Amount** scaling that component's contribution to the mask alpha —
the "Amount or Opacity slider for individual tools within a mask" that has sat as an open Adobe
feature request for years.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Mask Amount | 0–200 | 100 | Multiplier over the whole adjustment set; >100 amplifies past slider maxima |
| Pin scrub | Alt-drag on pin | — | Scrubs Amount with on-image ghost readout; no panel round-trip |
| Component Amount | 0–100 | 100 | Scales that component's alpha before the fold |

**How it works.** Mask Amount scales the adjustment deltas (exposure in EV, curve displacement,
wheel offsets) linearly; 0–200 means one drag replaces LR users' stacked-duplicate-masks trick for
exceeding +100. Component Amount multiplies the component alpha pre-fold — e.g. a subtracting brush
at 40 removes only 40% of the mask where it painted, which is how you dodge an AI mask's edge without
re-brushing at low flow.

**How it feels.** Amount sits at the top of the mask's adjustment panel; Alt-drag on the mask pin
scrubs it with the Speed-Edit ghost readout (docs/12-spec-ux.md). Both sliders obey the Lumen slider
contract (double-click reset, arrow nudge, typed entry).

**Vs. the field.** **Better than LrC 15.5 because** LrC has the 0–200 mask Amount and the pin
Alt-drag (both cloned here) but refuses per-component amount — its Amount is all-or-nothing across
the component stack. **Better than Capture One 16.8.4 because** C1's layer opacity is one dial per
layer; we give that dial at both granularities, and Amount >100 (amplify) has no C1 equivalent.

---

## 8.2 Components — manual and parametric

### Brush

**What it is.** Freehand painting of mask density, with an edge-aware automask and a separate eraser.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Size | 1–4000 px on-screen | 200 | `[` / `]`; Alt+scroll on canvas |
| Feather | 0–100 | 50 | `Shift+[` / `Shift+]`; hardness falloff of the stamp |
| Flow | 1–100 | 100 | Per-pass accumulation; digits 1–9 = 10–90%, 0 = 100%, two quick digits exact |
| Density | 0–100 | 100 | Opacity ceiling — painted area never exceeds Density regardless of passes |
| Automask | toggle (`A`) | off | Edge-aware confinement to similar color/texture |
| Eraser | hold Alt, or `E` | — | Own Size/Feather/Flow, remembered separately |

**How it works.** Strokes are stored as **vectors**: timestamped point lists with pressure
(NSEvent pressure; tablets supported), smoothed with Catmull-Rom, rasterized as stamped
radial-falloff discs at any resolution. Vector storage (darktable's approach) means strokes are
replayable at full res, at export res, and after any geometry change — no baked raster to smudge.
Automask is a per-stamp color-similarity gate against the stamp-center sample, computed in OKLab on
the mask-stage input; the known automask failure mode (speckle at high ISO) is damped by sampling
from the denoised stage input, not the raw signal. Eraser strokes are the same vector type with an
erase flag.

**How it feels.** `K` activates the brush. Cursor shows size and feather rings. Stamp-to-screen
latency budget ≤16.7 ms per frame including the composite — brush lag once several masks exist is
LrC's single most-reported masking complaint, so brush strokes render into the cached component
buffer incrementally rather than re-folding the whole stack per stamp.

**Vs. the field.** **Equal to LrC 15.5 on surface** (identical Size/Feather/Flow/Density + automask +
separate eraser contract, same keys), **better on substance because** strokes are vectors
(resolution-independent, geometry-proof) and the latency budget is enforced in CI (docs/12) where LrC
documents years of brush-lag threads. **Better than Capture One 16.8.4 because** C1's brush lacks a
Density ceiling, and its Magic Brush's fill-similar behavior is covered by Automask plus the
Similarity Point component below.

### Linear Gradient

**What it is.** A linear ramp between two draggable lines; the span is the feather.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Span / position / rotation | on-canvas handles | — | Shift constrains to 0/90°; drag center line to move |
| Mirror | toggle | off | Fades symmetrically from both sides — band masks in one drag |
| Invert | toggle (`'`) | off | |

**How it works.** Pure parametric ramp: alpha = smoothstep along the gradient axis; stored as two
endpoints in source coordinates. Zero raster storage, exact at any resolution.

**How it feels.** `M` activates; drag to create; endlessly re-editable. Renders at frame rate always.

**Vs. the field.** **Equal to LrC 15.5** (same tool, same key) **plus Mirror**, which turns the
common "two stacked opposing gradients" ritual into one control. **Equal to Capture One 16.8.4**,
whose parametric re-editable gradients set the standard.

### Radial Gradient

**What it is.** An elliptical falloff mask; the vignette/spotlight primitive.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Ellipse | on-canvas handles | — | Resize/rotate; Shift constrains to circle |
| Feather | 0–100 | 50 | Falloff width from ellipse edge |
| Invert | toggle (`'`) | off | Effect inside vs outside |

**How it works.** Parametric: signed distance to the ellipse mapped through a smooth falloff.
Stored as center/axes/rotation. Exact at any resolution.

**How it feels.** `Shift+M`; drag to create from corner, Alt-drag from center. Frame-rate always.

**Vs. the field.** **Equal to LrC 15.5** (same contract, default Feather 50 matched) and **equal to
Capture One 16.8.4**. There is nothing left to win here; parity with zero surprises is the goal.

### Luminance Range

**What it is.** Selects a tonal band of the image — the go-to for sky recovery, tone-targeted
dodge/burn, and taming night-scene highlights.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Band (min/max + falloff ramps) | trapezoid handles over a luminance histogram | full range | Drag body to move, edges to resize, outer thumbs for falloff |
| Smoothness | 0–100 | 50 | Global softness of both shoulders; low values risk banding, so the histogram shows the ramp |
| Show Luminance Map | toggle | off | Renders the image as the luminance matte being sampled |
| Eyedropper | click or drag-select | — | Sets the band from image content |
| Invert | toggle (`'`) | off | |

**How it works.** Per-pixel trapezoid function (darktable's parametric-mask shape: hard core, soft
shoulders) over the **scene-referred log luminance of the mask-stage input**, so the handles are
EV-denominated and the mask is stable under display-transform changes. Computed on the GPU per frame;
no raster stored.

**How it feels.** The band control sits over a live mini-histogram; dragging any handle updates the
image at frame rate with the overlay visible. Because it is a component, "Radial ∩ Luminance
highlights" — C1's signature Luma Range move — is two clicks.

**Vs. the field.** **Equal to LrC 15.5's Luminance Range** (band + Smoothness 50 default + luminance
map view, all matched) with EV-denominated handles LrC lacks. **Equal to Capture One 16.8.4's
per-layer Luma Range** — C1's most-loved refinement — but composable with every component type, not
just as a layer post-filter.

### Color Range

**What it is.** Selects pixels near sampled colors; the "this blue, wherever it is" mask.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Samples | up to 8 (Shift+click to add) | 1 | Per-sample chips with delete |
| Refine | 0–100 | 50 | Widens/narrows the envelope; Alt-drag shows the grayscale matte |
| Hue / Chroma / Luma tolerance | 0–100 each | linked to Refine | Disclosure: per-axis widths when Refine's single dial isn't enough |
| Invert | toggle (`'`) | off | |

**How it works.** Similarity in OKLab hue/chroma/lightness with trapezoid falloff per axis; multiple
samples union before falloff. Per-pixel GPU function, no raster. The usual pattern — intersecting a
color range with a spatial component — is exactly what the first-class Intersect button is for.

**How it feels.** Eyedropper with the scalable loupe (docs/04-spec-tone.md's WB loupe, reused).
Alt-dragging Refine shows the matte live, the micro-interaction LR users love.

**Vs. the field.** **Better than LrC 15.5 because** LrC caps at 5 samples with a single Refine dial;
we take 8 and add per-axis tolerances behind disclosure. **Equal to Capture One 16.8.4's Color Editor
advanced slices converted to masks** — C1's flow is the reference for precision, but it is a
tab-and-convert ritual; ours is a native component. (Full selective-color tooling with Uniformity
lives in docs/05-spec-color.md and is available *inside* masks via Point Color, §8.4.)

### Similarity Point and Similarity Line

**What it is.** The U-Point idea, licensed from history rather than DxO: click to sample a point, and
the mask is "pixels like this one, near here." Similarity Line is a linear gradient gated by the same
similarity test. This is the fast manual middle ground between brushing and AI.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Radius | on-canvas circle | ~15% long edge | Spatial falloff of a point |
| Chroma selectivity | 0–100 | 50 | How tightly the mask clings to the sampled color |
| Luma selectivity | 0–100 | 50 | Same for tone |
| Additional points | click (+) / Alt-click (−) | — | Positive points extend, negative points subtract |
| Line: gradient + sample eyedropper | detachable | at line | "Sky-colored pixels only, in the top half" |

**How it works.** Alpha = spatial falloff × similarity(sample, pixel) where similarity is a Gaussian
in OKLab chroma and lightness distance, widths set by the two selectivity sliders (DxO's parameters:
0–100, default 50 each, PL5-era Chroma/Luma selectivity). Points sharing a component union their
alphas; negative points subtract. The Line variant multiplies a linear ramp by the similarity gate,
with the sampling eyedropper detachable from the line itself (DxO Control Line's best idea). Per-pixel
GPU function, no raster.

**How it feels.** Two clicks select what takes minutes of brushing: click the sky, widen chroma
selectivity, done. Selectivity sliders live next to the point; on-canvas drag ring adjusts radius.

**Vs. the field.** **Better than LrC 15.5 because** LR has no equivalent at all — approximating a
control point takes Color Range ∩ Radial and still lacks luma gating. **Equal to DxO PhotoLab's
U-Point** (PL8-era; PL9 unverified this cycle) on the core mechanic, **better because** our points
compose with AI components and full mask algebra, where DxO through PL8 has no AI masks and no
intersect combinators.

---

## 8.3 Components — AI

All AI components follow the same contract: they produce a cached raster at generation resolution,
which the refinement chain (§8.5) upsamples edge-aware to full res. They compute asynchronously
(§8.7), store their **prompt** (clicks, boxes, scribbles, model + version) parametrically, and
recompute per-photo when embedded in presets (§8.10). Model choices and licenses: §8.8.

### Subject

**What it is.** One click selects "the subject."

**Controls.** One button; if multiple foreground instances exist, instance chips appear — tap to pick
one, several, or all. Standard refinement (§8.5) and algebra apply.

**How it works.** Two passes. **Instant pass:** Vision's foreground instance mask request
(`VNGenerateForegroundInstanceMaskRequest`, macOS 14+; Swift variant macOS 15+) — OS-supplied, no
model download, returns per-instance masks in well under a second on Apple Silicon (budget: 1 s).
**Quality pass:** BiRefNet (MIT) matting refines the chosen instance to a continuous-alpha,
hair-grade matte asynchronously; the mask row shows a subtle "refining" shimmer until it lands,
then the matte replaces the instant mask in place. Matte-grade masks cache at 16-bit; binary-ish
masks at 8-bit.

**How it feels.** Click → usable mask inside a second → visibly better hair edges a couple of seconds
later, with no modal wait. Failure is honest: "No clear subject found — try Object and scribble it."

**Vs. the field.** **Equal to LrC 15.5 on the click** (its 15.4 Select Subject model was a real
accuracy jump; parity is the quality target), **better on the mask itself because** the BiRefNet
matting pass yields continuous alpha for hair/fur where LR's subject masks still show imperfect hair
edges, and **better on failure behavior** — LR's canonical subject-mask failure is a GPU-driver
"Something went wrong." **Better than Capture One 16.8.4's Select Subject because** C1 has no
hair-matting pass and its AI masking is documented as slower than Adobe's on identical hardware.

### Sky

**What it is.** One click selects the sky, including through branches and around skylines.

**Controls.** One button; standard refinement and algebra.

**How it works.** Dedicated sky-segmentation model (MIT-licensed skyseg-class ONNX → Core ML; §8.8),
validated against the classic failure set: sunsets (color alone can't define sky), branches against
sky (thin-structure holes), reflections (water must *not* be sky — that's what Intersect with an
inverted Landscape "water" class or a linear gradient is for). Guided-filter refinement makes the
branch holes crisp at full res.

**How it feels.** Click, done, ≤1.5 s budget. The most common composite — "Sky, minus the mountain
it bled onto" — is Subtract + one scribbled Object component.

**Vs. the field.** **Equal to LrC 15.5's Select Sky** (the parity target). **Better than Capture One
16.8.4 because C1 has no sky mask at all** — a real, cited gap for landscape shooters and one of the
reasons its AI masking loses to LR's breadth.

### Background

**What it is.** One click selects everything that is not the subject.

**Controls.** One button; standard refinement and algebra.

**How it works.** Complement of the union of detected foreground instances, sharing the Subject
component's computation and cache (one model run serves both). We deliberately do not ship a separate
background model: a complement is consistent with Subject by construction — LR's separate models can
disagree, which is why its community workaround "subtract Entire Person from Background when
Background fails" exists.

**How it feels.** Identical to Subject; instant pass then quality pass.

**Vs. the field.** **Equal to LrC 15.5 in outcome, simpler in mechanism** (consistency by
construction instead of a second model that can disagree with the first). **Equal to Capture One
16.8.4's Select Background.**

### Object (click, scribble, or box)

**What it is.** Select an arbitrary thing: click it, scribble over it, or box it.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Click / Shift+click | include / additional include | — | SAM point prompts |
| Alt+click | exclude point | — | Carves the selection back |
| Scribble | drag | — | For cluttered scenes; strokes become dense prompts |
| Box | drag rectangle | — | For well-separated objects |
| Reset | button / Esc | — | Prompt-coaching: separate objects need a reset, not repair (the darktable 5.6 lesson) |

**How it works.** SAM 2.1-small (Apache-2.0, 46M params) via Core ML: the encoder runs **once per
photo** (1024 px input), its embeddings cached on disk across sessions; the decoder runs per prompt in
<10 ms, so every click/scribble/box refines interactively. Previous low-res masks feed back into the
next decode for iterative refinement — the proven desktop pattern (darktable 5.6, AnyLabeling). On
macOS 27+, Apple's `GenerateIterativeSegmentationRequest` (tap/scribble/box seeds, up to 13
include/exclude points) becomes the zero-download default path with SAM as the floor for older OS
versions and for determinism (§8.8). Geometry or pixel-changing edits upstream invalidate the
embedding cache; recompute is async (§8.7).

**How it feels.** First click on a fresh photo: ~1 s (encoder) then instant; every subsequent click:
instant. The include/exclude grammar is the same as the brush's add/erase mental model.

**Vs. the field.** **Better than LrC 15.5 because** LR's Select Objects offers only Brush Select and
Rectangle Select — no point prompts, no iterative include/exclude refinement — and each invocation is
a full model round-trip rather than a cached-encoder decode. **Better than darktable 5.6's SAM
integration on responsiveness** (same architecture, but our decoder budget is interactive and the
embedding cache is managed automatically, not a first-run surprise).

### People, with parts

**What it is.** Per-person masks decomposed into the nine parts portrait retouchers actually
address: **Face Skin, Body Skin, Eyebrows, Eye Sclera, Iris & Pupil, Lips, Teeth, Hair, Clothes** —
plus Entire Person. Multi-select parts into one combined mask or generate separate masks per part.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Person chips | Person 1…N, All People | — | Thumbnail per detected person |
| Part checkboxes | the 9 parts + Entire Person | Entire Person | Multi-check |
| Combined / Separate | toggle | Combined | One mask vs one mask per checked part |

**How it works.** Person instances come from Vision (`GeneratePersonInstanceMaskRequest`,
macOS 15+). Parts are synthesized per person: face regions (sclera, iris, lips, teeth, brows) are
seeded from Vision's face-landmark constellation and refined by SAM decoder prompts inside the face
crop plus color-similarity gating; Hair comes from the BiRefNet matting pass minus the face-skin
region; Face/Body Skin from skin-tone modeling inside the person matte; Clothes = person minus
skin/hair/head. On iPhone ProRAW files, Apple's embedded semantic mattes (skin, hair, teeth, glasses,
sky) are used directly — free and better than anything we compute. A dedicated commercially-licensed
face-parsing model is an open bake-off item (§8.8); the synthesis path above is the shippable v1 and
is honest about per-part confidence (a part that fails to resolve is flagged on its row, not
silently boxed).

**How it feels.** The LR flow, cloned: pick a person, check Teeth + Sclera, get one mask, pull
Whites up a touch, done. Separate-masks mode feeds adaptive presets ("Polished Portrait" preset =
6 part-masks with distinct adjustment sets, recomputed per photo, §8.10).

**Vs. the field.** **Parity ambition with LrC 15.5, honestly phased:** Adobe's dedicated part models
are the category leader, and our landmark+SAM synthesis will trail on small or turned faces at first
(LR's own part masks also degrade to boxes there). We match the *grammar* exactly — 9 parts,
combined-or-separate — and state per-part confidence instead of silently failing. **Better than
Capture One 16.8.4 because C1 has no person-part decomposition at all**, a real gap for exactly this
product's owner (portraits, events).

### Landscape classes

**What it is.** Semantic scene classes as components: **Sky, Water, Vegetation, Mountains,
Architecture, Ground** — one combined mask or separate masks per class.

**Controls.** Class checkboxes + Combined/Separate toggle, same grammar as People.

**How it works.** A scene-parsing segmentation model (bake-off open — the candidate weights are
trained on research-restricted datasets and must clear the license ledger, docs/17-appendix.md,
before shipping; §8.8). Until it clears, Sky comes from the sky model and Water/Vegetation are
served capably by Similarity Points — the roster row ships when the model does. We consciously ship
6 classes to LrC 14.3's 8: Snow is a Luminance Range intersect away, and the Natural/Artificial
Ground split costs model accuracy for a distinction a gradient usually handles. If the bake-off
model resolves 8 classes reliably, the roster grows.

**How it feels.** The batch-preset use case is the point: a landscape adaptive preset (sky −0.5 EV +
grad, vegetation +vibrance, water +clarity) recomputed across 300 travel frames (§8.10).

**Vs. the field.** **Consciously narrower than LrC 15.5** (6 classes vs 8, for the accuracy-per-class
reasons above — an explicit tradeoff, revisited when the model proves out). Reviewer consensus on
LR's landscape masking ("fast and accurate on clear scenes; fuzzy on intermingled vegetation/water")
sets a realistic quality bar. **Better than Capture One 16.8.4 because C1 has nothing in this
category.**

### Depth Range — for every photo

**What it is.** Mask by distance from camera: a near/far band with falloff, on **any** photo — not
just files that shipped with a depth map.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Depth band | trapezoid handles over a depth histogram | full range | Same interaction as Luminance Range |
| Smoothness | 0–100 | 50 | Shoulder softness |
| Show Depth Map | toggle | off | False-color depth view |
| Invert | toggle (`'`) | off | |

**How it works.** Monocular depth from Depth Anything V2 **Small** (Apache-2.0; the Base/Large
variants are CC-BY-NC and off-limits) via Core ML, ≤1 s budget, cached like any AI raster. Relative
depth is exactly right for masking: the band handles select ordinal depth, no metric calibration
needed. Files carrying real depth (iPhone portrait HEIC, ProRAW) use the embedded map instead.
Trapezoid band + guided-filter refinement, same machinery as Luminance Range.

**How it feels.** "Cool down the background" without selecting the subject; "lift the foreground
rocks" on a landscape. Atmosphere-by-distance grades (fog the far plane) become one drag.

**Vs. the field.** **Better than LrC 15.5 because** LR's Depth Range is enabled only for
iPhone-portrait HEIC files with embedded depth — a gimmick restriction; ours works on every raw ever
shot. **Better than Capture One 16.8.4** (nothing comparable). RapidRAW 1.6.1 is the only other
editor shipping Depth-Anything-based masks; we match it and exceed it on the band UI.

---

## 8.4 What you can adjust inside a mask

### The local adjustment set

**What it is.** Every mask carries a mini-recipe. The roster deliberately includes the two tools LrC
lacks locally (point curve, grading wheels) and full local detail controls (NR, moiré, defringe).

**Controls.**

| Group | Controls | Range | Notes |
|---|---|---|---|
| Amount | mask Amount | 0–200 | §8.1 |
| Light | Exposure | ±4 EV | Same engine as docs/04-spec-tone.md, gated by alpha |
| | Contrast, Highlights, Shadows, Whites, Blacks | ±100 each | The six-slider contract, local |
| **Curve** | **Point curve: Luma + RGB + per-channel R/G/B** | node editor | **LrC has no local curve as of 15.5.** Luminance-preserving default (docs/04's D10 semantics) |
| Color | Temp / Tint (relative) | ±100 | |
| | Hue shift (with fine mode), Saturation, Vibrance | ±180 / ±100 / ±100 | |
| | Color tint swatch + strength | picker, 0–100 | Colorize the masked region |
| | Point Color swatches | up to 8 per mask | Full sampled-swatch editor incl. Variance (docs/05-spec-color.md owns the spec) |
| **Grading** | **3-way wheels + Global, per-wheel Luminance, Blending, Balance** | wheels | **LrC has no local wheels as of 15.5.** Compact variant of docs/05's grading panel; zone pivots inherit the visible global pivots |
| Presence | Texture, Clarity, Dehaze | ±100 each | Local-Laplacian Clarity — halo-free, matters most at masked sky/land edges |
| | Grain | 0–100 | Amount only; character inherits the global grain engine (docs/06-spec-detail.md) |
| Detail | Sharpness | ±100 | Negative = blur |
| | Noise | 0–100 | Classical Tier-1 NR lift (docs/07-spec-denoise.md); disclosure splits Luma/Chroma |
| | Moiré | 0–100 | Directional chroma suppression |
| | Defringe | 0–100 | Local strength of docs/09-spec-geometry.md's defringe |

**How it works.** Each local op runs the same kernel as its global counterpart, in the same color
space (OKLab/UCS where the global op uses them — docs/05), composited through the mask alpha at the
local-adjustment stage. The local point curve is the one placement exception: it runs as a second
engine tap on the picture-domain signal after the display transform, through the same pre-geometry
mask raster, so curves feel identical globally and locally (docs/14-pipeline.md owns the two-tap
design). The local point curve defaults to luminance-preserving application so
steepening contrast inside a face mask doesn't pump saturation; the wheels run in the same UCS as the
global grading panel with the same soft gamut mapping. Local Noise is the classical tier (live,
profiled); the AI denoise splice is global-only by design (docs/07 owns why). Nothing here forks the
math: a masked adjustment is the global adjustment times an alpha.

**How it feels.** The panel mirrors the global panel's order, so nothing has to be re-learned;
collapsed groups keep the common case (Light + a curve) one glance tall. Masked grading with wheels:
click Sky mask, open Grading, drag the highlight wheel toward warm, watch only the sky move — the
Resolve power-window workflow inside a photo editor.

**Vs. the field.** **Better than LrC 15.5, and this is the headline:** LrC's local set (verified
roster: Light six + Temp/Tint/Hue/Sat/Point Color/tint swatch + Texture/Clarity/Dehaze/Grain +
Sharpness/Noise/Moiré/Defringe) still excludes the tone curve and the grading wheels in 2026 — masked
point curves exist in Camera Raw but not LrC, and the request thread names Capture One as the app
that has it. We ship both, plus Vibrance and split Luma/Chroma NR locally. **Equal to Capture One
16.8.4 in local depth** (C1's nearly-everything-per-layer model, including Color Editor and curves,
is the reference we match), **better in local grammar** because C1's layers don't have per-component
algebra or 0–200 amplification. **Better than DxO PhotoLab (PL8-era) because** U-Point local
adjustments have no local curves at all.

---

## 8.5 The refinement chain

### Refine, Edge Shift, Feather, Levels

**What it is.** Four post-combine controls on every mask — available from day 1 on every component
type, AI or manual.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Refine (edge-aware) | 0–100 | AI masks 10, drawn 0 | Guided-filter snap of the alpha to image edges |
| Edge Shift | −50 to +50 | 0 | Grow/shrink the boundary |
| Feather | 0–100 | 0 | Gaussian soften |
| Levels | Lo 0–100 / Hi 0–100 / Gamma 0.2–5.0 | 0 / 100 / 1.0 | Remap mask density; mini-histogram of the alpha shown |

**How it works.** The chain runs in a fixed order on the folded alpha:

```
folded alpha
  → guided-filter refine (image-guided, edge-aware; the step that turns a 1024px
    AI raster into a mask that holds at 100% zoom on a 61MP file; O(1) per pixel
    via box filters, 4× subsampled fast variant, radius ≈ Refine × 2% long edge)
  → edge shift (signed-distance dilate/erode; ±50 ≈ ±1% long edge)
  → feather (Gaussian, σ ≈ Feather × 1% long edge)
  → levels (lo/hi/gamma density remap — ART's mask-contrast idea, generalized)
  → × Amount
```

Guided-filter feathering is the engineering heart (darktable uses it for exactly this; it beats
DenseCRF on cost and is GPU-native). Raster components are generated at 1024–2048 px and *only* the
refine step touches full resolution, lazily per zoom tier, so refinement never blocks interaction.

**How it feels.** All four sliders live-preview against the current overlay mode at ≤16.7 ms (the
chain is four cheap GPU passes over one channel). Alt-drag on any of them shows the pure matte.

**Vs. the field.** **Better than LrC 15.5 because** Adobe shipped Feather (0–100) and Edge (−50..+50)
only in 15.3/15.5 (2026), on AI masks — we ship both on *every* mask from day 1 and add the Levels
density remap, which LrC has no equivalent for. **Better than darktable 5.6 in packaging** (same
guided-filter engineering, but dt exposes feathering as a per-module 0–10,000 parameter; ours is one
0–100 slider with sane scale mapping).

---

## 8.6 Overlays and keyboard grammar

### Mask visualization

**What it is.** Six overlay modes and a keyboard grammar cloned from LR so fifteen years of tutorials
and muscle memory transfer.

**Controls.**

| Control | Values | Default | Notes |
|---|---|---|---|
| Overlay mode | Color Overlay · Color on B&W · Image on B&W · Image on Black · Image on White · Matte (white on black) | Color Overlay | `Alt+O` cycles |
| Overlay toggle | on/off | auto | `O` |
| Overlay color | red → green → white → black | red, per-mask swatch | `Shift+O` cycles |
| Auto-show | behavior | on | Shows on mask-row hover and during creation; hides while dragging adjustment sliders |

**How it works.** All six modes are trivial shader variants over the same refined alpha — one
compositing uniform, zero extra computation. The matte mode is the ground truth view used by every
Alt-drag interaction in this doc.

**How it feels.** Keyboard summary (full map in docs/12-spec-ux.md): `Shift+W` masking · `K` brush ·
`M` linear · `Shift+M` radial · `O` / `Shift+O` / `Alt+O` overlays · `'` invert · `[` `]` size ·
`Shift+[` `]` feather · digits flow · `A` automask · hold-Alt erase.

**Vs. the field.** **Equal to LrC 15.5** — its six modes and three overlay shortcuts are the industry
reference and are adopted verbatim. **Better than Capture One 16.8.4 and darktable 5.6**, both of
which offer fewer visualization modes and less consistent shortcuts.

---

## 8.7 The mask lifecycle — async, self-healing, honest

### Never block, never nag, never lie

**What it is.** The reliability contract (D30). Mask computation and recomputation are always
asynchronous; caches are versioned and self-healing; batch operations recompute automatically;
errors state their cause.

**How it works.**

```
UI thread:      composites cached rasters only. Photo switch with 10 AI masks
                = load memory-mapped alphas → ≤100 ms, always.
Background:     ┌ mask work queue (viewing-priority scheduling, shared with
                │ docs/07's denoise queue)
                │  encoder runs, model inference, guided-filter full-res refine,
                │  batch recompute jobs
                └ progressive delivery: instant pass → quality pass, in place
Invalidation:   every raster cache keyed by (assetID, componentID, model+version,
                sourcePrefixHash, pipelineVersion). Upstream pixel change (denoise
                splice, healing) → stale-flag + auto-enqueue. Geometry change →
                vectors reproject (free), rasters re-refine (cheap), embeddings
                invalidate (re-encode async).
Self-healing:   raster fails checksum or version → regenerate silently from the
                parametric truth. The raster is never the source of truth.
Batch:          sync / preset-apply / paste enqueues recompute for every target
                photo automatically, with progress in the background activity
                panel. Stale masks render with a badge but the photo stays
                fully editable meanwhile.
```

Two named anti-patterns define the contract. **LrC 15.0's sync regression:** auto-recompute-on-sync
became a manual per-photo "Update AI Settings" click, breaking batch workflows so badly that
high-volume shooters rolled back to 14.5.2; Adobe patched it piecemeal across 15.1/15.2. Lumen's
rule: *a batch operation is never followed by N manual clicks.* **The `.lrcat-data` folklore:**
corrupted AI-mask sidecars render masks black/blank, and the community fix is quit-and-delete-the-
sidecar — a UX failure dressed as a tip. Lumen's rule: *caches heal themselves; users never learn a
cache file's name* (docs/15-catalog.md owns the storage machinery, D52).

Error surfaces are specific and actionable, never "Something went wrong" (LR's despised catch-all,
usually a GPU-driver issue misreported as model flakiness): "Model not downloaded — [Download
(84 MB)]" · "No subject found — try Object and scribble" · "Out of memory at full res; mask computed
at half res — [Retry full]".

**How it feels.** Masks are always *there* — possibly briefly stale-badged, never a spinner, never a
freeze. LrC's documented 0.5–10 s Develop-switch freezes with AI masks are the failure this section
exists to prevent; the ≤100 ms photo-switch budget is measured in the CI release gate (docs/12,
D47).

**Vs. the field.** **Better than LrC 15.5 because** LR's mask re-evaluation is synchronous with the
UI (the root of its #1 masking complaint), its batch recompute broke for a whole release cycle, and
its cache corruption has a folk remedy instead of a fix. **Better than Capture One 16.8.4 because**
C1's AI masking is slower than Adobe's on identical hardware with no async-lifecycle story. This is
the section where Lumen wins masking without needing to out-model anyone.

---

## 8.8 The model stack

| Role | Engine | Size / cost | License | Notes |
|---|---|---|---|---|
| Subject / instances (instant) | Vision `VNGenerateForegroundInstanceMaskRequest` (macOS 14+; Swift request macOS 15+) | OS built-in, ~free | Apple OS | Zero download; per-instance masks |
| People instances | Vision `GeneratePersonInstanceMaskRequest` + person matte (macOS 15+) | OS built-in | Apple OS | Person chips in §8.3 |
| Hair-grade matting | BiRefNet (dynamic 256–2304 px / HR-matting variants) | ~3.5 GB fp16 inference; 58–96 ms/frame on desktop GPU class — run async, budget ≤3 s | **MIT** | The quality pass behind Subject/People; 16-bit mattes |
| Click/scribble/box select | SAM 2.1-**small** (46 M params) | encoder ~1 s once per photo (cached embeddings on disk); decoder <10 ms/prompt | **Apache-2.0** | The interactive engine; Tiny (38.9 M) is the fallback for low-memory configs |
| Zero-download interactive (adoption path) | Apple `GenerateIterativeSegmentationRequest` (macOS 27 beta) | OS downloadable assets | Apple OS | Tap/scribble/box seeds, ≤13 include/exclude points, qualityLevel; becomes the default on macOS 27+, SAM remains the floor |
| Sky | skyseg-class ONNX → Core ML | small, ≤1.5 s | **MIT** | Validated on sunsets / branches / reflections |
| Depth | Depth Anything V2 **Small** | ≤1 s at 518 px | **Apache-2.0** | V2 Base/Large are **CC-BY-NC — prohibited** (license ledger, docs/17-appendix.md) |
| Landscape scene parsing | bake-off open | — | **gate: unresolved** | Candidate weights trained on research-restricted datasets; ships only after the ledger clears it |
| Face parsing (parts) | v1: landmark-seeded SAM + BiRefNet + skin model (see §8.3); dedicated model = bake-off open | — | gate: unresolved | ProRAW files use embedded mattes instead |
| ProRAW semantic mattes | CIRAWFilter (skin/hair/teeth/glasses/sky) | free | Apple OS | D50; best-quality source when present |

Runtime: Core ML, fp16, ANE-first, fixed tile shapes (docs/13-architecture.md, D51); Metal 4
in-graph inference (`MTL4MachineLearningCommandEncoder`, macOS 26+) is the planned migration for the
refine passes. All model downloads are explicit, versioned, and local; one active model per task
(darktable 5.6's task/model registry pattern). Master AI off-switch per D5.

License landmines, restated because they are easy to trip on: no EdgeSAM, no RMBG, no MIRNet, no
Depth Anything V2 Base/Large — the safe list above is the whole list (docs/17-appendix.md owns the
full ledger).

---

## 8.9 Storage: parametric truth, disposable rasters

Owned schema lives in docs/15-catalog.md; the contract here:

- **Recipe JSON stores the parametric truth for every component**: brush stroke point lists with
  pressure; gradient endpoints; ellipse parameters; range-band parameters; sampled colors; similarity
  points with selectivities; AI components as *prompt records* (type, seeds/clicks/boxes, person/part
  or class selections, model id + version). Refinement and adjustment parameters ride along. XMP
  sidecars carry the same parametric definitions in Lumen's namespace, so masks survive catalog loss.
- **Raster caches are versioned and disposable**: 8-bit single-channel (16-bit for matte-grade),
  compressed, keyed as in §8.7. Any mismatch → regenerate. Deleting the entire mask cache loses
  nothing but warm-up time. `pipelineVersion` is in the key from day 1 (D52), so an engine upgrade
  regenerates rasters instead of rendering stale ones — LR's silent-PV-upgrade mistake, inverted.
- Embeddings (SAM encoder features) cache separately with the same key discipline; they are the
  largest per-photo artifact and are LRU-evicted without user-visible consequence beyond a 1 s
  re-encode.

## 8.10 Adaptive presets

Any preset (docs/11-output.md owns preset management; the Develop/Look split is D4) can embed masks —
including AI components — because masks are stored as prompts, not pixels. On apply, AI components
recompute **for the target photo**, asynchronously, through the §8.7 queue: a "Polished Portrait"
preset re-finds each photo's faces; a landscape preset re-finds each photo's sky. This is LR's
Adaptive Presets concept (the genuinely valuable core of it — we skip the marketplace mechanics) with
the recompute behavior LR broke in 15.0 guaranteed by architecture: preset-apply over 800 selected
frames enqueues 800 background jobs with progress, and every photo is editable while its masks
resolve. A prompt that finds nothing (no person in frame) lands as an empty mask with a badge and its
adjustments intact — never an error dialog, never a silent drop.

**Vs. the field:** equal to LrC 15.5's adaptive presets in concept, better in batch reliability
(§8.7); equal to Capture One 16.8.4's layers-aware Styles, better because our embedded AI components
re-target per photo where a C1 style's mask is what it is.

## 8.11 Scorecard

| Capability | Lumen | LrC 15.5 | C1 16.8.4 | DxO PL8-era |
|---|---|---|---|---|
| Component algebra | Add/Sub/**Intersect visible**, op editable | Add/Sub visible, Intersect hidden | Layers + Combine Masks | add/erase only |
| Per-mask Amount 0–200 + pin scrub | yes | yes | opacity 0–100 | opacity 0–100 (PL7+) |
| **Per-component Amount** | **yes** | no (open request) | no | no |
| Brush / linear / radial / luma / color range | yes (vector brush) | yes | yes (luma is layer-level) | partial |
| Similarity point/line | yes | no | Magic Brush (weaker) | **yes (U-Point — the source)** |
| Subject / Sky / Background / Object | yes + hair matting | yes (no point prompts) | no Sky; slower | none |
| People parts (9) | yes (phased quality) | **yes (leader)** | no | no |
| Landscape classes | 6 (deliberate) | 8 | no | no |
| Depth mask on every photo | **yes** | iPhone-HEIC only | no | no |
| **Local point curve** | **yes** | **no** | yes | no |
| **Local grading wheels** | **yes** | **no** | yes (Color Balance/layer) | no |
| Local NR / Moiré / Defringe | yes (+ luma/chroma split) | yes | partial | no local NR |
| Feather + Edge refinement | day 1, every mask, + Levels | 15.3/15.5, AI masks | partial | no |
| Async lifecycle, auto batch recompute, self-healing caches | **contractual (§8.7)** | no (15.0 regression; `.lrcat-data` folklore) | no | n/a |

The read of the table: parity across the roster, three capability wins (per-component amount, the
two local color tools, universal depth), and one categorical win — the lifecycle. Nobody in this
market has shipped masking that is both LrC-broad and never-blocks-reliable. That is the flagship.
