# 03 — Imaging Pipeline

The technical core of Lumen. This doc fixes the pipeline order, the color architecture, and which stages come from Apple RAW vs. which we build. Background research (algorithms, references, prior art) is condensed here; sources in 08-research-notes.md.

## The one non-negotiable decision: scene-referred, linear, float, unbounded

Every serious modern pipeline (Lightroom internally, darktable since ~3.4, Ansel, RapidRAW) works **scene-referred**: pixel values stay proportional to scene light, linear, 32-bit float, allowed to exceed 1.0, from decode until a single display/tone transform near the end. Reasons, learned the hard way by darktable's decade-long migration:

- Physical ops (blur, sharpen, denoise, blends, masks' feathering) are only correct on light-linear energy values; on gamma-encoded data they produce halos and hue-shifted edges.
- A 12–14 EV RAW squeezed through an early tone curve destroys data every later stage could have used.
- Curves applied per-RGB-channel on nonlinear data twist hue and saturation uncontrollably.

Consequences for Lumen: every custom stage must tolerate values >1 and <0 (no clamping until output); "brightness" is primarily the linear exposure multiplier, not a curve; the tone curve and other display-referred-feeling controls live *after* the tone-mapping stage or are explicitly defined on log-encoded input; f32 working precision (f16 acceptable for masks and final display output only — f16's 10-bit mantissa bands in deep shadows after exposure pushes).

- **Working color space: linear Rec.2020.** darktable's choice, for good reasons: enormous but physically real gamut (unlike ProPhoto, whose imaginary primaries produce negative-energy values in math), and HDR export becomes a near-no-op. Perceptual spaces (OKLab) are used *inside* specific ops (HSL, color range masks) and converted back.

## Stage order

Fixed order, declarative recipe (see 06). Stages 1–2 are Apple's; 3 onward are ours.

```
 1. RAW STAGE (CIRAWFilter / Apple RAW — GPU, scene-referred)
      decode → black/white level → white balance → highlight reconstruction
      → demosaic (Bayer + X-Trans) → optional camera NR → lens corrections
      → camera color matrix → linear working RGB, exposure applied in-raw
 2. [optional cached splice] AI DENOISE — RAW-adjacent denoise, see 04
 3. TONE — exposure trim, contrast, highlights/shadows/whites/blacks
      (region controls built as EV-zone weighting à la darktable's tone equalizer)
 4. TONE MAP — sigmoid-style display transform (hue-preserving + per-channel modes)
 5. CURVE — point + per-channel RGB curves (defined on the tone-mapped, log-ish signal,
      where curves behave like photographers expect)
 6. COLOR — HSL 8-band mixer (in OKLab/HSV hybrid), vibrance/saturation,
      color grading wheels (later), B&W mix (later)
 7. PRESENCE — clarity (local contrast via guided/bilateral base-detail split),
      dehaze (dark-channel-prior-inspired), texture (mid-frequency band boost)
 8. LOCAL — for each mask: rasterize mask (05), apply its sub-recipe
      (a subset of stages 3–7 parameters), blend through mask alpha
 9. DETAIL — capture sharpening (unsharp on luma with edge masking; amount/radius/masking)
10. EFFECTS — post-crop vignette, grain
11. GEOMETRY — crop / rotate / straighten (sampled once, Lanczos)
12. OUTPUT — display: to screen profile via ColorSync
             export: resize (Lanczos) → output sharpen → convert to sRGB/P3/AdobeRGB → encode
```

Ordering rationale worth recording:
- Denoise before any contrast/sharpening (they amplify noise).
- Masks that reference luminance must specify *which* luminance; ours sample the **stage-3 output** (scene tone-adjusted, pre-tone-map) with log shaping so range sliders feel linear to the eye.
- Exactly one tone-mapping transform, ever. (darktable's "don't stack basecurve+filmic+sigmoid" lesson.)
- Sharpening after local edits so masked clarity doesn't double-sharpen halos; geometry last so all raster caches are crop-independent.

## What the Apple RAW stage gives us vs. what we control

`CIRAWFilter` (macOS, GPU, ~all mainstream cameras) exposes scene-referred knobs we map directly into the recipe: exposure, temperature/tint (and neutral-point), highlight/shadow extended-dynamic-range amounts, luminance/color NR, sharpness/detail/contrast booster, lens correction toggle, moiré reduction. Crucially it hands back a **linear scene-referred CIImage** we can keep processing.

This closes the hardest, least-differentiating 40% of the pipeline (format decoding for every camera brand, demosaic incl. X-Trans, per-camera color matrices, embedded lens profiles) on day 1. Its costs, so they're on the record:

- Rendering is Apple's, not bit-identical to Adobe's or darktable's. Fine — "our look" is defined by our downstream stages.
- Its parameter set is fixed; we can't insert custom code *between* its internal stages (e.g., our own highlight reconstruction or demosaic choice). The one real casualty: AI denoise can't run on the true pre-demosaic mosaic (see 04 for the mitigation).
- Behavior can shift across macOS releases → golden-image tests must pin macOS version expectations, and `pipelineVersion` gates any observed rendering change.

**Escape hatch (designed now, built only if needed):** a `RawSource` protocol with two implementations — `AppleRawSource` (default) and later `LumenRawSource`: LibRaw (LGPL/CDDL dual license) or darktable's rawspeed for decode to the u16 mosaic + metadata, then our own Metal kernels: per-channel black/white levels → WB multipliers → highlight reconstruction ("inpaint opposed" — darktable's robust default, cheap) → demosaic (**RCD** — near-AMaZE quality, compact ~600-line reference implementation, GPU-portable, darktable's default since 3.4; bilinear for preview LOD; LMMSE for high-ISO; Markesteijn ported for X-Trans) → camera matrix from the DNG `ColorMatrix1/2` dual-illuminant model (LibRaw ships the Adobe-derived coefficient table). Everything downstream of stage 2 is untouched by the swap — that's the point of the protocol.

## Implementation notes per custom stage

- **Kernels**: Core Image custom kernels in Metal Shading Language, one `.ci.metallib`. CI gives us lazy graph fusion, ROI-based tiled evaluation, and color-managed working space for free; we follow its extended-range linear working format (RGBAf/RGBAh, wide gamut).
- **Tone regions (h/s/w/b)**: implemented as smooth EV-zone weight functions on log2(luma) — the darktable tone-equalizer approach with a guided-filter luminance mask — not as curve segments; this avoids the classic halo/inversion artifacts.
- **Tone map**: sigmoid family (2–3 params: contrast, skew) rather than filmic's many-knob design; darktable's community consensus is sigmoid/AgX-style transforms are simpler and at least as good. AgX-style primaries "purity" control is a later addition. HDR export target = same transform aimed at PQ peak >1.0 (deferred, but the scene-referred core makes it cheap).
- **HSL**: hue-band weights computed in OKLab hue with smooth band overlap; luminance moves via chroma-preserving scaling to avoid the LR "luminance slider desaturates" artifact.
- **Clarity/texture/dehaze**: single shared base/detail decomposition (guided filter at two radii) feeding all three, computed once per render at working resolution.
- **Sharpening**: luma-only unsharp with an edge mask (threshold on local gradient — the LR "masking" slider); radius bounded ≤3px at capture stage; output sharpening is a separate export-time pass scaled to target size.
- **Histogram/scopes**: computed on a ~1MP proxy render of stage 10 output; clipping indicators from the same proxy; never from the full-res image.
- **Precision budget**: f32 intermediates; accumulations (blur sums, histograms) always f32; masks and final display surface f16/8-bit as appropriate.
- **Caching**: per-stage fingerprints — a slider in stage 6 only re-renders 6→12 (Core Image's graph gives some of this; we additionally pin materialized intermediates after expensive stages 2 and 8-inputs). This is the single biggest interactivity lever (darktable's per-module cacheline design).
- **Tiling**: interactive view renders only the visible ROI at screen resolution (CI does this natively); full-res passes (export, AI stages) tile with per-stage declared halo (e.g., blur radius) and overlap-discard stitching. Apple-Silicon unified memory raises the ceiling, but a 61MP f32 RGBA frame is ~1GB — tiling for export is not optional.

## Golden-image testing

Every stage lands with: a fixed test RAW (small crops from our corpus), a recipe exercising the stage, and a perceptual-hash + max-ΔE assertion on the output. Goldens re-baked only by an explicit script that bumps `pipelineVersion` when a change is intentional. This is what lets us refactor shaders without silently changing three years of edits.
