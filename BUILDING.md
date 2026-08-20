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

The bundle is signed ad-hoc, not notarized, so the first launch needs the usual
right-click → **Open** rather than a double-click — macOS refuses an unnotarized app
opened the normal way, and says so in a dialog that offers no way past it.

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
runner**: every push compiles all four targets and runs both suites there, and the CI
log is filtered down to deduplicated diagnostics so a round is readable.

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
   `scripts/gen-fixtures.py` — an executable mirror of the canonical-JSON, curve, zone,
   mask-algebra, XMP and schema logic — and fails if the committed fixtures drifted.

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
  tested; no Core ML model is bundled, so the AI mask kinds rasterize to nothing and
  `denoise.mode = .ai` currently falls back to the classical tier.
- **Tier-1 classical denoise and capture sharpening exist but are not in the reference
  renderer's stage list.** Both are implemented and unit-tested in `LumenCore`; what
  actually runs on the live path is Apple's decode-stage noise reduction and sharpener,
  driven by the same slider values, so the controls work — but the f32 reference does
  not model S2/S3/S4, which means the golden suite cannot catch drift in them. `.off`
  really is off. (An earlier version of this file claimed the reference ran Tier 1. It
  did not.)
- **Halation runs only on the GPU path.** `ReferenceRenderer` has no halation stage, so
  the golden suite cannot compare it against anything — the same shape of gap as
  capture sharpening and Tier-1 denoise above. What the graph does is checked by eye
  and by the kernel's own unit tests, not by a reference.
- **Local noise, moiré, defringe, grain and the local tone curve are not wired.** They
  have wire formats and no stage reads them, so the mask panel does not show them: a
  slider that moves a stored value and changes no pixel costs the user the time to find
  out. The local curve in particular has to tap after the display transform, alongside
  the global curve, and the local stage runs before it. Everything else the mask panel
  offers — exposure, contrast, the tone pair, temp, tint, hue, saturation, vibrance,
  texture, clarity, dehaze, sharpness, point colour — is wired and covered by a test
  that asserts each one changes the render.
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
