# Building Lumen

This is the honest ledger: what exists, where it has been verified, and what to do
first on a Mac. Read the "Known gaps" section before drawing conclusions from anything
above it.

## Run it

Requires macOS 15+ and the Swift 6 toolchain (Xcode 16+).

```sh
swift test               # engine contracts + the GPU golden suite
swift run LumenApp       # launch directly
scripts/build-app.sh     # or build dist/Lumen.app and `open dist/Lumen.app`
```

**Or download it, already built.** Every push builds the bundle on CI and attaches it:
open the branch's latest run under the repository's **Actions** tab, and take the
`Lumen-app` artifact from the summary page. Unzip and `open Lumen.app`.

**Then clear the quarantine flag, or it will not open.** A bundle that arrives through
a download carries `com.apple.quarantine`, and quarantine plus an ad-hoc signature
reports as *"Lumen is damaged and can't be opened. You should move it to the Trash"* —
which is a lie, and which right-click → **Open** does **not** get past. Run this once:

```sh
xattr -dr com.apple.quarantine Lumen.app
open Lumen.app
```

A bundle you built yourself with `scripts/build-app.sh` never left the machine, so it
has no quarantine flag; there, right-click → **Open** on the first launch is enough.
This paragraph exists because the failure looks exactly like a broken build, and the
first thing anybody would conclude from that dialog is that the app does not work.

The first thing to do is open a folder of your own RAWs (⌘O) and cull it: arrow keys to
move, `P`/`X`/`U` to flag, `1`–`5` to rate, `6`–`9` to label, `E` for the loupe, `G`
back to the grid. Press ⌘/ for the full keyboard reference. Then edit one frame and
export it (⌘E).

## Where the code lives

| Target | Contents | Platforms |
|---|---|---|
| `LumenCore` | The whole engine as pure Swift: colour science, the display transform, tone, curves, colour and grade, the film chain, spatial filters, denoise, mask rasterization, scopes, the SQLite catalog, the recipe format. No UI, no Apple-only frameworks. | macOS + Linux |
| `LumenPipeline` | The Core Image render path: thirty-two small kernels, the graph, the RAW stage, export. No AppKit, no SwiftUI — deliberately, so it stays testable headless. | macOS |
| `LumenApp` | The SwiftUI application. | macOS |

## How this code was verified

**LumenCore compiles and tests locally now.** `scripts/install-linux-toolchain.sh`
fetches a Linux Swift toolchain; `swift build --target LumenCore` takes about ten
seconds and `swift test --filter LumenCoreTests` runs the ~200 tests that do not need
Core Image. That covers eighteen thousand lines — all the colour science, tone, grade,
film, detail, denoise, mask algebra, catalog and XMP.

It does NOT cover LumenPipeline or LumenApp, which are `#if os(macOS)` and need Core
Image, AppKit and SwiftUI. Those still go through the macOS runner, and
`scripts/check-swift-surface.py` remains their only local feedback — which is why that
script has eight passes rather than one. Two bugs shipped in a single afternoon that a
compiler catches in seconds: a member that did not exist on a type, and an overlay
drawing against a rectangle the renderer had already applied.


There is no Swift toolchain on the machine this was written on, and swift.org is
blocked by its egress policy. So the verification loop is **GitHub Actions' macOS
runner**: it compiles all four targets and runs both suites there, and the CI log is
filtered down to deduplicated diagnostics so a round is readable.

> **⚠️ A large batch of commits went uncompiled for a while.** Partway through
> 2026-08-20 GitHub stopped allocating runners — every run failed in about three
> seconds with no job starting, on both lanes, with empty logs, which is the signature
> of exhausted Actions minutes on a private repository. Roughly seventy commits landed
> while that held. The repository is public now, the push trigger is back on, and the
> first real run since (#58) reached the compiler and reported **one** error across
> those seventy commits: `CatalogStore` matched on `SQLITE_CORRUPT`/`NOTADB`/`FORMAT`
> without importing the C module those come from. The predicate now lives on
> `SQLiteError` in `SQLite.swift`, the one file that does import it. That error stopped
> the build at LumenCore, so LumenPipeline and LumenApp are still waiting on a compiler
> — treat them as unverified until a run gets past this point.
>
> What stood in for it meanwhile, and still runs on every push: the Python mirror below,
> and `scripts/check-swift-surface.py`, which makes eight mechanical passes over the
> whole tree — every capitalized identifier resolves against the declarations in-tree,
> every `Type(...)` call site matches one of that type's declared initializers, every
> call to an actor-isolated member is awaited, every `TypeName.member` names something
> that type has, every platform symbol is used in a file that imports its module, and
> every member read off an explicitly typed value exists on that type.
> Each pass is verified able to fail by substituting wrong code; the third exists
> because a missing `await` was found by hand in code the first two both accepted, and
> the fifth because pass 1 waved `SQLITE_CORRUPT` through — its known-platform list is
> global, imports are per-file, and "that is a real symbol" was never the same question
> as "that symbol is in scope here". Pass 5 now reproduces the compiler's diagnostic on
> that file and line exactly. The sixth followed the same way: `photo.url` reached a
> compiler because `PhotoItem.id` IS the URL, and pass 4 only ever checked
> `TypeName.member`, never a member on an instance. Pass 6 scopes by FUNCTION — a
> per-file version was written first, reported a clean tree, and was structurally blind,
> because in a thousand-line view model a common name like `photo` is bound by inference
> somewhere and the rule that refuses ambiguous names refused all of them. They catch renames, typos, reshaped initializers and
> isolation slips. They do not check a single type, they cannot see leading-dot enum
> cases, and they are not a compiler.

Three layers of checking, in order of strength:

1. **`LumenPipelineTests` runs the real Core Image graph on the macOS runner.** It
   compiles every kernel, renders synthetic frames through the actual pipeline, reads
   the pixels back, and compares them against the f32 reference implementation in
   `LumenCore`. This is what makes a GPU path trustworthy from a machine with no GPU:
   if a shader drifts from its reference, the next push says so.
2. **`LumenCoreTests` asserts contracts, not numbers.** The display transform hits all
   four of its anchors; the wavelet stack reconstructs exactly at unit gains; the
   guided filter smooths interiors while holding a step edge; a chroma move preserves
   perceived brightness and a luminance move preserves chroma ratios; every film stock
   anchors mid-grey and stays monotone; tile plans cover the frame exactly; every Auto
   output lands inside its slider's range. These survive refactors that change numbers.
3. **The Linux fixture lane** regenerates `Tests/LumenCoreTests/Fixtures` with
   `scripts/gen-fixtures.py` and fails if the committed fixtures drifted. That script
   began as a mirror of the canonical-JSON, curve, zone, mask-algebra, XMP and schema
   logic; it now also executes an independent implementation of most of the engine —
   the shaper, the display transform, the tone and grade solvers, the parametric curve,
   the colour stage, the guided filter, the radial mask, and the whole film chain — and
   asserts properties on it that no Swift test can reach from a machine with no
   toolchain. `enginemath.json` then carries its sampled outputs back for
   `EngineMathFixtureTests` to replay, which is what ties the two implementations
   together rather than letting the mirror stay green while the Swift drifts.

   Two lessons are baked into how those checks are written, both learned the hard way:
   **a check must be able to fail** — several were rewritten after a wrong
   implementation was substituted and they passed anyway, one of them a pure algebraic
   tautology — and **two implementations agreeing is worth nothing if both are asked
   the wrong question**, which is how a mask falloff that had been reduced to a hard
   edge survived in both the Swift and its mirror.

**A failing `LumenCoreTests` fixture test means the Swift diverged from the verified
reference — fix the Swift, not the fixture.** Change a fixture only for an intentional
format change, and say so in the commit.

## The units bug this codebase keeps making

Four separate defects, found on four separate days, are the same mistake: **a
constant denominated in EV, applied to a `LumenLog`-encoded plane.** One stop is
`1/LumenLog.range` = 1/24 of an encoded unit, so a number carried across without
converting is wrong by 24 if it is a slope and by 576 if it is a variance.

| Where | Was | Should have been | What it did |
|---|---|---|---|
| `applySharpen`'s gain exponent | `k` | `k · range` | Texture and Clarity moved the picture by 1/25 of what they said |
| Presence guided bases | ε = 0.0008, 0.004 | ε / range² | Bases blurred across 50.6% of a 3 EV step; Clarity left a 0.72 EV trench beside every hard edge |
| Dehaze transmission refinement | ε = 0.0025 on the dark channel | `0.02 / range²` on log luminance | Transmission inherited the dark channel's blocky edges |
| Structure tensor thresholds | raw gradient | gradient × range | Masking kept 17.8% of the sharpening on an edge instead of 73.7% |

The tell is always the same: a threshold that sounds reasonable in stops —
"a tenth of a stop", "0.02 EV/px" — sitting next to a plane produced by
`logLuminance`, which is encoded and not EV.

Two rules that would have caught all four:

1. **Write the conversion, not the result.** `DetailEngine.baseEpsilon /
   (LumenLog.range * LumenLog.range)`, never `1.736e-5`. The reader can check
   the first and can only trust the second.
2. **Say the unit at every boundary.** A kernel taking a threshold should say in
   its doc comment which plane it expects, and `structureTensor` now scales into
   EV at the source so there is one denomination downstream rather than each
   reader choosing.

**The denoise stage is the exception to the whole section, and says so.** S3 works in
the LINEAR working image's own units, because `variance = a·signal + b` is a statement
about linear signal — nothing on that path may carry a `LumenLog.range`. Its own
numerical hazard is different and is documented at `ClassicalDenoise.GPUPlan`: the
generalized Anscombe transform carries a `2/a` factor, which for a read-noise-dominated
profile reaches 2.0e8 against a half-float working format that stops at 65 504. The
kernels work in `scale · (f(x) − f(0.18))` and compute it as `2(x − x₀)/(√u + √u₀)`
rather than as a difference of two transforms — the same number, without ever forming
the large one. Modelled against the f64 reference, the pedestal halves the half-float
error of the stage: worst pixel 9.8e-4 against 1.6e-3, RMS 1.2e-4 against 2.2e-4, on a
stage whose effect is 1.5e-2 to 4.8e-2.

## The other kind of unit: what a Core Image kernel is allowed to read

A second class of defect, found the same way — by modelling the arithmetic first and
then not believing the graph.

`CIColorKernel` carries a contract: **it reads exactly the pixel it is producing.**
That promise is what lets Core Image fuse colour kernels together and concatenate them
with geometry nodes, and it is not advisory. S3's à-trous transform was first built by
handing one colour kernel five *translated* copies of the same image and letting each
`__sample` argument pick up its own offset. It compiled, it ran, and it produced a
picture — and on the macOS runner the five-level stack differed from
`ClassicalDenoise.apply` by **71% of the stage's own effect**, while the numpy model of
the identical arithmetic agreed with the reference to 6e-16 in double and 5e-4 in half.
The maths was never wrong; the graph was not computing the maths.

A kernel that reads a neighbourhood must be a general `CIKernel`, must say where it
samples with `samplerTransform`, and must be applied with a `roiCallback` that tells
Core Image how far it reaches. The ROI is not a formality either: it is what makes a
tiled render of a 45-megapixel export produce the same pixels as a 64-pixel test frame,
and S3's deepest à-trous level reaches 32 px.

The tell: a stage whose end-to-end golden is wrong by a large *fraction of its own
effect* rather than by a rounding error. That is a structural difference, and the first
question to ask is not "is the formula right" but "is the graph evaluating the formula".
`RenderGraph.localStructure` had already reached for `CIFilter.convolution3X3` on a
clamped image rather than translated inputs; that precedent was there to be read.

Which is also why every primitive in S3 now has its own golden against its own
reference — `SpatialOps.atrousSmooth`, `gaussianBlur`, `ClassicalDenoise.edgeMap`,
`SpatialOps.guidedFilter`. A maximum over a five-level wavelet stack tells you the
denoise is wrong. It cannot tell you which tap moved.

The tone mask is the one place ε = 0.004 on an encoded plane is *correct*:
`ReferenceRenderer.applyTone` encodes with `LumenLog` too and passes the same
number, so both paths agree and the softness is a shared choice about a selection
mask. Check the reference before "fixing" it.

## The architecture, in one page

Rendering is a pure function of `(original, recipe, pipelineVersion, target)`. Nothing
is destructive; the original file is never written to.

Nearly every colour-bearing stage — printer lights, the colour tools, the grade, the
film chain, the display transform, the tone curve — is a pure RGB→RGB function. Rather
than port each one into a shader and hope the two stay in step, the engine evaluates
the composed function once in Swift and bakes it into lookup tables the GPU fetches:

```
S6  linear matrix     white balance (CAT16) · exposure · printer lights, fused into one 3×3
S7  tone              six sliders + zones, as a gain curve over an edge-aware guided mask
S8  presence          texture / clarity / dehaze off ONE base–detail decomposition
S9  colour   ┐
S10 grade    ┘        one 3-D table over the log domain
S11 local             mask sub-recipes, blended in scene-linear
S12 sharpen
S13 effects           vignette, then halation — in that order, because that is the light path
S14 render   ┐        THE display transform, or a film stock's negative+print chain
S15 curve    ┘        one 3-D table, log domain in, display-linear out
S16 geometry          crop ∘ rotate, one resample
```

The custom-shader surface is therefore thirty-two small kernels
(`Sources/LumenPipeline/Kernels.swift`) — the log shaper, image-by-image arithmetic for
the guided filter, mask compositing, grain, vignette, dehaze, halation, and the nine
that make up S3's variance-stabilizing transform and à-trous shrinkage. Everything else
is a stock filter or a table.

If a kernel fails to compile on a given machine, `KernelLibrary.isAvailable` goes false
and the renderer says so in the viewer rather than rendering something wrong.

## Known gaps and deliberate deviations

These are tracked, not hidden.

- **No one has run this app on a real Mac yet.** CI compiles it and runs the suites;
  the first launch on real camera files is still ahead. Expect layout surprises and
  `CIRAWFilter` behaviour on specific bodies to need attention. That is the honest
  state, and it is why the first session on a Mac should be `swift run LumenApp` with a
  folder of your own frames.
- **The loupe is a SwiftUI image view, not the Metal/EDR layer.** The render plumbing —
  draft decode, coordinator actor, one graph for preview and export — is the real
  architecture; only the view swaps when the EDR viewport lands. HDR *export* maths is
  implemented and tested; the HDR *viewport* is not.
- **Three AI mask kinds now compute; four still wait on a model.** Subject, Background
  and People come out of Apple's Vision framework — on-device, no download, no licence
  ledger — through `VisionMattes` and the `VisionMatteWorker` actor, which is
  deliberately not the render actor: the coordinator suspends rather than blocks while
  a matte is computed, and frames keep being drawn from the cache. Background is the
  COMPLEMENT of the subject rather than a second request, as docs/08 §8.3 requires.
  The segmenter sees a NEUTRAL rendition of the file, uncropped and unrotated, so the
  matte neither moves when the exposure does nor lands in the wrong frame; it caches
  per file in `PipelineRenderer`, bounded like the source cache, and export generates
  it inline rather than delivering a file with the mask contributing nothing.
  Sky, Object, Landscape and Depth Range have no model bundled and rasterize to
  nothing; `MaskKind.matteProvider` says which is which in one place, and the panel
  reads it — the roster is split into "on this Mac" and "needs a model Lumen does not
  ship", and a component whose pass has run and found nothing says so instead of
  looking like one still working.

  **Not verified on hardware.** Nothing in this file's Vision path has run on a Mac
  yet: the mask's ORIENTATION in particular is argued from convention (a CGImage's row
  0 is the top, Vision returns a buffer in the same order, and `Plane` is top-down too)
  rather than observed. If a subject mask comes out mirrored vertically, that is the
  line to look at, and it is a one-line fix.

- **AI denoise is modelled but not wired to a model.** The cached-splice blend, the
  artifact key and the tile plan all exist and are tested; `denoise.mode = .ai` drives
  the decoder's own noise reduction from its Amount slider as a stand-in.

  That stand-in reaches RAW files only. `RenderedImageSource.decode` takes the recipe
  and reads nothing but the scale factor, so on a JPEG, HEIC or TIFF `.ai` means every
  denoise stage off — Tier 1 zeroed by the mode coupling, Tier 2 absent, and Amount
  driving a decoder stage that path does not have. The panel now distinguishes the two;
  the code does not, and closing it needs a change in `LumenPipeline`.

  The mode coupling itself used to zero Tier 1 unconditionally. docs/07 §2.1 says the
  masters drop to zero "unless the user has hand-set them, in which case their values
  are respected", which needs a bit per master, and the recipe had none — so
  `ISODefaults.classic(for:)` took them as parameters **defaulting to false** and
  `RenderPlan` passed neither. The exception could not fire on any photograph, and the
  only trace was a default argument at a call site nobody reads. `ClassicNR` carries
  `lumaUserSet` / `chromaUserSet` now, the panel sets them, and the parameters are gone
  rather than defaulted — a default argument is a silent answer to a question the caller
  was never asked. Both are false by default and serialize sparsely, so no recipe
  already written changes its canonical form or its fingerprint.

  Until recently that gap was much wider than it looked: the renderer rasterized every
  mask with no source image, so **Luma Range, Colour Range and both Similarity kinds
  also selected nothing** — on every preview and every export, with no badge, because a
  recipe with no source is not invalid. Linear, Radial and a plain brush were the only
  kinds that worked. The mask Refine slider and the brush Automask toggle died on the
  same argument. Fixed, and `MaskKind.readsSourceImage` now states which kinds need the
  picture so a renderer cannot quietly fail to supply it again.
- **Tier-1 classical denoise ships; capture sharpening still does not.** S3 is in the
  graph — `RenderGraph.applyDenoise`, nine new kernels — and `KernelGoldenTests`
  compares it against `ClassicalDenoise.apply` on real frames, so the golden suite can
  catch drift in it. All seven controls are on the wire and in the panel, the profile
  follows the capture ISO, and Off is off including Hot Pixels. Two things it is NOT:
  `ReferenceRenderer.render` still starts at S6, so the CPU stage runs one level up in
  `PipelineRenderer.renderReference` rather than inside the reference's own stage list;
  and Tier 2 remains a cached-artifact design with no model, so `.ai` still drives the
  decoder's own denoise from its Amount. Capture sharpening (S4) is unchanged: Apple's
  at-demosaic sharpener scaled by the slider, with `richardsonLucy` uncalled AND
  untested — it appears in no file under `Tests/`, so "written" is the whole claim.

  **What the golden suite could not say is whether any of it is GOOD.** Every denoise
  assertion in the suite measured noise σ falling, which stays true while the picture is
  being destroyed — a stage returning flat grey removes 100% of the noise. Scored
  against ground truth instead (`ProofFrames.cleanISO6400`, `chromaEdge`,
  `noisyChromaEdge`; `DenoiseQualityTests`), both master sliders were spending their top
  halves buying negative quality: at Colour 100 a saturated colour edge survived at
  0.709 of its step, at the ISO 25600 default 0.738, and on a noisy colour edge every
  Colour setting from about 40 up scored WORSE than not denoising at all. Both travels
  are now bounded at 2.5σ — measured, not chosen: past that a soft threshold keeps under
  5% of a band — with each curve anchored so the mid travel keeps the authority the
  flat-field goldens require. The luminance-guided blotch pass came down from a 0.5 mix
  to 0.10, which is where most of the colour edge was going: its guide is luminance, so
  across a boundary that is pure chroma there is nothing to stop it.

  Residual error against the clean frame, both masters together, in sRGB code values:
  undenoised 3.623, best point 2.030 → 2.018, full deflection **3.552 → 2.869**.

  The ISO-adaptive Colour defaults resolved INTO that harmful region — 40 at ISO 6400,
  55 at 25600, both worse than no denoise at all on a noisy colour edge. The anchors are
  10 / 20 / 25 / 30 now, and the reason the old curve climbed is worth keeping: every
  threshold in this stage is denominated in the profile's σ, **and σ already rises with
  ISO**, so a slider that also rises with ISO applies the gain adaptation twice. Swept
  on the corrected curve the optimum does not move with ISO at all. `luminanceAnchors`
  has the same structure and has not been measured; the double count is structurally
  identical there and should be checked before it is defended.

  What this does NOT fix: luminance still gives error back over its travel on a frame
  whose texture sits near the noise floor, because the edge map that would tell them
  apart is stabilized by a σ 1.5 pre-blur and cannot see 6 px detail. Changing that
  operator changes a kernel too, so it is not a Linux-side fix.
- **Halation runs on both paths, and the golden suite now compares them.** It used to
  be GPU-only, which meant the slider did nothing on every headless render and any
  golden that set it diverged. The second half of that sentence was untrue when it was
  written: a grep of `Tests/LumenPipelineTests` for "halation" returned nothing, so
  every halation assertion in the repository was on the reference path, and deleting
  the call to the stage from `RenderGraph.build` left the whole suite green while every
  preview and every export lost the glow. In that gap the GPU stage was blurring at
  three times the model's radius — it had kept a private `CIFilter.gaussianBlur()` with
  the old `sigma * 3` in it, so the correction that landed in `RenderGraph.gaussianBlur`
  (`CIGaussianBlur.radius` IS the standard deviation, measured on the runner) reached
  the sharpen stage and mask feather and missed this one. Two goldens now hold it: one
  drives a clipped highlight through both paths and compares the second moment of the
  glow against the profile's own `2·Σwσ²/Σw`, where a support-radius conversion is a
  factor of nine; the other renders the same frame through `RenderGraph.build` at
  Halation 0 and 100 and requires the difference to appear beside the highlight and not
  at the far corner. Both are macOS-lane tests. Grain is still in the state halation was
  in: nothing renders it through the graph, so its call site can be deleted green.
- **Local noise, moiré, defringe and grain are not wired.** They have wire formats and
  no stage reads them, so the mask panel does not show them: a slider that moves a
  stored value and changes no pixel costs the user the time to find out. The local
  tone curve was on this list and is off it: it taps AFTER the display transform,
  alongside the global curve and through the same pre-geometry mask alpha, on both
  render paths (`LocalCurve` is the one implementation; `applyLocalCurves` is the stage
  on each side). Baking it into the local stage's table instead would have been the
  units mistake above in a new costume — a control denominated on the display's encoded
  axis evaluated against a scene-referred plane. Everything else the mask panel
  offers — exposure, contrast, the tone pair, temp, tint, hue, saturation, vibrance,
  texture, clarity, dehaze, sharpness, point colour — is wired and covered by a test
  that asserts each one changes the render. Two caveats that test did not have and now
  does: **Point Colour** was declared identity on the GPU path and did nothing inside a
  mask there, and the local **Colour tint** was missing from the reference renderer, so
  each path silently dropped one control the other applied. Both now go through one
  shared implementation. **Whites and Blacks inside a mask do nothing on their own** —
  they move the tone engine's anchors, and a mask has no display transform for those
  anchors to feed, so they only reshape where Highlights and Shadows act. The panel
  says so.
- **A lot of the catalog schema has no app behind it yet.** The tables, indices and
  `CatalogStore` API exist and are tested, and nothing in the app calls them: the
  preview/artifact cache (so thumbnails re-decode from the embedded JPEG on every
  launch rather than being served warm), stacks, keywords, collections, jobs, the
  export log, per-source view state, and virtual copies — `saveRecipe` only ever
  writes `kind = .working`, so `.version` and `.snapshot` rows are never created and
  the queries that filter on them can never match. The SQL filter and sort engine is
  in the same position: `PhotoQuery`, the FTS index and the fourteen chip indices are
  built and unused, because `FilterBar` filters in memory. None of this is broken, and
  all of it is unfinished — the schema went in ahead of the features, which is the
  right order, but it means a schema tour overstates what the app does.
- **The catalog's integrity check runs now, and restores.** `quickCheck()` and
  `integrityCheck()` used to be documented as running on every open and had no callers,
  so a corrupt catalog was discovered when a query threw — and a thrown query degrades
  to showing everything, which is the shape of failure where the library looks nearly
  right. `CatalogStore.recoverIfNeeded` runs before the store opens, and on a failed
  `PRAGMA quick_check` restores the newest backup that passes its own check, setting the
  damaged file aside rather than deleting it; `CatalogService` calls it and `AppState`
  shows the after-the-fact notice §15.8 asks for. `integrityCheck()` gates `backup()`,
  because a corrupt catalog that backs itself up rotates the last readable snapshot out
  of existence. Still missing from §15.8: the 7-daily/4-weekly/6-monthly retention
  policy — backups accumulate one per quit and one per menu command, forever.
- **HDR export writes no gain map.** `renderHDRPair` and the whole `GainMap` relation
  are implemented and tested, and nothing calls them — `export` renders once and emits a
  single rendition. The missing piece is an auxiliary gain-map image attached through
  `CGImageDestination`; `CIContext.write*Representation` takes no metadata argument, so
  it cannot get there from here.

  **Re-examined for Batch 6, and deliberately left off.** The route exists —
  `CGImageDestinationAddAuxiliaryDataInfo` with `kCGImageAuxiliaryDataTypeISOGainMap`,
  which wants the map's pixel data, a `kCGImageAuxiliaryDataInfoDataDescription`
  describing its pixel format and stride, and ISO 21496-1 parameters as
  `kCGImageAuxiliaryDataInfoMetadata`. It is not written here because none of those three
  can be got right without a Mac to open the result on, and a file carrying a
  *malformed* gain map is strictly worse than one carrying none: an HDR viewer will
  apply it and render the picture wrong, where today it simply shows the SDR base. That
  is the "a control that lies is worse than an absent one" rule applied to a file format.
  The remaining Batch 6 items were finishable without a Mac; this one is not, and the
  honest score stays where it is. Until then the toggle is inert and `hdrIsWritable`
  says so in one place. It used to be worse than inert: the HDR ceiling reached the
  render plan, put display white at 4.0, and the 8-bit encode then clipped everything
  above diffuse white — so ticking the box threw away exactly the highlight roll-off it
  was meant to preserve.
- **Export metadata: the subtractive half is proven by construction, the additive half
  is not.** Strip GPS, EXIF, Camera serial and Keywords remove what they name, and that
  is reliable whichever way the encoder treats the property dictionary — either it
  honours it and the keys are gone, or it ignores it and they were never going to be
  written. Before this the entire section had no reader at all.

  Copyright, Contact and the DPI pair *are* now written, into the TIFF and IPTC
  dictionaries, correctly ordered after the drops so that switching EXIF off cannot
  carry a copyright away with the dictionary it lives in. **What is not established is
  whether they arrive.** All of it rides `image.settingProperties` into
  `CIContext.write*Representation`, and nobody has verified on a Mac that the encoder
  serialises properties that were ADDED rather than merely preserved. An earlier version
  of this file said the additive half was impossible because that API "takes no metadata
  argument"; that is the pessimistic reading of an API whose whole purpose is to carry a
  dictionary to an encoder, and it is no better evidenced than the optimistic one. The
  panel says the fields are written and unconfirmed, which is the only caption that is
  true today.

  **One afternoon at a Mac settles it**: export a JPEG and a TIFF with a copyright set,
  read them back with `CGImageSourceCopyPropertiesAtIndex`, and check
  `kCGImagePropertyTIFFCopyright` and `kCGImagePropertyIPTCCopyrightNotice`. If they are
  absent, the file has to be authored through `CGImageDestination`, which takes an
  explicit properties dictionary and removes the question — the same route the gain map
  needs. Zero tests touch `applyMetadataPolicy` on either platform, so nothing would
  notice either outcome today.
- **The crop tool is reachable now, and correct.** `showCrop` had no writer, so a
  complete interactive `CropOverlayView` was dead code. A first attempt at wiring it
  drew the wrong rectangle and was reverted the same hour: `renderPreview` applies
  geometry before returning, and the overlay's rect is normalized to the
  straightened frame, so the two composed into a second inset crop that compounded
  on every drag. `applyGeometry(skipCrop:)` is the fix — while R is held open the
  renderer returns the straightened frame WITHOUT its crop, so the rectangle is
  drawn against the frame it is expressed in. Orientation and scale still apply,
  because a crop tool on an unstraightened frame asks the user to place a rectangle
  against a picture they are not editing.
- **The straighten ruler is in; Auto is not.** Straighten used to be a number with
  nothing to measure it against. `StraightenOverlayView` sits above the crop rectangle
  while the crop tool is open, and one drag along a horizon or a doorframe writes
  `geometry.angle` through the same coalescing key the slider uses. The arithmetic is
  `Straighten` in `LumenCore` rather than in the view, because the sign depends on two
  things a view cannot check — the frame on screen has ALREADY been rotated by the angle
  in the recipe, and a horizontal flip inverts the correction — and both are wrong in the
  way where the first drag improves the picture and the second makes it worse.
  `Straighten.displayedDirection` is the forward mapping the inverse is tested against.
  The specced binding is ⌘-drag inside crop mode; it is an explicit "Straighten by line"
  button instead, because a modifier-qualified drag is a gesture nobody discovers.
  **Auto-straighten is not implemented** — it wants Vision's horizon request cross-checked
  against a gradient histogram, and there is no button for it rather than one that guesses.
- **Soft proofing reaches pixels.** `SoftProof` was a struct with a gamut test and no
  caller of any kind. It is now a viewing mode on `AppState` (⇧S, or the Effects panel's
  Soft Proof section), threaded through `RenderCoordinator` into `RenderPlan`, and it
  splits in two on purpose:
  - The **picture** half — destination primaries, the intent's gamut map, and the
    paper-and-ink simulation — is composed onto the end of `finishLUT`, the one object
    the GPU graph and `ReferenceRenderer` both apply. No new kernel, and it cannot be
    present on one path and missing from the other. Measured, it costs nothing: worst
    table-versus-exact error 0.1343 with the proof composed in, against 0.1344 without.
  - The **gamut flag** is a graph stage, not a table entry, because a trilinear table
    turns a step function into a ramp. Baked, the flag's edge sat a mean of 0.017 OKLCh
    chroma from the true boundary and mislabelled 6.0% of a hue/chroma/lightness sweep.
    Computed per pixel from the unproofed table, that is 0.0033 and 0.71%. The stage
    needs no new kernel either — `Σ max(v−1,0) + max(−v,0)` in the destination's
    primaries is two `highlightEnergy` clamps, an `addGlow`, a `luminance` with unit
    weights, and a scale that saturates `blendMask`'s own clamp into a step.

  One limit worth stating: the loupe is handed an **sRGB** `CGImage`, so proofing to a
  space at least as wide as sRGB changes little on screen — the flag and the paper
  simulation are what carry information there. A wider preview surface is the EDR
  viewport's job. Compare panes do not proof; the loupe does.
- **8-bit exports are dithered.** There was no dithering code in the repository and the
  export sheet said so. `PipelineRenderer.applyDither` now adds a tiled 8×8 ordered
  pattern of at most half an output code immediately before the encoder, after every
  resample, so a long smooth gradient keeps its local mean instead of stepping. The
  amplitude is this file's recurring units bug in a new dress: one code is 0.0003 of
  display white at the bottom of the sRGB curve and 0.008 at the top, so a constant
  offset would be 27× wrong at one end. `Dither.codeStep` writes the conversion —
  encode, step half a code either way, decode — against the DESTINATION's own transfer
  curve, and it is baked into a per-channel table the GPU fetches. 16-bit targets are
  left alone. One approximation, stated: the offset is added in the working primaries
  and the encoder converts afterwards, so a saturated colour's dither is rotated by that
  3×3 — of order one, and a dither only has to be about a code wide to break a band.

### What the engine, masking, panel and dailies audits found

Four more adversarial passes — the GPU kernel layer, the masking system end to end,
every develop panel's bindings, and the scopes/zones/heal group — found the following.
Everything below is FIXED unless it says otherwise.

The two most-used presence sliders were doing about a twenty-fifth of what they said.
`Texture` and `Clarity` take a gain exponent per stop, but the plane their detail bands
come off is LumenLog-encoded — 24 stops squeezed into [0,1] — so `exp2(k·Δ)` computed
`2^(k·ΔEV/24)`. Texture at +100 moved local contrast by 2.6% where the reference moves
it by 100%, on every preview and every export and inside every mask. **Dehaze** blew the
picture out from the other direction: airlight was the MEAN of the dark channel rather
than its brightest fraction, which collapsed the transmission, and a 0.1 floor then
allowed tenfold amplification — +50 put a tenth of a test frame above scene white and
+100 put nearly half of it there, clipping. The presence stages also ran in a different
ORDER from the reference (dehaze first rather than last), so any two of the three set
made the paths disagree by construction.

**On-image mask gestures landed somewhere other than where they were dragged.** The
canvas normalized against the cropped preview and stored the result as a
source-normalized coordinate, and was handed the cropped extent as the source size — so
on a left-half crop of a 6000 px frame a radial dropped at the visual centre was written
1500 source pixels away, and a brush painted about three times wider than its cursor
ring. **Painting one stroke could delete every earlier stroke** on that component: the
canvas appends to the set it is handed, and that came from the memory cache alone, so a
miss meant the next stroke replaced an hour of masking with itself. **Brush Automask**
was dead on the shipping path, and the **mask overlay** — the app's only way to LOOK at
a mask — always drew a flat tint over the whole frame, which reads as "this mask selects
everything". The overlay was fixed twice: the first fix produced a real alpha and then
handed it over as a grey `CGImage` with no alpha channel, which SwiftUI's `.mask`
promptly read as "opaque everywhere" and drew the same flat tint by a second route. It
now carries the alpha as numbers and composites all six of docs/08 §8.6's modes against
the sampled picture, through the geometry inverse, so it lands where the mask is on a
cropped frame too.

**Protect Skin protected everything except skin.** `skinLineDegrees` was the NTSC I-bar
measured from +b while both consumers read it from +a, so `skinWeight` scored zero on
every representative skin tone and high on brick and fire-engine red — with the control
on by default at 70, and the vectorscope's skin graticule equally wrong.

Smaller, all fixed: the vignette was centred on the sensor rather than the crop;
`ReferenceRenderer` dropped `finishScale`, so every HDR-target render on that path came
out `1/white` too dark; the two paths used different grain seeds, so no golden could
ever compare grain; a mask's Amount did not scale its Point Colour swatches; the
histogram's "Working %" printed the encoded axis value, disagreeing with the loupe's
readout by 2.6× in the shadows for the same pixel; the curve editor's histogram backdrop
was always nil; `toneGainCubeCached` was a `lazy var` on a struct, so no `let`-held plan
could call it and 32 768 samples were rebaked every frame; and double-clicking a slider
label PINNED an "auto" value instead of clearing it — resetting Temp wrote 5500 K and
changed the picture.

### Still open, from those audits

- **Dehaze's sky guard is still reference-only.** The recombination now matches — one
  luminance ratio rather than a per-channel divide, so a recovered sky keeps its colour
  (measured: the old form rotated a veiled blue by 13.4°, the new one by 0.00°). What is
  still missing is the per-pixel transmission floor the reference lifts toward 0.9 where
  the frame is bright and flat, which needs the structure-tensor gradient and
  log-luminance planes the kernel is not given. Its absence makes the GPU strip slightly
  more haze from a clear sky than the reference does; it is not a colour error.

- **A rendered file gets Lumen's display transform on top of the one already baked in.**
  JPEG/HEIC/PNG/TIFF now decode and edit (`RenderedImageSource`), which they could not
  before — the loupe threw `.undecodable` and every develop slider moved a value that
  reached no pixels. Colour handling is Core Image's: the file's profile converts into
  the linear Rec.2020 working space, which puts mid-grey at 0.18 by construction, so the
  scene-referred stages are dimensionally correct. What cannot be recovered is headroom
  and the curve the file already carries, so S14 applies a second tone mapping. The
  Linear render preset is the honest setting for such a file and nothing picks it
  automatically — a source that rewrote the user's recipe would be worse than one that
  renders what the recipe says. Their Temp/Tint are relative to a 5500 K reference
  rather than a camera neutral, which is docs/04's stated fallback.

- **Per-zone colour, saturation and falloff are a wire format no stage reads.**
  `ZoneAdjust.wheel`, `.sat` and `.falloff` round-trip through the sidecar and the
  catalog and change nothing; `zonePanelStops` takes `.ev` alone, and
  `zonePanelIsIdentity` inspects `.ev` alone, so they do not even force a re-render. The
  Zones panel shows the exposures and the pivots — which do reach pixels — and says the
  other three are absent rather than shipping them inert. (The panel itself no longer
  missing: it was built in this session, and until then the whole register was
  unreachable.)
- **Heal/clone does not exist on any path, and the panel now says so.** `Heal {
  strokesRef, count }` is declared and wired into `Develop`, and there is no writer, no
  blob loader and no render stage. A recipe arriving with `heal.count = 40` renders with
  all forty spots present. The Effects panel carries a Retouch section with no controls
  and a note saying exactly that, so somebody hunting for spot removal learns it is
  absent rather than concluding they cannot find it. `heal` deliberately still
  participates in `renderIdentity`, so it busts the cache: nothing writes it today, so
  that costs nothing, and stripping it would plant a stale-cache bug for the day a heal
  stage lands. Perspective/Upright is in the same position and the Crop section says so.
- **Speed Edit (D44) is not implemented.** Correctly absent from the keyboard reference,
  so nobody is sent looking for it.
- **The eyedropper is wired; what it feeds is not all verified.** The probe is
  `PipelineRenderer.sampleSceneLinear`, reading the DECODED frame before any of Lumen's
  stages. Two taps come off it, deliberately: `solveNeutral` wants the value BEFORE
  white balance because it is computing that white balance, and `sampleWorking` applies
  the linear stage first because every colour tool must compare against what the colour
  stage actually sees — a swatch picked off a warm frame would otherwise stop matching
  the moment Temp moved. Both live on the render actor, beside the source that knows the
  as-shot neutral.

  Five consumers now pick: white balance, global Point Colour, per-mask Point Colour,
  and the samples that Colour Range and both Similarity kinds compare against. A
  colour-driven mask component is still born carrying one placeholder grey so it is a
  valid component, and the first real pick replaces it rather than sitting beside it —
  otherwise every colour mask would select its target plus mid-grey, which on a
  photograph is most of the frame.

  None of this has been exercised by a human. The coordinate inverse is shared with
  `MaskCanvas` and the probe has two tests, but "the click lands where the cursor was"
  is not something CI can tell us.
- **A kernel that fails outside the core four degrades one stage silently in EXPORT.**
  The preview now takes the real CPU fallback when a core kernel is missing, and labels
  a reduced render with the names of whatever else failed. `export` has no equivalent:
  it renders through the graph regardless, so a missing `vignette` or `grain` kernel
  writes a file with that stage absent and nothing said. The pieces to fix it are in
  place — `renderReference` and `KernelLibrary.unavailableKernels` — but a file is not a
  preview, and silently substituting the reference renderer mid-export is a decision
  that wants a Mac to test on first.
- Creative sharpening is not resolution-scaled — `applySharpen` takes its radius in raw
  pixels and its à-trous band at fixed pixel steps, where every other spatial stage
  sizes itself off the long edge — so an export is less sharpened than the frame the
  user judged. **And no surface in the application shows the difference**: previews
  render at up to 4096 px, so "1:1" on a 45 MP file is already a half-resolution render
  and there is nowhere to look at export sharpening honestly. The Masking gate IS
  frame-proportional, so the gate and the band it gates scale differently as well. The
  claim is by construction, not by number — `ScaleHonestyTests` covers texture and
  clarity and not sharpen — and the panel says so rather than the delta being measured.

  Also: a mask's COLOUR table still runs at 33³ even on export
  (`RenderGraph.Options.lutSize` has one reader now — the local curve's table, which
  does take the export size); and the waveform grows blank columns on crops narrower
  than 256 proxy pixels.
- **Texture is still well under the strength it specifies**, and the fix above is not
  that fix. The units bug was real and is closed; what remains is the band SHAPE.
  Shipping Texture is one guided band scaled by a constant, where the reference sums the
  full à-trous stack normalized to `referenceBandWeight(halfWidth: 1.6)`. Measured at
  1.8×–17× weak across seven frames. The port reached 1.00× parity twice and was
  reverted twice (`4a58716`, `8324f37`) — not because it was wrong but because it was
  finally strong enough to expose a coherence gate that cannot tell a steep gradient
  from an edge. The third attempt starts from `8324f37`'s message, which lists what each
  of the four pieces has to do and in what order.

### What the fourth audit found

An adversarial pass over the catalog, export, XMP, HDR and app layers — everything
outside the engine — found twenty-one defects. All are fixed; four were data loss and
are worth naming, because they are the class this project cares most about.

Opening a folder of RAWs that had been through Lightroom and pressing one rating key
**replaced that photo's `.xmp` with Lumen's eight fields and nothing else** — every
`crs:` develop setting, every keyword, the capture date and the colour label gone, on a
photo Lumen had not even rendered. Two defects compounded: the reader only understood
the element form, so every Adobe sidecar (which uses the attribute form) parsed to
"nothing found", and the writer replaced the whole file. `XMPMerge` now splices only
the fields Lumen owns and leaves the file alone entirely when it cannot do that safely.

A photo's catalog identity was its **basename**, while the folder scan is recursive and
`photo` is `UNIQUE(folder_id, filename)` — so `day1/DSC_0001.NEF` and
`day2/DSC_0001.NEF` were one row, and editing both left only the second. A **RAW and its
JPEG shared one sidecar path**, so on a RAW+JPEG card each overwrote the other's recipe.
And **export had no overwrite or collision guard at all**, silently replacing a previous
delivery while the status line reported every file as written.

The rest were controls that could not work or did not describe themselves: culling had
no undo (and ⌘Z silently undid an unrelated develop edit instead), the undo stack
outlived its folder and wrote into the previous one's sidecars, the scopes and Auto Tone
measured a draft render with presence, local adjustments, sharpening, halation and grain
all absent, crop ratios were computed against an assumed 3:2 on every camera, the
watermark panel said it composited nothing while the encoder composited it at twice the
requested size, brush masks were missing from the first render of every photo, and
nothing ran at quit so the last two seconds of culling never reached disk.
- **Hot Pixels and the rest of Tier 1 reach the shipping path.** This entry said the
  opposite for two revisions after it stopped being true — "Hot Pixels reaches no path
  at all", "`ClassicalDenoise` has no caller anywhere in `Sources/`" — while
  `RenderGraph.applyDenoise` was calling `gpuPlan` on every preview and every export,
  and while THIS FILE said so, in a bullet two hundred and eighty lines earlier.
  Twice, then, this bullet has been the thing it warns against: it was first written to
  correct a stale "reference-only" note, and then went stale in exactly the same way.

  What is true today: S3 runs in the graph, all seven controls reach it, and the
  hot-pixel pass is a separate kernel dispatched from the same stage. The lesson the
  original entry drew still stands and is the reason this one names its evidence — an
  honesty note is a claim like any other, and the fact that it is confessing something
  does not exempt it from being checked. **A disclosure with no `file:line` in it is a
  disclosure nobody can re-verify**, which is how both versions of this bullet survived
  an audit apiece.

  Sharpening's Masking and Halo Suppression are also not unwired: both reach the GPU as
  arguments to `KernelLibrary.sharpenDelta`, and Detail reaches it as its own argument
  rather than folded into a radius. Halo Suppression has no test on any path, which is a
  different problem and an open one.
- **Remove chromatic aberration and the whole Defringe group are not wired**, and the
  Effects panel no longer shows them. The CA toggle, the Defringe switch and its six
  sliders: eight controls with a wire format and no reader — grep `removeCA` and
  `Defringe` across `Sources/` and only `Recipe.swift` answers.
  `lens.profile` is the one thing in that section that is genuinely consumed, at decode.

  A footnote conceding it was not enough. The CA toggle DEFAULTED TO ON, so every photo
  in the library carried a ticked box that moved nothing, and the toggle's own tooltip
  described the mechanism — "R and B are re-registered to G by a radial polynomial fit,
  folded into the geometry warp" — two rows above the note admitting none of it exists.
  The controls are gone and the sentence stays, which is the form `MaskPanel` already
  used for the local noise/moiré/defringe/grain group.
- **xxh64, not xxh3**, for `recipe_fp` and blob refs (docs/15 says xxh3). The `xxh64:`
  prefix makes the algorithm self-describing, so upgrading later is a migration rather
  than a breakage.
- **SQLite directly, not GRDB.** No external dependency: the build is hermetic and the
  C API is small enough to wrap correctly. `Sources/LumenCore/Catalog/SQLite.swift`.
- **Ingest copies nothing yet.** The one-screen flow, templates and verification
  settings exist; the copy engine behind them does not, and the UI says so instead of
  pretending the button works.
- Several controls the specs describe have no wire format yet (per-band mixer
  core/feather, film exposure, halation size, vignette shape, printer-light quarter
  points). Those controls are absent rather than fabricated; adding them is one
  `pipelineVersion` bump.

## Working on this from a machine without Xcode

```sh
python3 scripts/gen-fixtures.py   # regenerates fixtures + all Linux-side checks
```

Exit code 0 means canonical/sparse serialization behaves, hashes match xxhash's C
implementation, curves are monotone, zone weights sum to 1, mask semantics hold, XMP
parses, and both databases' DDL executes with the cull query on its index.

Everything else goes through CI. The workflow prints only sorted, deduplicated
diagnostics, so one round is a short read rather than a four-thousand-line scroll.
