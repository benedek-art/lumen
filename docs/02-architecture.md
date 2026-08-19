# 02 — Architecture & Stack

## Stack decision: native macOS (Swift + Core Image/Metal + SwiftUI/AppKit)

Chosen because it maximizes reuse of both **platform machinery** and **our existing skills** (GhostType is a Swift/SwiftUI macOS app):

| Need | macOS-native answer | What it saves us |
|---|---|---|
| RAW decode + demosaic + lens corr. for ~800 cameras | `CIRAWFilter` (Apple RAW, GPU, scene-referred controls) | The single hardest subsystem — years of camera-format work |
| GPU image pipeline | Core Image custom kernels (Metal Shading Language) with lazy graph fusion, tiling, and color management built in | A hand-rolled compute-shader scheduler |
| AI subject masks | Vision (`VNGenerateForegroundInstanceMaskRequest`, person segmentation) | Model sourcing/porting for the most-used mask |
| ML runtime for denoise/sky/SAM | Core ML (ANE/GPU), `coremltools` conversion from PyTorch/ONNX | Bundling and optimizing an inference engine |
| Fast RAW metadata/preview extraction | ImageIO (`CGImageSource`) | An EXIF library + preview extractor |
| Color management | ColorSync + Core Image working-space handling | ICC plumbing |
| UI | SwiftUI + AppKit escape hatches (`NSViewRepresentable`) + Metal loupe view | Known territory |
| Catalog | SQLite via GRDB.swift | — |

**Alternatives considered** (details in 08-research-notes.md): Rust/wgpu/egui — best portability story and proven viable (RapidRAW: Tauri + Rust + wgpu, a usable solo-dev Lightroom alternative in ~6 months; vkdt: the darktable author's Vulkan compute-shader DAG rewrite), but we'd own RAW decode (rawler is alpha-status), the Rust UI stack is the acknowledged weak link, and none of Apple's free ML comes along. Electron/WebGPU — best UI polish per hour, but 16-bit pixel handoff friction and a lower performance ceiling for 45MP interactive editing. C++/GTK fork of darktable — the Ansel cautionary tale: one person forking a ~1M-LoC GPL app stays in permanent alpha. Native macOS wins on time-to-usable *for this user* by a wide margin; the trade is zero portability, which the product spec already declares a non-goal. Notably, the industry-consensus shape those projects converged on — GPU compute pipeline, thin declarative UI, text sidecars, SQLite index — is exactly what we're building, just on Apple's runtime.

## Process & module layout

Single app process (Core Image schedules GPU work off-thread; heavy CPU work on structured-concurrency task groups). Swift Package with these targets:

```
LumenCore        — no UI. Catalog (GRDB), recipe model + codecs, XMP I/O,
                   scanning/watching, preview cache, export engine.
LumenPipeline    — no UI. The render graph: RAW stage wrapper, custom CIKernels,
                   mask rasterizer, denoise stages, color management, golden tests.
LumenML          — Core ML model wrappers: subject/sky/SAM segmentation, AI denoise,
                   tiled-inference utilities, model download/caching.
LumenApp         — SwiftUI/AppKit app: library UI, loupe (Metal), develop panels,
                   mask editing UI, export UI, keyboard system.
TestAssets       — small RAW corpus + golden outputs.
```

Dependency rule: `LumenApp → {LumenPipeline, LumenML, LumenCore}`, `LumenPipeline → LumenCore` (for recipe types) and nothing UI-ward. Everything in Core/Pipeline is testable headless (CLI test runner renders recipes → hashes).

## The render path (summary; full detail in 03-imaging-pipeline.md)

```
RAW file ──CIRAWFilter──▶ scene-referred linear CIImage
        (WB, exposure-in-raw, highlight recovery, demosaic, lens corr, optional NR)
   │
   ▼
[Lumen stages — custom CIKernels in linear working space]
   denoise (classic or AI, cached) → tone mapping & regions → curve → HSL →
   presence (clarity/dehaze/vibrance) → color grading → local: Σ(masked adjustments) →
   detail (sharpen) → effects (vignette/grain)
   │
   ▼
geometry (crop/rotate) ──▶ display transform (to screen profile)  — or —
                         ▶ export transform (resize, output sharpen, to sRGB/P3, encode)
```

Key properties:
- **One declarative recipe → one pure function of (file, recipe, targetSize)**. The same graph renders thumbnails, loupe, and exports; only target size/quality knobs differ. No separate "preview pipeline" to drift out of sync.
- Core Image graphs are lazy and fused; we rebuild the graph on parameter change and let CI re-render only what's needed. Interactive renders happen at view resolution (CI handles ROI), full-res only for 1:1 zoom, AI stages, and export.
- Expensive stages (AI denoise, AI mask rasters) are **cached artifacts** keyed by (photo, upstream-param fingerprint), not recomputed per slider move; the graph splices the cached texture in.
- Masks rasterize to single-channel `CIImage`s; each mask's adjustment sub-recipe renders as `blend(base, adjusted, mask)` — composition detail in 05-masking.md.

## Concurrency model

- **Main actor**: UI state, recipe edits (recipes are value types; an edit publishes a new recipe version).
- **Render actor** (per visible image): debounces recipe changes, owns the CI graph, renders into the Metal layer; cancels superseded renders.
- **Ingest actor pool**: folder scans, EXIF reads, preview generation (bounded parallelism, QoS background).
- **ML actor**: serializes Core ML jobs (models are memory-hungry; one at a time, progress-reporting, cancellable).
- Catalog writes go through GRDB's write queue; UI observes via GRDB observation → SwiftUI.

## Error-handling & safety posture

- Originals opened read-only, ever. Export never overwrites without an explicit flag.
- Catalog is WAL-mode SQLite with `VACUUM INTO` backups on quit (see 06).
- A corrupt/unsupported RAW degrades to its embedded JPEG with a badge, never a crash.
- All AI models run locally; the app makes zero network calls (model files ship in the bundle or are downloaded once from our own release assets, checksummed).

## Repo & build

- This repo (`lumen`) is the app: Swift Package (like GhostType) + `build-app.sh`-style release script producing a signed `.app`/DMG. Xcode-free CLI builds keep CI simple; goldens run via `swift test`.
- macOS 15+ target (gets newest Vision/Core ML APIs; we only run it on our own machine).
