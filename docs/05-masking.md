# 05 — Masking

Flagship feature #2. Target: Lightroom's masking panel semantics (the best UX in the business), implemented with darktable's engineering (the best-documented open implementation).

## The model (Lightroom semantics, adopted wholesale)

- A photo has a list of **masks**. Each mask = a stack of **components** combined with **add / subtract / intersect**, each component individually invertible.
- Component types: brush, linear gradient, radial gradient, luminance range, color range, AI subject, AI sky, AI background, AI object (click/box), AI person, depth range (later).
- Arbitrary combinations are first-class: "Sky ∩ luminance 0.6–1.0, minus a brush stroke" is the design's core test case.
- Each mask carries one set of local adjustment parameters (a subset of the global recipe: exposure, contrast, tone regions, temp/tint, saturation, clarity, sharpness, NR boost) applied through the mask's alpha.

## Engine design

```
component → float [0,1] buffer at working resolution
   drawn shapes: stored as vectors (strokes with pressure/hardness, gradient
     endpoints, radial ellipse), rasterized on demand at any resolution
   range masks: per-pixel function of the stage-3 image (see 03 for the
     luminance-reference decision), trapezoid range with soft shoulders
     (darktable's parametric-mask shape), color range in OKLab hue/chroma
   AI masks: cached raster at generation resolution, upsampled
        ↓  combine (add = max/union, subtract = min(a, 1-b), intersect = multiply, invert)
mask raster → refinement chain (darktable's order):
   guided-filter feathering (edge-aware snap to image edges — the critical step
     that makes 1024px AI masks crisp at full res; guided filter is O(N), GPU-cheap)
   → gaussian blur (softness)
   → levels/contrast curve on the mask
   → global opacity
        ↓
out = mix(base, adjusted(base, maskParams), mask)
```

Notes:
- Masks are computed at the pipeline point where local adjustments apply (stage 8 in 03), from that stage's input — so a mask never sees its own adjustments (no feedback).
- Mask overlay display modes: color overlay, white-on-black, black-on-white, image × mask — cheap shader variants of the same raster.
- Storage: vectors in the recipe JSON; AI rasters as compressed blobs in the cache, **regenerable** — and flagged stale when upstream pixels materially change (Adobe's "run Denoise before AI masks" ordering problem, solved by automatic invalidation instead of user discipline).

## AI components — what runs where

| Component | Engine | Cost | Notes |
|---|---|---|---|
| Subject | **Vision** `VNGenerateForegroundInstanceMaskRequest` (macOS 14+) | ~free, built-in | The single most-used AI mask, zero model shipping. Instance masks → tap to pick among multiple subjects |
| Background | invert of Subject | free | |
| Person | Vision person segmentation (+instance) | free | Body parts (hair/skin/teeth) are a later, separate model |
| Sky | dedicated sky-seg model (MIT `skyseg` ONNX → Core ML), fallback: semantic-seg "sky" class | small, <1s | Validate on sunsets/branches-against-sky, the classic failure cases |
| Object (click/box) | **SAM 2.1 tiny/small** (Apache-2.0, ~39–46M params) via Core ML | encoder ~1s once per photo (cached embeddings), decoder <10ms per click | The proven desktop pattern (darktable 5.6, AnyLabeling): encode once at 1024px, cache the three feature maps, run the tiny decoder per click with fg/bg points + previous low-res mask fed back for iterative refinement |
| Depth range | Depth Anything V2 **Small** (Apache) via Core ML | <1s | Relative depth map + range slider; V2 Base/Large are CC-BY-NC — off-limits |

All rasters from these run through guided-filter feathering at full res, which is what turns a 1024px segmentation into a mask that holds up at 100% zoom (darktable uses DenseCRF for the same purpose; guided filter is cheaper and GPU-native for us).

## Brush specifics (the fiddliest component — decisions up front)

- Strokes stored as timestamped point lists with pressure; parameters: size, feather (hardness falloff), flow (per-pass accumulation), erase flag. Rasterized as stamped radial-falloff discs along the smoothed (Catmull-Rom) path — replayable at any resolution.
- Auto-mask ("brush inside edges") = per-stamp color-similarity gate against the stamp-center color, computed on the stage-3 image — LR's auto-mask behavior.
- Tablet + trackpad pressure via NSEvent pressure; Wacom if available.

## UI plan

Right-panel mask list (LR-style): masks with visibility eye, component stacks expandable; canvas interactions per component type (drag gradient, two-axis radial, brush cursor with size/feather rings, click/shift-click/alt-click for SAM points); `O` toggles overlay, `alt+O` cycles overlay modes. Every mask op is a recipe mutation → undo/history for free.

## Build order (within Phase 4)

1. Engine + linear gradient (simplest raster) + per-mask adjustments end-to-end.
2. Radial + luminance range + refinement chain (feather/blur/levels).
3. Brush (vector store + rasterizer + auto-mask).
4. Color range + mask algebra UI (add/subtract/intersect/invert).
5. Vision subject/background/person.
6. Sky model, then SAM click-to-select (encoder caching infra shared with denoise's ML runner).
