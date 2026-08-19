# 07 — Roadmap

## Honest sizing, first

A *full* Lightroom clone is a multi-year, multi-person project — darktable has ~20 years of commits. The reason Lumen is still realistic: we're one user on one platform, and macOS ships the three hardest subsystems (RAW engine, GPU imaging framework, segmentation models) ready to use. So the plan is shaped as **"usable for real culling in week 1, usable for real editing within a few weeks, better-than-LR-for-us after that"** — with every phase ending in something we actually use on real photos, so course corrections happen early, not after months.

Rule: **each phase has an exit test on real files from our own library.** We don't advance while the exit test fails.

## Phase 0 — This document set (done)

Everything researched and decided before code: scope, stack, pipeline design, data model, mask model, denoise strategy.

## Phase 1 — Walking skeleton (the "it's real" build)

Goal: open a folder of RAWs, see them, edit one with basic sliders, export a JPEG.

- App shell: SwiftUI window, three-pane layout (folder sidebar / center view / right panel), grid ↔ loupe switch.
- Folder scan (no catalog yet — in-memory), thumbnails from embedded RAW previews.
- Loupe: Metal-backed zoomable/pannable image view (this component is load-bearing for everything after — build it properly once).
- `CIRAWFilter` decode with sliders: exposure, temp/tint, highlights, shadows, NR on/off.
- Export current photo to JPEG (quality + long-edge resize).

**Exit test:** cull a real shoot's folder and export 5 edited JPEGs we'd actually post.

## Phase 2 — Catalog + non-destructive core

Goal: edits and culling survive restart; the data model from 06 exists for real.

- GRDB catalog, folder registration, background scan + FSEvents watching.
- Preview cache (thumb/grid/fit levels), embedded-preview fast path.
- Edit recipes persisted per photo + XMP sidecar writing; copy/paste settings.
- Flags/ratings/labels with LR keyboard mappings; filter bar; sort.
- Batch export with presets.

**Exit test:** import 5,000-photo archive; grid scrolls at 60fps; quit/relaunch loses nothing; cull a shoot start-to-finish faster than in LR.

## Phase 3 — The develop engine

Goal: our own adjustment stack downstream of Apple's RAW stage (see 03-imaging-pipeline.md); this is where Lumen's look starts being *ours*.

- Custom Core Image/Metal kernel chain in linear working space: tone region controls (highlights/shadows/whites/blacks done our way), point tone curve + per-channel, HSL 8-band mixer, vibrance/saturation, clarity/dehaze, vignette/grain.
- Sharpening with masking control.
- Crop/straighten UI with angle/level tool.
- History (undo ring) + snapshots; before/after views.
- Histogram (with clipping indicators) + R/G/B readouts.

**Exit test:** re-edit 10 previously-LR-edited photos; results as good or better to our eye; slider→screen latency <50ms at fit zoom.

## Phase 4 — Masking

Goal: LR-parity local adjustments (see 05-masking.md).

- Mask framework: mask = algebra tree of components → single-channel raster at working resolution; per-mask adjustment recipe applied through it.
- Linear gradient, radial gradient, brush (pressure-aware, feather/flow/erase) with vector stroke storage.
- Luminance range + color range masks with live preview overlay.
- AI: subject (Vision), background (invert), sky (Core ML segmentation model).
- Mask panel UI: list, overlay modes, add/subtract/intersect/invert.

**Exit test:** replicate 5 typical LR mask edits (sky darken, subject lift, background desat, radial vignette, brushed dodge) with equal or better results.

## Phase 5 — Denoise (flagship)

Goal: better *experience* than LR AI Denoise (see 04-denoise.md).

- Classic path shipped first: chroma NR + luminance wavelet/bilateral NR as pipeline stages (already partly available in Phase 1 via Apple RAW NR — this replaces it with controllable versions).
- AI path: Core ML denoise model (converted from an open pretrained model), tiled inference, applied as a **cached non-destructive pipeline stage** — no DNG duplicates, re-runs automatically if upstream RAW params change materially.
- Quality bake-off on our own high-ISO shots: classic vs AI vs LR reference exports.

**Exit test:** ISO 6400+ shots from our camera denoise in <10s and look better than our old LR exports.

## Phase 6 — Dailies & polish (ongoing)

Lens corrections beyond Apple's built-ins, defringe, color grading wheels, B&W mode, geometry sliders, healing brush, smart collections, second-monitor loupe, HEIF/AVIF export, DCP camera profiles, auto-tone, Super Resolution — pulled in **by annoyance-priority**: whatever we miss most while actually using Lumen gets built next. The backlog lives in GitHub issues from here on.

## Standing engineering rules

- Performance budget enforced from Phase 1: fit-view render <50ms, 1:1 pan never blocks, scan/preview generation never blocks the UI thread.
- Every pipeline stage gets a golden-image test (fixed RAW in `TestAssets/`, hash of output) so refactors can't silently change renders — this is what makes `pipelineVersion` honest.
- Real RAW test set: build a small corpus now — our main camera bodies, high-ISO samples, X-Trans if any, plus a few borrowed DNGs of other brands.
- Ship-to-self weekly: `build-app.sh`-style release build in Applications, used for real photos, from Phase 1 onward.
