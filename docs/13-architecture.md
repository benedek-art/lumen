# 13 — Architecture & Stack

This doc owns the engineering skeleton: the stack decision and its alternatives, module layout,
the concurrency and cache model, the memory budget, the ML runtime strategy, the Apple-RAW contract
and its escape hatch, the safety posture, and the build/release machinery. What it does not own:
pipeline stage order and color architecture (14-pipeline.md), storage schemas and recipe format
(15-catalog.md), latency budgets and the five-loop release gate definitions (12-spec-ux.md),
phasing (16-roadmap.md), and the license ledger (17-appendix.md).

The governing constraint is stated once: **one developer, one platform, one user.** Every choice
below buys either leverage (platform machinery doing undifferentiated work) or control (owning the
pieces where Lumen is supposed to be better). Nothing is chosen for portability, team scaling, or
resale — those are explicit non-goals in 00-vision.md.

## 1. Stack decision

Swift + Core Image with custom Metal kernels + Vision/Core ML + SwiftUI/AppKit + GRDB(SQLite).
Chosen because it maximizes reuse of platform machinery *and* the owner's existing skills
(the owner already ships a Swift/SwiftUI macOS app).

| Need | macOS-native answer | What it saves us |
|---|---|---|
| RAW decode + demosaic + lens corrections for ~all mainstream cameras | `CIRAWFilter` (macOS 12+, GPU, scene-referred controls, ProRAW semantic mattes) | The single hardest, least-differentiating subsystem — years of camera-format work |
| GPU image pipeline | Core Image custom kernels (Metal Shading Language) with lazy graph fusion, ROI-tiled evaluation, and color management built in | A hand-rolled compute-shader scheduler and tiler |
| One-click AI masks | Vision: `GenerateForegroundInstanceMaskRequest`, person segmentation, aesthetics scores (macOS 15+); iterative segmentation on macOS 27+ | Model sourcing, porting, and maintenance for the most-used masks |
| ML runtime for denoise/SAM/matting/depth | Core ML on ANE/GPU; `coremltools` conversion from PyTorch | Bundling and optimizing an inference engine (darktable ships ONNX Runtime per-platform; on macOS it statically links Core ML — validating that on this OS the runtime problem is already solved) |
| Fast RAW metadata/preview extraction | ImageIO (`CGImageSource`) | An EXIF library + embedded-preview extractor |
| Color management | ColorSync + Core Image working-space handling | ICC plumbing |
| EDR/HDR display | `CAMetalLayer` fp16 extended-linear + `NSScreen` headroom APIs | An entire HDR display subsystem (see 11-spec-output.md) |
| UI | SwiftUI + AppKit escape hatches (`NSViewRepresentable`) + Metal viewer layer | Known territory; native menu bar/toolbar/full-screen for free |
| Catalog | SQLite via GRDB.swift | A storage engine (schema in 15-catalog.md) |

### Alternatives considered (updated Aug 2026 from the open-source teardown)

**Rust + wgpu (the RapidRAW path).** RapidRAW v1.6.1 (Aug 2026, ~9.4k stars, AGPL-3.0) is the
strongest evidence this stack works: one solo developer shipped roughly 70% of Lightroom's surface
in ~14 months — Tauri + React shell, full 32-bit float WGPU/WGSL pipeline, AgX tone mapping,
SAM 2 / Depth Anything V2 masking, a <20 MB binary. It is also the evidence for what the stack
costs: rawler-based decode leaves X-Trans demosaic quality on the roadmap, export has had
VRAM/memory failures into 1.6.x, and the README concedes it "isn't yet as polished as Darktable,
RawTherapee, or Lightroom." On this path we would own RAW decode (rawler is the weak link), get
none of Apple's free ML or RAW machinery, and buy portability we don't want. Rejected.

**Vulkan compute DAG (the vkdt path).** vkdt 1.0.0 (Dec 2025) is the performance ceiling of the
field — a full GPU node graph rendering full-res in real time, with jddcnn joint demosaic+denoise
compiled ONNX→SPIR-V. It proves interactive full-resolution processing is achievable on modern
GPUs, which raises our own bar. But it is Linux-first, developer-grade UI, runs on macOS only via
a brew + MoltenVK build, and demands 4–8 GB VRAM with its own LOD dials. We take its lesson
(GPU-resident full-res pipeline, in-graph neural stages) and none of its stack. Rejected.

**Forking darktable (the Ansel path).** Aurélien Pierre forked darktable 4.0 in May 2022, froze
features for four years to rewrite the core, and in Aug 2026 the project is still explicitly alpha
("0.0.0" nightlies). One person carrying a ~1M-LoC GPL C/GTK codebase is a permanent-alpha
sentence. Ansel still matters enormously to Lumen — its cache benchmarks are the blueprint for
section 3 — but as a critique to mine, not a codebase to inherit. Rejected.

**Electron/WebGPU.** Best UI iteration speed per hour, but 16-bit pixel handoff friction, a lower
performance ceiling for 45–61MP interactive work, and none of the platform ML. Rejected without
much agonizing.

**Apple-engine-only app (the RAW Power path).** RAW Power (Gentlemen Coders, Nik Bhatt — ex-Apple
Senior Director of Engineering for Aperture/iPhoto) is the existence proof that a one-person
editor built directly on `CIRAWFilter` works and is loved for being instant and tiny. Its ceilings
are equally instructive: camera support lags macOS point releases, there is no custom demosaic or
camera-profile control, Apple's rendering is opinionated (Boost), and the engine can shift under OS
updates. So Lumen adopts the RAW Power strategy *as the default path* and pre-designs the exit
(section 6): Apple's engine day 1, our own RAW stage behind a protocol when the ceilings start
costing image quality.

The convergent shape of every serious modern editor — GPU compute pipeline, scene-referred linear
core, thin declarative UI, text sidecars, SQLite index — is exactly what we build. We just build it
on Apple's runtime, where a solo developer gets the largest fraction of it for free.

## 2. Module layout

Single app process. One Swift Package, five targets:

```
LumenCore      — no UI, no Metal. Catalog access (GRDB), recipe model + codecs,
                 XMP sidecar I/O, folder scanning/watching, preview-cache index,
                 export job model, hashing/fingerprints.
LumenPipeline  — no UI. The render graph: RawSource protocol + AppleRawSource,
                 custom CIKernels (.ci.metallib), display transform, mask
                 rasterizer, cache manager (prefix cache, artifact cache),
                 export renderer, golden-test harness.
LumenML        — Core ML model wrappers behind task protocols: segmentation,
                 matting, depth, denoise, upscale, inpaint. Tiled-inference
                 utilities, model registry (download/verify/activate), encoder
                 embedding cache.
LumenApp       — SwiftUI/AppKit app: library UI, Metal viewer, develop panels,
                 mask editing UI, export UI, keyboard system (12-spec-ux.md).
TestAssets     — small RAW corpus (Bayer + X-Trans + ProRAW + malformed files),
                 golden outputs, noise-profile fixtures.
```

Dependency rules, enforced by the package manifest (a target simply cannot import what it does not
declare):

```
LumenApp ──▶ LumenPipeline ──▶ LumenCore
   │              │
   └──▶ LumenML ◀─┘  (Pipeline depends on LumenML *protocols* only;
                      concrete Core ML models are injected by the app)
```

- Nothing in `LumenCore` or `LumenPipeline` imports AppKit/SwiftUI. Ever.
- `LumenPipeline` consumes ML through protocols (`DenoiseModel`, `SegmentationModel`, …) so the
  pipeline builds and tests headless with stub models — no 1GB weights in CI, and the AI master
  switch (section 5) is trivially honored by injecting nothing.
- Recipes are value types defined in `LumenCore`; rendering is a pure function
  `render(source, recipe, target) -> image`. The same function serves thumbnails, loupe, and
  export — there is no separate "preview pipeline" to drift out of sync.
- Headless testability is a design requirement, not a nicety: a CLI runner
  (`lumen-render <raw> <recipe.json> --size …`) renders recipes to hashes, which is what golden
  tests, perf budgets, and future batch tooling all sit on.

## 3. Concurrency model and cache discipline

### Actors

| Actor | Owns | Rules |
|---|---|---|
| **Main actor** | UI state, current selection, recipe edits | Recipes are values; an edit publishes a new immutable recipe version. Zero pipeline work here — no decode, no render, no mask rasterization, no cache I/O. Debug builds assert it (`precondition(notOnMain)` at every pipeline entry point). |
| **Render actor** (one per visible image) | The CI graph for that image, its prefix cache handles, the Metal drawable | Coalesces/debounces recipe versions (renders the newest, skips stale), cancels superseded renders, publishes frames to the viewer layer. |
| **Ingest pool** (structured task group, bounded width, `.utility`/`.background` QoS) | Folder scans, EXIF reads, embedded-preview extraction, thumbnail generation, verified copy | Direction-aware prefetch orders its queue (10-spec-library.md); paging work preempts thumbnail backfill. |
| **ML actor** | Core ML sessions and the inference queue | Serializes heavyweight jobs (models are memory-hungry — one resident heavyweight at a time), reports progress, is cancellable between tiles, honors viewing-priority scheduling (the image on screen jumps the queue — 07-spec-denoise.md). |
| **Catalog** | GRDB write queue | All writes serialized through GRDB; UI observes via GRDB's observation → SwiftUI. Never blocks on render or ML work. |

```
 keystrokes/sliders          files on disk                models
       │                          │                          │
  ┌────▼─────┐   recipe vN   ┌────▼──────┐  artifacts   ┌────▼────┐
  │  Main    │──────────────▶│  Render   │◀────────────▶│   ML    │
  │  actor   │  frames ready │  actor(s) │              │  actor  │
  └────┬─────┘◀──────────────└────┬──────┘              └────┬────┘
       │                          │  prefix/artifact caches  │
  ┌────▼─────┐               ┌────▼──────────────────────────▼────┐
  │ Catalog  │               │        Cache store (Metal heaps    │
  │ (GRDB)   │               │        + disk, purgeable, keyed)   │
  └──────────┘               └───────────────────────────────────-┘
```

### Cache discipline (D49) — this is architecture, not optimization

Ansel exists because darktable recomputed the whole pipeline on every parameter change and ran
pipeline work on the GUI thread. Pierre's own benchmarks against darktable 5.0 (Feb 2026) put
numbers on what disciplined caching is worth: **5.4–40× faster recompute on mid-pipeline parameter
change** (recompute only downstream), **1.27–100× faster export** by reusing the cached pipeline
prefix, lighttable open 3.53× faster, view switch 6×, grid scroll 7×, idle power 0.85 mW vs
103 mW. His diagnosis — "darktable is leaking performance by the GUI" — is the failure mode these
rules exist to make impossible:

1. **Pipeline-prefix caching.** Every stage's output is addressable by a fingerprint:
   `hash(source id, pipelineVersion, target scale, upstream fingerprints, this stage's params)`.
   Expensive checkpoints are materialized as textures (RAW-stage output, AI-denoise splice, the
   local-adjustments composite); cheap stages stay fused inside Core Image's lazy graph between
   checkpoints.
2. **Downstream-only recompute.** A slider in the color stage re-renders from the nearest upstream
   checkpoint forward — never the RAW decode, never the denoise. The fingerprint chain makes this
   automatic rather than hand-maintained: a changed param changes its stage's fingerprint and every
   fingerprint downstream, and only those.
3. **Export reuses the interactive cache.** Export is the same pure render function at full
   resolution. Any full-res prefix already materialized (above all: the AI-denoise artifact, which
   costs seconds) is reused byte-for-byte; the export queue never re-runs an AI stage whose cached
   artifact is valid. Editing then exporting an image should cost roughly one pipeline tail, not
   two full pipelines.
4. **Zero pipeline work on the GUI thread.** The main actor's only jobs are input, state, and
   drawing UI chrome. Every violation is a bug with a debug-build assertion waiting for it.

Cached artifacts with independent lifetimes (AI denoise output, mask rasters, SAM encoder
embeddings) are keyed by (photo, upstream-param fingerprint, model version) and spliced into the
graph as textures — a slider move downstream of a cached artifact never touches the model. Their
storage lifecycle and self-healing rules live in 15-catalog.md; their invalidation triggers (e.g.,
geometry changes invalidate encoder embeddings) live with each feature's spec.

## 4. Memory budget (D48)

The arithmetic that governs everything, at the two sensor sizes that matter (the owner's 45MP
bodies and the 61MP ceiling of current full-frame):

| Buffer at full res | 61MP (9504×6336) | 45MP (~×0.74) |
|---|---|---|
| RGBA fp16 working buffer | ~482 MB | ~356 MB |
| RGBA fp32 buffer | ~964 MB | ~713 MB |
| Single-channel fp32 mask | ~241 MB | ~178 MB |
| Laplacian pyramid overhead | ×1.33 of base | ×1.33 |
| Realistic interactive graph (source + working + 2 checkpoints + display + 2 masks, fp16) | ~2–3 GB | ~1.5–2.2 GB |
| Peak during pyramid/LLF ops | +~1 GB | +~0.7 GB |

Ten full-res fp32 buffers at 61MP would be ~10 GB — unshippable on a 16 GB machine. Hence the
precision doctrine:

- **Pipeline semantics are f32; working buffers are fp16.** The math is defined and golden-tested
  as f32; intermediate textures are stored RGBA fp16 wherever a stage's error analysis allows.
  fp16's 10-bit mantissa bands in deep shadows after large exposure pushes, so
  **accumulation-sensitive kernels compute internally in fp32** (blur sums, pyramids, histograms,
  scopes, variance estimates) and deep-shadow paths (exposure > +3 EV territory, denoise variance
  stabilization) read/write fp32 checkpoints. Masks are single-channel fp16; grid/library proxies
  are 8/10-bit.
- **Tiling policy.** Interactive renders evaluate only the visible ROI at view resolution (Core
  Image does this natively). Full-res passes (export, AI stages) tile: classical kernels tile with
  each stage's declared halo (its blur/support radius) and overlap-discard stitching; **every ML op
  on >16MP inputs runs tiled at fixed 512–1024 px tile shapes with overlap** — fixed shapes both
  bound memory and keep Core ML from re-specializing per size (section 5).
- **Purgeable heaps.** All cache textures live in `MTLHeap`s marked purgeable; the cache store
  responds to memory-pressure events by dropping LRU entries. Because every cache entry is
  recomputable from (file, recipe) by construction, eviction is always safe — losing a cache can
  cost time, never correctness.
- **Model residency.** Heavyweight weights (BiRefNet-class matting ~1 GB fp16 at inference,
  NAFNet-class denoise ~100–300 MB) load on demand and unload on pressure; the ML actor keeps at
  most one heavyweight resident.

**Hardware floor: Apple Silicon with 16 GB unified memory** — everything works, with aggressive
tiling and purging. **Comfort spec: 32 GB+** — multi-image compare, resident ML weights, and
full-res graphs coexist without eviction churn. These two numbers are the budget every feature is
tested against; a feature that requires more than the 16 GB floor to function (not merely to be
fast) doesn't ship.

## 5. ML runtime strategy (D51)

### Now: Core ML on ANE, fp16, fixed tiles

All shipped models run through Core ML with ANE/GPU compute units. The constraints that shape
model prep, learned from Apple's own docs and darktable's conversion experience:

- **ANE is fp16-only.** Every model must be numerically validated in fp16 (norm layers and large
  activations are the usual failures — darktable hit fp16 overflow on its Bayer denoise model).
  Models that can't be made fp16-safe run GPU-fp32 via mlprogram `compute_precision`, at a power
  and speed cost, or don't ship.
- **Fixed tile shapes.** Enumerated/dynamic shapes cause re-specialization and scheduling misses;
  we bake fixed 512–1024 px input shapes into converted models and tile everything larger
  (section 4). This matches darktable's static-tile packaging and the ≤10 s/45MP denoise budget in
  07-spec-denoise.md.
- **Conversion path: `torch.jit.trace` → coremltools.** The `torch.export` path had ~68% op parity
  as of coremltools 8.1; trace is the reliable route. Toolchain pinned at coremltools 9.0
  (Nov 2025: torch 2.7, int8 I/O, macOS 26 targets); stateful models (macOS 15+, coremltools 8.0)
  are available if an encoder/decoder split ever wants persistent KV-style state.
- Compositing math stays in our Metal kernels, never inside a network — networks produce
  images/mattes; the pipeline blends them (fp16/fp32 under our control).

### Next: Metal 4 in-graph inference (macOS 26+)

Metal 4 (macOS 26 Tahoe) makes tensors first-class (`MTLTensor`) and adds
`MTL4MachineLearningCommandEncoder`, which dispatches whole networks **inside the Metal command
stream**: coremltools `.mlpackage` → `metal-package-builder` → `MTLPackage` →
`MTL4MachineLearningPipelineState`, synchronized with render/compute via ordinary barriers
(`MTLStageMachineLearning`), intermediates in a caller-provided `MTLHeap`. "Shader ML" embeds
micro-networks directly in compute/fragment shaders via Metal Performance Primitives (`matmul2d`,
inline tensors).

Migration plan, availability-gated, not a rewrite: per-tile denoise moves into the render graph
first (it currently pays a Core ML round-trip per tile; in-graph dispatch eliminates the
sync/copy overhead that dominates tiled inference), then any learned micro-ops (e.g., learned
local-tone weights) as Shader ML. Heavyweight one-shot jobs (matting, SAM encoder) stay on Core
ML/ANE, where power efficiency wins over graph locality. MPSGraph remains the niche middle for
hand-built math graphs (FFT deconvolution experiments) and is not load-bearing.

| Runtime | Use for | Why |
|---|---|---|
| Core ML (ANE) | Heavyweight models: denoise, matting, SAM encoder, upscale, inpaint | Best ANE access + power efficiency; model packaging; async batch |
| Metal 4 ML encoder (macOS 26+) | Per-tile in-graph inference once adopted | No round-trip; barrier-synchronized with the render graph |
| Shader ML (macOS 26+) | Micro-nets inside kernels | No memory round-trip at all |
| MPSGraph | Custom math graphs, prototyping | Interleaves with Metal without Core ML packaging |

### Model registry (darktable 5.6's architecture, adopted)

darktable 5.6 landed the right shape for local-AI management and we copy it almost verbatim:

- **Tasks, not models, are the API.** The registry defines tasks — `subject-matte`,
  `interactive-mask`, `depth`, `denoise`, `upscale`, `inpaint` — and features consume "the active
  model for task X." Many models may exist on disk per task; exactly one is active. Swapping a
  model (or a whole model generation) never touches feature code, and per-model quality bake-offs
  (07-spec-denoise.md) become configuration.
- **Download on demand.** The app bundle ships small (Vision covers day-one masking with zero
  downloads). Model packs are fetched once from our own release assets, SHA-256-checksummed,
  versioned, never auto-updated. Model files and licenses are enumerated in 17-appendix.md.
- **Master switch.** One switch disables all non-OS ML: with it off, no weights load, no runtime
  spins up, AI-dependent controls hide — zero cost, exactly like darktable's off-by-default design.
  (Lumen ships with it on; the point is that "off" is genuinely off — D5.)
- macOS spares us darktable's entire runtime-management surface (ONNX Runtime paths, execution-
  provider pickers): Core ML is in the OS. Our preferences show a switch and a model list, nothing
  else.
- **OS-model ladder:** where Apple ships an equivalent capability, it becomes the zero-download
  default for that task and our bundled model becomes the quality fallback — concretely,
  `GenerateIterativeSegmentationRequest` (macOS 27 beta) is planned as the default
  `interactive-mask` engine on 27+, with SAM 2.1-small the fallback and quality option
  (08-spec-masking.md owns that choice).

## 6. The RAW stage: CIRAWFilter contract + RawSource escape hatch (D50)

### Usage contract for AppleRawSource (the default)

`CIRAWFilter` (macOS 12+) closes the hardest 40% of the pipeline on day 1 — decode for ~all
mainstream cameras, demosaic including X-Trans, per-camera color, embedded lens corrections —
and hands back a scene-referred linear image we keep processing. We use it under a strict
contract:

- **Pin `decoderVersion`.** Rendering stability across macOS updates is opt-in via
  `supportedDecoderVersions`; the pinned version is recorded in every recipe, and a decoder bump is
  an explicit, badged migration (D52 — never Lightroom's silent process-version upgrade). Golden
  tests key expectations to (macOS version, decoder version).
- **Draft mode + `scaleFactor` for preview decodes.** `isDraftModeEnabled = true` and reduced
  `scaleFactor` make browse/loupe decodes cheap; full-quality decode is reserved for 1:1 zoom, AI
  stages, and export. (Culling never touches RAW decode at all — embedded JPEGs first,
  10-spec-library.md.)
- **`linearSpaceFilter` is the scene-referred injection point.** With `boostAmount = 0` the output
  is a flat, near-linear starting point (RAW Power made "Boost is Apple's secret sauce" a known
  concept; we simply turn it off) and our pipeline attaches while the image is still linear.
  Apple's display-referred tone machinery is never used — Lumen has exactly one display transform
  (04-spec-tone.md).
- **Harvest ProRAW semantic mattes** (skin, hair, teeth, glasses, sky + portrait matte) as free
  mask sources for iPhone DNGs (08-spec-masking.md).
- **Capability introspection everywhere.** `is*Supported` queries and `supportedCameraModels` gate
  per-file features; unsupported knobs disable visibly rather than silently no-op.

The ceilings, on the record because RAW Power already paid to discover them: camera support
arrives with macOS point updates (new bodies can wait months); no access to the mosaic, demosaic
choice, or intermediate stages; no custom camera profiles; highlight-reconstruction and NR behavior
opaque; rendering can drift with the OS (mitigated by pinned decoders + goldens, not eliminated).

### RawSource: the escape hatch is a protocol, designed now, built when needed

```swift
protocol RawSource {
    func metadata(for file: URL) throws -> RawMetadata
    func decode(_ file: URL, request: RawDecodeRequest) async throws -> SceneLinearImage
    // request: target scale, draft/full, WB override, decoder pin
}
```

`AppleRawSource` is implementation #1. `LumenRawSource` is #2, built only when Apple's ceilings
cost us image quality (the trigger conditions are in 16-roadmap.md): **LibRaw under CDDL-1.0** for
decode to the u16 mosaic + metadata — LibRaw is dual-licensed LGPL-2.1/CDDL-1.0, and CDDL's
file-level copyleft is the friendlier terms for a closed-source app — then our own Metal kernels:
per-channel black/white levels → WB → "inpaint opposed" highlight reconstruction (darktable's
robust default) → demosaic (**RCD** default; **LMMSE** for high ISO; **Markesteijn** for X-Trans)
→ dual-illuminant camera matrix from the DNG ColorMatrix model. Everything downstream of the RAW
stage is untouched by the swap — that is the entire point of the protocol. Stage-level detail
lives in 14-pipeline.md; the raw-domain denoise ambition that motivates the hatch most strongly is
in 07-spec-denoise.md.

## 7. Error handling & safety posture

- **Originals are read-only. Always.** Lumen opens source files with read-only intents, never
  writes into a RAW, and export never overwrites without an explicit flag. Edits are recipes;
  rendering is a pure function; there is no code path that can damage a source image.
- **Degrade, never die.** A corrupt or unsupported RAW renders its embedded JPEG with a visible
  badge stating exactly what happened ("decoder failed: unsupported compression") — never a crash,
  never a gray tile, never "Something went wrong." Honest error surfaces are a product rule
  (D30): every failure message names the component and the recoverable action.
- **Self-healing caches (D52).** Every derived artifact — previews, mask rasters, AI outputs,
  encoder embeddings — carries a version + checksum and is recomputable from (file, recipe). A
  stale, corrupt, or missing artifact is detected and rebuilt in the background; there is no user-
  facing "delete the cache folder" ritual. Lightroom's `.lrcat-data` folklore (users hand-deleting
  opaque cache folders to fix black AI masks) is the named anti-pattern.
- **Catalog safety** is owned by 15-catalog.md: WAL-mode SQLite, `VACUUM INTO` backups, XMP
  sidecars as the portable second copy of every edit. Architecture's contribution: catalog writes
  are serialized on one queue and no render/ML failure can leave a transaction open.
- **Isolation of the risky parts.** ML inference and RAW decode are the crash-prone surfaces; both
  run behind actors with per-job failure containment — one bad file or one failed inference skips,
  logs, badges, and the batch continues (darktable's per-image skip-and-continue rule).
- **No network, by architecture.** The app makes zero network calls except explicit, user-initiated
  model downloads from our own release assets (checksummed). No telemetry exists to disable.

## 8. Build & release

- **Repo = one Swift Package.** Xcode-free `swift build` CLI builds keep CI trivial; a release
  script produces the signed `.app`/DMG. Goldens, unit tests, and perf budgets all run under
  `swift test` + the headless CLI renderer — no simulator, no UI automation on the critical path.
- **CI gates.** Golden-image tests per pipeline stage (14-pipeline.md) and the five-loop
  performance gate (first-browse, grid scroll, slider drag, photo switch, AI round-trip — budgets
  defined in 12-spec-ux.md, D47) run on every merge. A feature that busts its loop doesn't ship;
  Lightroom 15.4's pulled release is the standing cautionary tale.
- **Ship-to-self weekly.** The owner runs the newest build on real shoots every week from Phase 1
  (16-roadmap.md). Dogfooding cadence is the antidote to both the Exposure failure (stagnation)
  and the ON1 failure (features outrunning the foundation).
- **Deployment target: macOS 15 Sequoia**, with an explicit API adoption ladder — the macOS line
  is 15 → 26 Tahoe → 27 (beta), and each rung is availability-gated, never a rewrite:

| macOS | APIs adopted | Role |
|---|---|---|
| 15 Sequoia (target) | CIRAWFilter (12+), Vision Swift requests (foreground/person masks, aesthetics scores), stateful Core ML, Adaptive HDR read/write (`.HDRImage` gain-map export), EDR display path | Baseline — everything in the plan works here |
| 26 Tahoe | Metal 4: `MTLTensor`, `MTL4MachineLearningCommandEncoder`, Shader ML | Performance tier: in-graph inference migration (section 5) |
| 27 (beta) | `GenerateIterativeSegmentationRequest` | Zero-download interactive masking becomes the default engine; bundled SAM 2.1 remains the fallback |

One user means the target can ride close to current macOS; the ladder exists so that riding it is
a per-feature `if #available` decision with a fallback, not a fork of the app.

---

**Sources note.** Stack and cache evidence: open-source deep teardown (RapidRAW 1.6.1, vkdt 1.0.0,
Ansel benchmarks vs darktable 5.0, darktable 5.6 AI subsystem). Platform facts: Apple developer
documentation (CIRAWFilter property surface, Vision requests, coremltools 8.x/9.0 releases,
Metal 4 / WWDC25), memory arithmetic from the imaging-tech digest. RAW Power/Nitro evidence: the
Mac-native editors survey. Full bibliography in 17-appendix.md.
