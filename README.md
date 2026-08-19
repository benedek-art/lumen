# Lumen

A personal RAW photo editor for macOS. One user, one platform, no subscription: import → cull → develop (non-destructively, with first-class denoise and masking) → export.

Lightroom stopped earning its subscription for this workflow, so Lumen replaces it — not by cloning all of Lightroom, but by building the parts that matter for one photographer, better: instant culling, a develop engine with our own look, Lightroom-grade masking (including AI subject/sky/object selection), and local AI denoise measured in seconds with no duplicate files.

## Status

**Phase 0 — planning complete, no code yet.** Everything below is researched and decided; implementation starts at Phase 1 of the roadmap.

## Why this is feasible for one person

macOS ships the three hardest subsystems ready to use: Apple's GPU RAW engine (`CIRAWFilter`: decode, demosaic, lens corrections and camera color for essentially every mainstream camera), Core Image/Metal for a custom GPU pipeline, and Vision/Core ML for segmentation and local ML. Independent proof the overall shape works: RapidRAW (a solo developer shipped a usable GPU Lightroom alternative in ~6 months on maximal library reuse) and vkdt (full-res interactive compute-shader pipeline). Lumen takes the same shape — GPU pipeline, thin declarative UI, SQLite index, sidecar-mirrored edits — on Apple's runtime, in Swift, which is the stack we already build apps in.

## The plan

| Doc | Contents |
|---|---|
| [01 — Product spec](docs/01-product-spec.md) | Full Lightroom feature inventory → must/should/later/never; what "better than LR for us" means; non-goals |
| [02 — Architecture](docs/02-architecture.md) | Stack decision (Swift + Core Image/Metal + Vision/Core ML + SwiftUI), module layout, concurrency, safety |
| [03 — Imaging pipeline](docs/03-imaging-pipeline.md) | Scene-referred linear f32 pipeline, stage order, Apple RAW stage vs. our stages, escape hatch to a custom RAW source, golden-image testing |
| [04 — Denoise](docs/04-denoise.md) | Two tiers: classical profiled wavelet/NLM (live) + AI denoise as a cached non-destructive step; model bake-off protocol; license landmines |
| [05 — Masking](docs/05-masking.md) | LR mask semantics (component stacks + algebra) on darktable-style engineering; Vision subject masks, SAM 2.1 click-to-select, guided-filter refinement |
| [06 — Catalog & storage](docs/06-catalog-library.md) | SQLite schema, JSON edit recipes, XMP sidecars, preview cache, embedded-preview fast path |
| [07 — Roadmap](docs/07-roadmap.md) | Six phases, each ending in a build we actually use, with exit tests on real photos |
| [08 — Research notes](docs/08-research-notes.md) | Prior art, reusable libraries and licenses, vetted model zoo, sources |

## Roadmap at a glance

1. **Walking skeleton** — browse a folder, edit a RAW with basic sliders, export a JPEG.
2. **Catalog** — non-destructive persistence, culling workflow, preview cache, batch export.
3. **Develop engine** — our own tone/curve/HSL/clarity stack; the look becomes ours.
4. **Masking** — gradients, brush, range masks, AI subject/sky/background, mask algebra.
5. **Denoise** — profiled classical NR + local AI denoise, cached, benchmarked against LR.
6. **Dailies** — everything else, prioritized by what we miss while actually using it.

## Principles

- Originals are read-only, forever. Edits are recipes; rendering is a pure function.
- Scene-referred, linear, float, unbounded — one tone transform, at the end.
- Every pipeline stage lands with a golden-image test; rendering never changes silently.
- Local-only: no network calls, no telemetry, models run on-device.
- Ship-to-self weekly from Phase 1; annoyance drives the backlog.
