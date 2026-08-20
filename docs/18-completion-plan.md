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
| Texture | 55 → 70 | Coherence gate shipped (structure tensor). The à-trous band is still a guided-filter approximation |
| Dehaze colour stability | ~~45~~ **done** | Luminance-ratio recombination shipped; golden asserts 0° hue rotation where the old per-channel form rotated a veiled sky by 13.4° |
| Sharpen Masking | ~~35~~ **done** | Edge gate from a Sobel structure measure, in the graph |
| Halo Suppression | ~~35~~ **done** | One-sided overshoot clamp, in the graph |
| Capture sharpening | 25 | `richardsonLucy` + `estimatePSFSigma` have no caller; the toggle scales Apple's demosaic sharpener instead |
| Vignette | 70 | Reference is frame-centred, GPU is crop-centred; they disagree on any cropped photo and no golden covers it |

### Batch 2 — Denoise, the declared flagship

| Item | Now | Closes it |
|---|---|---|
| Tier 1 classical | 15 | CIKernels for the VST and à-trous shrinkage so `ClassicalDenoise` runs in the graph. The engine is done and tested; it has no kernels |
| Luminance Detail / Contrast, Colour Detail / Smoothness | 10 | Four of seven Tier-1 controls have no wire format |
| Hot Pixels | 5 | Reads nowhere on any path — the panel's note about it is itself wrong |
| ISO-adaptive defaults | 10 | `ISODefaults` has the spec's anchors and no caller |
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
| Subject / Person masks | 5 | Apple's Vision framework, on-device, no download. `VNGenerateForegroundInstanceMaskRequest` and `VNGeneratePersonSegmentationRequest` |
| Sky / depth / object | 4 | Need models. Fetchable now that the network policy is open; until one is bundled the UI says so plainly rather than implying a background pass |
| Local point curve | 8 | `LocalPlan` reads no `adjust.curve` |
| Local grading wheels | 8 → **done** | Landed |
| Mask overlays | 25 | One mode of six, no colour cycling, no keys |
| Async mask lifecycle + raster cache | 10 | Rasters recompute synchronously every frame; the `artifact` table is built and unused |
| Whole-mask invert | 0 | No wire format at all |

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
| Straighten | 45 | Number only — no ruler, no auto |
| Perspective / Upright | 3 | A `Codable` struct nobody constructs |
| Heal / clone | 2 | Declared, no writer, no stage. A recipe with `heal.count = 40` renders unchanged and busts every cache |
| HDR gain map | 15 | Math written and tested behind a hardcoded `false` |
| Soft proofing | 10 | Engine exists, zero UI callers |
| Export dithering | 0 | Still no dithering code. The export sheet no longer claims there is |

## Order, and why

1. **Batch 1** first: it changes every photograph and needs no UI.
2. **Batch 2** next: it is the declared flagship and the engine is already written.
3. **Batch 5** and **Batch 3** together: colour is the thesis, and the library is what
   makes the app usable for more than one photo at a time.
4. **Batch 4**, then **Batch 6**.

## Verification

Scores in this document are claims, and claims get checked. After each batch:

- The six mechanical passes and the fixture gate, on every push.
- The macOS suite, with the fast lane for iteration.
- **Independent agents re-audit the batch against its spec**, with the same instruction
  the first five had: trace UI → model → the stage that reads it, and treat "code
  exists" as worthless without a caller. An agent that scores a feature it cannot trace
  to a render stage has not verified it.

The rule that makes this honest: **a score may only go up when something can be traced
from a control to a pixel.** Not when code is written.

## Two things this plan cannot do

- **Fetch a model — no longer true.** This said `huggingface.co` was unreachable. The
  environment's network policy was widened from "trusted" to "all" mid-session, so
  models can be fetched and `download.swift.org` opened too, which is how LumenCore now
  compiles locally in ten seconds instead of seventeen minutes through CI.

- **Judge a photograph.** Every exit test in docs/16 is "on the owner's real photos, to
  the owner's eye". Nothing here substitutes for that.
