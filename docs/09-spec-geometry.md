# 09 — Geometry, Lens & Retouch

Crop and straighten, lens corrections, chromatic aberration and defringe, guided transform, and
the retouch family: heal/clone, content-aware Remove, and one-click Dust Removal. This is the
"make the frame honest" doc — every tool here either corrects what the optics did or removes what
the scene should never have contained. Nothing here invents content; that boundary is drawn
precisely in the Remove entry below.

Scope boundaries: capture sharpening (including its corner weighting, our answer to DxO's lens
softness maps) is owned by `docs/06-spec-detail.md` — a pointer entry at the end of this doc says
what belongs to geometry and why. Masking machinery (SAM click-to-select, subject models, guided
feathering) is `docs/08-spec-masking.md`; the Remove tool's object mode borrows it. Pipeline
stage order, warp caching, and the single-resample rule's implementation live in
`docs/14-pipeline.md`. The slider contract (click-anywhere rows, scrubby numbers, Alt-drag
diagnostics, double-click reset) is `docs/12-spec-ux.md`. Model licenses and the patent ledger
are `docs/17-appendix.md`.

Four commitments govern this doc:

1. **One warp, one resample.** Every Lumen-side geometric operation — manual distortion
   correction, rotation, perspective homography, crop scale — is composed into a single warp
   field and sampled once with Lanczos-3. No stacked resamples, no cumulative softening. (The
   Apple RAW stage's own lens correction happens at decode, upstream of this warp; see Lens
   Corrections.)
2. **Everything sticks to pixels, not to the frame.** Masks, heal pins, Remove regions, and dust
   spots are stored in *source coordinates* — the image as decoded, before any geometry. Change
   the crop, the angle, or the keystone at any time and every mask and pin reprojects
   automatically. ART (1.26.7) documents the opposite as a workflow rule — finish your geometry
   before you draw masks, because they will not follow later changes. Documenting a trap is not
   fixing it. Lumen fixes it; see "Geometry ordering and mask reprojection" below.
3. **Removal yes, generation no (D33).** Lumen's retouch tools reconstruct plausible background
   from the image's own evidence — locally, instantly, with no cloud, no credits, no prompt box.
   Object-removal inpainting is the one sanctioned exception to the scene-integrity AI doctrine
   (`docs/00-vision.md`), and it stays an exception: fills come from a local model that
   reconstructs, never a generative service that invents.
4. **Honest about lens corrections.** DxO lab-measures every body+lens combination; we read
   embedded correction metadata. Those are different classes of information and this doc says so
   plainly instead of marketing around it. The flip side: DxO refuses to open raws from
   unsupported cameras. Lumen never refuses a file.

The surface, as the user meets it — a toolstrip above the viewer plus one panel:

```
Toolstrip:  [Crop R] [Transform ⇧T] [Retouch Q]
             │            │              │
             │            │              ├─ Heal · Clone · Remove (one tool, 3 modes)
             │            │              ├─ Dust Removal   [Apply] → per-spot review
             │            │              └─ Visualize Spots ──○── threshold
             │            └─ Auto · Level · Vertical · Guided (4 guides + loupe)
             │               Manual: Vertical/Horizontal/Rotate/Aspect/Scale/Offset
             └─ Aspect ▾ · Angle · Auto · O overlays · X flip · shield opacity

┌─ LENS ───────────────────────────────────────┐
│ ◉ Lens corrections (built-in profile)        │  auto from embedded metadata
│   Distortion  0 ──────○────── 200   (100)    │  profile-relative override
│   Vignetting  0 ──────○────── 200   (100)    │
│ ◉ Remove chromatic aberration                │  default on for raw
│ Defringe ──────────────────────── [⌄]        │  dual-thumb hue ranges + eyedropper
│ Manual ────────────────────────── [⌄]        │  distortion + vignette fallback
└──────────────────────────────────────────────┘
```

---

### Crop

**What it is.** Non-destructive framing: an aspect-constrained rectangle plus a rotation angle,
stored in the recipe, never touching pixels until render. The grammar is Lightroom's, cloned
deliberately — R is muscle memory for every LR refugee, and crop is the single most-used tool in
the app after the tone sliders.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Aspect preset | Original · 1:1 · 5:4 · 4:3 · 3:2 · 7:5 · 16:9 · 16:10 · Custom… | **Original** | Custom ratios remembered in a 3-slot recency list inside the menu |
| Ratio lock | locked / free | locked | Padlock toggle; free-form drag when unlocked |
| Angle | −45.0° … +45.0° | 0.0° | Scrubby number; arrow keys step 0.1°, Shift-arrow 1.0°, Alt-arrow 0.02° |
| Auto | button | — | Auto-straighten; see Straighten / Level |
| Flip orientation | portrait ↔ landscape | as framed | **X** key, exactly LR's binding |
| Overlay | Thirds · Grid · Diagonal · Triangle · Golden Ratio · Golden Spiral | Thirds | **O** cycles; **Shift+O** cycles the 8 orientations of Spiral/Triangle; cycle list user-editable |
| Overlay visibility | Auto / Always / Never | Auto | Auto = visible while dragging |
| Shield opacity | 0–100% | 80% | Dimming outside the crop box; remembered globally, not per photo |

**How it works.** The crop is a normalized rectangle + angle in the recipe; at render time it is
composed with any transform homography and manual distortion into the single geometry warp
(`docs/14-pipeline.md`), which runs *last* in the raster pipeline. Because geometry is last,
every upstream cache — denoise artifacts, mask rasters, the full developed image — is
crop-independent: dragging the crop re-runs only the final warp of an already-rendered fp16
buffer, which is a GPU texture sample, not a pipeline recompute. Defaulting to **Original**
ratio (D31) rather than "unconstrained" means the first drag preserves the camera's aspect —
the choice photographers want 90% of the time — and one click on the padlock frees it.

**How it feels.** **R** enters crop from anywhere, including the Library grid. Lumen crops the
way LR does and Capture One does not: **the image moves under a fixed frame** (D31). Drag the
image to reposition, drag corners to resize, drag outside the frame to rotate (the angle readout
ghosts next to the cursor), scroll to scale. The full develop pipeline stays live inside the
crop UI — tone, color, masks all render while framing. Overlays fade in on drag and out on
release (Auto mode). Return commits, Esc reverts, double-press R resets the crop entirely. Every
interaction is under the one-frame rule (≤16.7 ms, D43) because only the final warp recomputes —
LrC needed its 15.0 release to make crop dragging "smoother," an admission it hitched for years,
notably with soft proofing on.

**Vs. the field.** **LrC 15.5:** equal on grammar by design — aspect list, custom memory, lock,
O/Shift+O overlay cycling including golden spiral orientations, X flip, ruler drag, and the
shield-opacity control LrC only added in 15.5 are all here. Better on two counts: default aspect
is Original with custom-ratio recency memory, and crop dragging cannot hitch because it is
architecturally a texture warp, not a re-render. **Capture One 16.8.4:** better — C1's crop is
serviceable but its overlay set is thinner and its frame-moves-over-image interaction makes
recomposition a two-step fiddle; the LR interaction model is the one users describe as "right."

---

### Straighten / Level

**What it is.** Getting the horizon flat or a vertical true, three ways: a ruler you drag along
a reference line, an Auto button, and the Angle number itself.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Ruler tool | drag a line | — | Cmd-drag anywhere inside crop mode, no tool switch — LR's binding |
| Auto | button | — | Horizon/vertical detection; sets the Angle slider visibly |
| Angle | −45.0° … +45.0° | 0.0° | Shared with the Crop entry above |

**How it works.** The ruler computes the angle between the dragged line and the nearest axis:
a line within ±45° of horizontal levels to horizontal, otherwise to vertical — draw along a
horizon or along a doorframe, same gesture. Auto runs on a ~2 MP proxy: the OS-provided Vision
horizon-detection request seeds the estimate, cross-checked by a gradient-orientation histogram
(dominant edge direction near horizontal); if the two disagree by >1.5° or confidence is low,
Auto declines with a status message rather than guessing — honest error surfaces (D30), never a
silent wrong rotation. The result is written into the visible Angle value, so the user can nudge
it — auto sets sliders, never hides behind them (D11 doctrine applied locally).

**How it feels.** Cmd-drag is available the moment crop mode opens; the drawn line renders with
a degree readout, and release animates the rotation in ≤100 ms. Auto returns in ≤150 ms on the
proxy. A leveled image with the Angle slider at a visible non-zero value teaches the user what
happened.

**Vs. the field.** **LrC 15.5:** equal — ruler drag and Auto both cloned, same gestures.
Better in one detail: LrC's Auto silently does nothing when it fails to find a horizon; Lumen
says so. **Capture One:** equal; C1's straighten is fine and unremarkable. This is a solved
problem and we solve it the standard way.

---

### Lens Corrections

**What it is.** Optical corrections — distortion, vignetting, lateral CA — applied from the
correction metadata modern lenses embed in their raw files, with profile-relative overrides and
a fully manual fallback for glass that carries no metadata.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Lens corrections | on / off | on (raw, when metadata present) | Header shows what was found: "Built-in profile: RF 24–70mm F2.8" |
| Distortion | 0–200 | 100 | Percent of the profile's prescription; >100 overcorrects — LR's proven override semantics |
| Vignetting | 0–200 | 100 | Same semantics |
| Manual › Distortion | −100 … +100 | 0 | Barrel ↔ pincushion, with alignment grid overlay while dragging |
| Manual › Vignette Amount | −100 … +100 | 0 | Corrective (pre-crop) — the creative post-crop vignette is `docs/06-spec-detail.md` |
| Manual › Vignette Midpoint | 0–100 | 50 | |

**How it works.** The default path is the Apple RAW stage (`docs/14-pipeline.md`):
`CIRAWFilter.isLensCorrectionEnabled`, with per-file capability queries, applies the correction
opcodes and manufacturer profiles embedded in the raw at decode. That covers essentially every
modern mirrorless lens — Canon RF, Nikon Z, Sony E, Fujifilm X, Micro Four Thirds, and
fixed-lens compacts all embed mandatory correction metadata (LrC shows these as "Built-in Lens
Profile applied" and won't even let you disable them). What it does *not* cover: adapted vintage
glass, manual lenses with no electronics, and older DSLR-era lenses without embedded opcodes —
for those, the Manual disclosure is the fallback. The 0–200 override sliders re-warp relative to
the decoded correction (a differential warp folded into the single geometry resample); manual
distortion joins the same warp; manual vignette correction is a radiometric radial gain applied
in scene-referred linear, before tone — where a light-falloff correction mathematically belongs.

**How it feels.** For raw files with metadata the panel is a checkbox that is already on, with
the detected lens named in the header — zero decisions on the happy path. The override sliders
and Manual section sit behind disclosures because they are exceptional-case tools.

**Vs. the field.** **LrC 15.5:** roughly equal for mirrorless — both read the same embedded
metadata, and Lumen adds LR's 0–200 override semantics on top of the built-in profile, which LR
itself refuses for built-ins. Consciously worse for old DSLR glass: Adobe ships a database of
thousands of hand-made LCP profiles and Lumen ships none in v1 — a lensfun-backed manual profile
picker is on the roadmap (`docs/16-roadmap.md`), not in the launch build. **DxO PhotoLab
(PL8-era; PL9 unverified this cycle):** consciously worse, stated without flinching — DxO
lab-measures distortion fields, vignetting falloff, CA, *and per-aperture sharpness maps across
the frame* for each body+lens pair. No metadata-based system does spatially-varying softness
correction; our honest approximation is the corner-weighted capture sharpener
(`docs/06-spec-detail.md`, cross-referenced at the end of this doc). What we refuse to copy is
the cost of DxO's religion: PhotoLab will not open raws from unsupported cameras at all. Lumen
opens everything Apple RAW or LibRaw can decode, and degrades gracefully.

---

### Remove CA + Defringe

**What it is.** Two tools for two different failures. Remove CA fixes *lateral* chromatic
aberration (wavelength-dependent magnification — colored edges that grow toward corners) by
geometric per-channel alignment. Defringe fixes *axial* CA and sensor blooming (purple/green
fringes on high-contrast edges anywhere in the frame) by targeted desaturation — geometry can't
fix axial CA, which is why both tools exist.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Remove chromatic aberration | on / off | on (raw) | One checkbox, LR semantics |
| Purple Amount | 0–20 | 0 | LR's exact scale, kept for portability of shared advice |
| Purple Hue | dual-thumb range | 30 / 70 | Two thumbs bound the targeted hue band |
| Green Amount | 0–20 | 0 | |
| Green Hue | dual-thumb range | 40 / 60 | Deliberately narrower — protects foliage, LR's tuning, kept |
| Fringe eyedropper | click a fringe | — | Scalable loupe; auto-sets Amount + hue range thumbs |

**How it works.** Remove CA estimates per-channel radial scale by aligning R and B to G:
gradient misregistration is measured in radial bands on a proxy, a low-order radial polynomial
is fit per channel, and the correction folds into the geometry warp — cheap, safe, and on by
default. Defringe operates post-demosaic in OKLCh: pixels whose hue falls inside a thumb-bounded
band *and* whose local gradient magnitude marks them as edge pixels get chroma pulled toward
zero, feathered on both hue and edge-distance so legitimate purple subjects away from edges
survive. Both hue bands run simultaneously. Defringe is also available as a per-mask local
control (`docs/08-spec-masking.md`) for the stubborn axial cases — matching the local Defringe
LR users reach for when the global checkbox isn't enough.

**How it feels.** The eyedropper is the tool: click the fringe under a magnified, scalable
loupe and Lumen sets the Amount and drags the hue thumbs for you — LR's most-beloved optics
micro-interaction, cloned to the pixel (D32). **Alt-dragging any Defringe slider shows the B&W
visualization**: the image in grayscale with only the pixels being desaturated in color —
instant feedback on whether the band is eating your subject's purple jacket. Both amounts
default to 0; defringing is a decision, not a default.

**Vs. the field.** **LrC 15.5:** equal by faithful clone — same 0–20 amounts, same 30/70 and
40/60 hue defaults, same eyedropper-with-loupe, same Alt-visualization. Every LR tutorial on
defringing works verbatim in Lumen; that is the point. **Capture One 16.8.4:** better — C1
offers CA Analyze plus a single Purple Fringing slider, with no hue-range control, no green
band, no eyedropper, and no visualization. **DxO:** equal-ish on lateral CA (their module data
is better-calibrated; our estimation approach is self-calibrating on any lens), better on the
interactive defringe surface.

---

### Guided Transform (Upright)

**What it is.** Perspective correction: automatic, semi-automatic (draw the lines that should be
straight), and manual. Converging verticals on architecture, tilted horizons on ultra-wides,
keystone from shooting up — corrected by a single homography.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Mode | Off · Auto · Level · Vertical · Guided | Off | Buttons, one active at a time; LR's grammar minus "Full" (see below) |
| Guides | up to 4 | — | Draw along lines that should be vertical/horizontal; magnified loupe follows the cursor; live correction once ≥2 guides exist; guides re-editable and deletable |
| Strength | 0–100% | 100% | Fractional application of the solved correction — C1's naturalism back-off, adopted |
| Vertical | −100 … +100 | 0 | Forward/back keystone |
| Horizontal | −100 … +100 | 0 | Side keystone |
| Rotate | −10.0 … +10.0 | 0 | Fine rotation; coarse rotation belongs to Crop |
| Aspect | −100 … +100 | 0 | Stretch to compensate perspective squash |
| Scale | 50–150 | 100 | Zoom to hide warped edges |
| X / Y Offset | −100 … +100 | 0 / 0 | Recenter after warping |
| Constrain crop | on / off | on | Auto-crops the warp wedges away |

**How it works.** Each guide is a constraint: this image line must map to a vertical (or
horizontal) line in the output. Two or more guides overdetermine a homography solved closed-form
by least squares — the solve is sub-millisecond, so correction updates live as a guide endpoint
is dragged. Auto mode runs line-segment detection plus vanishing-point estimation on a ~2 MP
proxy (≤300 ms, background) and applies a balanced level + perspective correction; Level and
Vertical are constrained subsets of the same solve. LR's "Full" mode is deliberately absent: LR
users' own consensus is that Full often distorts and Guided is the tool that actually works —
we ship the two modes people use and the one that is safe. The **Strength** slider interpolates
the solved homography toward identity: 100% renders verticals dead-parallel, which on tall
buildings reads as falling-backward; 85–95% reads true. Capture One ships this back-off (its
keystone Amount); LR makes you fake it by hand-tuning sliders. The homography composes into the
single geometry warp — never a second resample — and a grid overlay appears while any manual
slider drags.

**How it feels.** **Shift+T** opens Transform. Guided mode is the star: the loupe magnifies
under the cursor for pixel-accurate guide placement along a mullion or a horizon, the image
warps live at the second guide, and guides stay draggable afterward. Manual sliders follow the
full slider contract and hit the one-frame rule, since dragging them only re-runs the final
warp. Auto analysis is recomputed on demand (an Update affordance appears if lens corrections or
crop changed after the solve — LR buries this; we surface it).

**Vs. the field.** **LrC 15.5:** equal on the core — LR's Guided Upright is considered
excellent and basically solved, and Lumen clones its 4-guide + loupe interaction outright — and
better on two counts: the Strength back-off exists, and masks/retouch pins survive transform
changes without smearing (see the reprojection section below). **Capture One 16.8.4:** better —
C1's Keystone has guided placement and the Amount back-off (which we took), but no Auto mode and
a clunkier guide-editing flow. **DxO ViewPoint (≈$99 add-on):** consciously worse on one axis —
ViewPoint's Volume Deformation Correction, which fixes the stretched-heads anamorphic distortion
of people at wide-angle frame edges, is unique in the industry and Lumen does not ship an
equivalent in v1. It is the one geometry feature on the someday list (`docs/16-roadmap.md`);
everything else ViewPoint does, this panel covers without a second purchase.

---

### Geometry ordering and mask reprojection

Not a feature — an invariant, stated once because three tools in this doc depend on it.

All spatial edit state — mask components (`docs/08-spec-masking.md`), heal/clone pins, Remove
regions, dust spots — is stored in **source coordinates**: the decoded image before Lumen-side
geometry. The UI necessarily operates on the *displayed* image, after geometry, so every input
gesture is inverse-projected through the current warp at capture time (a brush stroke is
inverse-warped into source space before storage), and every stored shape is forward-projected
for display and hit-testing. Since the geometry warp is a single invertible composition
(homography ∘ rotation ∘ radial distortion), both projections are exact and cost microseconds.

The payoff: change the crop, the angle, the keystone, or the lens-profile override at any point
— before masking, after masking, mid-retouch — and every mask, pin, and spot stays glued to the
image content it was drawn on. Raster mask caches keyed to source space don't even invalidate;
only the final warp re-samples them (D30, D49). ART documents the opposite behavior as a
workflow rule ("do geometry first"); LR handles it correctly and quietly; Lumen matches LR and
says so in the spec so the implementation never regresses it: **golden test — draw a mask,
rotate 10°, crop 50%, apply keystone; the mask must track to sub-pixel accuracy**
(`docs/14-pipeline.md` owns the test harness).

---

### Heal / Clone

**What it is.** Classical retouch: Clone copies pixels from a source patch exactly; Heal copies
texture but blends it into the destination's light and color. Both live as editable pins in the
recipe — nothing is baked.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Mode | Heal · Clone · Remove | Heal | One toolstrip tool (Q), three modes; mode switchable per pin after the fact |
| Size | 1–200 px (display) | 40 | Scroll or `[` `]` while hovering |
| Feather | 0–100 | 50 | |
| Opacity | 0–100 | 100 | |
| Source | draggable pin | auto | `/` re-rolls the auto-chosen source — LR's binding |
| Source transform | flip H/V · rotate · scale 50–200% | none | Per-pin; DxO ReTouch's transformable source, adopted |
| Pin list | per-photo | — | Every stroke is a pin: select, re-mode, re-source, delete |

**How it works.** Strokes are stored as vector paths in source coordinates
(resolution-independent, reprojection-safe). Source selection and texture continuation use a
PatchMatch-family randomized nearest-neighbor-field search — the algorithm behind every
Photoshop-grade heal since 2009: fast, texture-faithful, no ML required. Heal mode then applies
**gradient-domain (Poisson) blending**, matching the boundary conditions of the destination so
the patch inherits local illumination and color — this is the difference between Heal and Clone,
and it is why healed skin doesn't show a pasted-patch edge. Auto source selection searches an
expanding ring around the target, scoring candidates by texture similarity and penalizing
sources that cross strong edges. Computation runs only on the stroke's bounding region at full
resolution; results are cached as versioned raster artifacts keyed by stroke hash + upstream
pipeline state (D52), so unrelated slider moves never re-run retouch.

**Patent caution (r11, flagged honestly):** Adobe holds patents around PatchMatch; their status
and expiry are **(unverified)** — original filings date to ~2009–2010, so expiry is near or past
by implementation time, and non-infringing NNF-synthesis variants exist. The implementation
session must clear this with counsel before shipping; the ledger entry lives in
`docs/17-appendix.md`. The gradient-domain blending step (Pérez et al. 2003) carries no such
concern.

**How it feels.** **Q** activates retouch. Paint over the blemish; the ghost result appears
within 100 ms for typical spot-sized strokes (discrete-action budget, D43); larger strokes
compute async with the stroke outline held visible — the UI never blocks. Pins are always
re-enterable: click one to drag its source, flip/rotate/scale the source patch (fixing the
classic "cloned texture runs the wrong way along an arm" problem LR simply cannot fix), switch
Heal↔Clone↔Remove, or delete.

**Vs. the field.** **LrC 15.5:** better — LR's Heal/Clone is fast and reliable and Lumen clones
its pin grammar (`/` re-roll included), then adds the per-pin source transform LR lacks.
**DxO PhotoLab 8 ReTouch:** equal on the transformable source (we took it from them), better on
integration — DxO has no AI object removal at all through PL8, so ReTouch is their ceiling;
here it is the floor under Remove. **Capture One 16.8.4:** better — C1's heal/clone-on-layers is
capable but burns two of its 16 layer slots per retouch type and has no source transform.

---

### Content-Aware Remove

**What it is.** Object removal for the cases patch synthesis can't handle: the tourist against a
complex background, the power line crossing foliage, the trash can in the corner. A local
inpainting model reconstructs the background — on device, in seconds, with no credits and no
prompt box.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Remove brush | Size 1–200 · Feather 0–100 | 40 / 50 | Same brush as Heal/Clone; Remove is the third mode |
| Object mode | rough scribble / box → snapped selection | off | Segmentation snap via the masking stack (`docs/08-spec-masking.md`) |
| Include shadow | on / off | on | Extends the region over the object's detected contact shadow |
| Refresh | per pin | — | Re-runs the fill with jittered context — a different plausible result |
| Convert to Heal | per pin | — | Escape hatch when ML overreaches on a simple case |

**How it works.** The fill model is local and license-clean: **MI-GAN (MIT, mobile-sized,
~5–7M-parameter class)** is the primary candidate, with a **retrained LaMa** (code Apache-2.0;
the distributed Big-LaMa weights have research-dataset provenance, so Lumen retrains rather than
ships them — flagged in `docs/17-appendix.md`) as the quality alternative; the bake-off protocol
mirrors the denoise bake-off in `docs/07-spec-denoise.md`. MAT is research-only and excluded.
Inference runs on a 1–2 MP context window around the hole (Core ML, fp16), then the fill is
guided-filter-upsampled to full resolution and **re-grained**: local noise statistics (σ via MAD
of a high-pass band in the surrounding annulus) are estimated and matching grain is synthesized
onto the fill so it doesn't sit as a smooth patch inside a textured photograph (D33). Results
land as editable pins with cached raster artifacts, exactly like Heal.

**The boundary, stated precisely (D33/D5):** Remove reconstructs background that plausibly
exists behind an object, from the image's own statistics. Lumen will not add objects, extend
canvases, replace skies, or take a text prompt. Removal is scene-integrity-compatible — the
scene existed; the tourist was occluding it. Generation is a different product and Lumen refuses
to become it.

**How it feels.** Brush or box the object, release, and the fill appears — target ≤2 s for a
typical removal at 1–2 MP context on Apple Silicon, backgrounded with the region outlined while
computing. Refresh re-rolls locally in the same ≤2 s; there is no network, so there is no
"servers busy," no offline failure state, and no meter anxiety.

**Vs. the field.** **LrC 15.5:** two comparisons, honestly separated. Against LR's *local*
Content-Aware Remove: better — same speed class, plus re-grained fills and the segmentation
snap. Against **Generative Remove (Firefly, cloud)**: better on everything that made Lumen's
thesis — it requires internet, fails when Adobe's servers are busy, sits inside a generative
credit system (base Photography plan post-June-2025: 25 credits/month; Remove doesn't decrement
yet but Adobe's own FAQ reserves the right), and its failure mode is meme-famous: objects
replaced with random animals and people, because a generative model *invents*. A
reconstruction-class local model cannot hallucinate a llama into your wedding photo.
**Consciously worse** on the far end, and the spec says so: for very large, semantically complex
occlusions — a fence across the entire frame, half a building — Firefly's server-scale diffusion
will produce fills a 7M-parameter local model cannot. That is the documented gap, accepted as
the price of local-only, and it covers a small minority of one photographer's real removals.
**DxO PhotoLab 8:** better — no generative or ML fill exists there at all. **Capture One
16.8.4:** better — same story.

---

### Dust Removal (one-click)

**What it is.** Sensor-dust cleanup as a single action: detect every dust spot, heal each one,
and present the results for per-spot review. LrC 15.0 shipped this and it was instantly loved;
it is exactly the kind of tedium AI should erase, and it is fully local.

**Controls.**

| Control | Range | Default | Notes |
|---|---|---|---|
| Apply | button | — | Scans, heals, and lists every detected spot |
| Sensitivity | 0–100 | 50 | Detection threshold; re-scans live |
| Spot list | per-photo | — | Each spot is a pin: click to delete or refresh individually |
| Visualize Spots | on / off + threshold 0–100 | off / 50 | High-contrast inverted-edge view that makes dust jump out — LR's diagnostic, cloned |
| Apply to selected | button | — | Batch: runs detection + healing per frame across the selection, background queue |

**How it works.** Detection is classical, not neural — dust is a well-posed blob problem: a
Laplacian-of-Gaussian response on luminance at dust scales (roughly 5–50 px at full resolution)
finds small, soft-edged, low-contrast dark blobs; candidates are filtered by circularity,
contrast polarity, and absence of underlying image structure (dust dims, it doesn't texture).
Each accepted spot becomes a standard Heal pin filled by the PatchMatch engine — spots are
small, so ML inpainting is unnecessary and the whole pass costs ≤2 s per 45 MP frame in the
background. Because every result is an ordinary pin, review is just the pin list: delete a false
positive, refresh a bad fill, and the sensitivity slider re-scans without touching confirmed
spots.

**Batch is the point.** Dust lives on the sensor, so it haunts every frame of a shoot — but its
visibility varies with aperture, so Lumen re-detects per frame rather than stamping one frame's
spots everywhere. "Apply to selected" queues the whole shoot in the background with progressive
per-frame results (D30's queue discipline), turning the classic landscape-shoot chore — same
spot, three hundred skies — into one click and a coffee.

**How it feels.** Visualize Spots first if you want to see what you're hunting; Apply; watch the
spot count appear ("14 spots removed"); skim the pins at 1:1 with `.`/`,` stepping through
spots; done. Per-spot review means trust: nothing is hidden inside an opaque "AI fixed it."

**Vs. the field.** **LrC 15.5:** equal per-image — Lumen clones the Apply + per-spot
delete/refresh + Visualize Spots design that Ask Tim Grey's Aug-2026 assessment called a genuine
time-saver — and better in batch, because LR runs Dust Removal one photo at a time while Lumen
queues a selection. **Capture One 16.8.4:** better for field shooters — C1's automatic dust
mapping is tied to the LCC calibration-frame workflow (shoot a plate through an opal filter),
which is excellent in a studio and useless on a hillside. **DxO PhotoLab 8:** better — DxO has
dead-pixel suppression but no dust-spot detection/removal pass.

---

### Corner-weighted capture sharpening (cross-reference)

**What it is.** Not a tool in this panel — a pointer. The optics-correcting sharpening pass that
compensates lens softness, including its extra strength toward the corners, is specified and
owned by `docs/06-spec-detail.md` (Capture Sharpening: auto-radius Richardson–Lucy
deconvolution, σ estimated from Bayer greens, corner boost). It is listed here because it is
conceptually a *lens correction* — the fourth thing DxO's optics modules fix — and an
implementer reading this doc for "what do we do about lens softness" must be sent there, not
left thinking the Lens panel is the whole answer.

**Vs. the field.** **DxO PhotoLab (PL8-era):** consciously worse, by declared design — DxO's
Lens Sharpness applies deconvolution weighted by *lab-measured, per-aperture MTF field maps*;
Lumen's corner boost is a radial approximation calibrated from the image itself, not from a
bench. We close the "corners are mush" complaint without claiming laboratory parity — the exact
honesty D24 requires. **LrC 15.5:** better — LR has no capture-stage deconvolution and no
spatial weighting at all; its Detail slider blends toward deconvolution with a hand-set radius,
uniformly across the frame.

---

## The scoreboard

| Feature | vs LrC 15.5 | vs best-in-class |
|---|---|---|
| Crop | equal grammar, better defaults + never hitches | better (C1) |
| Straighten / Level | equal, honest failures | equal (C1) |
| Lens corrections | equal mirrorless, worse legacy-DSLR profile DB | consciously worse (DxO lab modules); we never refuse a file |
| Remove CA + Defringe | equal by exact clone | better (C1 has no defringe UI of this depth) |
| Guided Transform | equal core, better Strength back-off + mask reprojection | better (C1 keystone); consciously worse (DxO ViewPoint volume correction) |
| Heal / Clone | better (source transform) | equal-plus (DxO ReTouch) |
| Content-Aware Remove | better than local LR; beats cloud Firefly on trust/latency/cost; worse on giant occlusions — documented | better (C1/DxO: nothing comparable) |
| Dust Removal | equal per-image, better in batch | better (C1 needs LCC plates) |
| Lens-softness sharpening | better (LR has none) | consciously worse (DxO MTF maps) — see docs/06 |

Two "consciously worse" entries, both against DxO's laboratory — the one competitor asset that
cannot be engineered around, only approximated honestly. Everything else in this doc is a clone
of the field's best interaction (LR's crop/defringe/upright grammar), an adoption of the field's
best idea (C1's Strength back-off, DxO's transformable source), or a local-only answer to a
cloud feature that photographers distrust. That is the pattern this plan repeats on purpose.
