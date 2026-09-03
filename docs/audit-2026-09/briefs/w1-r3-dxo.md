# R3 — DxO PhotoLab + FilmPack (current releases)

Read `briefs/w1-common.md` first. Output: `docs/audit-2026-09/w1/r3-dxo.md`.

DxO is the raw-quality and lens-correction benchmark, and FilmPack is the closest
shipping analogue to Lumen's Film Lab (a physical negative→print model with halation and
grain). `docs/03` mentions DxO; go deep on everything below.

## Must cover
1. **DeepPRIME / XD2 / XD3** — what it does at the demosaic level, its controls
   (luminance, chrominance, dead pixels, maze, force details), speed on Apple silicon,
   when it runs (export only vs preview at 100%), the preview window.
2. **Lens modules** — what a module corrects (distortion, vignetting, CA, lens
   softness), how modules are fetched, the Lens Sharpness tool (global/detail/bokeh).
3. **ClearView Plus** — behaviour vs dehaze; halo behaviour.
4. **Smart Lighting** — modes (uniform/spot-weighted), the spot-weighted face boxes.
5. **Selective tone, Tone curve, Color rendering** (camera profiles, the DCP/"Color
   rendering" choices), **HSL** tool (the colour wheel with range/feather/uniformity).
6. **Local adjustments** — U Point control points (what "U Point" selection actually
   does), gradient/radial masks, brush, luminosity mask, the local adjustment mask
   manager, on-canvas equaliser.
7. **FilmPack** — the film stock list (negatives, slides, B&W, instant), how a stock is
   modelled (colour rendering + tone + grain), the **grain** model (intensity, size,
   the "grain from actual film scans" claim), halation? light leaks, vignette, texture,
   frames, "Time Machine". What does an emulation change: tone curve, colour, grain.
8. **Noise reduction (classic, HQ)** and **sharpening** controls and defaults.
9. **PhotoLibrary / culling** — rating/tag, the filter, the "Advanced History".
10. **Export** — recipes, formats, sizes, output sharpening, ICC, watermark.
11. **UI system** — the palette/customisation model, what dates or modernises it.
