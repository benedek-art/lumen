# R5 — The creative bar: Luminar Neo · ON1 Photo RAW · Radiant Photo · Dehancer · Filmbox · FilmConvert Nitrate · RNI

Researched 2026-09-01 against briefs `w1-common.md` and `w1-r5-creative.md`. Read before this:
docs/02 (LrC 15.5), docs/03 §7.7–7.8 and §5 table (Luminar/ON1/Radiant/Exposure rows), docs/17 §B model zoo,
docs/00 §3 laws (Law 7 zero-chroma chrome, Law 3 first render is onboarding, Law 15 progress ladder).

**Access note.** `WebFetch` is egress-blocked on every vendor domain tried (dehancer.com, videovillage.com,
manual.radiantimaginglabs.com, support.skylum.com, on1.com). Everything below is from `WebSearch` result
summaries (tagged `[search: url]`), training knowledge (`[knowledge]`), or the repo (`[docs/nn]`). Exact
slider ranges and defaults for the vendor tools are therefore mostly **unverified**; where a range is given it is
`[knowledge]` unless tagged otherwise.

**Lumen ground truth used for the "Lumen would need" lines** (grep of `Sources/`, 2026-09-01):
- `Sources/LumenCore/Engine/FilmLab.swift` — Film Lab engine: negative curve → transmittance → print curve, each a
  per-channel sigmoid in log-exposure→density; six stocks (`lumen/portra400`, `gold200`, `ektar100`, `trix400`,
  `velvia50`, `cine250d`); per-stock `printCurve`/`printName` ("Lumen Type-C Paper", "Lumen Grade 2 Paper",
  "Lumen Print Film 2K"; Velvia has none), `halationStrength` RGB (Portra 0.050/0.015/0.000; Tri-X 0.040 neutral;
  Velvia zero), `FilmCrossover` (shadow/highlight/push tints, DIR `interlayer` 0…0.6, `coupler` −0.5…0.5),
  `GrainPlan` (line 1048), creative-grain roughness → octave persistence `0.25 + 0.005·roughness`.
- `Sources/LumenCore/Recipe/RecipeLook.swift` — `FilmLab{stock, amount 0…100, exposure, pushPull −1…+2, halation
  0…100, grain{size (1.0 = stock), amount 0…100}, printSize?}`; `Look.vignette` (EV) + `vignetteFeather`;
  `Look.grain: CreativeGrain?` (amount/size/roughness 0…100, `Recipe.swift:986`); `Look.lut: LUTReference?`
  (`ref`, `name`, `tap: display|log`, `amount 0…100`); `RenderParams.preset` Neutral/Soft/Punchy/Film Base/Linear
  with contrast/skew/hue keep/black target; `GradingWheels` (global/shadows/mid/high + blending/balance/pivots);
  `PrinterLights` master/r/g/b; `Primaries`; `BlackAndWhite` 8 bands.
- `Sources/LumenApp/LookPanel.swift` — Film Lab UI rows: Stock picker, Strength, Film Exposure, Push / Pull,
  Halation, Grain, Grain size; "Saved Looks" = name field + Save + row list (`LookSubset` extract/apply-to-all).
- `Sources/LumenApp/EffectsPanel.swift` — Vignette (EV, feather) and Grain (stock rows or creative rows).
- `Sources/LumenPipeline/VisionMattes.swift` — `VNGenerateForegroundInstanceMaskRequest` + person segmentation only;
  `MaskKind.aiSky/.aiObject/.aiLandscape` are enumerated in `MaskPanel.swift` but no sky/object model is wired.
- `Sources/LumenCore/Image/DenoiseEngine.swift` — classical VST + à-trous wavelet tier plus an "S2 AI splice" slot.
- **Absent in `Sources/`**: bloom (only a comment in `Kernels.swift:424`), any LUT import/apply UI for
  `LUTReference`, layers/blend modes/opacity, preset thumbnails or hover preview, a print-stock picker separate from
  the negative, CMY colour head, film damage/gate weave/overscan (docs/03 says avoid), scene-classified auto.

---

## A. Tone & sliders

| Capability | How it works | Source | Lumen would need |
|---|---|---|---|
| Luminar **Enhance AI** | One "Accent AI" slider (0–100) drives up to ~12 hidden adjustments (shadows, highlights, contrast, tone, saturation, exposure, details); a second "Sky Enhancer AI" sub-slider adds sky clarity/contrast only where a sky is detected. Presented as the first thing in the Essentials tool list. | [search: https://skylum.com/luminar/enhance-ai], [search: https://fstoppers.com/lightroom/move-over-lightroom-luminar-neo-one-704484] | A content-aware "auto" that is a *single visible slider* rather than a button; Lumen has per-slider auto (Law 19) but no one-slider scene enhancer. |
| Luminar **Relight AI** | Builds a monocular depth map, then exposes **Brightness Near**, **Brightness Far**, **Depth** (the near/far split point), **Dehalo** (feathers the depth edge, protects hair), **Warmth Near** (−cool/+warm foreground). Runs locally; "optimized for better performance" in 2026. | [search: https://support.skylum.com/editing-tools/creative-tools/relight-ai], [search: https://skylum.com/whats-new/luminar-neo] | Depth-Anything-V2-Small is already in the docs/17 zoo for depth masks; Relight = depth mask × exposure with a feather control. Lumen has no depth model wired in `Sources/`. |
| Radiant **scene-aware auto** | On open, classifies the photo into one of 13 scenes and applies a per-scene Develop Setting; scene rules are contextual (nightscapes keep the black point; golden hour keeps the warm cast; faces get face-aware exposure and backlight relighting). Override = pick another Smart Preset from the scrollable list, then a strength slider under the picker. Claimed 96% scene accuracy, all local. | [search: https://shotkit.com/radiant-photo-smart-presets/], [search: https://manual.radiantimaginglabs.com/1/en/topic/available-smart-presets], [docs/03 §5 Radiant row] | Lumen's auto is visible/reversible per docs/04 but has no scene classifier and no "strength of the auto" slider. `Vision` `CalculateImageAestheticsScoresRequest` is the only OS classifier referenced in docs/17; no scene model in `Sources/`. |
| FilmConvert Nitrate **Level / Mid Point** | Level sets black/white clip points; **Mid Point** slider sets where mid-grey lands *before* the film curve, i.e. an exposure-into-the-stock control; separate **Exposure**/Temp/Tint applied pre-emulation. | [search: https://jonnyelwyn.co.uk/film-and-video-editing/understanding-film-emulation-with-filmconvert-nitrate/] | Lumen's `FilmLab.exposure` ("Film Exposure") is the same idea — present. |

## B. Colour & grading

| Capability | How it works | Source | Lumen would need |
|---|---|---|---|
| Dehancer **CMY Color Head + Print Toning** | Emulates enlarger dichroic filtration: C/M/Y density sliders applied at the *print* stage (subtractive; moving Y warms the whole print in density space), plus Print Toning for tint/split-tone. | [search: https://www.dehancer.com/learn/article/film-profiles], [search: https://www.dehancer.com/learn/article/film-compression], [docs/03 §7.8] | Lumen has `PrinterLights` (RGB points) in the Look, which is the additive-domain cousin; a CMY head *inside the print stage* of `FilmChain` is absent. |
| Dehancer **Film Developer** | One tool controlling gamma curve, contrast, fog, graininess and saturation as if changing developer/time — "simplify interpretation of a variety of sources within a single node". | [search: https://www.dehancer.com/learn/articles/dehancer-film-developer] | Lumen couples contrast+grain+crossover via `pushPull` (−1…+2 stops) — partial; no fog/Dmin control exposed. |
| Dehancer **Film Compression** | Highlight roll-off tool: **Impact** (pushes highlights toward mids), **White Point** (default 100; lower = more contrast in the compressed range), **Tonal Range**, **Color Density**. | [search: https://www.dehancer.com/learn/article/film-compression] | Lumen's negative shoulder is the stock's `FilmCharacteristic`; no user-facing shoulder/compression control. |
| Nitrate **Film Color / Film Curve** | Two sliders separate the stock's *chroma* from its *tone curve* (0–100 each); on log profiles they become "Film Color" + "Cineon-to-print" emulation. Three colour wheels (Shadows/Mid/High) and Saturation live *after* the stock. | [search: https://jonnyelwyn.co.uk/film-and-video-editing/understanding-film-emulation-with-filmconvert-nitrate/], [search: https://postperspective.com/review-filmconvert-nitrate-for-film-stock-emulation/] | Lumen has one `FilmLab.amount` (Strength) blending the whole stock; no colour-vs-curve split. |
| Luminar **Mood (LUT)** | Loads .cube LUTs; only **Amount**, **Contrast**, **Saturation** are adjustable; built-in "Mood" packs. | [search: https://support.skylum.com/editing-tools/creative-tools/mood-lut], [search: https://www.mathewbrowne.co.uk/the-ultimate-guide-to-luts-in-luminar-neo/] | `LUTReference{tap, amount}` exists in the recipe model but **no UI** and no import path found in `Sources/LumenApp`. |
| Radiant **Looks** | "Color Grading" section is a Looks collection, each a LUT; third-party .cube can be dropped into **My Looks**; applied as a finishing step after the scene auto. | [search: https://manual.radiantimaginglabs.com/1/en/topic/color-grading] | Same gap as above. |
| RNI All Films 5 | 180+ simulations (B&W, Infrared, Instant, Negative, Slide, Vintage); since v5 each preset assigns a **camera profile** (a DCP with an embedded look table) with the profile **Amount** adjustable, plus a "toolkit" of stackable grain/fade/vignette/contrast presets. Fixed display-referred; no spatial phenomena. | [search: https://reallyniceimages.com/products/rni-all-films-5-pro-for-adobe-lightroom.html], [search: https://www.sebastian-schlueter.com/blog/2020/1/22/rni-all-films-5-review], [docs/03 §7.8] | Nothing to take structurally (docs/03 verdict stands); the *toolkit* idea — small stackable finishing presets — maps to Saved Looks + Effects. |

## C. Film & grain

### C.1 Film-emulation approach per product

| Product | Model type | User controls (as reported) | Source |
|---|---|---|---|
| **Dehancer** | "Profiled characteristic curves, not LUTs" — film profiles measured from real negatives *and darkroom prints* via colorimetry/densitometry; each stock captured at 3 exposures and Push/Pull interpolates between them. Chain order in the panel: camera log/input profile → Film Profile (60+) → Exposure → Push/Pull → **Film Developer** → **Film Compression**/Expand → **Print** (print films Kodak 2383, Fujifilm 3513; photo papers Kodak Endura, Bromportrait) → CMY Color Head + Print Toning → Halation → Bloom → Grain → Film Breath → Gate Weave → Film Damage → Overscan → Vignette → Defringe; Monitor tools (false colour, clipping). | Push/Pull (stops, from 3 captured exposures), Print on/off + stock, CMY head, Developer (gamma/contrast/fog/graininess/saturation), Compression (Impact, White Point=100, Tonal Range, Color Density), halation/bloom/grain sections (below), Breath, Gate Weave (Impact), Damage (Dust/Hair/Scratches with per-format Tool Profiles), Overscan (8/16/35/65 mm gates+perforations), Vignette. **No bleach bypass** found. | [search: https://www.dehancer.com/features], [search: https://www.dehancer.com/shop/dehancer-photo], [search: https://blog.dehancer.com/articles/film-breath-and-gate-weave/], [search: https://www.dehancer.com/learn/article/damage], [docs/03 §7.8] |
| **Filmbox Pro 3.x** (Video Village) | Empirical photochemical pipeline: the whole colour path is built from an actual **contact print of 250D onto 2383**, characterized with a custom scanner rig under a broad-spectrum illuminant; spatial layer (grain, dust, halation, gate weave) modelled from test patterns shot on S35 250D and scanned on an Arriscan. Not a LUT on the finished frame. Negative stocks: Vision3 50D/200T/250D/500T (+ Ektachrome with print modes "Extended"/"Standard"/"Full"). **Lab module**: Neutralize, Defog (de-ages discontinued stocks). Multi-node: split into negative-only and print-only nodes and grade between them "like a film-scan DI". | Few controls by design; grain and halation sections below; gate weave + procedurally placed real dust samples. | [search: https://videovillage.com/blog/2025/08/18/filmbox-pro], [search: https://videovillage.com/filmbox/], [search: https://postperspective.com/review-video-villages-filmbox-pro-film-emulation-ofx-plugin/], [docs/03 §7.8] |
| **Filmbox Looks** (Oct 30 2025) | Same engine, packaged as **101 photochemical presets** with a streamlined panel; projects open in Pro without conversion. Hosts: Resolve, Baselight, Premiere, After Effects (no Lightroom host found). | Preset + a small grading panel. | [search: https://videovillage.com/blog/2025/10/30/filmbox-looks], [search: https://videovillage.com/filmbox-looks/] |
| **FilmConvert Nitrate 3.x** | Curve+matrix model per (camera profile × stock): 100+ camera/shooting-profile packs map the sensor response onto the stock's measured response; full **custom curve controls per stock** (edit highlight/shadow roll-off per channel, "design your own stock"). Grain from real scans (below). Halation added May 2024. | Film Size (Super 8 → 35 mm Full Frame), Film Color, Film Curve, Exposure, Temp/Tint, Level (Blacks/Whites/Mid Point), 3 wheels, Saturation, Grain, Halation. **Bleach bypass** not found as a control. | [search: https://www.filmconvert.com/nitrate], [search: https://digitalfilms.wordpress.com/2024/05/19/filmconvert-nitrate-adds-halation/], [search: https://jonnyelwyn.co.uk/film-and-video-editing/understanding-film-emulation-with-filmconvert-nitrate/] |
| **RNI All Films 5** | LUT-in-a-DCP + preset stack (see B). No spatial layer. | Profile Amount; toolkit presets. | [search: https://www.sebastian-schlueter.com/blog/2020/1/22/rni-all-films-5-review] |
| **ON1 Effects "Film Grain"** | Grain *overlay* from real scans of named Kodak/Ilford/Fujifilm stocks; film-type dropdown + sliders. **"Vintage"** filter: pick a colour from a Color menu, Amount, Saturation, plus its own Film Grain sub-section. Both are stack filters with blend mode + mask. | Film type, Amount, Size (ranges unverified). | [search: https://www.on1.com/blog/8-must-have-photo-effects-and-filters-to-enhance-your-photos/], [search: https://scottdavenportphoto.com/blog/the-vintage-filter-on1-photo-raw] |
| **Luminar Neo "Film Grain"** | Procedural stylised grain: **Amount**, **Size**, **Roughness** — the Lightroom triple. LUT looks via Mood (see B). | 3 sliders | [search: https://support.skylum.com/editing-tools/creative-tools/film-grain] |
| **Lightroom Classic** | Amount 0–100 (0), Size (25), Roughness (50); monochrome luminance noise late in the pipe; at Size ≥ 25 a slight blue-channel component is added so the grain interacts with NR more naturally. | [docs/02 §Effects, line 421], [search: https://legendarypresets.com/realistic-film-grain-without-losing-detail/] | — |

**Lumen would need (C.1):** a **print-stock picker independent of the negative** (Dehancer/Filmbox both let you
print Portra onto 2383 or Endura; Lumen binds one `printCurve` per stock); a **Filmbox-style "Lab" pair**
(Neutralize/Defog) which is one Dmin/base-fog slider Lumen's `FilmCharacteristic.dMin` could expose; a
**colour-vs-curve split** (Nitrate); nothing for gate weave/damage/overscan (docs/03 "avoids"). Present: exposure
into the stock, push/pull coupling, per-stock halation, print stage, six deep stocks.

### C.2 Grain models

| Product | Mechanism | Tonal dependence | Chroma | Resolution / size anchor | Where in chain | Source |
|---|---|---|---|---|---|---|
| **Dehancer** | Physical emulsion modelling — "the image itself entirely consists of grain": reconstructs the frame from local colour/brightness plus an emulsion model; profiles for **8/16/35/65 mm × ISO 50/250/500** (12 profiles); custom mode exposes size, amount, resolution and "where it is most pronounced" (shadows/mid/highlights weighting). | Yes — user-weighted across tonal range | Per-channel ("three-dimensional quality", reviewers) | Anchored to film format; scales with frame | After print, before vignette (panel order) | [search: https://www.dehancer.com/learn/article/grain], [search: https://ricksreviews.org/blog/2024/09/17/full-review-about-dehancer-film-emulation/], [search: https://blog.dehancer.com/articles/dehancer-tool-profiles/] |
| **Filmbox Pro** | Sampled from real scans: reproduces "the tonal distribution of grain across the density of each channel of the negative", structural + temporal qualities, and large-scale development effects. Controls: global intensity, **dye-cloud colorfulness**, mix film-stock characteristics, structure (softness, mid-frequency, streakiness, anamorphic desqueeze), **9-zone fader** distributing intensity across tone. | Yes — 9-zone fader over density | Yes — "dye cloud colorfulness" slider | Modelled at S35 gate from Arriscan patterns; resolution-independent via the pipeline model | Part of the negative stage (before print node) | [search: https://videovillage.com/filmbox/], [search: https://www.newsshooter.com/2021/05/05/video-village-filmbox/] |
| **FilmConvert Nitrate** | Real grain scans; 8 sizes (8 mm … 35 mm Full Frame) selected by Film Size; models "the amount of grain required for each colour and exposure". **Grain response curve** = separate strength in shadows/mids/highlights; plus size, softness, strength, **saturation** of grain particles. | Yes — 3-point curve | Yes — grain saturation slider | Anchored to emulated film size | After the stock curve | [search: https://www.filmconvert.com/nitrate], [search: https://postperspective.com/review-filmconvert-nitrate-for-film-stock-emulation/] |
| **Lightroom / Luminar / ON1** | Screen-space noise overlay (LR, Luminar) or scanned plate overlay (ON1); tonal weighting only via LR's Size/Amount interaction | Weak / none | LR: mono + slight blue at Size ≥ 25 | Pixel-anchored (changes with export size) | Last | [docs/02], [search: https://legendarypresets.com/realistic-film-grain-without-losing-detail/] |
| **Lumen** | Density-domain plate modulated by p(1−p) (peaks mid-density), per-channel scale; creative grain roughness → octave persistence 0.25…0.75; size anchored to a 35 mm gate and `printSize`; stock grain vs creative grain with `GrainPlan.filmOwnsTheGrain` precedence. | Yes, by construction | Yes (per-channel plate) | Gate/print-anchored | Density domain after the curve | `FilmLab.swift`, `EffectsPanel.swift`, [docs/03 §7.7] |

**Lumen would need (C.2):** a **tonal-distribution control** (Nitrate's 3-point curve or Filmbox's 9-zone
fader) — Lumen has none, the p(1−p) shape is fixed; a **grain chroma/"dye-cloud colorfulness"** slider — the
per-channel scale exists in the model but is not user-facing; **format presets** (8/16/35/65 mm) as named sizes
instead of a bare "Grain size" ratio. Linear-vs-print: Dehancer, Filmbox, Nitrate and Lumen all apply grain
*after* the characteristic curve (density/print domain), never in scene-linear — consistent with docs/03 §7.7.

### C.3 Halation and bloom

| Product | Halation | Bloom | Where | Source |
|---|---|---|---|---|
| **Dehancer** | Red/orange halo from the emulsion. Controls: **Source Limiter** (brightness of light source that triggers it; low = more halation), **Background Gain** (lets halation appear over most backgrounds), **Smoothness** (softer halos), **Local Diffusion** (spread from edge = halo size), **Amplify** (strength + orange colouration). Profiles per format incl. "No Remjet" (CineStill-style) variants. | Optical + emulsion glow around bright areas: **Threshold (Highlights)** (brightness from which bloom is sourced; higher = wider highlight range), **Size** (small = thin foliage vs sky, large = big sources), plus amount/softness. Bloom profiles per 8/16/35/65 mm. Vendor guidance: use both together. | Separate sections after Print, before Grain; also sold as separate Halation/Bloom/Grain node plugins | [search: https://www.dehancer.com/learn/articles/halation-in-dehancer], [search: https://www.dehancer.com/learn/article/bloom], [search: https://blog.dehancer.com/articles/separate-plugins/] |
| **Filmbox Pro** | Independent **spatial size, opacity, colour balance, saturation, and "characteristic amber glow"**; modelled from S35 250D test patterns. | Not a separate "bloom" control found; the print/scan softness is part of the spatial model. | Inside the negative model (pre-print) | [search: https://videovillage.com/filmbox/] |
| **FilmConvert Nitrate** (2024) | Red-layer bounce model: **Enable**, **Sensitivity** (threshold), **Boost** (usually 0; adds strength where present), size/spread, and sliders to dial back the **red fringing**; "view isolated halation" toggle. | none | After stock curve | [search: https://digitalfilms.wordpress.com/2024/05/19/filmconvert-nitrate-adds-halation/], [search: https://www.filmconvert.com/plugin/halation] |
| **Resolve Film Look Creator** | halation + bloom sections in one panel | yes | after tone | [docs/03 §7.6] |
| **Lumen** | Single **Halation** slider 0…100 scaling a per-stock RGB strength (red-dominant, e.g. 0.050/0.015/0; Tri-X neutral; Velvia 0), applied pre-curve on linear light (S13). No size/threshold/colour controls. | **Absent** (comment only in `Kernels.swift:424`). | Pre-curve (Law-correct) | `FilmLab.swift:161,244,451` |

**Lumen would need (C.3):** a **Bloom** op (threshold + radius + amount, achromatic, post-curve — the "optical"
glow Dehancer distinguishes from emulsion halation); halation **size** and a **"No Remjet"/redness** control
(`FilmStock.halationRedness` exists in the model, not in the UI); an **isolated-halation view** (Nitrate) as a
viewer overlay. Difference to hold: halation = red-dominant, source-thresholded, pre-development; bloom =
achromatic, wide, post-print — Dehancer's vendor doc states them as distinct phenomena and recommends both.

## D. Looks / presets & effects

### D.1 Presets UX matrix

| Product | Live thumbnails on *your* image | Hover preview on main image | Amount/strength | Favourites / packs | Apply on import | Other | Source |
|---|---|---|---|---|---|---|---|
| **Luminar Neo** | Yes (preset cards rendered on the photo) | Yes — "hover over its presets to see a preview before applying" | Yes — strength slider on the applied preset; presets are "saved starting points", every tool stays editable | Heart icon → Favorites; categories; **"For This Photo"** AI-suggested category | Not found; batch via **Sync Adjustments** after edit | Aug 2026 redesign unified Catalog+Edit | [search: https://manual.skylum.com/neo/en/topic/browsing-and-applying-presets], [search: https://blog.skylum.com/luminar-presets/], [search: https://skylum.com/whats-new/luminar-neo] |
| **ON1 Photo RAW 2026** | Yes — previewed on the working image in every module incl. Browse; **module badges** on each thumbnail; new **full-screen preview** mode | Not native — a user feature-request "Hovering over presets" exists on ON1's ideas board | Preset is a filter stack; per-filter Opacity/blend rather than one preset amount (unverified) | Presets Manager (import/export/organise); tag go-to filters, hide unused; **AI Style Advisor** learns habits; **AI Adaptive Presets** carry AI masks; UI presets to mimic LR/C1 layout | Feature-request "Apply preset from Favorites when importing" exists → absent as of the request | Sync Settings / batch | [search: https://www.on1.com/blog/on1-photo-raw-a-new-way-to-work-with-presets/], [search: https://www.on1.com/products/photo-raw/ideas/idea/hovering-over-presets/], [search: https://www.on1.com/products/photo-raw/ideas/idea/apply-preset-from-favorites-when-importing/], [search: https://www.on1.com/products/photo-raw/features/] |
| **Radiant Photo 2** | Smart Preset picker is a scrollable list (thumbnails) | — | **Strength slider** under the picker scales the whole auto | Develop Collections per scene; Workflows (e.g. Portraiture) | The auto *is* applied on open; smart batch export | Looks (LUT) as finishing | [search: https://manual.radiantimaginglabs.com/1/en/topic/smart-presets-presets], [search: https://photofocus.com/photography/kicking-the-tires-on-the-new-radiant-photo-v2/] |
| **Dehancer** | Film-profile list (no per-image thumbnails reported) | — | Per-section on/off + amount | Profiles as packs (film, print, grain, halation, bloom by format) | n/a (plugin) | | [search: https://www.dehancer.com/features] |
| **Filmbox Looks** | 101 presets | — | — | — | n/a | | [search: https://videovillage.com/blog/2025/10/30/filmbox-looks] |
| **LrC 15.5** | Yes; hover live preview; Amount 0–200 | Yes | Yes | Folders, per-camera/ISO defaults, adaptive presets | Yes | | [docs/02 §2.20] |
| **Lumen** | **No thumbnails** — Saved Looks is a text list with a name field + Save | **No** (no hover-preview code found) | No amount on a saved look (`LookSubset.applied` is all-or-nothing) | No favourites/packs | No | Apply-to-all via `LookSubset.applied(toAll:)` | `LookPanel.swift:175–215`, `LookSubset.swift` |

**Lumen would need (D.1):** per-look **thumbnails rendered on the current photo** (small `RenderPlan` at
thumbnail size), **hover-to-preview** on the loupe, a **look Amount** (blend the Look subset toward the current
recipe — the `LUTReference.amount` pattern generalised), favourites + packs, and an apply-on-import hook.

### D.2 Effects stacks and layers

| Capability | How it works | Source | Lumen would need |
|---|---|---|---|
| **ON1 Effects stack** | 30+ filters (Dynamic Contrast, Vintage, Grunge, Film Grain, LUTs, Textures, Sun Flare, Glow…) stacked as ordered layers; each filter has its own **blend mode**, **opacity**, and **mask** (AI, brush, gradient, luminosity, line, colour range, depth); a stack-level mask above the top filter; "Apply To" luminosity/colour-range blending options per filter `[knowledge]`. 2026 added four new filters and favourites/hide in the filter chooser. | [search: https://www.on1.com/products/photo-raw/features/], [search: https://lifeafterphotoshop.com/how-to-mask-effects-in-on1-photo-raw/], [search: https://www.on1.com/blog/announcing-on1-photo-raw-2026-with-advanced-ai-tools-masking-layers-and-creative-filters/] | Lumen has fixed staged ops with per-stage masks (docs/14); no reorderable stack, no blend modes, no per-effect opacity. |
| **Luminar layers** | Image/texture layers with **Layer Properties**: Opacity slider and Blend Mode; masks per layer; Spring 2026 "enhanced Mask Feathering". Adjustments are non-destructive per layer. | [search: https://support.skylum.com/editing-tools/layers/layer-properties], [search: https://skylum.com/whats-new/luminar-neo] | Not on Lumen's roadmap; note only. |
| **Vignette** | LR: post-crop with Highlight/Color priority; Dehancer: vignette after grain; Luminar: Vignette tool with placement. | [docs/02], [search: https://www.dehancer.com/features] | Lumen: EV-denominated amount + feather — present, arguably better-specified. |

## E. Denoise & sharpening

| Capability | How it works | Source | Lumen would need |
|---|---|---|---|
| **ON1 NoNoise AI 2027** (announced Aug 2026, ships late Sept 2026, $70 / $50 upgrade) | Rebuilt inference engine, **AI Model Selector** — models tuned for wildlife, people, astrophotography, **scanned film**; new **TackSharp AI** deblur; "no cloud lock-in, no data mining"; native Windows-on-ARM; vendor hardware acceleration. Model sizes not published. | [search: https://www.dpreview.com/news/on1-nonoise-ai-2027-announcement/], [search: https://www.on1.com/blog/new-on1-nonoise-ai-2027-ai-noise-reduction-tacksharp-ai-model-selector/] | Lumen's `DenoiseEngine` is classical + an AI splice slot; a *subject-class model selector* is a UX idea worth noting for docs/07's bake-off (one model per task, user-visible). |
| **Luminar Noiseless AI / Supersharp AI / Upscale AI** | Extensions; Supersharp uses classical sharpening + a GAN for detail fill; Upscale to 6×; all local ("more demanding on hardware"). Sizes not published. | [search: https://skylum.com/luminar-for-intel], [search: https://www.travishale.com/noise-reduction-sharpening-luminar-neo/] | — |
| **Luminar Structure AI** | Local-contrast/detail slider that **excludes detected people** (and skin) automatically. | [search: https://skylum.com/product-tour] | Lumen: Clarity/Texture via local Laplacian (docs/06) + person matte exists in `VisionMattes` — a "protect people" toggle on Clarity is a one-mask wiring job. |

## F. Masks

| Capability | How it works | Source | Lumen would need |
|---|---|---|---|
| **ON1 Super Select AI** | Tap any object → instant selection, including *sub-components* of an object (a rock, a tree); selection feeds an adjustment or effect layer. Local. | [search: https://www.on1.com/videos/sneak-peek-at-the-new-super-select-ai-coming-in-june/], [search: https://www.on1.com/products/photo-studio/features/] | Lumen: SAM-2.1-small click-to-select is specified (docs/08) but `VisionMattes.swift` implements only foreground-instance + person. |
| **ON1 Sky Swap AI** (Photo RAW 2026.5, July 2026) | Sky replacement with foreground relighting. | [search: https://www.on1.com/blog/july-2026-on1-recap-sky-swap-photo-raw-2026-5/] | Out of scope (generative replacement); but the **sky matte** is needed — `MaskKind.aiSky` is enumerated, no model wired. |
| **Luminar Sky AI** | Sky mask + replacement; sliders: **Horizon Blending**, Horizon Position, **Relight Scene** (matches foreground to sky colour temperature), **Sky Global** (mix amount), Sky Local, Close Gaps, **Defocus**, Flip, Grain, Atmospheric Haze, Warmth, **Reflection Amount** (water). Mask is still called best-in-class for skies (docs/03). | [search: https://manual.skylum.com/neo/en/topic/sky-ai-tool], [search: https://support.skylum.com/editing-tools/landscape-tools/sky-ai], [docs/03 §5] | A sky model (docs/17 lists skyseg/InSPyReNet). |
| **ON1 mask kinds** | AI (Super Select), brush, gradient, luminosity, line, colour range, depth; per-filter and stack-level. | [search: https://www.on1.com/products/photo-studio/features/] | Lumen has brush/gradient/luminosity/colour/AI subject/person (docs/08, `MaskPanel.swift`); "line mask" (linear gradient by drawn line) is the same as gradient. |

## G. UI / UX — what makes each feel modern or dated (one paragraph each)

**Luminar Neo.** Dark, near-black chrome with large rounded tool cards, a vertical tool list grouped by category
(Essentials / Creative / Portrait / Professional) each with a coloured icon, and one big slider per AI tool —
the "one slider does twelve things" pattern is the product. Reviews describe it as "clean and simple", "easy to
understand tool icons", and the August 2026 update replaced the Catalog/Edit tab split with a **single unified
workspace** ("significantly less friction"). Presets are image-rendered cards with hover preview and a heart for
favourites; the Relight/Sky tools onboard by doing something dramatic on first click (Law 3 in the wild). What
dates it: the coloured icon set violates Law 7 and the tool list is a long scroll; historic complaints are slider
lag and RAM (docs/03 §5). [search: https://www.nomadasaurus.com/luminar-neo-review/], [search: https://skylum.com/whats-new/luminar-neo], [docs/03 §5]

**ON1 Photo RAW 2026.** Feature density is the identity: Browse/Edit modules, a right-hand stack of Develop /
Effects / Portrait / Local panes, filter chooser with favourites/hide, preset browser with module badges and a new
full-screen preview. Reviewers say it "crams a lot of functionality into an interface that's very well managed
overall but can sometimes feel crowded and confusing" and that it has "a somewhat complex and dated look" — dense
small type, many bordered boxes, mixed icon styles, a modal-heavy import. Its one modern move is the **layout
presets that mimic Lightroom or Capture One** and a personal default stack — an explicit admission that muscle
memory is the onboarding. [search: https://www.digitalcameraworld.com/cameras/on1-photo-raw-2026-review-its-hard-not-to-like-this-affordable-do-it-all-photo-editing-program], [search: https://www.photoworkout.com/on1-photo-raw-review/], [search: https://www.on1.com/products/photo-raw/features/]

**Radiant Photo 2.** Minimal by construction: a left column with only Navigator, Workflow (the detected scene),
Develop Collections (starting points), Presets; the image fills the rest; the auto has already happened when the
photo opens, so the empty state is never empty — reviewers call it "incredibly simple", "well-presented and
minimalistic". A Pro/manual mode discloses sliders. What dates it: the finishing tools are ordinary, the LUT Looks
are a flat list, and the app is a finisher rather than a browser (no real DAM). The pattern worth stealing is the
**strength slider under the smart preset** — one control that scales an entire opinionated auto. [search: https://www.digitalcameraworld.com/cameras/radiant-photo-2-review], [search: https://photofocus.com/photography/kicking-the-tires-on-the-new-radiant-photo-v2/], [docs/03 §5]

**Dehancer.** A single long, dark, sectioned panel in the analog-chain order (profile → exposure → push/pull →
developer → compression → print → colour head → halation → bloom → grain → breath → gate weave → damage →
overscan → vignette), each section with an enable toggle and 2–6 sliders; in Lightroom it is an external-editor
round trip (TIFF out, TIFF back) rather than a live panel `[knowledge]`. Modern: the chain order itself teaches
the physics; profile lists are typographic and restrained; monitor tools (false colour, clipping) are one click.
Dated: panel length (docs/03 §7.8's stated weakness), no thumbnails, no hover, everything requires scrolling,
and per-section numeric ranges are opaque (0–100 for physical quantities). [search: https://www.dehancer.com/features], [search: https://www.provideocoalition.com/review-dehancer-film-emulation-plugin/], [docs/03 §7.8]

**Lumen would need (G):** image-rendered preset cards (Luminar/ON1), a strength-of-the-whole-look slider
(Radiant), and the chain-order panel as *teaching* (Dehancer) — Lumen's Film Lab already lists Stock → Strength →
Film Exposure → Push/Pull → Halation → Grain, which is the right order; it lacks the section toggles and print row.

## H. Viewer & scopes

| Capability | How it works | Source | Lumen would need |
|---|---|---|---|
| Dehancer **Monitor** tools | False colour and clipping overlays inside the plugin; Defringe tool. | [search: https://www.dehancer.com/features] | Lumen has scopes + clipping (docs/12); false-colour overlay is a cheap addition if absent. |
| Nitrate **isolated halation view** | Toggle to show only the halation contribution. | [search: https://digitalfilms.wordpress.com/2024/05/19/filmconvert-nitrate-adds-halation/] | A "show effect only" viewer mode for halation/grain. |
| ON1 **full-screen preset preview** | Preset browser expands to the full viewer. | [search: https://www.on1.com/blog/on1-photo-raw-a-new-way-to-work-with-presets/] | — |

## I. Pipeline & performance

- Order of operations, all three physical emulators agree: input transform → exposure into the stock → negative
  curve (+ halation *before/within* the negative) → print curve → bloom → grain (density/print domain) → vignette.
  Filmbox lets the negative and print be **separate nodes** with grading between them; Dehancer sells halation,
  bloom, grain as separate node plugins. [search: https://videovillage.com/filmbox/], [search: https://blog.dehancer.com/articles/separate-plugins/]
- Dehancer's model is heavy: reviewers note render-time cost; Luminar claims a "modular engine" distributing load;
  ON1 is "feature-rich and slow" six years running (docs/03 §5). No vendor publishes ms/frame. [search: https://skylum.com/whats-new/luminar-neo], [docs/03 §5]
- **Lumen would need:** nothing structural — `FilmChain` occupies the S14 display slot, halation is S13
  pre-curve, grain is a plate; adding bloom is one post-curve blur at half-res (docs/03 §7.7 cost envelope).

## J. Library / culling / export / ingest

| Capability | How it works | Source | Lumen would need |
|---|---|---|---|
| Luminar **Sync Adjustments** | Copies all edits (incl. layers/watermark) to selected photos; used as batch. | [search: https://skylum.com/blog/guide-to-layering-watermarking-and-beyond] | Lumen has `LookSubset.applied(toAll:)` for looks; full-recipe sync per docs/10. |
| ON1 **Sync Settings / batch** | Sync chosen settings across selection; batch export/resize. | [search: https://scottdavenportphoto.com/blog/how-to-batch-edit-with-sync-settings-in-on1-photo-raw] | — |
| Radiant **smart batch export** | Auto per photo during export. | [search: https://radiantimaginglabs.com/radiant-photo-2/] | Scene-aware auto at ingest is the Law-3 version of this. |
| Apply preset on import | LR yes; ON1 requested (absent); Luminar not found. | [docs/02], [search: https://www.on1.com/products/photo-raw/ideas/idea/apply-preset-from-favorites-when-importing/] | Lumen: no import-preset hook found in `Sources/LumenCore/Ingest`. |

## K. Crop / lens / geometry

Not applicable beyond: Dehancer **Overscan** (adds gate/perforation frames for 8/16/35/65 mm) and **Gate Weave**
(Impact scales positional jitter — video), both on docs/03's "avoid" list. [search: https://www.dehancer.com/features]

## L. State / undo

Not applicable. All four apps are non-destructive; Luminar keeps a per-image edit history; ON1 keeps edits in
sidecars/catalog; nothing here changes docs/12's undo model. [search: https://skylum.com/whats-new/luminar-neo]

## M. Recipe / serialization / sidecars

| Capability | How it works | Source | Lumen would need |
|---|---|---|---|
| Filmbox Looks ↔ Pro | Looks projects open in Pro "without conversion" — one parameter schema, two UIs. | [search: https://videovillage.com/blog/2025/10/30/filmbox-looks] | Same principle as Lumen's `LookSubset` over `Recipe`. |
| ON1 Presets Manager | Import/export/organise presets; AI Adaptive Presets serialise AI masks. | [search: https://www.on1.com/blog/on1-photo-raw-a-new-way-to-work-with-presets/] | Lumen saved looks live in the catalog (`refreshSavedLooks`); no export/import file format found. |
| LUT files | Luminar Mood and Radiant My Looks accept .cube. | [search: https://manual.radiantimaginglabs.com/1/en/topic/color-grading] | `LUTReference.ref = "blob:xxh64:<hash>"` and `BlobStore` exist; the .cube parser/UI does not. |

---

## AI features worth noting for a local-only app (brief item 9)

| Feature | Local? | Model / size | Source |
|---|---|---|---|
| Luminar GenErase | **Cloud only** ("all edits are performed on the cloud") | — | [search: https://support.skylum.com/luminar-neo-tips/generative-tools-in-luminar-neo-everything-you-need-to-know] |
| Luminar GenSwap / GenExpand / Sky AI / Relight AI / Structure AI / Noiseless / Supersharp / Upscale | Local (desktop only; "more demanding on hardware") | Sizes not published; system floor 8 GB RAM, 10 GB disk, GPU with OpenGL 3.3+ | [search: https://skylum.com/luminar-online], [search: https://support.skylum.com/about-luminar-neo/system-requirements] |
| ON1 NoNoise AI 2027, TackSharp, Super Select, Sky Swap, Keyword AI | Local ("no cloud lock-in") | Sizes not published | [search: https://www.on1.com/blog/new-on1-nonoise-ai-2027-ai-noise-reduction-tacksharp-ai-model-selector/] |
| Radiant scene detection + face/skin (10-point skin tone) | Local ("all analysis happens on your own computer") | Sizes not published | [search: https://radiantimaginglabs.com/radiant-photo-2/] |
| Dehancer / Filmbox / Nitrate | No ML; GPU shaders | — | [search: https://www.dehancer.com/features] |

Takeaway for Lumen: the creative bar's *non-generative* AI (depth relight, people-protected clarity, sky/subject
mattes, scene-classified auto) is all local at competitors and all coverable by the docs/17 zoo (Depth Anything
V2 Small, Vision person/foreground, a sky model, an aesthetics/scene classifier). The only cloud dependency in the
set is GenErase, which Lumen excludes by law.

---

## New relative to docs/02–03

- Dehancer's **named halation controls** (Source Limiter, Background Gain, Smoothness, Local Diffusion, Amplify)
  and **bloom controls** (Threshold/Highlights, Size), its vendor statement that halation and bloom are distinct
  phenomena to be used together, and its **12 grain profiles** (8/16/35/65 mm × ISO 50/250/500) with
  shadow/mid/highlight weighting; **Film Compression** (Impact, White Point default 100, Tonal Range, Color
  Density); **Film Developer** as a single "development" control; Film Damage = Dust/Hair/Scratches; print films
  2383/3513 and papers Endura/Bromportrait as *selectable print stocks*. docs/03 §7.8 had only the chain order.
- Filmbox Pro 3.x's characterisation method (contact print of 250D→2383 scanned under a broad-spectrum
  illuminant; spatial model from Arriscan-scanned test charts), its **grain control set** (dye-cloud colorfulness,
  softness/mid-frequency/streakiness/desqueeze, **9-zone tonal fader**), halation (size/opacity/colour
  balance/saturation/amber), the **Lab module** (Neutralize/Defog), and **Filmbox Looks** (Oct 2025, 101 presets,
  Premiere/AE hosts). docs/03 called Filmbox "deliberately few controls" — true for Looks, less so for Pro.
- FilmConvert Nitrate: 100+ camera profiles × per-stock editable curves; grain from real scans in 8 sizes with a
  3-point tonal response curve and grain **saturation**; halation added May 2024 with Sensitivity/Boost/red-fringe
  controls and an isolated view. Not in docs/02–03 at all.
- ON1: NoNoise AI **2027** with a subject-class model selector and TackSharp; Sky Swap AI in 2026.5 (July 2026);
  preset browser with module badges + full-screen preview; AI Style Advisor; evidence that **hover preview** and
  **apply-preset-on-import** are open user requests (absent).
- Luminar: Relight AI's five sliders; Sky AI's slider set; Enhance AI = Accent + Sky Enhancer sub-sliders;
  Structure AI's people exclusion; presets with hover preview, strength slider, heart favourites, "For This Photo";
  Layer Properties opacity/blend; **GenErase cloud-only vs everything else local**; August 2026 unified
  Catalog+Edit redesign.
- Radiant: the **13 scene classes** (Auto Radiant, Landscape, Landscape–Night, Landscape–Winter, People,
  People–Night, Underwater, Black & White, …), contextual rules (black point kept at night, warm cast kept at
  golden hour), strength slider under the picker, Looks accept .cube, all-local claim.
- LR grain detail: blue-channel component at Size ≥ 25 (secondary source).
- Lumen-side: `LUTReference` and `halationRedness` exist in the model with no UI; bloom absent; Saved Looks has no
  thumbnails/hover/amount.

## Could not verify

- Every vendor page was egress-blocked; **no slider range or default** for Dehancer, Filmbox, Nitrate, Luminar,
  ON1 or Radiant is primary-source verified. Ranges quoted are reviewer paraphrase or `[knowledge]`.
- Whether any of Dehancer/Nitrate/Filmbox exposes a **bleach-bypass** control (none surfaced in searches).
- Filmbox grain **resolution independence** mechanism (stated as a property of the pipeline model; no numbers).
- Dehancer grain: whether "true grain" scans are used vs pure physical modelling — vendor text says "physical
  modelling of the emulsion" for grain and "real scans" only for damage/dust.
- ON1 Effects per-filter "Apply To"/luminosity blending option names; ON1 Film Grain filter's exact slider list.
- Model download sizes for Luminar Extensions, ON1 NoNoise 2027, Radiant — none published in reachable sources.
- Radiant's remaining scene classes beyond the eight named (vendor says 13).
- Dehancer-in-Lightroom being a TIFF round-trip rather than a live panel (`[knowledge]`, plausible, unconfirmed).
