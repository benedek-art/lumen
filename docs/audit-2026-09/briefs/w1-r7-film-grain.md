# R7 — film emulation & grain science

Read `briefs/w1-common.md` first. Output: `docs/audit-2026-09/w1/r7-film-grain.md`.

The owner has lifted the deferral on film & grain: *"film is researched enough that
emulating it would be pretty simple, and grain wouldn't be a large thing to do."* This
dossier feeds the C1/C2 audits and the W5 film/grain implementation stream directly, so
it must end in **buildable specifications**, not a survey.

## Lumen today (read before specifying)
- `Sources/LumenCore/Engine/FilmLab.swift` (1627 lines) — a physical model: negative
  characteristic curve → inversion → print curve, per-stock parameters, a halation
  profile. Read the stock table and the parameter struct.
- `Sources/LumenCore/Recipe/RecipeLook.swift` — `FilmLab{stock, amount, exposure,
  pushPull, halation, grain, printSize}` and `FilmGrain{size, amount}`.
- `Sources/LumenCore/Recipe/Recipe.swift` — `CreativeGrain{amount, size, roughness}`
  (a SECOND grain system, in Effects).
- `Sources/LumenPipeline/Kernels.swift` — `lumenGrain`, `lumenAddGlow`,
  `lumenHighlightEnergy`; `Sources/LumenPipeline/RenderGraph.swift` S13.
- `docs/05-spec-color.md` §Film Lab; `docs/31-defect-audit.md` round two #2 (Film Lab
  discards the display transform — a known S1).

## Part 1 — film emulation: the science, then a spec
1. The negative: characteristic (H&D) curves per dye layer, gamma, toe/shoulder,
   spectral sensitivity vs the camera's, cross-talk/inter-layer effects, colour
   couplers. The print: paper curves, print contrast grades, dye density → viewing.
   Where does "look" come from in each: colour shift (crossover), saturation, contrast.
2. The three implementation routes and their fidelity/cost: (a) 3D LUT captured from a
   real scan (Dehancer/RNI route); (b) curve + matrix model fitted to datasheets (the
   Kodak/Fuji published curves — list which datasheets are public: Portra 160/400/800,
   Ektar 100, Gold 200, Ultramax 400, Vision3 250D/500T, Fuji Pro 400H, Superia,
   Velvia 50, Provia 100F, Astia, Ilford HP5/FP4/Delta, Tri-X, T-Max; CineStill 800T);
   (c) spectral simulation (what Filmbox / "spectral film simulation" projects do).
   Which route is right for Lumen given the existing model, and what it needs added.
3. **Spec**: for each of ~10 stocks, the parameters Lumen's model needs (per-layer
   gamma, toe, shoulder, Dmin/Dmax, colour crossover, saturation, halation strength/
   colour/radius) with values or a method to derive them from public curves. State
   confidence per stock.
4. Push/pull: what changes physically (contrast, grain, shadows) → parameter deltas.
5. Halation: physics (anti-halation layer, red-orange, radius ∝ highlight energy),
   the threshold/radius/colour parameters; how Dehancer/Filmbox expose it; the
   right stage (before the print curve, on scene-linear).
6. Bloom vs halation vs "glow"; lens diffusion; light leaks — which belong in Film Lab.

## Part 2 — grain: the science, then a spec
1. Models: Newson, Delon, Galerne 2017 "A Stochastic Film Grain Model for Resolution-
   Independent Rendering" (Boolean model, grain radius, Monte Carlo); the Poisson
   photon-noise model; simple noise-texture multiplication (what most apps do); grain
   as a function of density (more in mid-tones, less in Dmin/Dmax); per-layer vs
   luminance grain; chroma grain; the effect of print scaling (grain size in mm on
   the negative → pixels at a given output size — `printSize` exists in Lumen for this).
2. Resolution independence: how to make grain identical at preview (1024–2560 px) and
   export (8000 px) — seed, scale, band-limiting; what Lumen's two systems do today.
3. **Spec**: the ONE grain system Lumen should have (merge `CreativeGrain` and
   `FilmGrain`, or keep two with a stated reason), its parameters (amount, size in µm
   or normalised, roughness/softness, luminance dependence, chroma), the algorithm for
   the GPU kernel (per-pixel, band-limited noise; how many octaves; how to get
   "clumping" without a Monte Carlo per pixel), where in the chain (after the print
   curve, before the display transform? in linear?), and a test that proves preview
   ↔ export parity and resolution independence numerically.
4. Defaults per stock family (ISO 100 / 400 / 800 / 3200; colour negative vs slide vs
   B&W) — values with a source or a stated derivation.

End with **"Buildable in 24h"**: the minimal subset that materially improves what the
owner sees, in priority order, with files to touch.
