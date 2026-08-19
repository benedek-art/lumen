# 03 — Research: The Field

Teardowns of every competitor cluster that matters to Lumen, researched August 2026. Each section states
findings with evidence, then closes with a boxed verdict: what Lumen takes, what Lumen avoids. The
Lightroom Classic teardown lives in docs/02-research-lightroom.md; the literature shelf in
docs/01-research-literature.md. Decisions extracted here are specified in docs 04–15; this file is the
evidence trail.

Version ground truth for this sweep: Capture One 16.8.4, darktable 5.6.0, RawTherapee 5.13, ART 1.26.7,
vkdt 1.0.0, RapidRAW 1.6.1, LrC 15.5, macOS 15 Sequoia → 26 Tahoe → 27 beta. DxO PhotoLab 9, Nik
Collection 8, and Topaz's current generation could not be re-verified this session; DxO/Nik/Topaz facts
below are cited at PL8 / Nik 7 / Photo AI 3.x level and flagged where a newer release may have moved them.

The one-line reading of this entire file, argued in docs/00-vision.md: the field is a set of
single-virtue products. Nobody combines culling speed, raw truth, workflow grammar, color depth, denoise
quality, and native Mac speed in one app. Every section below documents one virtue worth taking and at
least one failure worth refusing.

---

## 1. Capture One 16.8.4 — the color benchmark

Capture One (versionless continuous releases since the Feb 2023 licensing pivot; there was never a
"Capture One Pro 24") is the strongest develop-module competitor to Lightroom and the industry reference
for out-of-camera color, selective color, and tethering. Current: **16.8.4, released 2026-07-15**. The
2026 releases tell you where the company is headed: 16.8 (May 2026) shipped Enhanced Denoise (AI),
2nd-gen wireless tethering, Assisted Review culling beta, and "Actions" service-routing for
Studio/Enterprise tiers; 16.8.4 is mostly Multi-User Session syncing and web admin. Single-photographer
desktop features get fewer headline slots each cycle. That drift, plus the pricing history below, is why
C1 refugees exist.

### 1.1 Base Characteristics: default rendering as a product pillar

**Finding.** C1's most-cited advantage is not a tool, it is the starting point: hand-built per-camera ICC
profiles (Generic per body, **ProStandard** hue-preserving, Ecommerce variants) paired with a selectable
base curve (Film Standard default; Film Extra Shadow, Film High Contrast, Linear Response, Auto). The
profile+curve choice can be saved as the default per camera model.

**Evidence.** Fstoppers-class consensus: C1 defaults are "quantitatively correct yet pleasing," so files
"need less work than in LR with Adobe Color." ProStandard's specific promise is engine-level: hues stay
put as contrast and exposure move — reds don't go orange as they darken, skin doesn't twist when contrast
is added — and cross-camera matching improves. This is a rendering-engine property, not a preset.

**What Lumen takes.** Two things, at different layers. Hue-preservation under tone moves becomes default
engine behavior, not a profile option — free if the tone pipeline is built in a hue-linear space, which
ours is (docs/14-pipeline.md, docs/04-spec-tone.md). And opinionated per-camera starting renderings with
a saveable per-body default and a linear escape hatch — cheap relative to perceived value (docs/04-spec-tone.md).

### 1.2 Tone: Exposure semantics, the HDR panel, Levels

**Finding.** C1 splits tone across three tools with distinct semantics: Exposure (linear EV gain, ±4 EV
range unverified), Brightness (midtone lift with shoulder protection — the batch-friendly slider),
Contrast, and an asymmetric Saturation (positive = vibrance-like with skin protection, negative = true
desaturation, −100 ≈ B&W). The **High Dynamic Range panel** (since C1 20) has four bidirectional sliders:
Highlight, Shadow, White, Black.

**Evidence.** Verified comparisons (Thomas Fitzgerald, Life after Photoshop): C1's Highlight/Shadow apply
roughly double LR's effect per unit (C1 +50 ≈ LR +100) and Highlight recovers more data; White/Black are
deliberately gentle because black/white point setting is culturally delegated to the Levels tool (combined
RGB + per-channel, midtone gamma, and **output levels** for matte/print-safe looks). Reviewers call C1's
HDR "the simplest and most obvious to use" of the big three.

**What Lumen takes.** Lumen keeps LR's six-slider names and ranges for muscle-memory transfer
(docs/04-spec-tone.md owns that decision), but takes two C1 ideas: bidirectional recovery sliders that
also amplify, and output-levels semantics inside the Zones panel's advanced disclosure. The strength
lesson is documentation: whatever the per-unit response is, publish it.

### 1.3 The Luma curve

**Finding.** C1's Curve tool has tabs RGB / **Luma** / R / G / B. The Luma curve (since C1 12) applies
contrast to luminosity only: no saturation pumping, no hue shift as the curve steepens.

**Evidence.** The most-cited "C1 curve advantage" over LR, whose RGB point curve saturates as it steepens;
colorists use Luma for contrast and per-channel curves for casts.

**What Lumen takes.** A Luma curve tab, and further: Lumen's *default* point-curve behavior is
luminance-preserving with opt-in legacy chroma amplification (docs/04-spec-tone.md). Low cost, permanent
color-quality win.

### 1.4 Color Editor + Skin Tone Uniformity — the single most differentiated color feature in the field

**Finding.** Color Editor has three tabs, works globally and per layer. Basic: 8 preset hue ranges with
H/S/L and Smoothness. Advanced: eyedropper-pick any color → a slice on the color wheel with adjustable
range handles + smoothness, "view selected color range" isolation, invertible slices, and **"Create
Masked Layer from Selection"** (a color range becomes a spatial mask). Skin Tone tab: pick a target color;
besides H/S/L amounts there are **three Uniformity sliders (hue, saturation, lightness)** that compress
variance toward the picked target rather than shifting color.

**Evidence.** Official docs plus Capture One's own blog ("the uniformity sliders are where the real power
lies"). Fixes blotchy skin, uneven makeup, red ears, damage from aggressive global contrast — with zero
brushing. Famously abused for smoothing skies (Digital Camera World tutorial). Nothing in LR does this;
LR's Point Color (2023) and Variance slider are Adobe's partial catch-up.

**What Lumen takes.** Uniformity as a *general* variance-compression mode on any color selection, not a
skin-only tool, plus dedicated skin machinery as a product pillar (docs/05-spec-color.md). Also
selection-to-mask promotion: any color range convertible to a spatial mask component (docs/08-spec-masking.md).

### 1.5 Color Balance (4-way grading)

**Finding.** Master + Shadow/Midtone/Highlight wheels; each zone wheel sets hue+saturation and carries its
own Lightness slider. Predates LR's Color Grading panel (2020) which copied the model.

**Evidence.** Colorist consensus: C1's zone crossfades are smoother and wheels more precise; LR added
Blending/Balance sliders C1 lacks. Neither exposes zone pivots.

**What Lumen takes.** Per-wheel luminance (C1) + Blending/Balance (LR) + the thing both refuse: visible,
draggable zone pivots (docs/05-spec-color.md, via Resolve — section 7).

### 1.6 Clarity methods, Structure, sharpening halo suppression, Dehaze, grain, hot pixels

**Finding.** Clarity (±100) ships with a 4-method dropdown — Natural (halo-suppressed, saturation-limited,
skin-safe; negative = beloved softening), Punch (contrast + saturation), Neutral (Punch without the
saturation), Classic (large-radius, halo-prone) — plus a separate Structure (±100) micro-contrast slider.
Sharpening adds a **Halo Suppression** slider to Amount (0–1000)/Radius/Threshold, inside a three-stage
pipeline (input/diffraction → creative → per-recipe output). Dehaze (since C1 21) pairs Amount with an
auto-analyzed Shadow Tone color to avoid LR's casts. Film Grain models named grain types (Fine, Silver
Rich, Soft, Cubic, Tabular — list from stable documentation, not re-verified) with Impact/Granularity,
applied at output resolution. Noise reduction includes a **Single Pixel** slider that kills hot pixels.

**Evidence.** Halo suppression is repeatedly cited as why C1 sharpening can be pushed harder than LR's;
method-selectable Clarity has no mainstream rival; Single Pixel is a long-exposure/night-shooter favorite
absent from LR.

**What Lumen takes.** Halo-free Clarity by construction rather than by method dropdown (local Laplacian —
docs/06-spec-detail.md), halo suppression on manual sharpening, color-stable Dehaze, a hot-pixel control
in Tier-1 denoise (docs/07-spec-denoise.md), and physically-modeled grain that goes further than C1's
types (section 7; docs/05-spec-color.md). The method dropdown itself is the *avoid*: one good algorithm
beats four selectable ones (see the RawTherapee failure mode, section 6.8).

### 1.7 Layers and masking

**Finding.** Up to 16 layers per image; each carries nearly the full adjustment set, opacity, and masks:
brush with auto-mask, re-editable parametric linear/radial gradients, Magic Brush, AI Select
Subject/Background/People (16.3.0, Nov 2023), AI Eraser, heal/clone layers, and a signature **per-layer
Luma Range** refinement with falloff handles. 16.7.0 added Combine Masks to merge mask types into one
editable group.

**Evidence.** The layer model (opacity, reorder, copy between images, styles-on-layers) is architecturally
cleaner than LR's masks-with-sub-masks. But LR's AI breadth is greater: C1 has **no sky mask and no
person-part decomposition** — a real gap for exactly Lumen's owner (portraits + night skies). And the fact
that C1 needed Combine Masks in 16.7 to tame its own mask-type sprawl is a design admission.

**What Lumen takes.** Luma-range refinement on every mask with visual band handles, per-mask
amount/opacity as a first-class dial, and looks-applicable-to-a-masked-group with intensity
(docs/08-spec-masking.md). Lumen designs one composable mask model from day 1 instead of accreting
sixteen types and merging them later.

### 1.8 Speed Edit

**Finding.** Hold a mapped key + drag/scroll/arrow anywhere — no slider on screen, no UI targeting; fully
remappable; works in full-screen review; applies to all selected images at once.

**Evidence.** Universally praised across reviews: "rather genius," "second nature within a few minutes,"
"a serious timesaver… especially if you edit hundreds of files at once." The best pure-ergonomics idea in
raw editing of the 2020s, and cheap to build.

**What Lumen takes.** Wholesale, with curated default bindings (docs/12-spec-ux.md).

### 1.9 Process Recipes

**Finding.** A recipe = stored output definition (format, quality/bit depth, ICC, resize, destination
path with tokens, naming, watermark, metadata, output sharpening, open-with). **Check multiple recipes →
one Process click emits all outputs simultaneously**, on a background queue with reorder/pause.

**Evidence.** Verified Pro-only and impossible in LR's single-shot export dialog (LR needs plugins or
repeated exports). A daily 10× for event delivery: full-res TIFF to archive + 2048px sRGB to client +
watermarked web JPEG in one click.

**What Lumen takes.** The entire pattern (docs/11-spec-output.md).

### 1.10 Sessions, tethering, and the studio drift

**Finding.** Sessions (self-contained per-job folders: Capture/Selects/Output/Trash, EIP packing) coexist
with LR-style Catalogs; catalogs are the perennial #1 "C1 is worse" complaint (slow at scale, weak search,
no faces/map). Tethering is the industry standard (fast USB, Live View, Next Capture
Adjustments/Naming, Overlay, Capture Pilot; 2nd-gen wireless at near-wired speeds in 16.8). C1 also ships
volume-shooter AI: Smart Adjustments (face-based WB+exposure normalization to a reference frame) and
Match Look (reference-image look transfer).

**What Lumen takes.** Session *portability* thinking (folders are self-contained; Lumen's folder-first
library + sidecars achieves this, docs/10-spec-library.md, docs/15-catalog.md) and a
Smart-Adjustments-lite "match exposure/WB to reference frame" for event batches. Tethering, overlays,
Capture Pilot, LCC, annotations-to-PSD: studio features orthogonal to a one-photographer tool.

### 1.11 The pricing burn

**Finding.** Feb 2023: subscription-first pivot; new perpetual licenses frozen at purchase version; public
backlash forced repeated policy re-edits; versioned releases ended. May 2024: multi-user perpetual killed
with a **344% studio price hike** ($1,598 → $5,500 for 10 seats — PetaPixel, verified). Mar 2025: +6%
across the board. Community sentiment since: widespread distrust, "switched to alternatives," anger at
subscription prices while the denoise and DAM gaps lingered for years.

**What Lumen takes.** The opening. C1 alienated exactly the "own your tools" photographer Lumen is built
by and for. Also the roadmap lesson: C1 shipped AI denoise three years after Adobe and launched it slow on
Apple Silicon (verified: quality-competitive on night skies, "no Apple Silicon optimization story yet").
Treating denoise as optional cost them the narrative; Lumen ships it in Phase 1 (docs/16-roadmap.md).

### 1.12 Scorecard vs Lightroom Classic 15.5 (2025–2026 consensus)

| C1 wins | LR wins |
|---|---|
| Default color / per-camera profiles | DAM: catalog scale, search, maps, faces |
| Color Editor depth + Skin Uniformity | AI masking breadth (Sky, Objects, person parts) + speed |
| Luma curve; Levels with output levels | Denoise maturity + speed (ANE since 15.4) |
| Layers: opacity, luma range, retouch-on-layers | HDR + panorama merge (absent entirely in C1) |
| Tethering (not close); studio workflow | Ecosystem: mobile/cloud, plugins, presets, learning |
| Process Recipes multi-output export | Price (Photography plan < C1 Pro subscription) |
| UI customization + Speed Edit ergonomics | |

> **What Lumen takes:** hue-preserving engine math as default behavior (ProStandard's promise, made
> universal); per-camera default renderings with a linear escape hatch; the Luma curve and
> luminance-preserving point curves; Uniformity variance-compression generalized beyond skin;
> color-selection-to-mask promotion; luma-range refinement on every mask; per-mask opacity and
> looks-on-masked-groups; Speed Edit; Process-Recipe multi-output export; halo suppression; Single Pixel
> hot-pixel control; bidirectional recovery semantics; match-to-reference-frame batch normalization;
> subscription-free positioning aimed squarely at C1's burned users.
>
> **What Lumen avoids:** mask-type sprawl requiring a later "Combine Masks" apology; method dropdowns as
> a substitute for one correct algorithm; shipping AI denoise years late and unoptimized; the split-brain
> Sessions-vs-Catalogs library story; studio/team/cloud feature drift; paid style-pack monetization;
> trust-burning license pivots.

---

## 2. DxO PhotoLab / PureRAW / Nik — the image-quality benchmark

Verification note: solidly verified through PhotoLab 8 (Oct 2024), PureRAW 5 (Apr 2025), Nik 7
(Jun 2024). **PhotoLab 9 (expected Oct 2025) and Nik 8 (Jun 2025) exist with high confidence but their
feature lists are unverified**; nothing below assumes them.

### 2.1 DeepPRIME: the denoise lineage and its 2026 standing

**Finding.** DxO's moat is a raw-domain pipeline: DeepPRIME runs **joint demosaic + denoise as one CNN on
the raw mosaic** — the architecture Adobe later adopted for AI Denoise. Lineage: PRIME (2013, classical)
→ DeepPRIME (PL4, 2020) → XD (PL6, 2022) → XD2 (PureRAW 4, Feb 2024) → XD2s (PL8, Oct 2024, fixed XD's
bokeh artifacts) → XD3 with X-Trans beta (PureRAW 5, Apr 2025). Control surface: a Luminance slider
(0–100, default 40); chrominance is fully automatic.

**Evidence.** 2026 standing (verified via the LR digest's sources, Finding the Universe / Fstoppers): the
LR-vs-DxO gap has closed to pixel-peeping; DxO still edges extreme-ISO fine texture (feathers, foliage);
LR at worst "a touch softer"; Topaz third on raw. Speed on Apple Silicon (approximate, 45MP): DeepPRIME
~5–10 s, XD-class ~10–25 s; LR post-15.4 ANE is ~5 s on M4 Max. And the standing UX wart: **DeepPRIME is
never live** — PhotoLab previews it only in a ~1:1 magnifier patch; the full image renders at export.

**What Lumen takes.** Raw-domain joint demosaic+denoise as the v2 quality ceiling (via the RawSource
escape hatch, docs/07-spec-denoise.md, docs/14-pipeline.md); v1 RGB-domain is acceptable precisely
because the 2026 gap is pixel-peeping-small. And the visible differentiator: **full-image cached preview
with an instant Amount blend**, which neither DxO nor Topaz has ever shipped.

### 2.2 Optics modules and Lens Sharpness

**Finding.** DxO lab-measures each camera+lens combo (distortion fields, vignetting, lateral CA, and
**MTF sharpness maps across the frame per focal length and aperture**). Modules auto-download per
detected combo (~100k+ combos claimed, approximate). Lens Sharpness applies deconvolution whose strength
varies spatially with the measured softness field: Global ≈ −3.0..+3.0 around the measured optimum, plus
Details and Bokeh sub-sliders (ranges unverified).

**Evidence.** No profile-based system (Adobe LCP, manufacturer opcodes) applies measured, spatially
varying sharpening; even sharpness from mediocre zooms is the single most-cited reason wildlife forums
recommend PureRAW. The flip side is religion taken too far: **PhotoLab refuses to open raws from
unsupported cameras** — drones, phones, niche bodies — a hard wall users hate.

**What Lumen takes.** The honest approximation: auto-radius deconvolution capture sharpening with a
user-tunable corner boost (docs/06-spec-detail.md) — closing the "corners are mush in LR" complaint
without claiming lab parity. And the inverse of the lockout: Lumen never refuses a file; Apple RAW is
broad and LibRaw broader (docs/14-pipeline.md).

### 2.3 Smart Lighting and ClearView Plus

**Finding.** Smart Lighting: zone-based adaptive tone from DxO's single-shot-HDR lineage; Uniform vs
**Spot-Weighted mode, which auto-detects faces** and accepts user-drawn weighting boxes; intensity 0–100
with Slight/Medium/Strong ≈ 25/50/75. ClearView Plus: one 0–100 slider fusing dehaze + large-radius
micro-contrast; effective, heavy-handed at high values (dark halos, gritty skin).

**Evidence.** Smart Lighting is one of the best auto starting points in the industry for mixed-light
event work; reviewers advise Slight/Medium because Strong flattens.

**What Lumen takes.** Face-weighted auto tone with editable weight regions — cheap on Apple's Vision
stack and aimed at the owner's event workload (docs/04-spec-tone.md). ClearView's fusion is the
anti-pattern: Lumen keeps Dehaze and local contrast as separate, named controls sharing one engine
(docs/06-spec-detail.md).

### 2.4 ColorWheel + Uniformity — the best-liked HSL in the industry

**Finding.** 8 channels picked via swatch or eyedropper; the selected channel appears as an **arc on a
hue ring with four handles** (two core, two feathered falloff); rotate to shift hue; Saturation and
Luminance −100..+100; and the signature **Uniformity** slider that converges hues inside the selection
toward the mean. Before/after swatch pair; doubles as a B&W channel mixer.

**Evidence.** Repeatedly called the best HSL tool in any raw editor since PL3 (2019); it pre-dated and
visibly inspired LR's Point Color and 2026 Variance slider. The praised properties are specific: visual
range definition with feather handles, eyedropper-to-channel, Uniformity.

**What Lumen takes.** The entire interaction grammar for Lumen's Color Mixer, including Uniformity
(docs/05-spec-color.md). This plus C1's skin uniformity converge on the same insight from two vendors:
hue-variance compression is a first-class operation photographers lack in LR.

### 2.5 U-Point local adjustments

**Finding.** Control Points mask by **chroma+luma similarity to a sampled point within a radius**;
Control Lines gate a gradient by a detachable sampling eyedropper ("graduated filter that only hits
sky-colored pixels"); Chroma/Luma selectivity sliders (0–100, default ~50); negative points subtract;
per-mask Opacity since PL7; Luminosity masks (PL7-era) and Hue masks (PL8). PL7 replaced the on-canvas
"equalizer" mini-sliders with a docked palette + masks list — approved for scale, mourned by Nik veterans
for lost directness. Through PL8 there is **no AI masking at all** (PL9 unverified).

**What Lumen takes.** The similarity point/line as a mask component with chroma/luma selectivity — the
fast manual middle ground between brush and AI subject (docs/08-spec-masking.md) — and the PL7 UX lesson:
in-context controls near the mask and a full panel are not mutually exclusive; ship both.

### 2.6 PhotoLibrary, the missing merges, and the wide-gamut latecomer

**Finding.** A decade of stable reviewer consensus: "best image quality, worst DAM." Folder browser +
index, Projects, basic filters; no faces, no map, weak search, sluggish browsing. No pano stitch, HDR
merge, focus stacking, or tethering through PL8. And DxO shipped an Adobe-RGB-limited pipeline until
"DxO Wide Gamut" arrived in PL6 (2022) — even IQ-first vendors ran display-referred-ish pipelines for
years.

**What Lumen takes.** Confirmation that "develop engine + real library in one app" is a legitimate
thesis: DxO ceded the DAM and its users cull in Photo Mechanic. The wide-gamut history validates Lumen's
linear Rec.2020-from-day-1 stance (docs/14-pipeline.md). HDR merge gets a named "later" slot on the
roadmap, not a never — its absence is a real wound for landscape shooters in both DxO and C1
(docs/16-roadmap.md).

### 2.7 PureRAW — the existence proof

**Finding.** PureRAW is not an editor; it is a batch pre-processor: raw in → DxO demosaic + DeepPRIME +
optics corrections → Linear DNG → auto-returned into the LR catalog stacked with the original. People pay
**$119.99 on top of an Adobe subscription** for it. The whole per-batch decision surface is: model
choice, Luminance NR, force-detail, lens-softness intensity, correction toggles, output format,
destination, queue. Costs users grumble about: 2–4× file bloat per Linear DNG, batch wait, a second app.

**Evidence.** The adoption pattern matters: most PureRAW users process only their keepers after culling —
denoise-after-cull, exactly the workflow slot Lumen's cached AI-denoise step occupies.

**What Lumen takes.** Two proofs. Economic: photographers pay real money for five comprehensible controls
with trustworthy defaults. Strategic: PureRAW is what happens when a vendor's pipeline front-end beats the
incumbent's but its application can't displace the incumbent. Lumen owns the whole pipeline, so the goal
is "PureRAW quality without the DNG copies" — cache, not files (docs/07-spec-denoise.md).

### 2.8 Nik Collection: Silver Efex and the craft-look lesson

**Finding.** Nik 7 (Jun 2024) current-verified; Nik 8 (Jun 2025) exists, features unverified. Silver Efex
remains the B&W gold standard: ~39 named film emulations with per-stock grain and tone response, a **Zone
System readout** (hover zones 0–X highlight pixels per Ansel-Adams zone), Amplify Whites/Blacks, color
filter simulation, toning, control points inside the converter. Color Efex: ~55 stackable filters with
per-filter control points. The weakness is structural: plugins edit rendered TIFF intermediates —
destructive round-trips, file duplication, dated engines under refreshed UIs.

**What Lumen takes.** Users pay repeatedly for looks with craft (measured stocks, zone feedback) and
selective application that feels effortless. Both are portable ideas needing zero plugin architecture:
Lumen's B&W ships an 8-band mix + optional zone-system overlay (docs/05-spec-color.md), its Film Lab does
few stocks deeply (section 7). The TIFF round-trip model is the avoid: everything in Lumen is a pipeline
stage, nothing is an intermediate file.

> **What Lumen takes:** raw-domain denoise as the v2 ceiling and RGB-domain v1 as the verified-good-enough
> start; full-image cached AI preview with instant blend (the UX flaw both DxO and Topaz share, fixed);
> ColorWheel grammar + Uniformity; similarity points/lines with selectivity sliders; face-weighted auto
> tone with editable regions; corner-weighted capture sharpening as the honest Lens Sharpness
> approximation; measured-stock film/grain ambition (via section 7's physics, not preset packs);
> zone-system B&W overlay; the five-controls-that-convert PureRAW surface as a simplicity benchmark.
>
> **What Lumen avoids:** patch-only AI previews and export-to-see workflows; Linear DNG duplicate-file
> taxes; refusing unsupported cameras; a toy library that forces users into a second app; fused
> multi-effect sliders (ClearView); à-la-carte product sprawl (PhotoLab+FilmPack+ViewPoint+PureRAW+Nik ≈
> $650) that undercuts the anti-subscription message; TIFF round-trip plugin architecture.

---

## 3. Topaz Photo AI — the AI-utility benchmark

Version note: Photo AI 3.x (2024–2025) verified; a v4 or rebrand by late 2025 is plausible but
**unverified**.

**Finding 1 — the Autopilot lesson.** On open, Autopilot detects subject and faces, estimates noise and
blur, then auto-enables and auto-strengths denoise/sharpen/face-recovery/upscale. Reception is split the
same way in every review: genuinely fast batch triage ("open 200 files, trust it, export") versus
unpredictability and over-processing ("everything comes out looking like AI," plastic skin, crunchy
feathers). Power users switch everything to manual.
→ Lumen: auto-*compute* and auto-*suggest* with visible, reversible, per-decision evidence; never
auto-*apply*. This is the AI doctrine in docs/00-vision.md, and Topaz is its negative proof.

**Finding 2 — where Topaz actually wins.** On raw denoise it ranks third behind DxO and LR (color
shifts, texture hallucination at Strong/Extreme). Its real wins are where DxO can't play: JPEG/TIFF/scan
denoise, **motion-blur recovery** (dedicated Lens Blur and Motion Blur deconvolution models — a
consumer-level Topaz-only capability, artifact-prone at high strength), and upscaling. Speed ~10–30 s per
45MP image on M-series (approximate); preview is patches, full render at export — the same structural UX
as DxO.
→ Lumen: RGB-domain v1 denoise incidentally covers non-raw input. Motion-blur rescue is skipped: deep
specialist investment, artifact-prone output, and a photographer-owner culls blurred frames.
2×-class upscale at export is enough (docs/11-spec-output.md).

**Finding 3 — Gigapixel is now Adobe-validated.** LrC 15.2 (Feb 2026, verified) shipped Generative
Upscale "powered by Topaz Gigapixel," running **in Adobe's cloud for generative credits** — the first
third-party model embedded in LR, proof Gigapixel is the industry upscale reference, and a critique
magnet: it smooths some regions and oversharpens others versus Adobe's own Super Resolution. "Confident"
texture rather than faithful texture.
→ Lumen: confirmation that scene-integrity beats generative confidence for a working archive, and that
even Adobe now meters AI — the local-only, credit-free stance is a visible differentiator, not just an
ethic.

**Finding 4 — the pricing backlash.** Perpetual $199 (Photo AI) + optional ~$99/yr updates made Topaz the
poster child for pay-once among Adobe exiles. Then 2024–26 flagship generative models (Gigapixel v8
Recover/Redefine, Starlight video) moved to **cloud + credits**, and Topaz's own forum called it a
subscription with extra steps. The precise finding: users tolerate paid annual updates; they revolt at
metered features.
→ Lumen: personal software, zero credits, zero cloud. The plan and the moral coincide.

> **What Lumen takes:** the auto-suggest-never-auto-apply doctrine (from Autopilot's failure); local
> perpetual pricing psychology (from Topaz's success and its credit backlash); non-raw denoise coverage
> as a free side effect of RGB-domain v1; the 2× upscale ceiling.
>
> **What Lumen avoids:** silent auto-application; patch previews with export-to-see; motion-blur and
> generative-upscale specialist rabbit holes; cloud credits in any form; "AI-shiny" default renderings
> that users must fight.

---

## 4. The Mac-native field — the vacuum Lumen occupies

### 4.1 Pixelmator Pro & Photomator: the architectural cousin, acquired

**Finding.** Apple announced acquisition of the Pixelmator Team on Nov 1, 2024; completed early 2025;
through the Jan 2026 knowledge horizon both apps sat in caretaker mode — maintenance updates, no roadmap,
no sunset date (current Aug-2026 status unverified). Pixelmator Pro ($49.99 one-time) is the
architectural proof-of-concept for Lumen: all editing on Metal, Core ML models on the Neural Engine (ML
Super Resolution 3×, ML Denoise, ML Enhance trained on a claimed 20M+ photos, ML Crop, Match Colors,
subject removal), non-destructive, native AppKit/SwiftUI, fast on every Apple Silicon Mac. Photomator
(Mac App of the Year 2023) proved the library model: **edit the Photos library or any folder in place,
non-destructively, with no import step**, adjustments synced, edits writable back.

**Evidence.** Apple publicly celebrated the exact category Lumen targets, then bought the company and
stopped its evolution. The best Apple-native prosumer editor and the best Apple-native RAW app halted
simultaneously. There is no successor. The vacuum is not rhetorical.

**What Lumen takes.** The whole playbook it validated: Metal render graph + Core ML/ANE + OS APIs as solo-
developer leverage (docs/13-architecture.md); no-import browsing (docs/10-spec-library.md); and
Pixelmator's per-control disclosure pattern — auto/ML entry point on top, manual controls beneath,
double-click-to-reset — adopted as a design law (docs/00-vision.md, docs/12-spec-ux.md).

### 4.2 RAW Power & Nitro: the Apple-engine strategy and its ceilings

**Finding.** RAW Power (Gentlemen Coders; Nik Bhatt, ex-Apple Senior Director of Engineering for
Aperture/iPhoto) is the existence proof that a one-person, Apple-RAW-engine editor works: it surfaces
Apple's hidden `CIRAWFilter` controls (Boost, Black Boost, Local Tone Map, Recovery, raw NR, decoder
version pinning — the full property surface is API-verified), runs standalone on the filesystem, on the
Photos library, and as a Photos extension, and is renowned for being instant and tiny. Nitro adds local
adjustments and ML masking from OS APIs (Vision instance masks, semantic mattes). The ceilings are
equally instructive: camera support arrives only with macOS point updates; no custom demosaic, profiles,
or per-lens database; Apple's opinionated Boost rendering; engine behavior can shift under OS updates
(mitigated by pinning `decoderVersion`).

**What Lumen takes.** Exactly this strategy as the *default* RAW stage, with eyes open about the
ceilings: `CIRAWFilter` with pinned decoder version, draft mode and `scaleFactor` for preview decode, the
`linearSpaceFilter` scene-referred injection point — and the `RawSource` escape hatch (LibRaw + our own
Metal demosaic) precisely for what Apple's engine can't do (docs/14-pipeline.md).

### 4.3 Aperture: the mourned UX

**Finding.** Twelve years after its 2014 death, photographers still hack Aperture onto modern macOS via
Retroactive (verified: works through Tahoe 26; dies when Rosetta 2 is removed, planned macOS 28). What
they mourn is specific: the **Loupe** (hover magnifier for 100% focus checks without changing view), the
Light Table, **Stacks** (auto burst grouping with a pick), Versions at near-zero cost, ratings + color
labels + flags coexisting, the Keyword HUD, lift & stamp, full-screen culling with floating HUDs and dual
displays, and Aperture 3's brush-in/brush-away local adjustments with edge detection. The death lesson is
equally specific: migration to Photos flattened nine years of adjustments; never build an archive inside
an opaque database without an exit path.

**What Lumen takes.** The hold-key Loupe (unreplicated by any mainstream tool, cheap differentiation),
stacks, coexisting cull axes, lift & stamp semantics (docs/10-spec-library.md) — and the trust
architecture the death demands: originals read-only, human-readable JSON recipes, XMP sidecars,
app-death-survivable state (docs/15-catalog.md).

### 4.4 Apple Photos: the simplicity ceiling

**Finding.** Photos on Tahoe 26 has solid global adjustments (smart sliders with sub-sliders, Curves,
Levels, Selective Color, WB modes, Retouch) and on-device Clean Up (since 15.1, Oct 2024; visibly weaker
than Photoshop on large removals) — and **zero local masking, no lens-correction UI, no ratings beyond
favorites, no batch develop**. None of `CIRAWFilter`'s raw controls are exposed in its UI.

**What Lumen takes.** The gap definition. Photos is the floor of approachability; Lightroom is the
ceiling of workflow; Lumen's spec is the space between, reachable in one disclosure (docs/00-vision.md).

### 4.5 Affinity: the modality anti-pattern

**Finding.** Affinity Photo 2's Develop persona is powerful and wrong for photographers: modal
develop-then-commit to a pixel layer, historically destructive, settings not persisted as a first-class
recipe, no DAM. Canva bought Serif (Mar 2024, ~$380M reported) and on Oct 30, 2025 replaced the paid V2
suite with a free unified "Affinity" app requiring a Canva account, AI features behind Canva's
subscription. Community reaction: grateful and distrustful at once; the last big one-time-purchase champion
absorbed into a SaaS funnel.

**What Lumen takes.** Non-destructive recipes as the *only* model — no commit step anywhere in the app —
and another entry in the acquisition ledger: Pixelmator→Apple, Serif→Canva. Independent tools die;
portable data survives (docs/15-catalog.md).

### 4.6 The rest of the field, one lesson each

| Product | The lesson |
|---|---|
| **Luminar Neo** | Headline AI on a slow foundation produces churn, not loyalty. Sky AI is still best-in-class sky *masking*, but years of stable complaints (slider lag, RAM bloat, crashes after updates, dark-pattern pricing, weak DAM) define the brand. Foundation first, AI as quiet utility. |
| **ON1 Photo RAW 2026** | The kitchen-sink counterexample: browser+layers+Effects+NoNoise+Resize+Super Select+Keyword AI, one-time-friendly — and "feature-rich and slow" for six straight years of releases. Feature count outran the performance budget; every Lumen feature ships inside a latency budget or not at all (docs/12-spec-ux.md). |
| **Radiant Photo 2** | One idea done well: per-photo scene-detected, face-aware auto that gets volume shooters to 80% in one click. Validates scene-aware auto as a *starting point*; warns against opinionated defaults you can't neutralize (docs/04-spec-tone.md's auto is fully visible and reversible). |
| **Exposure X7** | No-import folder browsing + sidecar edits + a genuinely good film/grain engine = a beloved cull-and-look tool. Also: no major release since 2021 — one-time pricing without a shipping cadence fades. Sidecar-on-filesystem is the proven trust model; grain/film craft is a durable, un-commoditized differentiator. |
| **Darkroom** | Apple Design Award-grade approachability over a real toolset — and its Catalyst Mac app proves mobile-first is felt immediately by Mac users. Lumen is AppKit/SwiftUI-native, full menu bar, real keyboard ergonomics (docs/12-spec-ux.md). |

### 4.7 The mac-native playbook and the graveyard

What demonstrably works on this platform: (1) Apple frameworks as leverage — a solo developer gets ~80%
of a big-team matrix from Metal, Core ML, `CIRAWFilter`, Vision; (2) no import, ever; (3) sidecar/recipe
persistence that survives the app's death; (4) one-time pricing as identity; (5) speed as the marquee
feature — the evangelized apps (Photomator, RAW Power, Darkroom, Exposure) are the fast ones, the
complained-about apps (ON1, Luminar) are the slow ones, regardless of feature count; (6) simple surface,
deep basement; (7) AI as invisible utility, never generative spectacle.

The graveyard, one epitaph each: Aperture (platform owners kill pro apps; locked-in edits die),
Pixelmator (the healthiest indie exits overnight), Affinity (acquisition redefines economics), Exposure
(stagnation), Luminar (novelty treadmill), ON1 (bloat), Apple Photos (simplicity without depth is a
ceiling, not a product).

> **What Lumen takes:** the CIRAWFilter-default + RawSource-escape-hatch RAW strategy; Metal + Core
> ML/ANE + Vision as the leverage stack; no-import folder-first library with sidecar persistence;
> Aperture's Loupe, stacks, coexisting cull axes, and lift & stamp; Pixelmator's auto-on-top disclosure
> pattern; scene-aware reversible auto; a real grain/film engine as durable craft; speed as the headline
> feature with enforced budgets.
>
> **What Lumen avoids:** modal develop-commit design; proprietary opaque databases as source of truth;
> Catalyst/mobile-first UI; generative sky swaps, body reshaping, and cloud-dependent features; shipping
> features that break the latency budget; any dependency on a third-party app surviving.

---

## 5. Culling tools — the speed and truth benchmarks

### 5.1 Photo Mechanic: three architectural refusals

**Finding.** PM (Camera Bits, since 1998) is still the culling speed benchmark because of architecture,
not optimization. Three refusals: (1) **never decode RAW for display** — the contact sheet and preview
render the embedded JPEG, so display cost is independent of RAW complexity; (2) **no import, no catalog
write on browse** — opening a folder or card *is* the workflow, metadata goes to XMP/IPTC; (3)
**direction-aware pre-render lookahead** — the next arrow-key press swaps in an already-decoded image, so
paging feels gated only by key repeat. A just-shot 128GB card is browsable in seconds; LR's
"building previews" phase simply does not exist.

**Evidence.** Every fast culler since is a variation on these three (FRV, Narrative, LR's
embedded-preview mode). The pairing culture is proof of demand: DxO forums' standing line is "the
PhotoLibrary is a toy — I cull in Photo Mechanic." Sentiment is bimodal and decade-stable: "pried from my
cold dead hands" (sports/news/events) versus "UI from 2004." The late-2023 subscription switch (~$139/yr
PM tier, exact current pricing unverified) triggered real backlash; a visible cohort pins perpetual PM6.

**The keyboard model.** Three orthogonal axes, all single-keypress with single-key mode on, all
filterable, all batch-applicable: **Tag** (one bit, one key — the press workflow is binary and PM
optimizes the binary case to the floor), stars 0–5, color class 1–8 with editable names (shipped
defaults: Winner, Winner alt, Superior, Superior alt, Typical, Typical alt, Extras, Trash — an editorial
taxonomy, not just colors). Culling is: arrow, digit, arrow, digit. Filters collapse to survivors
instantly because they are metadata queries, not renders.

**Ingest.** The industry-reference card copy: multi-card simultaneous ingest, **primary + secondary
(backup) destination in one pass**, Incremental Ingest (re-inserted card copies only new frames), folder
naming + renaming via a 100+ token Variables system, IPTC stationery stamped during copy, Live Ingest
watch-folders, unmount-when-done. Notably absent: checksum verification (culture is "format in camera
after both copies confirmed"). Variables + Code Replacements (roster codes expanding to full captions)
are the agency moat Lumen deliberately does not need.

**What Lumen takes.** The three refusals wholesale, the keyboard model merged with LR's keys, and the
ingest dialog scoped to a solo shooter — with verified checksummed copy added, which PM itself lacks
(docs/10-spec-library.md owns all of this).

### 5.2 FastRawViewer: the raw-truth thesis

**Finding.** FRV (LibRaw LLC, ~$25) owns one claim nobody else makes: it displays actual RAW data and a
**RAW histogram**. Every in-camera and embedded-preview histogram is computed from the JPEG rendering —
post-WB, post-tone-curve, post-picture-style, 8-bit clipped — and therefore lies: typically **0.3–2 EV of
real highlight headroom** exists beyond where the JPEG histogram shows clipping, and "blown red" is
frequently just the red WB multiplier, not sensor saturation.

**Evidence.** FRV's toolkit answers the only three cull-time image-quality questions as momentary
keyboard-held overlays, not edits: per-channel **OverExposure/UnderExposure statistics** (% clipped, per
channel, with on-image overlays), **Shadow Boost** (temporary +EV lift), **Highlight Inspection**
(temporary darkening), plus focus peaking. Ratings/rejects go to XMP sidecars; rejects move to a
`_Rejected` subfolder — filesystem as database, zero lock-in. Adoption stays niche because truth-at-cull
is sold as a second app for connoisseurs.

**What Lumen takes.** FRV's entire reason to exist, folded into the cull loop: true raw histogram with
per-channel clipped-percent stats cached per image, hold-key shadow-boost and highlight-inspect overlays,
focus peaking on the loupe (docs/10-spec-library.md, histogram spec in docs/04-spec-tone.md). Lumen
decodes RAW for editing anyway; the marginal cost is a lazy stats pass. **No shipping product combines
PM-class paging with FRV-class truth.** Lumen does both in one window.

### 5.3 AI culling: Aftershoot, Narrative, and the absorbed feature

**Finding.** The market consolidated 2024–2026 and converged on the same four detectors everywhere:
**blink, focus/blur, duplicate grouping, best-of-group**. Aftershoot (wedding-market leader): local
processing after model download (RAWs never uploaded), unlimited volume, duplicate grouping with
best-frame proposal; sentiment ≈ "kills the obvious 60–80% reliably; I still review its maybes."
Narrative Select (Mac-native, fastest-feeling UI): embedded-preview paging at PM speed plus the signature
**assessments panel of per-face crops** badged with focus and eye-state, so a 12-person group shot is
judged without zooming. The incumbents absorbed the feature: LrC 15.0 shipped Assisted Culling (Oct
2025), 15.4 added the per-face Faces panel and auto duplicate stacking (and shipped Mac memory
leaks/freezes in the same release — the cost of bolting ML onto a heavy catalog loop); C1 16.8 shipped
Assisted Review beta (closed eyes, out-of-focus eyes, black frames).

**Evidence — the consensus, verbatim pattern across reviews and wedding forums:** promising, big
time-saver on obvious rejects, **"don't trust it yet"** for final selects. The loved UIs show per-face,
per-criterion evidence and let the human decide; the distrusted UX is silent auto-rejection. AI culling's
stable value is first-pass filtering and attention routing, not selection.

**What Lumen takes.** The whole consensus as a design contract: evidence-not-verdicts, per-face crop
strips with eyes/focus badges, adjustable strictness that filters what gets *flagged* never what gets
*removed*, no auto-reject ever — built from OS APIs (`VNDetectFaceCaptureQualityRequest`,
`VNDetectFaceLandmarksRequest` for EAR blink detection, `VNGenerateImageFeaturePrintRequest` for
duplicate grouping, aesthetics scoring on macOS 15+), run at background QoS off the paging path
(docs/10-spec-library.md). An Aftershoot-lite is buildable without shipping a single custom model.

### 5.4 Embedded-preview realities

**Finding.** Every mainstream RAW embeds a JPEG preview, but not equally: Canon CR2/CR3, Nikon NEF, and
Fuji RAF embed full resolution; **many Sony A7-series bodies through the ~A7 III era embed only
~1616×1080** — 100% focus checks from the preview are impossible on those bodies; Adobe-converted DNG
preview size is a converter setting. Orientation must be read from the RAW container's EXIF, not the
preview's own tags (some firmware writes them inconsistently). And the preview shows the *camera's*
rendering, so switching to the app's own render causes the infamous "Lightroom changed my photos"
tone jump.

**What Lumen takes.** A fallback ladder (page on whatever preview exists, background-render Lumen
previews for zoom, never block paging on raw decode), container-EXIF orientation normalization, and an
honest handoff: badge camera-rendered previews and swap to Lumen's render in the background before the
user edits (docs/10-spec-library.md).

> **What Lumen takes:** PM's three refusals as architecture law; the one-keystroke-one-decision
> auto-advance grammar with binary-first culling; PM's ingest scoped down plus verified checksummed copy;
> FRV's raw histogram, clipped-percent stats, shadow/highlight inspection overlays, and focus peaking
> folded into the cull loop; Narrative's face-evidence strip; the four-detector AI set from OS APIs,
> local, flags-only; the embedded-preview fast path with the Sony fallback ladder and honest
> preview-handoff badging.
>
> **What Lumen avoids:** import ceremonies and preview-building walls; agency machinery (code
> replacements, FTP, IPTC broadcast); silent AI rejection and hidden scores; running ML inside the paging
> loop (LrC 15.4's Mac freeze is the named failure); trusting preview-JPEG histograms for exposure
> decisions; subscription pivots on trusted tools.

---

## 6. Open source, deep — darktable, RawTherapee, ART, vkdt, RapidRAW, Ansel

Version reality (repo-verified Aug 2026): darktable **5.6.0** (Jun 2026; 5.8 in development, there is no
6.0), RawTherapee **5.13** (2026-07-25), ART **1.26.7** (2026-07-13), vkdt **1.0.0** (2025-12-13),
RapidRAW **1.6.1** (2026-08-07, ~9.4k stars), Ansel alpha nightlies (active daily). Open source is where
the algorithms are documented and the UX mistakes are public; this section is Lumen's richest single
source of both.

### 6.1 darktable's grading trio: the algorithms Lumen builds on

**color balance rgb** is the best-designed color grading module in FOSS, source-verified ranges: 4-way
grading (global offset / shadows lift / power / highlights gain, each luminance −1..+1, chroma 0..1, hue
0–360° with an opponent-color picker that neutralizes a cast in one click), master perceptual controls
(hue shift ±180°, vibrance, contrast around an 18.45% fulcrum, and chroma/saturation/brilliance each ×
global/shadows/mid/high at ±100%), luminance-range masks with fulcrum and falloff plus a
checkerboard-through-output preview, permanent soft gamut clipping at constant hue, all computed in
Kirk/Filmlight Ych and darktable UCS 2022 (Helmholtz–Kohlrausch-aware). Its docs open with "not suitable
for beginners" — the module is right and its packaging is wrong.
→ Lumen adopts the math and control inventory as the advanced disclosure of Color Grading, re-skinned and
self-calibrating (docs/05-spec-color.md).

**color equalizer** (4.8, refined 5.0): 8 fixed equally-spaced hue nodes × hue/sat/brightness tabs,
guided-filter smoothing, and the killer feature — two visualization toggles showing (a) what the tool
*can* touch (saturation-weighting influence map) and (b) what it *changed* (signed change map). Fixed
nodes + smoothing beats freeform curves for artifact avoidance.
→ Lumen: the 8-band mixer's engine and both visualizations (docs/05-spec-color.md).

**tone equalizer**: 9 EV-zone sliders (−8..0 EV) on a guided-filter luminance mask, with the beloved
on-canvas cursor (hover shows the zone; scroll dodges/burns it) — and the documented failure: users must
hand-calibrate the mask (two magic wands, five estimators, feathering to 10,000) before the sliders
behave. ART's 5-band version proves the machinery can be defaults.
→ Lumen: the engine with a self-calibrating mask (auto-normalized continuously) powers the six-slider
tone contract and the Zones panel; the scroll-to-dodge cursor is adopted (docs/04-spec-tone.md).

**rgb primaries** (4.6): six sliders + tint (per-primary hue and purity), gray-preserving. A channel
mixer re-parameterized to be understandable; the tool behind the "calibration look" economy.
→ Adopted nearly verbatim as Lumen's Primaries panel (docs/05-spec-color.md).

### 6.2 The tone-mapper museum: darktable's cautionary tale

**Finding.** darktable ships FOUR display transforms — base curve, filmic rgb, sigmoid, AgX — each with
docs warning "never use together." Sigmoid became the default in 5.2 (Jun 2025) with exactly two primary
sliders (contrast 0.1–10.0 default 1.5, skew ±1) plus preserve-hue 0–100% and a primaries subsection; AgX
arrived 5.4 (Dec 2025) with the most capable implementation (pivot, toe/shoulder power with
inverted-curve warnings, look section, primaries tab) and in 5.6 was re-tuned to match sigmoid's defaults
(preserve hue 60%). Filmic — five tabs, versioned color science v3–v7, its own reconstruction engine —
remains the single most complained-about learning cliff. AgX's small-screen "3-tab mode" is hidden behind
hand-editing darktablerc.

**Evidence.** Three public attempts to land a transform that is both correct and tractable; the community
equilibrium (sigmoid for defaults, AgX for difficult highlights, filmic for old edits) is itself the
indictment: users must know which third of the app not to use.

**What Lumen takes.** Exactly one AgX/sigmoid-class transform, sigmoid-simple face (2–3 controls +
presets), AgX-grade capability behind disclosure, never a second tone mapper. The decision and its
parameters live in docs/04-spec-tone.md; the museum is why.

### 6.3 diffuse-or-sharpen: ship the presets, never the math

**Finding.** One anisotropic multiscale PDE engine does deblur, dehaze, bloom, denoise, local contrast,
and inpainting — behind sliders named "4th order anisotropy," with docs admitting "users are likely to be
overwhelmed, unless they are already familiar with Fourier partial differential equations." It survives
only through its 21 named presets (lens deblur soft/medium/hard, dehaze, denoise fine/medium/coarse,
local contrast, bloom, sharpness…).

**What Lumen takes.** The proof that one shared engine can back five named tools with 1–2 sliders each —
and the rule that the math never reaches the UI (docs/06-spec-detail.md).

### 6.4 Two-module white balance: correctness debt as warnings

**Finding.** darktable's color calibration (CAT16 default, illuminant auto-classified from EXIF, gamut
compression for blue-LED failures, full channel mixer) is technically right and UX-wrong: it requires the
legacy white balance module set to "camera reference" and polices the arrangement with cross-module
warning badges.

**What Lumen takes.** CAT16 under the hood, one visible Temp/Tint surface, auto-switching
parameterization near/far from the locus, advanced illuminant behind disclosure, no legacy twin
(docs/04-spec-tone.md). One user intent = one control surface, whatever the pipeline does internally.

### 6.5 darktable 5.6's AI subsystem: the architecture to copy

**Finding.** Opt-in (off by default, zero cost when off), local-only ONNX with a published "scene
integrity" policy; **tasks decoupled from models** (mask/denoise/rawdenoise/upscale, one active model per
task, downloadable packs, user-retrainable); SAM 2.1/SegNext click-to-mask with foreground/background
points, per-image encoder caching across restarts, and output **vectorized into editable Bézier paths**
(works in styles/presets with zero AI dependency); neural restore with split before/after patch preview
and deliberate strength semantics (raw denoise = sensor-level blend; RGB denoise = wavelet-band-selective
texture restore); on macOS, ONNX Runtime is statically linked with Core ML and the runtime-management UI
simply disappears. The workflow wart: raw denoise outputs a DNG that round-trips through the library.

**Evidence.** This is the first mainstream FOSS editor to land AI cleanly, on its fourth attempt (4.8's
release notes record removing the first "because of mediocre quality").

**What Lumen takes.** The task/model registry, encoder caching, mask vectorization, split-preview
grammar, and the scene-integrity policy line (docs/08-spec-masking.md, docs/07-spec-denoise.md,
docs/00-vision.md). The DNG round-trip is skipped: Lumen splices denoise in-pipeline as a cached artifact
— vkdt proves in-graph is better, and Lumen has no legacy pipeline to appease.

### 6.6 darktable's UX debt, in its own release notes

The evidence is self-documenting: ~95 processing-module pages including deprecated-but-present twins
(color balance vs color balance rgb; four tone transforms; color zones vs color equalizer); a 5.0 warning
dialog for new users who press Tab; a 5.6 welcome screen "to help users understand the most relevant
configuration options"; a condensed-widget mode; camera-styles shipped in 5.0 so defaults stop looking
flat versus the OOC JPEG; AgX's 3-tab mode in a config file. When a module needs a hidden flag to fit on
screen, its information architecture failed. Every remedial feature is an admission Lumen gets to skip.

### 6.7 RawTherapee and ART: option proliferation and its cure

**Finding.** RT 5.13's engine remains reference-quality (AMaZE lineage demosaic, capture sharpening —
born in RT, adopted by darktable 5.4 inside demosaic with auto-radius from CFA data — wavelet machinery,
Inpaint Opposed highlight reconstruction). Its disease is also reference-quality: Selective Editing spots
accreted astronomer-grade options (Generalized Hyperbolic Stretch with symmetry points, Michaelis-Menten
tone mapper, 3-sigma displays); RT historically resolves design disagreements by adding a method dropdown
(5+ highlight methods, 7 curve modes, multiple tone mappers *inside a sub-tool*). The release notes read
like a spectroscopy manual.

**ART is the controlled experiment**: one developer cut RT's tool count roughly in half (~45 tools),
rebuilt local editing as adjustment layers with exactly 4 local tools × 4 composable mask types
(parametric HCL curves, ΔE2000 color similarity, area shapes with add/subtract/intersect, brush — one of
each per layer, deterministic combination order), replaced RT's tone systems with Tone Curves + a 5-band
Tone EQ with pivot + Log Tone Mapping, and lost approximately none of the results. ART's ΔE mask design
is the standout micro-pattern: for each of L/C/H, a *pair* of sliders — the reference value and its
**weight** in the distance computation, with the spectrum strip dimming when a dimension is zeroed.
"Value + importance" beats channel-curve stacks for legibility. ART also documents its own trap: masks
drawn before geometry changes "will mess them up."

**What Lumen takes.** ART's mask algebra and one-of-each rule (docs/08-spec-masking.md), the ΔE
weight-pair pattern for color-range refinement, the 5-band-plus-pivot simplification as proof for the
Zones panel — and auto-reprojection of masks through geometry changes, fixing the trap ART merely
documents. The RT lesson is a standing rule: the app picks the algorithm; the user overrides at most once
per domain.

### 6.8 vkdt, RapidRAW, Ansel: ceiling, velocity, autopsy

**vkdt** (darktable's original author) is the performance ceiling: a full-GPU Vulkan node graph rendering
full-res in real time, raw video, and **jddcnn** — joint demosaic+denoise U-Net compiled ONNX→SPIR-V,
trained in 1–2 hours on the author's own photos (clean provenance), backed by a 2026 paper on real-time
U-Net dispatch. Not consumer software (developer-grade UI, Linux-first), but proof that full-res
interactive is achievable and that in-pipeline neural denoise beats round-trip files.
→ Lumen: the performance existence proof for a Metal pipeline on unified memory; the jddcnn pattern for
denoise v2 (docs/14-pipeline.md, docs/07-spec-denoise.md).

**RapidRAW** is the closest existing product to Lumen's brief and a velocity benchmark: solo developer
(started at 18), Tauri+React+Rust with a WGPU f32 pipeline, <20MB binary, AgX tone mapping, layered
AI masking (SAM 2, U-2-Net, Depth Anything V2), LaMa inpainting, HDR merge, panorama, focus stacking,
tethering, film emulation, monthly releases — roughly 70% of Lightroom's surface in ~14 months.
Self-admitted weaknesses: X-Trans demosaic quality, polish/stability, VRAM issues on export. AGPL-3.0:
study, don't copy.
→ Lumen: the sizing calibration for docs/16-roadmap.md (a solo dev with maximal platform reuse moves
fast), and the depth warning — 20-year engines still win on demosaic and color-science rigor. Lumen
buys that depth via Apple's RAW stage and steals the verified algorithms elsewhere in this file.

**Ansel** (Aurélien Pierre's darktable fork, permanently alpha) is the definitive insider autopsy. His
own benchmarks vs dt 5.0 (Feb 2026): lighttable open 3.53× faster, view switch 6×, scroll 7×,
**mid-pipeline parameter change 5.4–40× faster by recomputing only downstream modules**, export reusing
the cached pipeline prefix 1.27–100×, idle lighttable power 0.85 mW vs 103 mW. Diagnosis: "darktable is
leaking performance by the GUI." Also a strategy datum: 45% of his telemetry users have no GPU — his
argument that vkdt can't be the mainstream future (irrelevant to Lumen's Apple-Silicon-only stance, but a
reminder that Lumen's hardware floor is a chosen luxury).
→ Lumen: the three engineering rules, adopted as law — cache pipeline prefixes, recompute only
downstream, no pipeline work on the GUI thread (docs/13-architecture.md, docs/14-pipeline.md). Also the
sustainability warning: a 4-year architecture freeze is how solo projects die; Lumen ships to itself
weekly (docs/16-roadmap.md).

### 6.9 The complexity failure-modes catalog

Distilled from all six apps; these are cited as named anti-patterns throughout the spec docs:

1. **Additive evolution without deletion** (dt's four tone mappers): a new tool must replace and migrate
   its predecessor, or not ship.
2. **Research parameterization leaking to the UI** (diffuse-or-sharpen, RT's GHS): every slider must be
   nameable by its visible effect.
3. **Mask calibration before benefit** (tone equalizer): internal state must self-calibrate; expose
   refinement, not prerequisites.
4. **Correctness debt surfacing as warnings** (color calibration × white balance): one user intent = one
   control surface.
5. **Screen overflow handled by hidden config** (AgX 3-tab mode): design for 13" first.
6. **Interaction inconsistency compounding** (dt's scroll sometimes adjusts, sometimes pans, sometimes
   rates — destructively, on hover): one global interaction grammar, table-tested.
7. **Options as conflict-avoidance** (RT's method dropdowns): the app picks; the user overrides once per
   domain.
8. **Preview infidelity** ("only guaranteed at 100% zoom"): scale-invariant preview is a UX feature, not
   a perf feature.
9. **Power without workflow** (module docs that explain *what*, never *when*): ship opinionated ordering
   and inline do-this-first hints.
10. **Solo-project sustainability cliffs** (Ansel's freeze, ART's "no goals beyond fun"): darktable-grade
    color science, ART-grade tool count, RapidRAW-grade cadence.

> **What Lumen takes:** color balance rgb's math and inventory; color equalizer's fixed-node engine and
> dual visualizations; tone equalizer's engine with a self-calibrating mask and the scroll-to-dodge
> cursor; rgb primaries verbatim; one AgX-class transform with a sigmoid-simple face; CAT16 single-surface
> WB; inpaint-opposed highlight recovery as the invisible default; capture sharpening at the demosaic
> stage; the preset-faced shared detail engine; dt 5.6's AI registry, encoder caching, mask
> vectorization, and scene-integrity policy; ART's mask algebra, ΔE weight-pairs, and 5-band tone proof;
> vkdt's in-pipeline neural denoise pattern; Ansel's three cache rules; the ten-rule failure catalog as
> standing law.
>
> **What Lumen avoids:** four tone mappers and every other deprecated-twin museum; a ~95-module panel;
> math-named sliders; two-module WB with warning police; hidden-config UI modes; per-module interaction
> dialects; method-dropdown proliferation; 100%-zoom-only truth; DNG round-trips for AI results;
> GPL/AGPL code reuse (reference only — license ledger in docs/17-appendix.md); multi-year rewrites
> without shipping.

---

## 7. Cinema and film — Resolve's grammar, film's physics

DaVinci Resolve context: 17 (2021) introduced the HDR palette and Color Warper; 19 (2024) added Film Look
Creator and Color Slice; Resolve 20 (2025) is current in a 20.x point release (exact version and its
color-page additions unverified). Studio is $295 one-time — a marketing datapoint in itself. The
community sentiment pattern is remarkably consistent: "Lightroom feels like a toy after log wheels and
curves," photographers demonstrably round-trip TIFFs into Resolve for the HDR palette and Sat-vs-Sat —
and Resolve is a non-starter as a photo tool (no stills RAW coverage, no DAM, no stills lens profiles).
**Best color tools, wrong vehicle.** That articulated, unserved demand is Lumen's color-depth opening.

### 7.1 Wheels, Offset, and printer lights

**Finding.** Resolve's primaries are four wheels, not three: Lift, Gamma, Gain, and **Offset** — a global
per-channel shift that is the digital descendant of lab printer lights. Verified math (from the
utility-dctls implementations of Resolve-compatible behavior): one printer point = ×10^(0.025/negGamma)
per channel, neutral at 25 on a 0–50 scale; at real negative gamma ≈0.6, **~12 points ≈ 1 stop** — small,
repeatable, keyboard-steppable, and colorists ride the hotkeys for shot matching. The gamma wheel maps
g ≤ 0 → exponent 1−4g, g > 0 → 1/(4g+1); the offset wheel's measured scale constant is
(offset−25)×((1.233137392−0.5)/100).

**What Lumen takes.** Printer lights as a first-class shot-matching tool: master exposure + R/G/B (C/M/Y)
trims in log space, keyboard-steppable at ~1/12-stop points (docs/05-spec-color.md). The fastest
batch-matching instrument ever devised, at near-zero implementation cost.

### 7.2 Log wheels and the pivot lesson

**Finding.** Log wheels (Shadow/Midtone/Highlight on bounded ranges with steep falloff) beat
Lift/Gamma/Gain for separation because LGG controls contaminate each other across the whole range — the
classic slider chase. Crucially, log wheels expose **Low Range / High Range pivots** (defaults ≈
0.33/0.66 normalized, unverified) so the user redefines what counts as shadows. LR's Color Grading panel
imitates log wheels with **no visible or adjustable pivots** — the #1 advanced-user complaint about it.

**What Lumen takes.** Visible, draggable zone pivots on the grading wheels (docs/05-spec-color.md).
Cheap, and it converts LR's most-criticized color tool into a precise one.

### 7.3 The HDR Grade palette — the best modern tonal-zone tool

**Finding.** Overlapping tonal zones (Global + Black, Dark, Shadow, Light, Highlight, Specular — naming
unverified), each with a color wheel, an **Exposure dial denominated in stops**, a Saturation dial, and
an adjustable **range pivot + falloff** pair, with a live zone-graph readout. It is color-space-aware:
zones are defined on scene-referred signal, so "Shadow" means the same thing for any camera. Per-zone
saturation solves "brightened shadows go gray" in place.

**What Lumen takes.** This is the model for Lumen's Zones panel — the advanced disclosure above the
six-slider tone contract, with pivots and falloff visible and draggable on the histogram
(docs/04-spec-tone.md). Zone thinking in stops matches how photographers already reason (Adams zones,
made adjustable).

### 7.4 The curves suite and the "expensive color" secret

**Finding.** Resolve ships Custom curves (per-channel + Y, per-end **Soft Clip with softness** — a
built-in mini film shoulder/toe), Hue-vs-Hue, Hue-vs-Sat, Hue-vs-Lum, **Lum-vs-Sat**, **Sat-vs-Sat**,
Sat-vs-Lum. Colorist consensus: Hue-vs-Hue and Hue-vs-Sat are daily drivers; Lum-vs-Sat and Sat-vs-Sat
are the "make it filmic" pair — film's apparent tonal richness is largely *saturation rolloff at the
extremes*, and digital looks "video-ish" because saturation stays linear all the way up. Both are 1D
LUTs, nearly free on GPU. Hue-vs-Lum is the artifact factory (hue is numerically meaningless noise near
neutral). Implementation requirements for artifact-free hue curves: periodic splines wrapping at 360°
(LR's windowed HSL bands are why band edges seam on gradients), evaluation in a hue-stable space,
chroma-weighted correction so near-neutrals are untouched, eyedropper-anchored points.

**What Lumen takes.** Lum-vs-Sat and Sat-vs-Sat internally as the saturation-rolloff machinery of the
Film Lab and the default saturation model (docs/05-spec-color.md); periodic-spline hue handling in the
Color Mixer (no band seams); soft-clip curve ends (docs/04-spec-tone.md). Hue-vs-Lum is deferred:
low usage, high artifact risk.

### 7.5 Color Slice, Color Warper, scopes

**Color Slice** (Resolve 19): six fixed vectors (R,G,B,C,M,Y) plus a dedicated **Skin vector**, each with
Hue / Saturation / **Density** — density darkens a hue as it saturates, deliberately subtractive,
film-print-like (slider set unverified). Welcomed as the faster alternative to hue curves; "printer-light
thinking applied to secondaries." **Color Warper** (17): a 2D hue/sat mesh you drag directly — loved for
directness, easy to overdo; the steal is the interaction (grab a color *in the image* and drag), not the
mesh. **Scopes**: RGB parade (a cast is visible as one channel's floor sitting higher — histograms cannot
show "blacks are blue"), luma waveform (spatial: shows *where* clipping is), vectorscope with the
skin-tone line (skin consistency across an event set). No mainstream stills editor ships any of them;
compute-shader binning at preview res costs <1 ms on Apple Silicon.

**What Lumen takes.** Density semantics inside the color tools, drag-on-image color editing without a
visible mesh, and the parade/waveform/vectorscope-with-skin-line trio one disclosure away in the grading
context (docs/05-spec-color.md, docs/12-spec-ux.md). The CIE scope is skipped.

### 7.6 Color management, the node lesson, Film Look Creator

Resolve's color-management doctrine — grade in one wide, stable working space; the display transform is
last and swappable; looks become portable across cameras — is Lumen's pipeline architecture stated in
cinema terms (docs/14-pipeline.md). The node graph is explicitly *not* copied: its real lessons (order
matters, correction and look are separate stages, one mask can feed several ops) are captured by a fixed
staged pipeline with per-stage masks. And the **correction-vs-grading split** — normalize first, apply
the look as a portable layer — is adopted architecturally as Lumen's Develop/Look split, the enabler of
one-look-across-800-frames (docs/00-vision.md, docs/05-spec-color.md).

**Film Look Creator** (Resolve 19) collapsed what used to be a 10-node PowerGrade into one panel with
format presets, tone/split-tone, halation, bloom, grain, vignette, and temporal extras — and became a
headline feature. The product lesson outranks the parameters: one Film Lab panel, preset-first,
sliders behind a disclosure, never film controls scattered across the app (docs/05-spec-color.md).

### 7.7 Film science: why film looks like film (verified physics)

Source-verified from the spektrafilm codebase (physically-based spectral simulation; constants below are
read from code, not folklore) and colorist-standard DCTL implementations:

- **Per-channel characteristic curves** in log-exposure→density space with asymmetric toe/shoulder:
  gentle highlight rolloff, lifted-then-crushed shadow toe, slight channel crossover in the extremes
  (warm highlights / cool shadows without split-toning). A parametric sigmoid with per-channel
  {gamma, Dmin ≈ 0.01, Dmax ≈ 4.0, offset} reproduces the shape space of real stocks. Trivial: 3×1D LUT.
- **Subtractive color**: CMY dye density, T = 10^−D — saturated colors *darken* instead of brightening.
  This, not a bigger vibrance slider, is "rich, expensive" color. Trivial per-pixel math.
- **Saturation rolloff + compression at extremes** (Lum-vs-Sat, Sat-vs-Sat): no neon highlights, no
  chroma-noise shadows. Trivial.
- **Couplers**: the orange mask and DIR inter-layer inhibition (verified same-layer gammas 0.341/0.324/
  0.273, inhibitor diffusion σ 20 µm + 200 µm tail) drive saturation *and* edge micro-contrast — film's
  built-in clarity. The spektrafilm README is explicit: datasheet curves alone are not enough; "the key
  is couplers." Free when baked into a LUT.
- **Halation** is red-dominant base back-reflection: verified default strengths RGB = (0.05, 0.015, 0.0)
  — red strongest, blue nil — first-bounce sigma 65 µm, 3 bounces, decay 0.5, applied **on linear light
  before development**. This is the CineStill 800T night-neon signature; digital "Glow" sliders look
  wrong because they are achromatic and post-curve. Cost: 2–4 separable blurs at half res.
- **Grain lives in the density domain**: per-layer particle counting where variance ∝ p(1−p) — grain
  amplitude peaks at mid densities and vanishes at Dmin/Dmax, unlike constant-σ digital overlays; blue
  layer coarsest (verified per-channel particle scale 0.8/1.0/2.0 RGB), so film grain is chromatically
  structured, not gray; size is anchored to *print* size, not pixels. Practical recipe: pre-baked
  tileable plates modulated by √(p(1−p)), applied in log/density space — ~90% of the physics at
  fragment-shader cost.
- **The print stage** is a second curve: the negative is low-gamma (~0.5–0.6); most of the "film S-curve"
  comes from projecting through enlarger Y/M dichroic filters (verified neutral defaults Y=55, M=65
  Kodak CC) onto paper with much steeper curves.
- **Push/pull** couples contrast + grain + color crossover, because extended development does — verified
  in spektrafilm's distinct portra_800_push1/push2 profiles. One slider, three coherent effects: the
  highest authenticity-per-slider ratio available. Relatedly, exposure *into* the film curve (pre-curve
  EV) is distinct from display brightness; overexposing "into Portra" produces the pastel airiness film
  shooters know — a behavior no digital editor has.
- **Cost envelope**: the full spectral chain is ~10 s per 6MP frame on CPU — offline only — but bakes
  losslessly into 3D LUTs per (stock × print × push), with halation and grain as live layers on top.

**License caution (verified):** spektrafilm is GPLv3 and its README claims derivative status even for
software "directly inspired by its methods," while inviting collaboration. Lumen's Film Lab is
clean-roomed from the primary literature it cites (Giorgianni & Madden, *Digital Color Management*; Hunt,
*The Reproduction of Colour* ch. 15); the constants above are usable as physical facts. Ledger in
docs/17-appendix.md.

### 7.8 Dehancer, Filmbox, and the LR preset ceiling

**Dehancer** contributes the mental model: an explicit analog chain UI (film profile → exposure →
push/pull → print stock as a *separate stage* → color head CMY → halation → bloom → grain → vignette),
with "profiled characteristic curves, not LUTs" as the pitch. Its weakness is panel length. **Filmbox**
is the accuracy ceiling: spectral Vision3 + 2383 print modeling with deliberately few controls, widely
called the most faithful 35mm emulation — accuracy + few controls beat flexibility + many controls for
perceived quality. Five great stocks done spectrally beat sixty curve-only ones.

**The LR film ecosystem's ceiling** is structural, not a quality gap: VSCO Film (discontinued Feb 2019),
Mastin Labs, and RNI build on per-camera DCP profiles + preset stacks — fixed display-referred renditions
that fall apart when exposure moves ±1.5 EV, with zero spatial phenomena (no halation, no density grain —
LR's Grain is three generic screen-space sliders — no print stage), per-body profile drift, and
preset-vs-profile confusion. Market signal that film looks are mainstream, not niche: Fujifilm's
in-camera simulations are a top-3 purchase driver for the X system (unverified, consistent across
sources). A physically-grounded film mode with real halation and density grain leapfrogs the entire
preset economy.

> **What Lumen takes:** printer lights (~1/12-stop keyboard points); visible draggable pivots on grading
> wheels; the HDR-palette zone model with per-zone stops/color/saturation and falloff; Lum-vs-Sat +
> Sat-vs-Sat as the filmic saturation machinery; periodic-spline hue curves; soft-clip curve ends;
> Density (subtractive) semantics and a skin vector; parade/waveform/vectorscope with the skin line; one
> wide working space with the display transform last; the Develop/Look split; the Film Look Creator
> panel pattern; the verified film-physics chain (characteristic curves, subtractive color, pre-curve
> red-dominant halation, density-domain p(1−p) grain, print stage, push/pull) baked to LUTs offline.
>
> **What Lumen avoids:** the node-graph UI; gate weave, flicker, dust/scratch overlays; the CIE scope;
> Hue-vs-Lum at launch; Dehancer-length control panels; DCP-preset film architecture; any GPLv3
> derivation in the Film Lab; Magic-Mask-style tracking (video-only).

---

## 8. Cross-field synthesis: capability × best-in-class × Lumen's stance

The one-table summary of everything above. "Stance" names the owning spec doc; the reasoning lives in the
sections and docs cited.

| Capability | Best-in-class today | Why they win | Lumen's stance |
|---|---|---|---|
| Culling/browse speed | Photo Mechanic | Three refusals: embedded JPEG only, no import, direction-aware prefetch | Adopt all three; <50 ms paging, keyed to repeat rate (docs/10-spec-library.md) |
| Raw truth at cull | FastRawViewer | Only tool with a true raw histogram + per-channel clip stats + inspect overlays | Fold FRV entirely into the cull loop; no competitor has PM speed + FRV truth in one app (docs/10-spec-library.md) |
| AI culling assists | Narrative Select / LrC 15.4 | Per-face evidence strips; "show me why, let me decide" | Same contract from OS Vision APIs; flags only, never auto-reject (docs/10-spec-library.md) |
| Ingest | Photo Mechanic | Dual-destination, incremental, template renaming, cull-while-copying | PM scoped to one shooter + verified checksummed copy PM lacks (docs/10-spec-library.md) |
| Default rendering | Capture One | Hand-tuned per-camera profiles + selectable base curve | Per-camera starting looks + linear escape hatch; hue-stable engine by construction (docs/04-spec-tone.md) |
| Tone contract | Lightroom Classic | The six-slider grammar is the industry's muscle memory | Keep it verbatim; implement on tone-eq engineering, halo-free (docs/04-spec-tone.md) |
| Tonal-zone control | Resolve HDR palette | Zones in stops with visible pivots + falloff | The Zones panel: 5 zones + Global, pivots draggable on the histogram (docs/04-spec-tone.md) |
| Display transform | darktable sigmoid/AgX | Scene-referred, hue-controllable, 2-slider face | Exactly one AgX-class transform; the four-mapper museum is the named anti-pattern (docs/04-spec-tone.md) |
| Curves | C1 (Luma) + Resolve (suite) | Saturation-stable contrast; Sat-vs-Sat/Lum-vs-Sat richness | Parametric + point + R/G/B + Luma; luminance-preserving default; rolloff curves internal (docs/04-spec-tone.md, docs/05-spec-color.md) |
| HSL / selective color | DxO ColorWheel | Visual arc + feather handles + eyedropper + Uniformity | Adopt the grammar for the 8-band mixer; add Point-Color-class swatches with Variance (docs/05-spec-color.md) |
| Color grading wheels | Resolve log wheels | Clean zone separation via adjustable pivots | 3-way + Global with per-wheel luminance, Blending/Balance, visible pivots; color balance rgb math beneath (docs/05-spec-color.md) |
| Shot matching | Resolve printer lights | ~1/12-stop keyboard-steppable log trims | Adopt wholesale; near-zero cost (docs/05-spec-color.md) |
| Skin tools | Capture One | Uniformity variance compression; nothing in LR compares | Generalized Uniformity + vectorscope skin line + skin-protected vibrance (docs/05-spec-color.md) |
| Film emulation | Filmbox (accuracy) / Dehancer (chain UI) | Spectral physics; stage-per-process mental model | One Film Lab: baked spectral LUTs, live halation + density grain, Push/Pull; 5–10 deep stocks (docs/05-spec-color.md) |
| Grain | spektrafilm physics | Density-domain, p(1−p) mid-peak, blue-coarsest, print-anchored | Pre-baked plates with the verified physics; kills LR's noise-overlay grain (docs/05-spec-color.md, docs/06-spec-detail.md) |
| Clarity / local contrast | C1 (Natural method) / darktable (local Laplacian craft) | Halo suppression as a feature | Halo-free by construction via local Laplacian; one shared detail engine, preset-faced (docs/06-spec-detail.md) |
| Sharpening | DxO Lens Sharpness | Lab-measured spatially-varying deconvolution | Honest approximation: auto-radius RL deconvolution + corner boost; C1-style halo suppression on manual (docs/06-spec-detail.md) |
| Denoise quality | DxO DeepPRIME XD3 | Raw-domain joint demosaic+denoise | v1 LR-class RGB (gap is pixel-peeping now); v2 raw-domain via RawSource; win the UX: full-image cached preview, instant blend, no file copies (docs/07-spec-denoise.md) |
| Denoise speed | LrC 15.4 (ANE) | ~5 s / 45MP on M4 Max | ≤10 s / 45MP on Core ML/ANE, background queue, viewing-priority (docs/07-spec-denoise.md) |
| Manual masking | LR semantics + darktable/ART engineering | Component algebra; guided-filter feathering; deterministic combine | LR grammar + Intersect visible; ART's one-of-each rule; async recompute always (docs/08-spec-masking.md) |
| AI masking | Lightroom Classic | Breadth: sky, objects, person parts | Match and exceed breadth locally: SAM 2.1 + Vision + BiRefNet + depth-for-every-photo; local curves and wheels *inside* masks, which LR still lacks (docs/08-spec-masking.md) |
| Similarity masking | DxO U-Point | Two-click chroma/luma selection with selectivity | Similarity point/line as a mask component (docs/08-spec-masking.md) |
| Healing / retouch | LR 15.0 (Dust Removal) / DxO ReTouch | One-click dust review; transformable source | PatchMatch heal + local inpaint models + one-click dust removal, all local (docs/09-spec-geometry.md) |
| Geometry / lens | LR (Defringe UX, Guided Upright) | Beloved micro-interactions | Clone the micro-interactions on Apple RAW corrections (docs/09-spec-geometry.md) |
| Scopes | Resolve | Parade/waveform/vectorscope; no stills editor has them | Ship the trio + skin line, one disclosure away (docs/05-spec-color.md, docs/12-spec-ux.md) |
| Export | C1 Process Recipes | Multi-recipe simultaneous output | Adopt wholesale; LR still can't (docs/11-spec-output.md) |
| HDR output | LR (gain-map pipeline) | ISO 21496-1 / Ultra HDR authoring | Headline feature on macOS EDR: gain-map HEIC/JPEG, SDR-proof toggle (docs/11-spec-output.md) |
| Editing ergonomics | C1 Speed Edit | Hold-key + drag anywhere, batch-applies | Adopt with curated defaults; plus the Lumen slider contract (docs/12-spec-ux.md) |
| Performance architecture | vkdt / Ansel | Full-res GPU graph; prefix caching, downstream-only recompute | Metal pipeline + Ansel's cache discipline as law (docs/13-architecture.md, docs/14-pipeline.md) |
| Library / DAM | Lightroom Classic | Scale, search, collections ecosystem | Folder-first + fast index; OR-filters LR can't do; automatic hygiene, no rituals (docs/10-spec-library.md, docs/15-catalog.md) |
| Data trust | Exposure X7 / the Aperture lesson | Sidecars on the filesystem survive the app | JSON recipes + XMP sidecars + read-only originals from day 1 (docs/15-catalog.md) |
| Pricing / trust | Topaz (pre-credits) | Pay once, own it, local | Personal tool: no subscription, no credits, no cloud, no telemetry — the field's every pivot is the evidence (docs/00-vision.md) |

The pattern the table makes visible: every best-in-class cell is a *different vendor*, and at least six
of them (PM, FRV, DxO, C1, Resolve, spektrafilm-class film physics) are structurally unable or
commercially unwilling to absorb the others. The combination is the product. That argument is made in
full in docs/00-vision.md; the roadmap that sequences it is docs/16-roadmap.md.

---

## Sources note

Compact attribution; the full bibliography with URLs lives in docs/17-appendix.md. Capture One: official
release notes (16.7.4–16.8.4) and support docs; Thomas Fitzgerald; Life after Photoshop; Fstoppers;
PhotoWorkout; PetaPixel (pricing); DPReview forums. DxO/Topaz: PhotoLab/PureRAW/Nik product
documentation and PhotographyLife-class reviews (PL8/PureRAW 5/Nik 7 level; PL9/Nik 8/Topaz-current
unverified this sweep); Finding the Universe and Fstoppers denoise standings; Adobe's Generative Upscale
FAQ. Mac field: Apple developer documentation (CIRAWFilter, Vision — API-verified), Pixelmator/Apple
acquisition announcements, Retroactive repo (verified), Aperture retrospectives, vendor pages for
Luminar/ON1/Radiant/Exposure/Darkroom. Culling: Camera Bits and FastRawViewer documentation, Aftershoot
and Narrative product pages, wedding-forum sentiment, sibling verification of LrC 15.x and C1 16.8
culling features. Open source: repo-verified primary sources — dtdocs and darktable release
notes/sources per tag, RawTherapee tagged release notes, ART reference docs, vkdt repo, RapidRAW repo,
Ansel repo and benchmarks. Cinema/film: thatcherfreeman/utility-dctls (verified DCTL math),
andreavolpato/spektrafilm (verified constants; GPLv3 caution), Resolve reference material and colorist
practice (Mixing Light-class, paraphrase level), Dehancer/Filmbox product documentation, VSCO/Mastin/RNI
ecosystem history.
