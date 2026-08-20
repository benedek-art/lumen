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
| `LumenPipeline` | The Core Image render path: fourteen small kernels, the graph, the RAW stage, export. No AppKit, no SwiftUI — deliberately, so it stays testable headless. | macOS |
| `LumenApp` | The SwiftUI application. | macOS |

## How this code was verified

There is no Swift toolchain on the machine this was written on, and swift.org is
blocked by its egress policy. So the verification loop is **GitHub Actions' macOS
runner**: it compiles all four targets and runs both suites there, and the CI log is
filtered down to deduplicated diagnostics so a round is readable.

> **⚠️ Nothing in this repository has been compiled since 2026-08-20.** Partway through
> that session GitHub stopped allocating runners — every run failed in about three
> seconds with no job starting, on the macOS *and* Linux lanes, with empty logs, which
> is the signature of exhausted Actions minutes or a hit spending limit rather than
> anything in the code. The push trigger is disabled so the failures stop emailing the
> owner; `.github/workflows/ci.yml` carries the one-line restore instructions. Until
> a run succeeds, **treat every commit after that point as unverified by a compiler**:
> the reasoning below still applies to the design, but "it builds" is currently a
> claim, not a result. Restoring it needs a spending-limit raise, a public repository,
> or the monthly reset — none of which a commit can do.
>
> What stands in for it meanwhile: the Python mirror below still executes on every
> change, and `scripts/check-swift-surface.py` makes four mechanical passes over the
> whole tree — every capitalized identifier resolves against the declarations in-tree,
> every `Type(...)` call site matches one of that type's declared initializers, every
> call to an actor-isolated member is awaited, and every `TypeName.member` names
> something that type has. Each pass is verified able to fail by substituting wrong
> code, and the third exists because a missing `await` was found by hand in code the
> first two both accepted. They catch renames, typos, reshaped initializers and
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

The custom-shader surface is therefore fourteen small kernels
(`Sources/LumenPipeline/Kernels.swift`) — the log shaper, image-by-image arithmetic for
the guided filter, mask compositing, grain, vignette, dehaze and halation. Everything
else is a stock filter or a table.

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
- **AI denoise and AI masks are modelled but not wired to models.** The cached-splice
  blend, the artifact key, the tile plan and the mask components all exist and are
  tested; no Core ML model is bundled, so the six AI mask kinds and Depth Range
  rasterize to nothing, and `denoise.mode = .ai` drives the decoder's own noise
  reduction from its Amount slider as a stand-in. `MaskKind.needsMatte` names the kinds
  that are waiting on a model, in one place, so the gap stays legible.

  Until recently that gap was much wider than it looked: the renderer rasterized every
  mask with no source image, so **Luma Range, Colour Range and both Similarity kinds
  also selected nothing** — on every preview and every export, with no badge, because a
  recipe with no source is not invalid. Linear, Radial and a plain brush were the only
  kinds that worked. The mask Refine slider and the brush Automask toggle died on the
  same argument. Fixed, and `MaskKind.readsSourceImage` now states which kinds need the
  picture so a renderer cannot quietly fail to supply it again.
- **Tier-1 classical denoise and capture sharpening exist but are not in the reference
  renderer's stage list.** Both are implemented and unit-tested in `LumenCore`; what
  actually runs on the live path is Apple's decode-stage noise reduction and sharpener,
  driven by the same slider values, so the controls work — but the f32 reference does
  not model S2/S3/S4, which means the golden suite cannot catch drift in them. `.off`
  really is off. (An earlier version of this file claimed the reference ran Tier 1. It
  did not.)
- **Halation now runs on both paths** and the golden suite compares them. It used to be
  GPU-only, which meant the slider did nothing on every headless render and any golden
  that set it diverged.
- **Local noise, moiré, defringe, grain and the local tone curve are not wired.** They
  have wire formats and no stage reads them, so the mask panel does not show them: a
  slider that moves a stored value and changes no pixel costs the user the time to find
  out. The local curve in particular has to tap after the display transform, alongside
  the global curve, and the local stage runs before it. Everything else the mask panel
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
- **`quickCheck()` and `integrityCheck()` are documented as running on every open.**
  They have no callers, so a corrupt catalog is discovered when a query throws.
- **HDR export writes no gain map.** `renderHDRPair` and the whole `GainMap` relation
  are implemented and tested, and nothing calls them — `export` renders once and emits a
  single rendition. The missing piece is an auxiliary gain-map image attached through
  `CGImageDestination`; `CIContext.write*Representation` takes no metadata argument, so
  it cannot get there from here. Until then the toggle is inert and `hdrIsWritable`
  says so in one place. It used to be worse than inert: the HDR ceiling reached the
  render plan, put display white at 4.0, and the 8-bit encode then clipped everything
  above diffuse white — so ticking the box threw away exactly the highlight roll-off it
  was meant to preserve.
- **Export metadata is subtract-only.** Strip GPS, EXIF, Camera serial and Keywords now
  remove what they name, which is reliable whichever way the encoder treats the property
  dictionary. Nothing *adds* a field: Copyright and Contact are stored with the recipe
  and never written, for the same `CGImageDestination` reason as the gain map. The panel
  says so. Before this the entire section had no reader at all.
- **The on-image crop tool does not exist.** `LoupeViewport.showCrop` has no writer, and
  unlike `beforeMode` — which was in the same state and now has its `Y` / `⇧Y` / `⌥Y`
  keys — it cannot simply be given one: `renderPreview` applies the crop before
  returning the image, so `CropOverlayView`, whose rect is normalized to the *source*
  frame, would draw a second inset crop over an already-cropped picture. Wiring a key to
  it would produce a tool that draws the wrong rectangle. The ratio menu is the whole
  crop surface for now, and it says so.

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
everything".

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

- **Per-zone colour, saturation and falloff are a wire format no stage reads.**
  `ZoneAdjust.wheel`, `.sat` and `.falloff` round-trip through the sidecar and the
  catalog and change nothing; `zonePanelStops` takes `.ev` alone, and
  `zonePanelIsIdentity` inspects `.ev` alone, so they do not even force a re-render. The
  Zones panel shows the exposures and the pivots — which do reach pixels — and says the
  other three are absent rather than shipping them inert. (The panel itself no longer
  missing: it was built in this session, and until then the whole register was
  unreachable.)
- **Heal/clone does not exist on any path.** `Heal { strokesRef, count }` is declared and
  wired into `Develop`, and there is no writer, no blob loader and no render stage. A
  recipe arriving with `heal.count = 40` renders with all forty spots present and nothing
  says so.
- **Speed Edit (D44) is not implemented.** Correctly absent from the keyboard reference,
  so nobody is sent looking for it.
- **There is no eyedropper anywhere.** The white-balance solver has no way to sample
  scene-linear values; Point Colour swatches and mask colour samples can only ever be
  seeded at 18% grey, which makes Colour Range, both Similarity kinds and the local
  Colour tint unable to reference a colour the user picked. All now labelled.
- **A kernel that fails outside the core four degrades one stage silently in EXPORT.**
  The preview now takes the real CPU fallback when a core kernel is missing, and labels
  a reduced render with the names of whatever else failed. `export` has no equivalent:
  it renders through the graph regardless, so a missing `vignette` or `grain` kernel
  writes a file with that stage absent and nothing said. The pieces to fix it are in
  place — `renderReference` and `KernelLibrary.unavailableKernels` — but a file is not a
  preview, and silently substituting the reference renderer mid-export is a decision
  that wants a Mac to test on first.
- Creative sharpening is not resolution-scaled, so an export is less sharpened than the
  frame the user judged; `RenderGraph.Options.lutSize` is dead and mask tables run at
  33³ even on export; and the waveform grows blank columns on crops narrower than 256
  proxy pixels.

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
- **Sharpening's Masking and Halo Suppression, and Hot Pixels, are reference-only.**
  All three are implemented and unit-tested in `LumenCore`; none has an equivalent on
  the shipping path, because a stock unsharp mask takes a radius and an intensity and
  the classical denoise engine is not in the graph. Detail DOES reach the GPU, as the
  unsharp radius it stands in for. The panels name which is which.
- **Remove chromatic aberration and the whole Defringe group are not wired.** Seven
  controls in the Effects panel with a wire format and no reader; `lens.profile` is the
  one thing in that section that is genuinely consumed, at decode. The panel says so.
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
