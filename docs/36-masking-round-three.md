# 36 — Masking, round three: the plan picked apart

**Commissioned 2026-08-31**, immediately after `docs/35`:

> "Take a look at the Lumen mask rebuild you just did. Pick apart any problems with it, any things
> that are missing that the competitors have. I would like this to be a premium masking area with
> anything and everything I would need to edit any of my photos."

`docs/35` is the audit, the design and the coverage matrix. This is the adversarial pass over it:
nine things wrong with the plan itself, twenty-five capabilities its matrix had no row for, and the
ten bets that would make this the best masking in the market rather than merely a complete one.

Two of `docs/35`'s own competitive claims turn out to be wrong. Those are §1.9.

---

## 1. NINE PROBLEMS WITH `docs/35`

### 1.1 The three zones have a fourth thing in them — and it is the thing the owner complained about

`docs/35 §4.1` organises the panel as **What / Edge / Effect**. The prototype built from it has a
fourth surface headed **Brush**, and that is not an oversight in the prototype; it is the model
failing. Brush Size, Feather, Flow, Density, Eraser and Automask are not properties of the mask, of
the component, or of anything in the *What* zone. They are **tool state for the next stroke**.

So the design as written reproduces the exact defect `docs/35 §2.4` diagnoses: four controls
formatted identically to the mask's own controls, sitting inside a section about the mask, that
cannot change the mask.

**The fix is better than the diagnosis.** `BrushStroke` already stores `size`, `feather`, `flow`,
`density`, `erase` and `automask` **per stroke**, as mutable, persisted fields
(`Sources/LumenCore/Model/BrushStroke.swift`). The data model has always been able to re-edit a
painted stroke. Only the UI cannot.

So:

- **A stroke becomes selectable.** Click a stroke on the canvas (or the newest one by default) and it highlights. The brush sliders then edit *that stroke* — and the picture changes, which is precisely what the owner tried and did not get.
- **With nothing selected they set the next stroke**, and the panel says which of the two it is in one word, not a paragraph: the section header reads **Brush · next stroke** or **Brush · stroke 7**.
- **The tool options live on a canvas-attached bar**, not as a column section, so their chrome is visibly different from a mask property. Photoshop's options bar, at Lumen's scale.

That is strictly ahead of Lightroom, which also bakes brush settings into the stroke and also offers
no way back. And it costs no wire-format change at all.

### 1.2 The engine plan missed the brush, which is the tool that most needs it

`docs/35 §5.1` moves the parametric kinds onto the GPU and says brush strokes "stay rasters — they
*are* rasters — and keep the cache". That sentence is true and it skips the actual defect.

`MaskRaster.brushPlane` is:

```swift
for stroke in set.strokes {
    paint(stroke: stroke, into: &p, width: w, height: h, longEdge: long, source: source)
}
```

**Every rasterization replays every stroke, from the beginning, always.** `paint` walks a stroke's
centreline, generates stamps at 10% of the radius, and writes a falloff disc per stamp. So a mask
with sixty strokes pays sixty strokes' worth of stamping on every settle, every export, and every
draft cache miss — and the sixty-first stroke makes all sixty-one more expensive. The cost of
painting grows with how much you have already painted, which is the worst possible shape for the
one tool a person uses continuously.

`docs/08 §8.2` specifies the opposite, in as many words: *"brush strokes render into the cached
component buffer incrementally rather than re-folding the whole stack per stamp."* It is not
implemented and `docs/35` did not notice.

**The fix.** Hold the brush component's plane keyed by `(strokesRef, stroke count, raster size)`.
When the set has only *grown* — the common case, since a stroke is appended on mouse-up — paint the
new strokes into the held plane. Any other change (undo, delete, a retro-edit from §1.1) fails the
key and rebuilds. Erase strokes fold multiplicatively in draw order, so append-only stays correct
by construction.

**The test that makes it real:** paint one stroke, measure; paint sixty, measure the sixty-first.
The second number must be within ~2× of the first. Today it is ~60×.

### 1.3 "Snap to edges" over-promises

`docs/35 §4.7` renames the guided-filter refine to **Snap to edges**. Wrong verb. A guided filter
*bends* the alpha toward image structure with a radius and a regularisation; it does not snap to
anything, and at low values it does nothing a person can see. A control named "Snap" that visibly
does nothing at 10 reads as broken — which is the failure mode this whole rebuild exists to remove.

**Use "Follow edges."** The glyph draws the alpha ramp *leaning onto* the structure, not clicking
to it. And the default for AI masks stays 10, where it earns its place invisibly.

### 1.4 Hover-to-preview will strobe

`docs/35 §4.4` makes the overlay appear on mask-row hover. With ten masks and a pointer crossing the
list on its way somewhere else, that is ten overlay builds and ten flashes of red over the
photograph — worse than not having it.

It needs a spec, not just an intent: **120 ms hover intent before anything happens, a 90 ms
crossfade in and out, and cancellation on exit.** Same numbers for the pins. Without those three
this feature ships as a flicker.

### 1.5 Nothing in the plan survives fifteen masks

Every screenshot, mock and paragraph in `docs/35` assumes three masks. A portrait retouch is
fifteen; a composited landscape is more. At `docs/35 §4.3`'s 44×30 thumbnail, fifteen mask rows are
~600 pt of list — so *Edge* and *Effect* are below the fold on every machine, and the three-zone
structure that was the whole idea stops being visible.

Three things are needed and none was named:

- **The mask list gets its own bounded scroll** (about six rows) so the zones below it never move.
- **A density toggle** — comfortable with thumbnails, compact without.
- **Groups.** Nobody in this field has them, and a twenty-mask retouch needs them: "Skin", "Eyes", "Background" as collapsible folders with their own enable toggle. This is a wire-format change and it is worth it.

Plus the small ones that only bite at scale: **search the mask list**, **auto-name a mask from what
it selected** ("Sky", "Person 1" instead of "Brush 1"), and **a pin that is off-screen when zoomed
still has to be reachable** — an edge-docked marker, not a lost mask.

### 1.6 The first mask a person ever makes was never designed

`docs/35 §2.3` correctly identifies that creation shows nothing, and §4.4 turns the overlay on. That
is a fix to a defect, not a first-run experience. The moment that decides whether a person believes
this tool is easy is the *first* mask they ever make, and the plan has nothing to say about it.

What it should say: the empty state is the picker board at full size (§4.2 already gets this
right), and the first mask of a session lands with its overlay on **and one line of live
instruction on the canvas** — "drag on the photograph to paint" — that disappears on the first
gesture and never returns for that tool. One sentence, once, at the only moment it can help. That
is the opposite of the nineteen paragraphs `docs/30` deleted, and it is the distinction the
silence rule was always making.

### 1.7 "Behind parity tests" is a phrase, not a harness

`docs/35 §5.1` says the new kernels ship "behind parity tests" six times and never says what one is.
For a change that moves six mask kinds from a f64 CPU reference onto the GPU, the harness is the
deliverable:

**One table-driven test. Every mask kind × three resolutions (256, 1024, and a non-power-of-two
like 1731) × GPU against `MaskRaster`, worst-pixel tolerance stated per kind.** Adding a kind
without adding a row must not compile. That single test is what makes the whole of §5.1 safe, and
it is a day's work that protects a fortnight's.

### 1.8 The wire-format changes have no migration story — and need none, which has to be said

`docs/35` counts six new fields and never says what a new field costs. The answer is: almost
nothing, and that is a property of this format worth stating so nobody plans around a migration
that isn't needed.

`MaskComponent.init(from:)`, `Mask.init(from:)`, `MaskRefine`, `LocalAdjust` and `Heal` all decode
every key with `decodeIfPresent` and a default. An old recipe missing a new key opens; a new recipe
read by an old build ignores it. So **every added field must be an additive optional with a
behaviour-preserving default, and every one ships with a decode test that opens a recipe written
before it existed.** `testAMaskWithoutTheInvertKeyStillDecodes` is the pattern; it just needs one
sibling per field.

### 1.9 Two competitive claims in `docs/35` are wrong

**Depth masks.** `docs/35 §6.A` and `docs/08 §8.3` both say Lumen's depth mask would be "better than
LrC because ours works on every raw", with RapidRAW named as the only other editor shipping
monocular-depth masks. ON1 Photo RAW lists depth masks among its masking tools alongside luminosity
masks, line masks and colour range. So depth-on-every-photo is a **parity** item against ON1, not a
category win. It is still worth shipping and still beats Lightroom's HEIC-only restriction — but the
sentence has to change.

**The competitive read itself.** `docs/35 §3` reads Lightroom, Capture One, DxO and darktable, and
omits the two most relevant applications for this particular question. **ON1** has the broadest
raw-editor masking roster in the market. **Photoshop** is where the masking vocabulary was invented
and where the two capabilities in §3 below still live exclusively. A masking plan that does not
read those two is not finished, and `docs/35`'s was not.

---

## 2. THE ROWS THE MATRIX DID NOT HAVE

`docs/35 §6` counted 91 capabilities. Twenty-five were missing from it. Same key: **SHIPS** ·
**PART** · **GONE** · **UNPROVEN**, and **⊕** for a new wire field.

### A · What a mask can select (+9)

| Capability | Status | Note |
|---|---|---|
| A component that references **another mask** (∪ ∖ ∩ across masks) | GONE ⊕ | Algebra today is *inside* one mask, so "Sky ∩ Person" means rebuilding both stacks. Photoshop loads a selection from any layer mask; C1's Combine Masks merges sources into one layer rather than referencing |
| Brightness Range on a **channel** — R / G / B / saturation / max / min, not only luma | GONE ⊕ | The whole Photoshop luminosity-mask tradition is channel-based. ON1 ships luminosity masks; we ship one luma band |
| A **luminosity series** — Lights 1–5, Darks 1–5, Midtones, self-feathering | GONE | Kuyper's series, which Lumenzia exists to generate. No raw editor has it natively |
| Lasso / polygon fill | GONE ⊕ | Faster than brushing anything with a hard boundary |
| Straight-line stroke (shift-click to connect) | GONE | In every paint application ever shipped |
| Brush stabilization | GONE | Catmull-Rom smoothing exists and is not user-controllable |
| Tablet **pressure and tilt** | PART | `BrushPoint.pressure` exists and is read; `MaskCanvas` writes `pressure: 1`, always. The retouch market is a tablet market |
| Import a mask from an alpha PNG | GONE | Lets a luminosity-mask user bring their own |
| Mask presets — a saved shape or a saved whole mask | GONE | A house vignette, a skin-softening mask, reusable |

### B · How the edge is shaped (+2)

| Capability | Status | Note |
|---|---|---|
| Refinement **per component**, not only per mask | GONE ⊕ | Today one chain runs after the fold, so you cannot soften an AI edge without softening the brush that trims it |
| Numeric geometry readout and angle snapping | GONE | Position, size and angle as numbers, 15° snap — repeatability across a series |

### C · What a mask can do to the picture (+4)

| Capability | Status | Note |
|---|---|---|
| **Blend mode per mask** — Normal / Luminosity / Colour / Multiply / Screen / Soft Light | GONE ⊕ | Photoshop, Affinity and ON1 have it; **Capture One does not**, and it is an open request there. A mask in Luminosity mode changes tone and leaves colour alone — the skin-retouch move |
| Per-mask **absolute white balance** in Kelvin | GONE ⊕ | Capture One ships a full WB tool per layer, with its own eyedropper. Ours is a relative shift. Mixed lighting — tungsten indoors, daylight through the window — is the case |
| Local **optical blur** (bokeh, highlight bloom), not a Gaussian | GONE ⊕ | Negative Sharpness is a Gaussian blur. LrC's Lens Blur has shaped bokeh; locally, this is the background-separation tool |
| **Healing**, as an operation a mask can gate | GONE | `Develop.heal` is a wire field (`strokesRef`, `count`) with **no reader on either render path**. Spot removal is table stakes in every competitor, and it is also the canonical upstream pixel change that must invalidate an AI matte |

### D · Seeing what you are doing (+5)

| Capability | Status | Note |
|---|---|---|
| Mask **groups** / folders | GONE ⊕ | §1.5. Nobody in this field has them |
| Search or filter the mask list | GONE | |
| Auto-name a mask from what it selected | GONE | "Sky", not "Brush 1" |
| Bounded mask list + density toggle | GONE | §1.5 — without it the three zones stop existing at fifteen masks |
| A pin that is off-screen when zoomed is still reachable | GONE | Edge-docked marker rather than a lost mask |

### E · Speed (+1)

| Capability | Status | Note |
|---|---|---|
| **Incremental brush accumulation** | GONE | §1.2. Painting currently costs more the more you have painted |

### G · Moving masks between photographs (+1)

| Capability | Status | Note |
|---|---|---|
| Export a mask as an alpha PNG | GONE | The Photoshop round-trip, and the only way a mask made here leaves the building |

### H · Proof (+3)

| Capability | Status | Note |
|---|---|---|
| A parity harness — every kind × three resolutions × GPU against CPU | GONE | §1.7 |
| A decode test per new wire field | GONE | §1.8 |
| A stroke-count scaling test | GONE | §1.2 — the sixty-first stroke within 2× of the first |

### The revised count

**116 capabilities. 41 ship, 6 are partial, 64 are gone, 5 are unproven.** Fourteen of the missing
need a new wire field; six need a model; six are engine readers for fields that already exist
(five local Detail, plus Heal).

`docs/35`'s reading of the shape still holds and gets sharper: the engine maths is in good order,
and everything missing is roster, plumbing, or panel. **The single largest correction is that one
of the missing items is a performance defect in the tool people use most** (§1.2), which the first
plan filed under "stays a raster".

---

## 3. THE PREMIUM BET

Completeness is the floor. These ten are what would make it the best in the market rather than
equal to it. Each names who else has it.

| # | The bet | Who else has it |
|---|---|---|
| 1 | **Blend mode per mask.** Luminosity, Colour, Soft Light on a *local adjustment* | Photoshop · Affinity · ON1. **No raw editor with Lumen's depth** — C1 users have been asking for years |
| 2 | **Channel luminosity masks with a series generator.** Lights/Darks/Midtones 1–5, self-feathering, one click | Photoshop, via a third-party panel people pay for. **Nobody natively** |
| 3 | **A component that references another mask.** Real algebra across the whole photograph, not inside one stack | Photoshop (load selection). **No raw editor** |
| 4 | **Retro-editable brush strokes.** Change a painted stroke's feather and watch it change | **Nobody.** Lightroom bakes; so do we, today |
| 5 | **The behaviour glyph.** Every shape-parameter draws itself, live, in its own label row | **Nobody, anywhere** |
| 6 | **Local point curve + local grading wheels** | Capture One. **Not Lightroom Classic**, in 2026 |
| 7 | **Per-component Amount** | **Nobody** — an open Adobe request |
| 8 | **Masks that survive the catalog.** Strokes in the sidecar; delete the catalog and the blob store and the mask still renders | **Nobody** — Lightroom's failure here has a folk remedy |
| 9 | **Depth on every raw** | ON1 · RapidRAW. Beats Lightroom's HEIC-only restriction — parity, not a win (§1.9) |
| 10 | **The speed contract.** Parametric kinds in shaders, incremental brush, one rasterization not two, bounded local adjust | **Nobody.** Brush lag and mask freezes are Lightroom's single most-reported masking complaint |

Six of those ten are already decided by work in this plan. Four — blend modes, channel luminosity
masks, cross-mask reference, retro-editable strokes — are new here, and between them they are about
a week of engine work and no models at all.

---

## 4. THE REVISED ORDER OF WORK

`docs/35 §8`, corrected. Two moves: **durability comes up** (a small fix guarding the worst
failure), and **the brush gets its own phase** (§1.1 and §1.2 are the same tool and should land
together).

### Phase 0 — sixty seconds
The HUD experiment. `rasters Nh Nb Ns` while dragging a radial, overlay off then on. Decides the
order of Phase C.

### Phase A — the afternoon, plus the thing that loses work
1. The picker board replaces the dropdown; group names fixed to *Draw it by hand · Find it by tone or colour · Find it for me*.
2. The rename table — with **Follow edges**, not Snap (§1.3).
3. Overlay on create and on row hover, **with the 120/90 ms intent-and-fade spec** (§1.4).
4. Two rings on the brush cursor.
5. **Brush strokes in the sidecar**, with the delete-the-catalog-and-the-blob-store round-trip test. Small, and it is the only item in the plan whose absence destroys work.

### Phase B — the brush becomes a tool
6. Stroke selection on canvas; the brush sliders retro-edit the selected stroke (§1.1).
7. Tool options move to a canvas-attached bar with their own chrome.
8. **Incremental brush accumulation** (§1.2), with the stroke-count scaling test.
9. Tablet pressure and tilt — the field and the reader exist; write it.
10. Shift-click straight lines; stabilization; lasso fill.

### Phase C — the panel as three zones
11. What / Edge / Effect; Strength into Effect; the row `⌄` menu.
12. Live alpha thumbnails on rows and chips.
13. `LumenBehaviourGlyph` and its eight shapes — prototyped in isolation first.
14. **The fifteen-mask answer**: bounded list, density toggle, search, auto-naming (§1.5).

### Phase D — the engine
15. `linear` + `radial` as kernels, **behind the parity harness of §1.7**. Re-run the HUD.
16. The overlay reads the render's alpha.
17. The range kinds as kernels; the GPU→CPU readback disappears.
18. Bound the local adjust to the mask's box, after measuring.

### Phase E — the premium four
19. **Blend mode per mask.** One enum, one kernel branch at the composite.
20. **Channel selection on Brightness Range**, then the luminosity series generator on top of it.
21. **A component that references another mask.**
22. **Per-mask absolute white balance**, alongside the relative shift.

### Phase F — the canvas and the roster
23. Pins, every mask drawn, off-screen pin docking, numeric geometry, angle snap.
24. The brush and tool keyboard grammar, entire.
25. Colour Pick's spatial half · the Brightness Range instrument · the five local Detail readers · the small wire fields · Depth · Sky · Object · Subject instances · People parts. Each AI kind lands with its lifecycle, not after it.

### Phase G — mask groups, and masks that leave the photograph
26. Groups.
27. Paste masks only / without masks; sync across a selection with progress.
28. Develop Presets carrying masks, AI recomputed per target photograph.
29. Alpha PNG export and import.

### Adjacent, and it blocks two things here
30. **Healing.** `Develop.heal` is a wire field with no reader. It is not a masking feature, but a photographer who can mask and cannot remove a sensor spot will not call this finished — and it is the canonical upstream pixel change that must invalidate an AI matte (`docs/35 §7.2`). Its own plan, scheduled against this one.

---

## 5. WHAT "FINISHED" MEANS

`docs/35 §9`'s acceptance table stands. Four rows are added, all from this round:

| Claim | The test |
|---|---|
| **Painting does not get slower** | Paint one stroke and time the rasterization. Paint sixty; time the sixty-first. Within 2×. Today it is ~60× |
| **A painted stroke is still editable** | Paint a stroke at Feather 0, select it, drag Feather to 100. The picture changes. This is the owner's original complaint, resolved rather than explained |
| **The GPU agrees with the reference** | Every mask kind × three resolutions × GPU against `MaskRaster`, worst-pixel tolerance stated per kind. Adding a kind without adding a row does not compile |
| **An old recipe still opens** | One decode test per added field, on a recipe written before that field existed |

And the standard the whole of this document is measured against, which is the owner's sentence and
not a metric: **anything he needs, for any photograph, without leaving the app.** Against that,
64 of 116 rows are still open — but none of them needs a different engine, six need a model, and
the four that would make this the best masking in the market need neither.
