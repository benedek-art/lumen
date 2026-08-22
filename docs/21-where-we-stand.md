# 21 — Where we stand, and what it will take

This is the written answer to three questions: what the goal actually is now, how far the
app is from it, and what has to happen next. It is built on a seven-domain audit that
traced every control from its UI element to the stage that reads it, scored against the
competition, and refused to credit any test that still passes when the feature's call
site is deleted. The full findings live in `docs/audit/`; this document is the map.

## 1. The goal changed, and the gap grew

Doc 19 narrowed the target. It dropped Lightroom feature parity and dropped beating DxO
at denoise, and refocused on "the creative darkroom plus the basics done great." That
narrowing is **withdrawn**. The goal is now what the README always claimed:

> Every control in the app measures as good as or better than the competition's
> equivalent, and the darkroom layer is where Lumen is clearly ahead.

This is a deliberate decision by the owner and it makes the app further from done than
doc 19's scoreboard suggested — not because anything regressed, but because the
yardstick moved back out. Ingest, virtual copies, HDR merge, tethering, panorama and the
print module return to the ledger as debt rather than disappearing as non-goals. Denoise
is measured against DeepPRIME again, not against "a competent classical wavelet
denoiser," which is what it honestly is.

Two facts bound what this pass can prove, and both are stated once here rather than
repeated at every finding. **This machine cannot run Lightroom, Capture One or DxO**, so
no number in this repository is a measurement against them; `docs/20-proof-standard.md`
defines the three tiers a comparison may rest on and requires every record to name
which. And **no one has run Lumen on a Mac with real camera files**, so everything below
is traced, not observed.

## 2. What the audit found

**257 findings across nine domains.** By severity:

| | Count | Meaning |
|---|---|---|
| **BROKEN** | 29 | Reaches pixels and produces wrong output |
| **FAKE** | 24 | A control storing what nothing reads, or a caption that misstates what happens |
| **UNPROVEN** | 57 | Plausibly correct; no test would catch it breaking |
| **PARITY-GAP** | 65 | Works, measurably shallower than the competitor's equivalent |
| **MISSING** | 65 | The competition has it, Lumen does not |
| Verified-good | 17 | Traced, tested, and genuinely at or above the bar |

By domain: Tone 46 · Masking 36 · Colour 35 · Library 30 · Detail 28 · Film 25 · UX 22 ·
Output 18 · Geometry 17.

## 3. The seven patterns

Individual bugs matter less than the shapes they keep taking. Every one of these is a
class, not an incident, and fixing the class is worth more than fixing its members.

**1 — The best version of a feature lives where no user pixel goes.** `ReferenceRenderer`
exists for goldens and renders nothing anyone sees, yet it holds the local-Laplacian
Clarity (DETAIL-03), the per-pixel dehaze sky guard (DETAIL-05), and the full à-trous
Texture band (DETAIL-01). The GPU gets an approximation, the specs describe the
reference, and the marketing claim — "halo-free Clarity, the single most visible engine
win over Lightroom" — is true of code that never runs for a photographer. Measured:
Clarity rims 0.127 EV at +100 against the local Laplacian's 0.0049, a 26× artifact gap,
in the exact failure class the product markets against.

**2 — A test that cannot fail.** Fifty-seven findings are UNPROVEN, nearly all with the
same proof: delete the call site and the suite stays green. The purest specimen is
FILM-04, a "test" named `testWhatCIGaussianBlurRadiusMeans` that measures a blur radius
and only `print`s it — zero assertions — while the defect it would have caught (FILM-03,
halation blurring at 3× its model's radius) sits eleven hundred lines away in the same
file that already records the measurement proving it wrong.

**3 — The caption that lies.** Twenty-four FAKE findings. A tooltip promising chromatic-
aberration machinery that does not exist, two rows above a footnote confessing it
(GEO-11). A "Flip with X" tip where X is the reject flag (GEO-03). A mask panel stating
Whites and Blacks do nothing alone, describing an engine two rewrites old (MASK-05). A
slider component whose header documents keyboard nudging the file contains no code for
(UX-04). This project's own rule is that absence is honest and a lying control is worse
than none; the rule is being applied to new work and not retroactively.

**4 — Two ledgers that disagree.** State kept in two places drifts, and the drift is
always silent. The Vision matte cache evicts past twelve files while the app's
availability ledger never trims, so the thirteenth photo back renders an empty subject
mask while the panel says ready (MASK-07). The "attempted" ledger is per-file where it
must be per-kind, so adding a second AI mask kind never computes it and the panel then
explains that Vision found no person — about a request never made (MASK-06). The B&W
band stash is view state with no photo identity, so toggling off on one photo and on
again on another writes the first photo's mix into the second (COLOR-20).

**5 — Units.** BUILDING.md has a section titled "The units bug this codebase keeps
making." It is still making it. Halation passes a sigma where a sigma is wanted and
multiplies by three anyway (FILM-03). The loupe requests thumbnails at bucket 2048 while
the prefetch ring warms bucket 256, so every advance pays a cold decode — defeating
measurable goal #1 by a mismatch between requester and prefetcher (UX-02). Sub-second
capture times parse "7" as 7 and "070" as 70, inverting burst order (LIB-26). Sharpening
radius is denominated in raw pixels at whatever resolution the graph happens to run, so
the export is less sharpened than any frame the user can see — and, because previews cap
at 4096 px, **there is no surface in the app where export sharpening can be judged
truthfully** (DETAIL-11).

**6 — The app layer has no test target.** `Package.swift` declares tests for LumenCore
and LumenPipeline only. Every UI-to-recipe binding, the keymap, culling, the prefetch
ring, the quit flush, `startingRecipe`, and Auto Tone's measurement function are
unfalsifiable by construction. Several findings are only findings because the logic sits
in LumenApp; moving pure functions down into LumenCore is the cheap half of the fix, and
the pattern is already established in the codebase.

**7 — The drag hides the stage you are dragging.** Denoise, presence and sharpen are all
gated off draft renders, and masks are dropped from drafts entirely. So while dragging
Texture, Clarity, Dehaze, any of seven denoise sliders, any sharpening slider, halation,
grain, or *a mask's own local sliders*, the picture shows the recipe with that stage
absent, and it pops in on release (MASK-04, DETAIL-20, FILM-20). This is the same defect
the owner reported in his own words — "while I'm dragging a different colour comes up on
the screen and then when I let go it applies something different" — fixed for colour in
doc 19 Phase 1 and still open for every spatial stage.

## 4. Where Lumen is genuinely ahead

Not everything is debt, and the audit was told to say so. Traced, tested, and at or
above the bar: **printer lights** in exact twelfths of a stop, which no competing stills
editor ships at all. **Visible draggable zone pivots**, the fix to Lightroom's oldest
grading complaint. The **local point curve and local grading wheels**, neither of which
Lightroom has, both real on the shipping path with the curve covered by a golden that
fails if its call site is deleted. **Soft proofing**, the strongest item in the output
domain — real end-to-end on both render paths, tested on both platforms, honestly
captioned about its own limits. **The film engine's core**: per-channel characteristic
curves in log-exposure/density space with mid-grey solved by bisection, subtractive
density colour, and three decorrelated per-channel grain plates at per-channel crystal
sizes — Lightroom's grain is monochrome screen-space luma noise. **The catalog store
layer** — identity, culling persistence, SQL filter and sort, sub-second tiebreak, XMP
merge discipline — is the strongest-tested code in the project. And the **hot-pixel
filter** is the one control in the whole detail domain that passes all four conditions
cleanly.

The pattern in that list is worth naming: **the parts with no competitor to copy are the
parts that came out best.** The weakest areas are the ones where a known-good design
existed and the work was to match it.

## 5. The two pillars that never reach the screen

Two of the README's six measurable goals are defeated by wiring, not by difficulty, and
both should be embarrassing to leave standing.

**Raw truth.** `RawStatistics` is a complete, tested, EV-binned per-channel sensor
histogram with clipping percentages. Its only callers are two serialization round-trip
tests. There is no raw histogram, no clipped-percentage readout, no shadow-boost or
highlight-inspect hold, and no raw-clipping overlay anywhere a user can see. The
develop-side histogram bins the *rendered* proxy — precisely the lying histogram the
FastRawViewer pillar exists to replace (LIB-03, TONE-38, TONE-39).

**Culling speed.** The preview cache has a schema, a full store API, and zero app
callers, so every launch re-decodes every embedded JPEG. Then the prefetch ring warms
the wrong bucket (UX-02). Goal #1 is "next photo in under 50 ms from a pre-decoded
cache"; nothing is pre-decoded across launches and the ring does not warm what the loupe
asks for (LIB-02).

Neither needs invention. Both are around a hundred lines plus a test seam.

## 6. Order of work

Sequenced by consequence, not by domain.

**Batch A — Things that produce a wrong file or lose work.** LIB-01 (a rename or move
orphans every rating and edit — the project's first principle is that the work
survives), LIB-08 (a newer sidecar loses to a stale catalog and is then overwritten),
MASK-23 (an export racing the blob load silently delivers empty brush masks), OUT-15
(export silently drops any stage whose kernel is missing and reports success), MASK-02
(masked colour exports at preview table precision), FILM-08 (export downsizing
attenuates grain the preview never showed), COLOR-20 (the B&W stash writes one photo's
mix into another).

**Batch B — Controls that are wrong or lie, where the fix is small.** The 24 FAKE
findings are mostly captions and mostly minutes each; the honest form is already
established in this codebase (hide the control, keep a note). The BROKEN set with cheap
fixes: TONE-01 (thread the real as-shot Kelvin), TONE-34 (Auto's highlight branch is
unreachable because its statistics are clipped at +2.47 EV), COLOR-25 (Protect Skin
breaks Saturation −100 = B&W at its shipped default), COLOR-04 (mixer Luminance dies
above scene white), DETAIL-13/14/16 (denoise Colour at 100 is worse than at 25, and the
ISO defaults resolve into that region), GEO-17 (the CPU fallback applies no geometry at
all), UX-02, UX-03, UX-09, UX-13, MASK-06, MASK-07, MASK-22, LIB-10, LIB-26.

**Batch C — The proof pass.** Every control gets its six proofs per doc 20. This is
where the 57 UNPROVEN findings are closed, and it is also the only way the fixes in A
and B stay fixed. Two structural pieces come first because everything else leans on
them: a **LumenApp test target** (or the migration of pure logic down into LumenCore),
and the **per-control registry** the harness sweeps.

**Batch D — The shipping path becomes the specced path.** Clarity's local Laplacian on
the GPU, Texture's third band-port attempt (the revert commit already states what it
needs: teach the coherence gate to tell a ramp from an edge *before* decoupling the two
radii), dehaze's per-pixel sky guard, capture sharpening's uncalled Richardson–Lucy.
This is the batch that changes what every photograph looks like.

**Batch E — The parity roster.** The 65 MISSING and 65 PARITY-GAP findings, ordered by
how often the owner would touch them. Saved looks and LUT import lead it: doc 19's own
verdict was that the darkroom "needs saveable looks and LUT import to be usable, not
more engine," and both are still unbuilt with the `look` table holding neither a reader
nor a writer.

**Deferred with reasons.** The HDR gain map and the EDR viewport need a Mac with an HDR
display; a malformed ISO 21496-1 map renders *worse* than none, so the deferral is
correct and stays. Perspective/Upright is four to six weeks and a new warp stage, not a
wiring job. Tier-2 AI denoise needs a model, which this pass has ruled out — though the
executor, tile pump and splice can all be built and tested now against a stub, so the
weights drop into a proven harness rather than an empty one.

## 7. What this pass cannot settle

Every finding in `docs/audit/` that depends on a running Mac is marked. The honest
summary: the GPU path, the Vision mattes' buffer orientation, every latency budget, all
layout, and whether `CIContext.write*Representation` serializes added metadata are
traced but unobserved. Most are closable **headlessly in the existing macOS CI lane**
with synthetic images and read-back — only the gain map and the EDR viewport genuinely
need a human sitting at an HDR-capable Mac.

And no measurement here substitutes for the exit tests doc 16 already specifies: the
owner's own photographs, judged by the owner's eye.
