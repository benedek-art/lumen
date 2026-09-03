# W1 synthesis — the gap table

Merged from `w1/r1-lightroom.md` (LrC 15.5), `r2-captureone.md` (C1 16.8), `r3-dxo.md`
(PhotoLab 10 / FilmPack 8), `r4-opensource.md` (darktable 5.6 / RawTherapee 5.13 / ART),
`r5-creative.md` (Luminar Neo / ON1 2026 / Radiant 2 / Dehancer / Filmbox / Nitrate / RNI),
`r6-denoise-decision.md`, `r7-film-grain.md`. Written 2026-09-01.

**How to read a cell.** Competitor cells: ≤12 words + the dossier's tag, abbreviated —
`[R1 s]` = that dossier's `[search: …]`, `[R1 k]` = `[knowledge]`, `[R1 d]` = `[docs/02–03]`,
`[R4 src]` = fetched source file, `[R6 f]` = fetched LICENSE/README, `[R7 c]` = read from
Lumen code. "—" = the dossier reports no equivalent. **Lumen** cell: one of `present` /
`partial` / `absent` / `model-only` (in the recipe or engine, no UI or no stage) / `ui-only`
(a control wired to nothing), with the file grepped this session. A `present` here is a
grep hit, not a behavioural verification — the auditor still runs it. **gap**: what Lumen
would need + size S/M/L.

Where this table disagrees with a dossier, the grep wins and the disagreement is noted
(three found: manual-sharpen Radius row, brush flow digit keys, `refineSaturation`).

---

## A · Tone & sliders

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Basic tone set | Exp ±5 midtone-weighted, Contrast, Hi/Sh, Whites/Blacks ±100 [R1 d] | Exposure/Contrast/Brightness/Saturation + HDR 4 bidirectional, ≈2× LR strength [R2 s] | Exposure ±4, Selective Tone 4 bands ±100 [R3 s] | sigmoid contrast/skew/targets; filmic white/black EV [R4 src] | Nitrate Level/Mid Point [R5 s] | `present` — `Recipe.Tone`, `BasicPanel.swift` | Brightness-class midtone slider absent (C1 batch slider) · S |
| Zone tone with movable pivots | five fixed histogram zones [R1 d] | — | four fixed bands [R3 s] | ART Tone EQ 5 bands + pivot [R4 k] | — | `present` — `Zones.pivots` `Recipe.swift:435`, `ZonesPanel.swift` | none — Lumen leads |
| Auto tone | ⌘U ML auto, per-slider ⇧-dbl-click auto [R1 d] | Auto on Levels/Exposure [R2 k] | Smart Lighting Uniform/Spot-Weighted, face-detect boxes [R3 s] | RT histmatching from embedded JPEG [R4 src] | Luminar Enhance AI one slider; Radiant 13-scene auto + strength [R5 s] | `partial` — `AutoTone.suggest` `AppStateActions.swift:39`, per-row "Set … automatically" `LumenControls.swift:521`; no face/scene awareness | face-weighted auto (Vision face rects) · M; auto-strength slider (Radiant) · S |
| Slider contract | ⇧ slows; ↑↓ 5 / ⇧10 / **⌥1**; dbl-click reset; scrubby number [R1 s] | ⇧-arrow 10×; dbl-click reset; **no fine-drag**; ⌥-click reset = momentary before [R2 s] | standard [R3 k] | scroll on hovered slider [R4 k] | — | `present` — `SliderDrag.swift` ⇧-fine, `SliderEntry.swift` arithmetic, `LumenControls.swift` dbl-click/⌥-scroll | ⌥-arrow fine step, hover-without-focus nudge, per-tool momentary-before · S |
| Tone curve | Parametric/Point/RGB, Refine Saturation 0–100 [R1 d] | RGB/Luma/R/G/B, on-image pick [R2 s] | RGB/R/G/B/Luma [R3 s] | RT 6 curve modes (std/weighted/film-like/luminance/perceptual) [R4 src] | — | `present` — `CurveSet.point/r/g/b/luma`, `CurveEditorView.swift`. **`refineSaturation`: 0 hits in `Sources/` (R1 said "Recipe only") → `absent`** | Refine-Saturation-style chroma damping on the curve · S |
| Histogram zone scrub | drag five zones = sliders; corner clip triangles; J [R1 d] | Levels doubles as scope [R2 s] | clipping toggles [R3 k] | — | — | `present` — `HistogramView.swift` | none |
| Levels tool | — | RGB+channel input/output levels, matte output [R2 s] | — | — | — | `absent` — 0 hits `outputLevels`; `MaskRefine.levels*` is mask density only | output-levels row (print-safe black/white) · S |
| Speed Edit | — | hold Q/W/E/R A/S/D/F + drag both axes/scroll/arrows; under-image slider; key+Space reset; batch [R2 s] | — | — | — | `present` — `SpeedEdit.swift` E/C/H/S/W/T/K/M, 150 ms hold; readout title only | under-image slider readout, key+Space reset, batch across selection · S–M |
| Display transform | PV6 fixed [R1 d] | fixed [R2 k] | DxO Wide Gamut, DCP curve choice [R3 s] | sigmoid: contrast 1.5, skew, targets, inset/rotation/purity; filmic 5-node spline [R4 src] | — | `present` — `DisplayTransform.swift:22-59` sigmoid + filmic anchors; `RenderParams.preset` | verify `whiteAnchorEV/blackAnchorEV` pinning is exercised (`DisplayTransform.swift:170`) · S |
| Tone-range-limited local contrast | — | Clarity 4 methods + Structure [R2 s] | Fine contrast Hi/Mid/Sh sub-sliders [R3 s] | RT local contrast darkness/lightness gains [R4 src] | — | `absent` — `Detail.clarity/texture` only; no darkness/lightness or tone-band split | asymmetric up/down or per-band clarity · M |
| Dynamic-range compression (gradient domain) | — | — | — | RT Fattal DRC, 1920 px cap [R4 src] | Luminar Relight (depth) [R5 s] | `absent` | not needed; Zones + Shadows cover it · — |

**Top 5 gaps by owner impact (A):** 1. Fine ⌥-arrow step / hover-nudge (every slider, all day). 2. Speed Edit readout under the image + key+Space reset. 3. `refineSaturation` on the curve (curves bleach). 4. Face-aware auto (Spot-Weighted). 5. Levels-style output black/white for print.

---

## B · Colour & grading

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| White balance + neutral pick | Temp/Tint, eyedropper [R1 d] | Temp/Tint, pick, Normalize tool [R2 s] | Temp/Tint presets [R3 k] | color calibration CAT16, image illuminant estimators (surfaces/edges), gamut compression [R4 src] | — | `present` — `WhiteBalanceEngine.swift` CAT + `neutralizing(sample:)`; no image-content auto-illuminant | content-based Auto WB (edge/surface) · M; Normalize-to-reference batch · S |
| HSL mixer | 8 bands H/S/L ±100 + TAT [R1 d] | Basic tab 8 ranges, Smoothness, gradient tracks [R2 s] | 8 swatches, arc with 4 handles, Uniformity [R3 s] | dt color equalizer 8 nodes + guided smoothing [R4 src] | — | `present` — `Mixer.bands[8]` core/feather, `uniformity` `Recipe.swift:615`; `MixerHueRing` handles `ColorPanel.swift:213` | none structurally; ring usability is B3's question |
| Point Color / picked colour range | up to 8 swatches, Range + H/S/L sub-ranges, Variance ±100, Visualize Range [R1 s] | Advanced: wedge hue×sat spans, 30 slices, invert, isolation B&W view [R2 s] | HSL arc [R3 s] | RT LabRegions [R4 k] | — | `partial` — `PointColor` sample/range/variance/HSL `ColorPanel.swift:335`; no isolation view, no separate hue/sat spans, no invert, no promote-to-mask | Visualize-Range/isolation toggle · S; two-axis range handles · M; "make this a mask" · S |
| Skin uniformity | — | Skin Tone tab: Amount HSL + Uniformity H/S/L 0–100 [R2 s] | Uniformity slider [R3 s] | RT skin window + Munsell [R4 src] | Radiant 10-point skin [R5 s] | `partial` — `Mixer.uniformity` (hue only), `PointColor.variance` one axis | sat/lightness uniformity axes · S |
| Colour grading wheels | 3-Way + Global, Blending 50, Balance 0; ⌘/⇧/⌥ wheel modifiers; no pivots [R1 d] | Master/3-Way, per-zone Lightness, no pivots [R2 s] | PL10 Nik-9 tone-zone wheel [R3 s] | color balance rgb: 4-way lum/chroma/hue, sat/brilliance, masked gains in linear Yrg [R4 src] | Nitrate 3 wheels after stock [R5 s] | `present` — `GradingWheels` global/sh/mid/hi + blending/balance/**pivots** `RecipeLook.swift:229`; `LumenColorWheel` `LumenControls.swift:1508`; 0 hits for wheel modifier keys | wheel ⌘=hue-only/⇧=sat-only/⌥=fine · S; luminance-as-J 3× leverage vs dt's linear gains — B2 question (docs/31) · M |
| Calibration / primaries | Process version, Shadows Tint, RGB primary hue/sat [R1 d] | — | DCP DxO/Adobe curve; ICC dropped PL7 [R3 s] | sigmoid inset/rotation/purity per primary [R4 src] | — | `present` — `Primaries` (`RecipeLook.swift`); `absent` DCP/camera-profile loading (0 hits) | DCP input profiles · L (only if camera-colour parity is wanted) |
| Vibrance / saturation / skin protect | Vibrance non-linear, Saturation linear [R1 d] | Saturation asym: + vibrance-like, − true desat [R2 d] | Vibrancy protects skin/sky [R3 k] | RT vibrance pastel/saturated split, skin window [R4 src] | — | `present` — `ColorAdjust.vibrance/saturation/density/protectSkin` `Recipe.swift:296` | none |
| B&W | 8-slider B&W mix + Auto [R1 d] | via Saturation −100 [R2 d] | FilmPack channel mixer/filter/toning [R3 k] | dt color zones B&W presets [R4 src] | — | `present` — `BlackAndWhite` 8 bands, `ColorPanel` | none |
| Printer lights | — | — | — | — | Dehancer CMY Color Head at print stage [R5 s] | `present` (additive cousin) — `PrinterLights` `LookPanel.swift:598` | CMY head inside `FilmChain` print stage · M |
| LUT apply | profiles only [R1 d] | — | .cube in Color Rendering, intensity [R3 k] | dt lut3d .cube/.3dl/HaldCLUT, LUT colourspace tag [R4 src] | Luminar Mood, Radiant My Looks .cube [R5 s] | `model-only` — `Look.lut: LUTReference` + `LUT.swift:330` .cube parser; **0 hits in `Sources/LumenApp`** | import + row (tap display/log, amount) · S; HaldCLUT · S |
| Soft proof + gamut warning | S key, paper/ink [R1 d] | Recipe Proofing [R2 s] | Preserve color details + monitor-gamut warning [R3 s] | — | — | `present` — `SoftProof.showGamutWarning` `EffectsPanel.swift:522`, `RenderGraph.swift:275` | placement (Effects panel) is a G1 question · S |

**Top 5 gaps (B):** 1. Point-Colour isolation view (Visualize Range / "view selected") — every competitor has it. 2. LUT import + row (model exists, dead). 3. Wheel modifier keys. 4. Content-based Auto WB. 5. Promote a colour pick to a mask.

---

## C · Film & grain

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Film emulation engine | Creative profiles only (LUT) [R1 d] | Film Grain tool only [R2 d] | FilmPack 8: 153 scanned renderings, Intensity [R3 s] | RT HaldCLUT film sim; ART negative inversion [R4 src] | Dehancer profiled curves + print stocks; Filmbox contact-print model; Nitrate curve+matrix per camera [R5 s] | `present` — `FilmLab.swift` negative→print sigmoid chain, 6 stocks (`:226-372`), baked 33³/65³ LUT | asymmetric toe/shoulder, sensitivity 3×3, paper families, ~10 more stocks [R7 C.1.3] · M |
| Stock roster | — | — | 153 [R3 s] | — | Dehancer 60+; Filmbox Vision3 ×4; RNI 180+ [R5 s] | `present` (6) — Portra 400, Gold 200, Ektar 100, Tri-X, Velvia 50, Cine 250D | Portra 160/800, Ultramax, HP5, T-Max, Delta 3200, 800T, Provia [R7 table] · M |
| Print stock independent of negative | — | — | — | — | Dehancer 2383/3513/Endura; Filmbox print node [R5 s] | `absent` — one `printCurve` per stock; 0 hits "Print Stock" in `LookPanel.swift` | paper table + Print Stock row · M |
| Push / pull physics | — | — | — | — | Dehancer 3 captured exposures interpolate [R5 s] | `partial` — γ ×1.18/stop, tints, grain ×1.35 (`FilmLab.build`); no fog rise, no ½-stop exposure loss, no saturation coupling | fog + exposure + γ ×1.12 deltas [R7 C.1.4] · S |
| Halation | — | — | none found [R3 s] | — | Dehancer Source Limiter/Background Gain/Smoothness/Diffusion/Amplify; Nitrate Sensitivity/Boost/isolated view; Filmbox radius [R5 s][R7 s] | `partial` — Amount 0–100 on wire/panel; Size 0.5–2 and Redness exist in `HalationProfile` but **not in recipe or panel** (0 hits `halationSize|halationRedness`); GPU/CPU gate disagree; weights un-normalised [R7 c] | Size + Redness rows on wire · S; 800T stock · S; one energy gate + normalised weights · S |
| Bloom / diffusion | — | — | FilmPack Blur [R3 s] | dt bloom/soften [R4 k] | Dehancer Bloom Threshold/Size; Filmbox in spatial model [R5 s] | `absent` — comment only `Kernels.swift:424` | Effects › Diffusion {amount, radius % frame}, scene-linear pre-halation [R7 C.1.6] · S–M |
| Grain model | Amount/Size/Roughness mono luma, screen-space [R1 d] | Fine/Silver Rich/… Impact/Granularity [R2 d] | scanned matrices per tone zone, unique per rendering, Size scaled to output [R3 s] | dt 3-octave simplex, ISO-scaled, paper LUT, width-relative; ART per-pyramid-level [R4 src] | Dehancer 12 format×ISO profiles; Filmbox 9-zone fader + dye-cloud colour; Nitrate 3-point curve + grain sat [R5 s] | `present` (two systems) — `FilmGrain` `RecipeLook.swift:457` + `CreativeGrain` `Recipe.swift:986`, density-domain √(p(1−p)), gate-anchored plate; `filmOwnsTheGrain` `FilmLab.swift:1137` | merge into ONE `Grain{amount,size,roughness,chroma,format,envelope}` [R7 C.2.3] · M |
| Grain tonal envelope control | — | — | shadow/mid/highlight matrices [R3 s] | dt midtones_bias [R4 src] | Filmbox 9-zone; Nitrate 3-point [R5 s] | `absent` — fixed p(1−p) | stock-derived envelope LUT (Nutting √D × print slope) [R7] · M |
| Grain chroma control | mono (+blue at Size≥25) [R5 s] | — | luminance-dependent [R3 s] | dt L-only [R4 src] | Filmbox dye-cloud colorfulness; Nitrate grain saturation [R5 s] | `absent` — per-channel plate scale (0.8/1/2) internal; 0 hits "chroma" in `EffectsPanel.swift`; colour blotches at export [R7 C.0-2] | chroma fraction χ row · S (kills export rainbow) |
| Format / gate size | — | — | Size vs print (unverified) [R3 s] | dt width-relative [R4 src] | Dehancer 8/16/35/65 mm; Nitrate 8 sizes [R5 s] | `model-only` — `FilmLab.printSize` dead on wire, no panel row (`LookPanel.swift:995`) | replace with Format enum (35/half/S35/120/4×5) · S |
| Preview↔export grain parity | screen-space (differs) [R1 d] | output-res render [R2 d] | — | dt rank-1 lattice AA; AV1 fixed template [R7 s] | Filmbox "resolution independent" [R5 s] | `partial` — amplitude test exists; **0.5-px plate floor re-pitches Ektar/Velvia at 2560 px** [R7 C.0-1]; no pattern/spectrum test | band-limited octave set + `GrainParityTests` · M |
| Negative scan inversion | — | — | FP8 10+ inversion curve presets [R3 s] | ART film negative per-channel power [R4 src] | — | `absent` (0 hits) | out of scope unless scanning is · — |
| Light leaks / textures / frames | — | — | FilmPack Defect/Intensity, textures, frames [R3 s] | dt framing/watermark [R4 k] | Dehancer damage/gate weave/overscan [R5 s] | `absent` | docs/03 "avoid" list; not this cycle · — |

**Top 5 gaps (C):** 1. Halation Size + Redness rows (+800T) — the demo everyone asks for. 2. Grain chroma fraction (export rainbow on colour stocks). 3. Band-limited plate so Ektar/Velvia preview matches export. 4. Bloom/diffusion. 5. Print-stock row + paper families.

---

## D · Looks / presets & effects

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Saved looks / presets | folders, hover live preview, Amount 0–200 [R1 s] | Styles (multi-tool) vs Presets (one tool), hover preview [R2 s] | partial presets, Subject-Type local presets [R3 s] | dt styles; RT partial .pp3 profiles [R4 k] | Luminar image-rendered cards, hover, strength, favourites; ON1 module badges; Radiant strength under picker [R5 s] | `partial` — `LookSubset.swift`, `LookKind` look/develop-preset/import-default, text list in `LookPanel.swift:175`; **no thumbnails, no hover preview (`LookPanel.swift:168`), no amount** | rendered thumbnails · M; hover preview · S; look Amount (generalise `LUTReference.amount`) · M |
| Preset Amount / intensity | 0–200 when saved with Support Amount [R1 s] | layer Opacity as style strength [R2 s] | Intensity per rendering [R3 s] | RapidRAW preset intensity [R4 src] | Luminar strength; Radiant strength [R5 s] | `partial` — `SpeedEdit.lookAmount` K key `SpeedEdit.swift:30` exists; `LookSubset.applied` is all-or-nothing | blend subset toward recipe · M |
| Adaptive (AI-mask) presets | Subject/Sky/People recomputed on apply; "Update AI settings" [R1 s] | Style Brushes auto-create layer [R2 s] | PL9 Subject-Type local presets [R3 s] | — | ON1 AI Adaptive Presets [R5 s] | `partial` — `Mask` has no register field, "no such thing as a look-tagged mask" `LookSubset.swift:36`; AI kinds re-resolve per photo by construction | look-tagged masks travel with a look · M |
| ISO-adaptive presets | interpolate between ISO anchors [R1 d] | — | — | dt auto-apply presets by camera/ISO [R4 k] | — | `partial` — ISO-adaptive **denoise** defaults only (`DetailPanel.swift:448`) | ISO-keyed look defaults · S |
| Apply on import | yes [R1 d] | Styles on import [R2 s] | — | — | ON1 requested (absent) [R5 s] | `absent` — no hook in `Sources/LumenCore/Ingest`; ingest is a stub | import-default look at ingest · S (after ingest ships) |
| Vignette | Amount/Midpoint/Roundness/Feather/Highlights, 3 styles [R1 d] | — | FilmPack intensity/midpoint/roundness/transition [R3 k] | dt/RT vignette [R4 k] | Dehancer after grain; Luminar placement [R5 s] | `partial` — EV amount + feather `EffectsPanel.swift:148`; no midpoint/roundness/highlights (by design: `:9`) | midpoint + roundness · S |
| Lens Blur / depth relight | depth model, 5 bokeh, focal-range strip, refine brush [R1 s] | — | PL10 Depth Mask bands [R3 s] | RapidRAW Depth Anything [R4 src] | Luminar Relight AI 5 sliders [R5 s] | `absent` — `depthRange` kind only, no depth source (`MaskPanel.swift:1245` "nothing estimates depth") | Depth-Anything-V2-Small wiring · L |
| Effects stack / layers / blend | — | 16 layers + opacity [R2 d] | — | dt 30 blend modes, RapidRAW mask blend [R4 src] | ON1 filter stack blend/opacity; Luminar layers [R5 s] | `absent` (by design) — `MaskBlend` normal/luminosity/colour only `RecipeMasks.swift:183` | none; keep fixed stages (docs/14) · — |
| Style brushes | — | first stroke creates layer with adjustments [R2 s] | Control Brush [R3 s] | — | — | `absent` (0 hits) | brush + preset local adjust in one gesture · S |
| Clarity / texture / dehaze | Texture/Clarity/Dehaze [R1 d] | Clarity 4 methods; Dehaze ± with Shadow Tone pick [R2 s] | ClearView Plus no-halo claim; Microcontrast [R3 s] | dt local laplacian; diffuse-or-sharpen 21 presets; haze 95th-pct airlight [R4 src] | Luminar Structure AI excludes people [R5 s] | `present` — `Detail.texture/clarity/dehaze`, `lumenDehaze` `Kernels.swift:147`; no negative-haze, no shadow-tone pick, no people-protect | people-protected clarity (person matte × clarity) · S; dehaze shadow tone · S |

**Top 5 gaps (D):** 1. Look thumbnails rendered on the photo. 2. Hover preview. 3. Look Amount. 4. LUT import row (see B). 5. Vignette midpoint/roundness.

---

## E · Denoise & sharpening

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Classical NR | Lum/Detail/Contrast + Color/Detail/Smoothness [R1 d] | Lum 50/Details 50/Color 50/Single Pixel 0 [R2 s] | HQ/PRIME Lum 40/Chroma 100/LowFreq 75/Dead 24/Maze 30 [R3 s] | dt profiled: v2 VST shadows/bias, 7 bands, Y0U0V0 wb-adaptive, NLM; RT Ldetail DCT + auto chroma [R4 src][R6 f] | — | `present` — `DenoiseEngine.swift` VST + 5-band à-trous, `ClassicNR(luma,chroma,hotPixels)`; 6 rows `DetailPanel.swift:414-485`; sub-sliders are engine constants, not on wire | v2 exponent-p VST + shadows/bias · S; 7 bands + per-band curves · M; NLM option · M; sub-sliders on the wire (§12.7) · S |
| AI denoise | Detail-panel toggle, Amount greyed until compute, cached raster, ANE ≈5 s/45 MP [R1 s] | Enhanced Denoise Impact, once-per-raw background cache [R2 s] | DeepPRIME/XD2s/XD3/DP3, joint demosaic, Loupe-only preview, ~4–18 s [R3 s] | darktable-ai NAFNet-w32 static 768² MIT; RawNIND UtNet2 fp16 NaN on ANE [R6 f] | ON1 NoNoise 2027 model selector; Luminar Noiseless [R5 s] | `ui-only` (stand-in) — "AI (stand-in)" segment `DetailPanel.swift:388` → `CIRAWFilter` NR `AppleRawSource.swift:318`; `AIDenoiseSplice`/`TilePlan` complete but **0 callers**; no `import CoreML` anywhere | adopt NAFNet-SIDD-w32 (MIT) per R6 §5: convert, `ModelStore` SHA-256 download (~35 MB), worker actor, encoding shim, 768/32 tiles · L |
| Amount blend post-compute | instant re-blend, no recompute [R1 s] | Impact [R2 s] | Loupe only [R3 s] | — | — | `model-only` — `AIDenoiseSplice.blend` `DenoiseEngine.swift:1358` uncalled | falls out of the row above · — |
| Hot / dead pixels | — | Single Pixel [R2 s] | Dead pixels 24 [R3 s] | dt hotpixels; RT hot/dead filters on CFA [R4 src] | — | `present` — `ClassicNR.hotPixels` post-demosaic | move ahead of S2 when AI lands [R6] · S |
| Capture sharpening | Raw Details toggle [R1 s] | Diffraction Correction checkbox [R2 s] | Lens Sharpness from module blur field, Global +1.00 [R3 s] | RT RL on CFA greens, auto σ = √(1/log maxRatio), corner boost; dt 5.4 cs_* [R4 src] | — | `partial` — `CaptureSharpen` recipe maps to `CIRAWFilter.sharpnessAmount` `AppleRawSource.swift:315`; `DetailEngine.captureSharpen` RL has **no pipeline caller** (docs/26 §6 "dead Radius") | wire RL path, flat-area threshold, corner boost; σ from demosaiced greens · M |
| Manual sharpening | Amount 0–150/Radius/Detail/Masking, ⌥-drag previews, ≥100 % only [R1 d] | Amount 0–1000/Radius/Threshold/Halo Suppression [R2 s] | USM Intensity/Radius/Threshold/Edge offset [R3 s] | RT 4-point threshold, plateau-relative halo control; dt soft-threshold USM [R4 src] | — | `present` — Amount/**Radius**/Detail/Masking/Halo Suppression rows `DetailPanel.swift:216-266` (**R1's "no Radius row" is stale**; the header comment refers to the Denoise fold); `haloSuppression` gated on USM magnitude (docs/26 §6) | re-gate halo on local min/max plateau (RT formula) · S; ⌥-drag matte/edge previews · S |
| Output sharpening | Screen/Matte/Glossy × Low/Std/High [R1 s] | Screen/Print + Viewing Distance [R2 s] | **none** (Bicubic sharper workaround) [R3 s] | dt/RT export resample options [R4 k] | — | `present` — `OutputSharpen.Medium` `ExportRecipe.swift:132`, PPI radius | viewing-distance param · S |
| Local sharpen / noise in masks | Sharpness ±100, Noise, Moiré, Defringe per mask [R1 s] | per-layer sharpening/NR [R2 k] | PL9 local DeepPRIME/demosaic/Lens Sharpness [R3 s] | RT locallab sensi* per tool [R4 src] | — | `partial` — `LocalAdjust.sharpness` offered; `noise/noiseChroma/grainAmount` **model-only** ("TRACTABLE", `RecipeMasks.swift:663-668`); `moire/defringe` model-only, "BLOCKED" (no global engine) | local noise (S11 smooth in kernel) · M; local grain (mask alpha into plate) · S once amplitude is settled |
| Diffraction correction | — | checkbox in Lens Correction [R2 s] | via Optics Module [R3 s] | — | — | `absent` (0 hits) | aperture/pixel-pitch deconvolution · M |
| Denoise quality gate | — | — | — | — | — | `partial` — `DenoiseQualityTests` on 128 px synthetic, engine-shaped noise [R6 §0] | 768² fixture + one real ISO 6400 stack pair · S |

**Top 5 gaps (E):** 1. A real AI denoiser behind the segment that says "AI" (R6: NAFNet-w32, hybrid). 2. Capture sharpen RL path actually called. 3. Halo suppression that reduces rims. 4. Local Noise slider (model exists). 5. Sharpen ⌥-drag previews.

---

## F · Masks

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Radial on-canvas grammar | drag-create, ⌥ from centre, ⇧ circle, 4 edge handles (⇧ aspect, ⌥ opposite), feather ring, rotate just outside rim ⇧15°, ⌘-dbl-click fill, ⌘⌥-drag duplicate, Delete key [R1 s] | ⌥⇧ circle, 4 handles on central line, ⇧-drag ring = feather centre-locked, drag through centre = invert [R2 s] | elliptical Control Points (PL10) [R3 s] | dt circle/ellipse: scroll size, ⇧scroll feather, ⌃scroll opacity [R4 src] | — | `present` — `MaskHandles.RadialGrab` move/resizeMajor/resizeMinor/feather/rotate/create, 15° snap `:380`; ⇧ round/snap, ⌘-drag new (`MaskCanvas.swift:358`); ⌥/⌘ flags read `:1702-1706` | ⌥-from-centre, ⌘-dbl-click fill, ⌘⌥-duplicate, Delete-key target (Keymap ~521), scroll/⇧scroll/⌃scroll on hovered mask · S–M |
| Linear gradient grammar | 3 lines, ⇧ axis, ⌥ symmetric, outer-line feather, rotate on centre line [R1 s] | ⌥ moves one line alone [R2 s] | grad with rotation/feather [R3 k] | dt gradient curvature (scroll), compression (⇧scroll) [R4 src] | — | `present` — `LinearGrab` move/start/end/startBand/endBand/create; ⇧ 0/90° constrain | curvature control · S |
| Brush | Size [ ], Feather ⇧[ ], Flow digits 1–9/0 two-digit, Density, ⌥ erase, A auto-mask, pressure→Flow, A/B `/` [R1 s] | Size/Hardness/Opacity/Flow/Auto Mask/Airbrush, HUD [R2 k] | size/feather/flow/opacity, Auto mask [R3 k] | dt scroll size/⇧hardness/⌃opacity, pressure by conf [R4 src] | — | `present` — `BrushStroke.swift` size/feather/flow/density/erase/automask/pressure; `MaskCanvas.swift:363` "[ ] size, ⇧[ ] feather, **digits set Flow**, A stays inside edges" (**R1's "flow digits absent" is wrong**); `BrushStabilizer.swift` | brush A/B toggle · S; right-click HUD · S |
| Magic / similarity brush | — | Magic Brush Tolerance + Refine Edge flood from stroke [R2 s] | Control Brush = brush × U Point [R3 s] | — | — | `partial` — `similarity` point with chroma/luma selectivity `MaskPanel.swift:1264`; composable via `intersect` of brush+similarity, not one gesture | stroke-driven flood · M |
| U-Point / Control Line | — | — | Control Point chroma/luma 0–100, negative points, opacity; Control Line eyedropper [R3 s] | ART ΔE weight pairs [R4 src] | — | `present` — `MaskKind.similarity`, `.similarityLine` `RecipeMasks.swift:248` | elliptical similarity region · S |
| Luminance range | 2 range + 2 falloff handles, Smoothness, Show Luminance Map [R1 s] | Range/Falloff per end, Radius px, Sensitivity, Invert, on top of any mask [R2 s] | PL7 luminosity mask [R3 s] | dt blendif 4-point ramps per channel, in/out [R4 src] | ON1 luminosity [R5 s] | `partial` — `lumaRange` lo/hi/smooth/channel (6 channels `:366`) + `luminosity` Lights/Darks/Midtones (**duplicate concepts** `:219`, `:246`); one smoothness for both ends; no luminance-map view | per-end falloff (4-point) · S; luminance-map overlay · S; collapse the two range kinds · S |
| Colour range | ⇧-click 5 samples, Refine, ⌥-drag matte [R1 s] | Advanced Color Editor → masked layer [R2 s] | Hue mask ring PL8 [R3 s] | — | ON1 colour range [R5 s] | `present` — `colorRange` samples/`rangeAmount` | none |
| Depth range | needs embedded depth map; Lens Blur depth not shared [R1 s] | — | PL10 Depth Mask from any raw, 3 bands [R3 s] | RapidRAW Depth Anything [R4 src] | Luminar Relight/ON1 depth [R5 s] | `model-only` — `depthRange` kind "still editable, no longer offerable" `MaskPanel.swift:1245` | depth model + provider · L |
| AI subject / person | Subject, Background, People (10 parts each), Objects brush/box, Landscape 8 classes, Sky; stale badge + Update [R1 s] | Subject/Background/People/AI Select click/AI Eraser; no sky [R2 s] | hover-click / box / 10 Subject Types, diffusion slider [R3 s] | dt 5.6 darktable-ai mask; RapidRAW SAM2/U-2-Net [R4 src] | ON1 Super Select sub-objects; Luminar Sky AI [R5 s] | `partial` — `VisionMattes.swift` foreground-instance + person only (`:102`, `:126`); `aiSky/aiObject/aiLandscape/aiPerson(parts)` kinds are `model-only` (`MatteProvider.model`, `RecipeMasks.swift:342`, "absent from the picker" `MaskPanel.swift:26`) | sky model · M; SAM-class click/box object select · L; people parts · L; stale-badge/Update on rows · S |
| Mask algebra & groups | Add/Subtract, ⌥=Intersect, Intersect-with ▸ submenu [R1 s] | Combine Masks (16.7), Luma Range refinement layer [R2 s] | subtract/invert/duplicate/combine [R3 s] | dt union/intersection/difference/exclusion; raster reuse [R4 src] | — | `present` — `MaskOp add/subtract/intersect` as equal buttons `MaskPanel.swift:13`, `MaskGroup`, `maskRef` raster reuse depth 8 | exclusion op · S (low value) |
| Refine: feather / edge / blur | Feather 0–100 + Edge −50…+50 on every mask incl. AI (15.5) [R1 s] | Feather r≤100, Refine r≤300 contrast-modulated [R2 s] | AI diffusion slider 9.6 [R3 s] | dt guided feathering_radius + 4 guide modes, details mask [R4 src] | Luminar mask feathering [R5 s] | `present` — `MaskRefine` feather (guided)/edge/blur/levels `RecipeMasks.swift:576-581` | feathering guide choice (input/output) · S; `details` (high-pass) mask · M |
| Per-mask amount / blend / invert | Amount 0–200 (⌥-drag pin scrubs), Invert [R1 s] | layer Opacity 0–100 [R2 d] | per-mask opacity [R3 s] | dt opacity + 30 blend modes [R4 src] | — | `present` — `Mask.amount 0…200`, `invert`, `MaskBlend` normal/luminosity/colour `RecipeMasks.swift:94-100`; `MaskComponent.amount` | pin-scrub of amount · S |
| Mask row menu | Rename/Duplicate/Invert/Dup+Invert/Delete/Delete Empty/Intersect-with ▸; component Convert Add↔Subtract [R1 s] | Fill Mask, Invert, Copy Mask From, Feather, Refine, Luma Range, Clear [R2 s] | visibility/opacity/invert/duplicate [R3 s] | dt mask manager [R4 src] | — | `partial` — Rename, Duplicate, Duplicate and invert, Delete, Move up/down, New group, Leave group, Ungroup `MaskPanel.swift:866-917` | Copy-mask-from, Delete Empty, Convert Add↔Subtract, Fill · S |
| Overlay | Show Overlay O, 6 modes ⌥O, colour ⇧O, auto-hide on drag [R1 s] | M show mask [R2 k] | show-mask overlay [R3 s] | dt checkerboard-through-output [R4 src] | — | `present` — O/⇧O/⌥O `Keymap.swift:252`, `MaskOverlayView` `ViewerOverlays.swift:493`, `MaskOverlayRule.swift` | checkerboard-through-output mode · S |
| Edit pins visibility | Auto/Always/Selected/Never, H [R1 s] | — | — | — | — | `absent` (0 hits `showEditPins`) | pin visibility rule + H · S |
| Local adjust set | Light/Color(+Point Color)/Effects(Grain)/Detail; **no local curve, no wheels** [R1 s] | all tools per layer [R2 d] | 10 equalizer sliders + HSL + curve + PL9 DeepPRIME/Lens Sharpness [R3 s] | dt any module per mask [R4 src] | ON1 per-filter [R5 s] | `present` and ahead — exposure…blacks, temp/tint/kelvin, hue/sat/vibrance, texture/clarity/dehaze/sharpness, colour tint, **point colours, local point curve, local grading wheels** `RecipeMasks.swift:690-692`, `MaskPanel.swift:1771-1843`; noise/grain model-only (E) | protect: local curve + wheels are unique · — |
| Mask persistence | parametric XMP, AI rasters in `.lrcat-data` (re-run elsewhere) [R1 d] | `.cos` per variant [R2 k] | `.dop` [R3 k] | dt XMP hex structs; masks are history items [R4 src] | ON1 adaptive presets serialise masks [R5 s] | `present` — `XMPSidecar` `lumen:recipe`, `BrushStroke` blobs, `MaskRasterCache` regenerable | F3's three data-loss bugs (ledger) — verify, not new |

**Top 5 gaps (F):** 1. Sky (and object click) mattes — the roster shows kinds it cannot make. 2. Luminance-map / matte visualisation while tuning ranges. 3. ⌥-from-centre, ⌘-dbl-click fill, ⌘⌥-duplicate, Delete key on canvas. 4. Scroll/⇧scroll/⌃scroll on a hovered mask (dt's triple). 5. Copy-mask-from / Delete-empty / Convert add↔subtract in the row menu.

---

## G · UI/UX (layout, design system, navigation/keys)

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Workspace / panel model | fixed right stack, Solo mode, Customize Develop Panel, Tab/⇧Tab hide [R1 k] | Tool Tabs, pinned vs scrollable, floating tools, custom tabs, saved workspaces [R2 s] | palettes float/dock, Essential/All, custom palettes, Favorites, active-only filter [R3 s] | dt module groups + quick access panel; RT fixed tabs [R4 k] | ON1 layout presets mimicking LR/C1; Luminar unified workspace [R5 s] | `partial` — `Workspace` cull/develop/crop/grade/deliver fixed `Workspace.swift:60-83`; sections solo by default `DevelopColumn.swift:423`, `PanelLayout` persists; 0 hits for panel-hide key or user tab composition | Tab-style hide-chrome key · S; "active-only" section filter (WorkspaceModification already knows) · S |
| Tool search | — | — | search field + Favorites star [R3 s] | dt module search [R4 k] | — | `present` and unique — ⌘K `ControlIndex.swift` / `ControlPalette.swift` | protect · — |
| Section header grammar | eye toggle, ⌥ header = reset [R1 d] | title · badge · "…" · reset arrow (⌥ = momentary before) · collapse [R2 s] | switch + reset per tool [R3 s] | dt on/off, presets, reset, multi-instance, mask indicator [R4 k] | Dehancer per-section enable [R5 s] | `partial` — `LumenSectionHeader` title/expanded/isModified dot + Reset via `WorkspaceModification`; no per-section momentary-before, no mask-indicator | ⌥-click header = before · S; "this section is masked" indicator · S |
| Key grammar | G/E/C/N, P/X/U, 0–9, `\`, Y, R, M, K, O, `'`, J, S, Z, Space [R1 d] | 1–5, +/−/*, G, M, B/E/L/T, . , ⇧Y, Q–R A–F; remappable [R2 s] | standard [R3 k] | dt any-widget shortcuts; RT w/z/f/1 [R4 k] | — | `present` — `Keymap.swift` g/e/c/n p/x/u 0–9 6–9 `\` y r m o `'` b l d h s a f z − = [ ] Space; `KeyGrammar.swift` parity test | user remapping · M (low priority); ↑/↓ on hovered slider · S |
| Viewer surround | L lights-out cycle [R1 d] | no lights-out; right-click background colour [R2 s] | — | dt colour assessment ISO 12646 ⌃B [R4 k] | — | `absent` — `Lumen.viewerBackground` fixed token `LumenControls.swift:108`; no lights-out (0 hits) | user surround + ISO 12646 key (Law 7 promises it) · S |
| Visual character | 2008 panel bevel lineage [R1 d] | near-black flat hairlines, 11–12 pt, large icon tabs [R2 s] | palette sprawl, Windows-first skin [R3 s] | dt dense; RT dropdown-per-disagreement [R4 d] | Luminar rounded cards + coloured icons; ON1 crowded; Radiant minimal [R5 s] | `present` — `LumenSurface` 0.055/0.085/0.11, radii 14/9/6/12, `LumenType` 13/12/10 pt, zero-chroma | G2's question; card radius 14 vs C1 near-square noted · — |
| First-render onboarding | — | — | — | — | Radiant auto on open; Luminar Relight on first click [R5 s] | `partial` — Law 3; `AutoTone` is a button | scene-aware first render · M |
| Speed-edit style hold-key | — | Q/W/E/R A/S/D/F [R2 s] | none [R3 k] | dt tone-eq hover+scroll [R4 k] | — | `present` — `SpeedEdit.swift` (dispatch site not re-found in `Keymap.swift`; verify) | see A |
| Help / empty states | — | — | — | — | — | not grepped (0 hits `HelpSheet`) | G3 question · — |

**Top 5 gaps (G):** 1. Hide-chrome / lights-out / user surround (viewer). 2. Section ⌥-click momentary-before. 3. Mask indicator on section headers. 4. "Active-only" section filter. 5. Hover-slider ↑/↓ without focus.

---

## H · Viewer & scopes

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Zoom grammar | Z toggle, ⌘=/−, Space temp [R1 k] | 25…1600 ladder, "." 100 %, "," fit, no single toggle [R2 s] | Loupe ≤1600 % [R3 s] | dt alt+1/2/3; RT z/f/1 [R4 k] | — | `present` — `ZoomLadder.swift` fit/1:1/2:1 max 16, z/−/= | none |
| Before / after | `\`, Y, ⌥Y, ⇧Y, ⇧R reference [R1 d] | Full vs Split slider, ⇧Y, before keeps geometry, ⌥-reset per tool [R2 s] | toggle + side-by-side + reference [R3 k] | RT w; dt snapshots split [R4 k] | — | `present` — `BeforeAfterMode` off/split/sideBySide/topBottom `ViewerOverlays.swift:34`; `CompareView` twoUp/survey | "before keeps crop/geometry" rule — H1 verify · S; reference-photo compare · S |
| Clipping / exposure warnings | J, ⌥-drag threshold views [R1 d] | highlight 250 default, shadow off [R2 s] | clipping toggles [R3 k] | dt raw over/under [R4 k] | Dehancer monitor tools [R5 s] | `present` — `ClippingOverlayView` `ViewerOverlays.swift:378`, `RawTruthPanel` raw-clip truth | thresholds/colours in prefs · S |
| Focus mask / peaking | — | Focus Mask threshold 250, colour/opacity prefs [R2 s] | — | — | — | `model-only` — `FocusPeaking` `Scopes.swift:1490`; 0 hits in `Sources/LumenApp` | viewer overlay + toggle · S |
| Scopes | histogram only [R1 d] | histogram + Color Readouts [R2 k] | histogram [R3 k] | dt waveform/parade/vectorscope (Luv/JzAzBz/RYB) [R4 k] | — | `present` and ahead — `ScopesView.swift` waveform/parade/OKLab vectorscope + skin graticule; `ReadoutHUD` | none |
| Soft proof | S, paper & ink, gamut triangles [R1 d] | Recipe Proofing [R2 s] | Preserve color details + gamut warning [R3 s] | — | — | `present` — `SoftProof` + `showGamutWarning` (B) | none |
| Momentary inspection holds | — | ⌥-click reset arrow [R2 s] | — | — | — | `present` and unique — `InspectionHolds.swift` `[`/`]` shadow-boost / highlight-inspect, `InspectionGain.swift` | protect · — |
| HDR display | SDR\|HDR split, Visualize HDR Ranges [R1 d] | — | — | — | — | `absent` in viewer (0 hits); `HDRSettings` export only | not this cycle · — |
| False colour / isolated-effect view | — | — | — | — | Dehancer false colour; Nitrate isolated halation [R5 s] | `absent` (0 hits `falseColo`) | "show effect only" mode for halation/grain · S |
| Navigator thumbnail | yes [R1 d] | yes [R2 k] | yes [R3 k] | dt navigator [R4 k] | — | `absent` as a pan navigator (only `MaskPanel(role: .navigator)`) | pan navigator · S (low) |

**Top 5 gaps (H):** 1. Focus peaking overlay (engine exists). 2. Before-keeps-geometry verification. 3. Clip thresholds/colours. 4. Isolated-effect view for halation/grain. 5. Reference-photo compare.

---

## I · Pipeline & performance

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Async AI, never blocking input | mask recompute freezes 0.5–10 s; Denoise background since 15.3 [R1 d] | Enhanced Denoise once per raw, background, shared across variants [R2 s] | DeepPRIME at export; Loupe preview only [R3 s] | dt ROI + per-module caches; vkdt all-in-VRAM [R4 src] | Dehancer heavy render [R5 s] | `partial` — `VisionMatteWorker`, `RenderCoordinator`, `DraftLadder`, `MaskRasterCache`; no AI denoise worker, no `ModelStore` (`AppUpdater` is the precedent, size+codesign only) [R6] | worker actor + SHA-256 model download + viewport-first tiles + cancel · M |
| Preview↔export scale invariance | 1:1 previews, Smart Previews [R1 d] | — | — | RT Fattal 1920 cap; dt "preview only exact at 100 %" [R4 src] | Filmbox resolution-independent [R5 s] | `partial` — `DetailEngine.pyramidReferenceLongEdge 2560`; grain floor breaks it (C); sharpening capped 4096 (`DetailPanel.swift:225` comment) | band-limited grain plate · M; sharpen preview honesty · S |
| Halation cost | — | — | — | — | — | `partial` — 3 full-res Gaussians `RenderGraph.swift:1320`; docs/14 promised quarter-res [R7 I] | half/quarter-res blur + upsample · S |
| Export/process queue | export dialog, batch presets [R1 k] | Batch tab: reorderable, pausable, background [R2 d] | export with progress; several presets simultaneously [R3 s] | RT batch queue [R4 k] | — | `absent` — one-shot multi-recipe run, single `exportProgress`; 0 hits queue/pause `ExportSheet.swift` | pausable background queue · M |
| Raw decode control | Adobe demosaic, PV [R1 d] | own [R2 k] | joint demosaic+denoise; refuses unsupported bodies [R3 s] | dt/RT full demosaic enums, dual, green-eq, CFA CA/flat/dark [R4 src] | — | `partial` — Apple `CIRAWFilter` (`AppleRawSource.swift`), draft/full ladder; no CFA access (`RawTruth`/LibRaw escape hatch) | LibRaw path for CFA-domain σ, raw denoise, auto-CA · L (v2) |
| Render process versioning | PV1–6 silent upgrade [R1 d] | — | `.dop` version-migrated [R3 k] | dt modversion + legacy_params per module [R4 src] | — | `present` — `pipelineVersion`, badged migration D52 `Recipe.swift:14` | M's question |
| GPU/CPU reference parity | — | — | — | — | — | `present` — `ReferenceRenderer.swift` golden; halation gate differs (C) | I2 question · — |

**Top 5 gaps (I):** 1. AI denoise worker/model store (nothing runs a model today). 2. Grain scale invariance. 3. Pausable export queue. 4. Quarter-res halation. 5. Sharpen preview honesty at 4096 cap.

---

## J · Library / culling / export / ingest

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Rating / flag / label keys + auto-advance | P/X/U, 1–5, 6–9, Caps Lock advance [R1 d] | 1–5, +/−/*, Select Next When [R2 s] | 0–5, labels, pick/reject [R3 s] | dt 0–5 + reject, F1–5 [R4 k] | — | `present` — `Keymap.swift:151-180`, visible auto-advance `FilterBar.swift:71` | none |
| Compare / survey | ↓ swap, ↑ promote, synced zoom X Y; Survey X removes [R1 s] | — | side-by-side, virtual copies [R3 k] | dt culling mode [R4 k] | — | `partial` — `CompareView` twoUp/survey synced zoom; ↓/↑ swap/promote and survey-X not found | swap/promote keys · S |
| Filter bar | Text/Attribute/Metadata tabs, text operators, lock, presets [R1 d] | Filters with live counts, ⌘-click OR, Smart Albums, recipe-on-album shortcut [R2 s] | rating/label/date/keywords search [R3 s] | dt collections by any metadata [R4 k] | — | `present` — `FilterBar.swift` All/Any + query sentence (unique), rating/label counts, camera/lens/ISO/keyword/stack behind a menu `:273-321`; smart albums `CatalogStore.swift:297` | text-field search operators · S |
| Similarity grouping / auto-stack | stacks manual [R1 d] | Cull window similarity 75 %, Auto Stack, Group Overview [R2 s] | PL9 stacks manual or by capture interval [R3 s] | — | — | `partial` — `feature_print`, `stack` tables `Schema.swift:99,194`; 0 hits for a grouping view or auto-stack | similarity/interval auto-stack view · M |
| Face focus / eyes | — | face crops, 50/100/200 %, Limit to Eye [R2 s] | none [R3 s] | — | Radiant face/skin [R5 s] | `partial` — `face(eyes_open)`, `frame_score` tables `Schema.swift:177-187`; 0 face UI in `GridView`/`FilmstripView` | face chips + eye zoom · M |
| Assisted review tags | AI status filter 15.3 [R1 d] | closed-eyes / mis-focus / exposure tags [R2 s] | — | — | — | `partial` — sort by sharpness/aesthetic (`FilterBar`); scores not tags | tag-as-filter · S |
| Quick Develop / batch relative | ‹ › relative buttons, ⌥ swaps [R1 s] | Speed Edit applies to selection; Normalize [R2 s] | — | — | Luminar/ON1 Sync [R5 s] | `absent` — 0 hits `quickDevelop`; `LookSubset.applied(toAll:)` is absolute | relative batch nudge · S |
| Painter / spray tool | keywords/labels/presets spray [R1 d] | — | — | — | — | `absent` | low priority · — |
| Export formats | JPEG/PSD/TIFF/PNG/DNG/AVIF/JXL, HDR [R1 d] | JPEG/TIFF/PNG/DNG/PSD, ICC file [R2 s] | JPEG/TIFF/DNG (HF-compressed) [R3 s] | dt/RT per-format options [R4 k] | — | `partial` — jpeg/heif/tiff/png `ExportRecipe.swift:24`; `hdrIsWritable { false }` `:542` (**HDR export is `ui-only`**); no DNG/JXL/AVIF | DNG (render-to-DNG) · M; HDR gain map actually written · M |
| Resize modes | W&H / Dimensions / Long / Short / MP / Percentage, Don't Enlarge [R1 s] | Fixed % / W / H / Dimensions / Long / Short, Never Upscale [R2 s] | long edge / dimensions, PPI, bicubic sharper [R3 s] | — | — | `partial` — none/longEdge/shortEdge/width/height/megapixels `:82-88`, `allowUpscale` | Dimensions + Percentage · S |
| Watermark | Text/Graphic, 3×3 anchor, rotate, presets [R1 s] | Text/Image, opacity, scale, offsets [R2 s] | text or image [R3 s] | dt watermark SVG [R4 k] | Luminar watermark [R5 s] | `partial` — text only: position/opacity/size/inset `ExportRecipe.swift:234-238` | image watermark · S; 3×3 anchor + rotate · S |
| Metadata policy | 5 include levels, Remove Person/Location [R1 s] | checkboxes rating/copyright/GPS/EXIF/keywords [R2 s] | — | — | — | `present` — `MetadataPolicy` EXIF/serial/GPS/keywords/copyright/contact `:105-110` | person-info strip · S |
| Multi-recipe export | multiple presets at once [R1 k] | checked recipes in one Process click; Ignore Crop; Recipe Proofing [R2 s] | several presets by suffix [R3 s] | — | — | `present` — checked recipes `ExportSheet.swift:4,250`, `SoftProofTransform` per recipe | Ignore-Crop per recipe · S |
| Ingest | Import dialog, presets on import [R1 d] | Face Focus, Auto Stack, naming tokens, backup, styles [R2 s] | none [R3 k] | — | ON1 requested [R5 s] | `ui-only` — `IngestSheet.swift:71` "verified-copy engine is not built yet"; `RenameTemplate.swift` present | ship the copy engine or remove the sheet (J3) · M |
| Sessions / catalog | `.lrcat` + XMP [R1 d] | Sessions vs Catalog [R2 d] | folder index, Projects, Favorites [R3 s] | dt library; RT sidecar-only [R4 k] | Radiant no DAM [R5 s] | `present` — folder-first + `CatalogStore`, smart albums, keywords tree, stacks | none |

**Top 5 gaps (J):** 1. Ingest that actually copies (or its removal). 2. HDR export that writes what the toggle says. 3. Similarity/auto-stack grouping for culling. 4. Compare ↓/↑ swap/promote. 5. Image watermark + Dimensions/Percentage resize.

---

## K · Crop / lens / geometry

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Crop tool | ratios, A lock, X swap, ⇧ keep ratio, angle ±45, ruler ⌘-drag, O overlays 6 + ⇧O, H hide [R1 s] | aspect presets, mask outside crop [R2 k] | aspect presets, horizon line [R3 k] | dt/RT crop with guides [R4 k] | — | `present` — `CropPanel.swift` ratio menu + padlock + orientation swap + angle + ruler; `CropOverlayStyle` off/thirds/grid/golden/diagonals `:41-50`; `Straighten.swift`; keys x/r/o/a | Triangle + Golden Spiral overlays, ⇧O flip · S; H hide guide · S |
| Upright / perspective | Off/Auto/Guided/Level/Vertical/Full, manual sliders, Constrain Crop [R1 d] | Keystone V/H/Both with guides [R2 k] | ViewPoint (paid) 4/8-point, volume deformation [R3 k] | dt rotate-and-perspective auto lines; RT perspective; RapidRAW guided [R4 src] | — | `model-only` — `Recipe.upright: Upright?` `Recipe.swift:1225`; "wire format with no stage behind" `CropPanel.swift:372` | guided/auto keystone stage · L, or delete the wire field · S |
| Lens profile corrections | Remove CA, profile, Distortion/Vignetting 0–200 [R1 d] | Distortion/Sharpness Falloff/Light Falloff/CA/Diffraction, LCC [R2 s] | Optics Modules >89k, blur field, longitudinal CA, on-demand download [R3 s] | lensfun / LCP, manual distortion [R4 k] | — | `partial` — `LensCorrections.profile: Bool` → Apple decoder `AppleRawSource.swift:118`; no per-axis sliders, no manual distortion | manual distortion/vignette amount · S |
| CA removal / defringe | Remove CA + Defringe purple/green 0–20 + hue ranges, eyedropper, ⌥ B&W [R1 d] | CA analyse + Purple Fringing tool [R2 s] | lateral CA auto, purple fringing size [R3 s] | RT CFA auto-CA polynomial, `defringe` Lab [R4 src] | Dehancer Defringe [R5 s] | `model-only` — `LensCorrections.removeCA`, `Defringe` 6 fields `Recipe.swift:1327-1357`; "wire format … no reader anywhere" `EffectsPanel.swift:430`, `RecipeMasks.swift` "BLOCKED" | Lab-domain defringe stage · M, or delete · S |
| Heal / clone / remove | Remove Q (generative), Heal, Clone [R1 d] | Heal/Clone layers [R2 s] | ReTouch [R3 k] | dt retouch heal/clone/fill/blur [R4 k] | Luminar GenErase cloud-only [R5 s] | `model-only` — `Heal` `Recipe.swift:1388`, no render stage (PLAN) | content-aware fill stage · L, or delete · S |
| Diffraction / flat-field / dark-frame | — | Diffraction checkbox [R2 s] | via module [R3 s] | RT ff_/df_ fields [R4 src] | — | `absent` | LibRaw path only · L |
| Demosaic choice | — | — | joint CNN [R3 s] | dt/RT 15+ methods, dual [R4 src] | — | `absent` — Apple's (undocumented) | cannot match without LibRaw · — |

**Top 5 gaps (K):** 1. Three dead wire fields (Upright, Defringe/removeCA, Heal) — surface or delete. 2. Manual distortion/vignetting sliders. 3. Overlay cycle completeness (triangle/spiral, ⇧O). 4. Guided keystone. 5. Diffraction/deconvolution (with E).

---

## L · State / undo

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| History panel | every edit, click to time-travel, hover preview, no branching [R1 d] | **none** (⌘Z only; variants) [R2 k] | Advanced History with tool + value per row, persisted [R3 s] | dt history = the document, compress; RT history + bookmarks [R4 k] | Luminar per-image history [R5 s] | `partial` — `HistoryStack.swift` record/undo/redo + `HistoryCoalescing`, `history` table; **no visible history list** (0 hits in `DevelopColumn`/`ContentView`) | history list with values (Law 24) · M |
| Snapshots | named, alphabetical, Update, sync via XMP [R1 d] | — | virtual copies [R3 k] | dt snapshots with split view [R4 k] | — | `model-only` — `HistoryStack.snapshots` `:202-209`; `CatalogService.swift:551` "until snapshots ship" | snapshot rows + compare · S |
| Virtual copies | yes [R1 d] | variants [R2 k] | any number [R3 k] | dt duplicates [R4 k] | — | `model-only` — `edit.kind` working/virtual copy/snapshot `CatalogStore.swift:91`; 0 hits "virtual" in `Sources/LumenApp` | New-copy action + grid badge · S |
| Copy / paste / sync subsets | checkbox tree incl. masks, saved subsets, Previous, Sync, Auto Sync, Match Total Exposures [R1 d] | copy all layers+masks [R2 s] | partial presets [R3 s] | RT partial profiles [R4 k] | Luminar/ON1 Sync [R5 s] | `present` — `LookSubset` look/develop-preset/import-default, `applied(toAll:)`; no Auto-Sync (0 hits) | Auto-Sync toggle · S; Match Total Exposures · S |
| Undo granularity | one drag = one step [R1 d] | unlimited session ⌘Z [R2 k] | standard [R3 k] | dt per-module item [R4 k] | — | `present` — `HistoryCoalescing.swift`, `CommandState.swift` Edit menu | A2/L verify "one drag one step everywhere" |
| Reset | ⇧⌘R, ⌥ = Set Default [R1 d] | per-tool reset arrow [R2 s] | per-tool reset [R3 s] | dt per-module reset [R4 k] | — | `present` — per-section Reset via `WorkspaceModification`; 0 hits `resetAll` | whole-recipe Reset + "set as default" · S |

**Top 5 gaps (L):** 1. Visible history list. 2. Snapshots UI (model waiting). 3. Virtual copies UI. 4. Auto-Sync. 5. Whole-photo Reset / set-default.

---

## M · Recipe / serialization / sidecars

| capability | LrC | C1 | DxO | dt/RT | creative | **Lumen** | gap |
|---|---|---|---|---|---|---|---|
| Sidecar format | XMP `crs:` parametric; AI rasters + Denoise in `.lrcat-data` [R1 d] | `.cos` XML; XMP metadata only [R2 k] | `.dop` all corrections + copies + history [R3 k] | dt XMP hex-packed structs; RT `.pp3` INI; RapidRAW JSON [R4 src] | ON1 sidecar/catalog [R5 s] | `present` — `XMPSidecar` `lumen:recipe` canonical sparse JSON + `xmp:Rating/Label`, `XMPMerge` in-place; `CanonicalJSON`, `Fingerprint` | history/snapshots in sidecar (DxO/dt do) · S |
| Version migration | PV silent upgrade [R1 d] | — | major-version migrated on open [R3 k] | dt modversion per module + legacy_params [R4 src] | — | `present` — `pipelineVersion`, tolerant decode, badged migration `Recipe.swift:14-29`, `RecipeDecoding.swift` | per-sub-struct migration check (M) · S |
| Dead / duplicate wire fields | — | — | — | — | — | `partial` — TWO grain structs (`FilmGrain`, `CreativeGrain`); dead `printSize`; `Upright`, `Defringe`, `removeCA`, `Heal`, `look.lut`, `depthRange` + 4 AI kinds without a stage/model; `Denoise.model` unused; `LocalAdjust.noise/noiseChroma/grainAmount/moire/defringe` unrendered | one `Grain` + migration [R7 M] · M; delete-or-surface list (K, D, F) · S each |
| Halation on the wire | — | — | — | — | Dehancer per-profile [R5 s] | `partial` — `halation: Double` only; Size/Redness are constructor args [R7 M] | `halationSize`, `halationRedness` tolerant-decoded · S |
| Look files | `.xmp` presets in folder [R1 k] | Styles packs [R2 s] | `.preset` export/import [R3 k] | dt styles export; RT `.pp3` [R4 k] | ON1 Presets Manager import/export [R5 s] | `absent` — looks live in `look` table only (0 hits export/import) | `.lumenlook` export/import · S |
| Stock data | — | — | lab-scanned proprietary [R3 s] | — | spektrafilm JSON profiles CC BY-SA [R7 f] | `present` — Swift literals `FilmLab.swift:214-420` | `Resources/film/<id>.json` fitted, Lumen-authored [R7] · M |
| Model identity on artifacts | — | once-per-raw cache [R2 s] | — | darktable-ai model per task [R6 f] | — | `present` — `model_id`/`model_version` on artifact table `Schema.swift:214`; `ArtifactKey` | fine as designed · — |
| AI raster regeneration | `.lrcat-data`, re-run elsewhere [R1 d] | — | — | — | — | `present` — `MaskRasterCache.swift` regenerable, never in sidecar (docs/02 §6.5 verdict) | none |

**Top 5 gaps (M):** 1. Merge the two grain structs. 2. Halation size/redness on the wire. 3. Decide every dead wire field. 4. Look export/import file. 5. Film stock data as fitted JSON.

---

## Cross-cutting

### Everything (or nearly everything) the field does that Lumen does not

1. **Preset/look Amount** — LrC 0–200, C1 layer opacity, DxO Intensity, RapidRAW intensity, Luminar/Radiant strength. Lumen: all-or-nothing `LookSubset.applied` (K-key `lookAmount` exists in `SpeedEdit` — verify what it drives).
2. **Live look previews** — LrC hover, C1 hover, Luminar/ON1 image-rendered cards. Lumen: text list, `LookPanel.swift:168` admits it.
3. **A colour-range isolation view** — LrC Visualize Range, C1 View selected color range, LrC ⌥-drag mattes. Lumen: none.
4. **AI mattes beyond person/foreground** — LrC 6 tools, C1 4, DxO 10 subject types, Luminar/ON1 sky + object. Lumen: 2 Vision requests; four kinds enumerated with no provider.
5. **A shipping AI denoiser** — LrC, C1, DxO, dt 5.6, ON1, Luminar all have one; Lumen's "AI" segment drives Apple's classical NR.
6. **On-canvas radial/linear extras** — ⌥-from-centre, ⌘-double-click fill, duplicate-by-drag, Delete key, scroll-to-size (dt), pin visibility modes.
7. **Visible history list / snapshots / virtual copies** — LrC, DxO, dt, RT all show a list; C1 is the only peer without one. Lumen has the model, no view.
8. **Panel chrome hide + user surround / lights-out** — LrC Tab/L, dt ⌃B, C1 right-click background. Lumen: fixed token.
9. **Image watermark, Dimensions/Percentage resize, DNG out** — every export dialog in the set.
10. **Halation size + colour controls** — Dehancer 5, Nitrate 4, Filmbox 1, Resolve 4. Lumen: Amount only.
11. **Grain tonal envelope + chroma** — DxO 3-zone matrices, Filmbox 9-zone + dye colour, Nitrate 3-point + sat. Lumen: fixed p(1−p), mono-or-rainbow.
12. **Working ingest** — LrC, C1 (with faces/stacks). Lumen: a sheet that plans and cannot copy.
13. **Focus peaking overlay** — C1 (threshold 250). Lumen: engine in `Scopes.swift`, no overlay.
14. **Levels / output black-white targets** — C1 Levels. Lumen: none (mask density only).

### What Lumen does that no competitor in the set does — the audit should protect these

1. **Local point curve + local grading wheels inside a mask** (`LocalAdjust.curve/wheels`, `MaskPanel.swift:1771-1843`) — LrC explicitly has neither; C1/DxO give per-layer tools but not wheels+curve together.
2. **Zone tone with movable pivots** (`Zones.pivots`, `ZonesPanel`) and **grading-wheel pivots** (`GradingWheels.pivots`) — LrC/C1 hide the zone boundaries.
3. **The query sentence** in the filter bar (`LibraryFilter.sentence`, `FilterBar.swift:52`) and the **All/Any** grammar — no peer spells the active filter in words.
4. **⌘K control palette** (`ControlIndex.swift`: "Nobody in the field has this").
5. **Slider arithmetic entry** (`SliderEntry.swift` `+=0.3`, `*2`) and ⇧-fine drag — C1 users ask for a fine-drag modifier and do not have one.
6. **Waveform / RGB parade / OKLab vectorscope with skin graticule** (`ScopesView.swift`) and the **raw-truth histogram** (`RawTruthPanel.swift`) — every peer stops at a histogram.
7. **Momentary inspection holds** `[`/`]` shadow-boost / highlight-inspect (`InspectionHolds.swift`).
8. **Physical film chain with per-stock halation** (negative→print sigmoids, S13 scene-linear halation, density-domain grain) — DxO FilmPack has no halation control at all; the stills-editor peers are LUT overlays.
9. **Add / Subtract / Intersect as three equal, post-hoc editable buttons** (`MaskPanel.swift:13`) plus `maskRef` raster reuse and mask groups — LrC hides Intersect behind ⌥.
10. **Output sharpening per medium with PPI-derived radius** — DxO has none; C1/LrC have it but Lumen's is scene-aware by design.
11. **Denoise Amount as an instant post-compute blend with a disk artifact keyed by model+fingerprint** (`AIDenoiseSplice`, `ArtifactKey`) — the design LrC only reached in 14.4; it just needs a model behind it.
12. **Six-channel luminance range** (`luma/red/green/blue/max/min`, `RecipeMasks.swift:366`) and the similarity-line (grad × U-Point) component.
13. **Canonical sparse JSON recipe with a fingerprint in the XMP sidecar**, never a hex struct (dt) or a catalog-only raster (LrC).

### Corrections to the dossiers found by grep

- `refineSaturation`: **0 hits** in `Sources/` — R1 §A.2's "appears in `Recipe.swift` only" is wrong; the control is absent.
- Manual sharpening **has** a Radius row (`DetailPanel.swift:236`); R1 §E.2's "deliberately has no Radius row" reads the file header, which refers to the Denoise fold.
- Brush **flow digit keys are present** (`MaskCanvas.swift:363` help text); R1 §F's "flow digit keys absent" is wrong (Keymap digits are ratings only outside the mask canvas).
- FilterBar **does** carry camera/lens/ISO/keyword/stack facets behind a menu (`FilterBar.swift:273-321`); R2 §J's `AppState.swift:236` quote is the in-memory fallback's limitation, not the bar's.
