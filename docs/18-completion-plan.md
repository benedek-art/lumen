# 18 — The 70% plan

Docs 00–17 decide *what* Lumen is and *when* each part gets built. This one decides what
gets built **next**, and it exists because a five-way audit of the shipped code against
those specs found something the roadmap could not have predicted: the gap is
overwhelmingly **connection, not invention**.

Whole engines are written, tested, and have no callers. `ClassicalDenoise`,
`AIDenoiseSplice`, `TilePlan`, `ISODefaults`, `NoiseProfile`, `ColorBalanceGrid`,
`DetailEngine.captureSharpen`, `richardsonLucy`, `estimatePSFSigma`, `SoftProof`,
`GainMap`, `RawStatistics`, `LocalNoiseAdjust`, the `.cube` parser, and roughly a third
of `CatalogStore` are all correct code that nothing calls. That is not a project 15%
built. It is a project whose halves have not been introduced.

## What "70%" means here

A feature counts as 70 when **all four** hold. Anything less is scored below it however
good the code is.

1. **It reaches pixels or disk on the SHIPPING path.** The GPU graph and export, not
   `ReferenceRenderer` — which renders no user pixels and is goldens-only. Several
   marquee claims (local-Laplacian Clarity, colour-stable Dehaze, sharpen Masking, Halo
   Suppression) are currently true only there.
2. **Its primary controls are reachable in the UI** without knowing a secret.
3. **At least one test can fail if it breaks** — a check that cannot fail is not a check.
4. **Nothing about it is inert or lying.** A control that stores a value nothing reads
   is worse than an absent one, because absence is honest. Where a sub-behaviour is
   genuinely deferred, the panel says so.

Documented sub-behaviours may be missing at 70. Alt-drag diagnostics, TAT, per-axis
refinements and the like are what 70→90 is made of.

## Where it stands, and what closes each gap

Scores are from the five subsystem audits. "Closes it" lists only what is needed to
reach 70 — not the full spec.

### Batch 1 — Make the shipping path the specced path

The single highest-value work in the project, because it changes what every photograph
looks like and needs no new UI.

| Item | Now | Closes it |
|---|---|---|
| Clarity | 50 | Local Laplacian on the GPU; today it is a guided-filter gain at a coarser radius |
| Texture | 55 → 70 | Coherence gate shipped, then corrected: it smoothed the tensor over 4× the reference's radius, squared the eigenvalue ratio, and omitted the strength gate, which between them had it closing on flat skin (0.596 where the reference says 0.000) and opening on edges (0.503 against 0.611). The à-trous band is still a guided-filter approximation |
| Dehaze colour stability | ~~45~~ **done** | Luminance-ratio recombination shipped; golden asserts 0° hue rotation where the old per-channel form rotated a veiled sky by 13.4° |
| Sharpen Masking | ~~35~~ **done** | Edge gate off the box-smoothed structure tensor, at the reference's radius. The first version read a bare per-pixel Sobel and kept 17.8% of the delta on an edge against the reference's 73.7% — and being per-pixel, it kept a different amount at preview scale than at export scale |
| Halo Suppression | ~~35~~ **done** | One-sided overshoot clamp, in the graph |
| Capture sharpening | 25 | `richardsonLucy` + `estimatePSFSigma` have no caller; the toggle scales Apple's demosaic sharpener instead |
| Vignette | 70 | Reference is frame-centred, GPU is crop-centred; they disagree on any cropped photo and no golden covers it |

### Batch 2 — Denoise, the declared flagship

| Item | Now | Closes it |
|---|---|---|
| Tier 1 classical | ~~15~~ **done** | Nine kernels in `RenderGraph.applyDenoise` at S3: the variance-stabilizing transform, the dilated B3-spline row, the two edge maps and the soft-threshold clamp. Modelled against the f64 reference before it was written — the GPU formulation agrees to 9e-16 in exact arithmetic and 1.3e-4 RMS in the half-float working format, on a stage that moves the frame by 1.5e-2 to 4.8e-2. Apple's decode-stage NR is off in Classic now, or the frame was smoothed twice |
| Luminance Detail / Contrast, Colour Detail / Smoothness | ~~10~~ **done** | All seven on the wire, all seven in the panel, decoding tolerant of the three-field form every existing recipe was written in. One definition of the per-band thresholds, read by both the reference and the GPU plan |
| Hot Pixels | ~~5~~ **done** | A branchless 8-neighbour median through a Batcher sorting network, gated on `k·σ` AND on strict extremum, in the graph. A one-pixel line survives at 100 |
| ISO-adaptive defaults | ~~10~~ **done** | `ISODefaults.startingDenoise` resolves the anchors into the recipe at import, off the catalog's EXIF ISO; the panel shows the resolved values and badges which ISO they came from, and the noise profile every threshold is denominated in follows the same ISO through `RenderPlan` |
| Tier 2 AI | 20 | `huggingface.co` is reachable now — the network policy was widened mid-session — so a model CAN be fetched and the ceiling is lifted |

### Batch 3 — The library half

| Item | Now | Closes it |
|---|---|---|
| EXIF into the catalog | 5 → **done** | `CaptureMetadataReader` + backfill pass landed |
| Preview cache on disk | 12 | STILL NOT WIRED. `ThumbnailLoader` has no injection point and is keyed by URL, so it cannot reach a photo_id; needs ~100 lines across it and AppState. Deliberately not half-shipped: a writer with no reader is more uncalled code, not less |
| Collections / keywords / stacks | ~~8~~ **done** | Sidebar section, album scoping, target album, keyword add/remove into FTS, stack create/collapse/promote/dissolve. Virtual copies still open: a version is a second edit row and the grid is one cell per URL, so it needs a model change |
| Filter bar → SQL | ~~30~~ **done** | Whole bar compiles to `PhotoQuery`, with camera/lens/ISO/keyword/stack chips, live facet counts and the All/Any toggle |
| Sort orders | ~~30~~ **done** | 12 of 12 on real EXIF, ordered in SQL. Two defects found while wiring: `capture_at` alone shuffles a burst (nine frames share a second — now breaks on `capture_subsec`), and the aspect sort was inert because `setMetadata` never maintained `photo.aspect` |
| Ingest copy engine | 5 | A planning UI with no copier and no hashing anywhere in the repo |

### Batch 4 — Masking

| Item | Now | Closes it |
|---|---|---|
| Subject / Person masks | 5 → **landed, unverified on hardware** | Vision's foreground-instance and person-segmentation requests, on a worker actor that is not the render actor, cached per file, generated inline for export. Background is the subject's complement. What is NOT verified: none of it has run on a Mac, and the buffer's orientation is argued from convention rather than observed |
| Sky / depth / object | 4 → **the UI is honest** | Still no models and still empty masks — but the roster is split into "on this Mac" and "needs a model Lumen does not ship", and a row that has run and found nothing says so rather than looking like one still working. `MaskKind.matteProvider` is the single source both read |
| Local point curve | 8 → **done** | Second tap after the display transform on both paths (`LocalCurve` / `applyLocalCurves`), through the same mask alpha; the mask panel shows the real curve editor, retargeted |
| Local grading wheels | 8 → **done** | Landed |
| Mask overlays | 25 → **done** | Six modes, four colours, `O` / `⇧O` / `⌥O` / `'`, panel menus as well as keys, composited against the sampled picture through the geometry inverse. The one mode that existed was also still drawing a flat tint: a grey CGImage used as a SwiftUI `.mask` has alpha 1 everywhere |
| Async mask lifecycle + raster cache | 10 → 25 | The AI mattes now have the lifecycle: a worker actor off the render path, a bounded per-file cache, one pass per file whatever it finds, invalidated with the source. The vector rasters still recompute per frame and the `artifact` table is still unused, so this is not closed |
| Whole-mask invert | 0 → **done** | `Mask.invert`, applied to the folded alpha ahead of the refinement chain, in `MaskRaster.combine` so all three consumers get it |

### Batch 5 — Colour depth

| Item | Now | Closes it |
|---|---|---|
| Eyedropper consumers | 0 → **done** | Landed: WB, both Point Colours, Colour Range, Similarity |
| Hue-Selective Equalizer | 0 | Does not exist. Doctrine 1 says it is the Mixer's second face |
| Skin tools | 8 | A product pillar; one of three parts exists |
| Advanced grading grid | 5 | `ColorBalanceGrid` is ~180 lines of correct unreferenced code |
| Mixer core/feather handles | 0 | No per-band wire format |
| Uniformity | 35 | `bandMeanHues` has a reader and no writer; `localMean` is passed the pixel itself, so the texture-preserving half is absent |
| LUT import | 5 | Parser exists and is tested; no importer, no UI, no stage reads `look.lut` |
| Film grain chromatic structure | 45 | One noise value written to all three channels; `plateScale(…, channel:)` unused |

### Batch 6 — Geometry and output

| Item | Now | Closes it |
|---|---|---|
| Crop tool | ~~30~~ **done** | `applyGeometry(skipCrop:)` — the loupe shows the uncropped frame while R is open, so the rect is drawn against the frame it is expressed in |
| Straighten | ~~45~~ **done** | Ruler shipped: one drag inside the crop tool writes `geometry.angle`, with the sign derived from `applyGeometry` and tested against its forward mapping, flip included. Auto is still absent, and correctly has no button |
| Perspective / Upright | 3 | Unchanged. A `Codable` struct nobody constructs — it needs a homography, a reference twin and mask reprojection, which is a new stage and not a wiring job. The Crop section now says it is absent |
| Heal / clone | 2 | Unchanged, and now legible: the Effects panel has a Retouch section with no controls and a note saying heal/clone is not implemented. `heal` still busts the cache on purpose — nothing writes it, so that costs nothing, and stripping it would plant a stale-cache bug for the day the stage lands |
| HDR gain map | 15 | Unchanged, deliberately. The route is `CGImageDestinationAddAuxiliaryDataInfo` + `kCGImageAuxiliaryDataTypeISOGainMap`; the data description and the ISO metadata cannot be got right without a Mac to open the result on, and a malformed gain map renders WORSE than none |
| Soft proofing | ~~10~~ **done** | ⇧S and an Effects panel section → `AppState.softProof` → `RenderCoordinator` → `RenderPlan`. The picture half rides in `finishLUT`, which both render paths apply (measured: 0.1343 worst table error with it, 0.1344 without). The flag is a graph stage rather than a table entry, because baking it put its edge 0.017 OKLCh chroma off the boundary and mislabelled 6.0% of a sweep; per-pixel it is 0.0033 and 0.71% |
| Export dithering | ~~0~~ **done** | Tiled 8×8 ordered dither of at most half an output code, on the output grid immediately before the encoder, amplitude measured against the destination's own transfer curve. 16-bit is left alone. The export sheet says what it does |

## Order, and why

1. **Batch 1** first: it changes every photograph and needs no UI.
2. **Batch 2** next: it is the declared flagship and the engine is already written.
3. **Batch 5** and **Batch 3** together: colour is the thesis, and the library is what
   makes the app usable for more than one photo at a time.
4. **Batch 4**, then **Batch 6**.

## Verification

Scores in this document are claims, and claims get checked. After each batch:

- The eight mechanical passes and the fixture gate, on every push.
- The macOS suite, with the fast lane for iteration.
- **Independent agents re-audit the batch against its spec**, with the same instruction
  the first five had: trace UI → model → the stage that reads it, and treat "code
  exists" as worthless without a caller. An agent that scores a feature it cannot trace
  to a render stage has not verified it.

The rule that makes this honest: **a score may only go up when something can be traced
from a control to a pixel.** Not when code is written.

## What an independent audit found

An agent that wrote none of this traced every claimed-done item from control to
pixel against the four conditions. **Thirteen of sixteen claims held. Three did
not**, and they are recorded here rather than quietly fixed, because the pattern
matters more than the individual bugs — every one is a shape this project has
shipped before.

| Claim | Audited | Why |
|---|---|---|
| Tier-1 denoise sliders | 70 as wiring, **not as behaviour** | The controls reach the shader's uniforms. But every behavioural proof of what a slider DOES is against `ClassicalDenoise.apply`, the reference that renders no user pixels; the two goldens binding the GPU stage to it were red on macOS |
| ISO-adaptive defaults | 60, not 70 | See below |
| Local point curve | 65, not 70 | The shipping half has no test. Delete the call in `RenderGraph` and the whole suite stays green while every preview and export loses the second tap |
| Vision person matte | 30 | Ten inert checkboxes, and the one Vision kind whose editor never showed its status |

**The ISO badge lied to every JPEG owner.** `startingRecipe` applies the ISO table
only to non-rendered files — a camera JPEG is already denoised and its pixels do
not follow the sensor model. The panel read the catalog's ISO for every format, so
on a JPEG shot at ISO 3200 it said "Adjusted from the ISO 3200 defaults", badged
an untouched photo "Manual", showed the section's modified dot, and made
double-clicking Luminance write 18.75 — a value the app had just decided that file
must not get — which was then applied against the ISO 100 profile anyway. Wrong in
four places at once, on every JPEG, HEIC and TIFF in the library.

**Sixteen controls stored values nothing read.** Ten person parts and six landscape
classes, with a caption saying parts were "synthesised from the person matte".
Nothing synthesised anything: `personParts` and `classes` had writers, a
declaration, and no reader anywhere. Shipped inside the batch whose headline claim
was that the AI roster is now honest. Removed — absence is honest.

**The gap this exposes in the test suite:** there is no test anywhere that puts a
mask through `RenderGraph`. `applyLocalCurves`, `LocalCurvePlan`, `applyLocal`,
`maskImages`, and the orientation of a mask raster in Core Image's y-up space are
collectively unasserted. Whole-mask invert escapes only because it lives in
`MaskRaster.combine`, which the CPU tests do cover — which is exactly why it scores
70 and the local curve does not.

## The accuracy the tables actually deliver

Colour is baked into 3-D LUTs and fetched per pixel. That is the architecture, and its
cost had never been measured — three tests asserted bounds nobody had checked, and all
three had been failing on macOS the whole time behind a lane that does not run them.

Measured against an exact evaluation, worst case across a swept recipe:

| | size 33 (preview) | size 65 (export) | size 129 |
|---|---|---|---|
| colour + grade table, in stops | 0.197 | 0.074 | 0.017 |
| share of samples over 0.02 EV | 10.6% | 4.1% | 0% |
| finish table, display-referred | 0.0265 | 0.0143 | 0.0057 |
| whole pipeline, display-referred | 0.0446 | 0.0296 | 0.0141 |

The error halves per doubling of the cube. That is the linear convergence of an
interpolation limited by the curvature of what it is approximating — not a bug waiting
to be found, and the only lever is a finer cube. `testTheColourTableConverges` now
asserts the ladder itself, so a loosened single-size bound cannot hide a real regression.

What it means for a photograph: the preview and the delivered file differ by up to 8 of
255 levels, worst on a saturated blue at 1.6 EV, and the preview is 11 levels off the
exact answer on a yellow-green at 4 EV. Raising `LUT3D.interactiveSize` from 33 to 65
would cut that roughly in half. It is now affordable in principle — the bake is
parallel across cores and cached across frames rather than rebuilt for each one — but
it costs latency on a colour edit and wants measuring on real hardware first.

## Two things this plan cannot do

- **Fetch a model — no longer true.** This said `huggingface.co` was unreachable. The
  environment's network policy was widened from "trusted" to "all" mid-session, so
  models can be fetched and `download.swift.org` opened too, which is how LumenCore now
  compiles locally in ten seconds instead of seventeen minutes through CI.

- **Judge a photograph.** Every exit test in docs/16 is "on the owner's real photos, to
  the owner's eye". Nothing here substitutes for that.
