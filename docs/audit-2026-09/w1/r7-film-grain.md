# R7 — Film emulation & grain science (W1 dossier)

Feeds the C1/C2 audits and the W5 film/grain stream. Every claim is tagged `[code: path]`,
`[search: url]`, `[fetch: url]` (page read in full), `[knowledge]` (training, unverified) or
`[docs/NN]` (already in the repo). Blocked domains this session, tried once each and not
retried: ipol.im, lirmm.fr, blog.dehancer.com, dehancer.com, videovillage.com,
postperspective.com. github.com and raw.githubusercontent.com read in full.

Areas A, B, F, G, H, J, K, L: **Not applicable** except where film touches them (noted inline
under C, D, I, M). The body is area C; D, E, I, M carry the spill-over.

---

## A Tone & sliders — Not applicable
(Film Exposure and Push/Pull are Film Lab controls; see C.)

## B Colour & grading — Not applicable
(Crossover, couplers and the print stage are film-model internals; see C §1.)

---

## C Film & grain

### C.0 Lumen today — what actually ships (read before the spec)

| Piece | As built | Source |
|---|---|---|
| Recipe | `FilmLab{stock: String, amount 0–100 (Strength), exposure −2…+3 EV, pushPull −1…+2, halation 0–100, grain: FilmGrain{size 1.0 (UI clamps 0.5–2.0), amount 0–100}, printSize: String? ("8x10", nil = 10 in)}` | [code: Sources/LumenCore/Recipe/RecipeLook.swift:409–477] |
| Second grain | `CreativeGrain{amount 0–100 (0 = off), size 0–100 → 7…56 µm pitch (comment says 4…32, code says 7…56), roughness 0–100 → persistence 0.25…0.75}` at `look.grain` | [code: Recipe.swift:986–999; FilmLab.swift `creativePitchMicrons`] |
| Panel rows (Film Lab, in Look) | Stock (menu: None + 6), Strength 0–100 step 1, Film Exposure −2…3 step 0.25, Push/Pull −1…2 step 0.25 (NOT detented at whole stops as docs/05 says), Halation 0–100 (default per stock), Grain 0–100 (default per stock), Grain size 0.5–2.0. **No** Halation Size, **no** Halation Redness, **no** print size / format row. | [code: Sources/LumenApp/LookPanel.swift:946–1010] |
| Effects › Grain | Two rows (Amount, Size 0.5–2) when a film chain owns the grain; three rows (Amount, Size 0–100, Roughness) otherwise. `GrainPlan.filmOwnsTheGrain` decides. | [code: Sources/LumenApp/EffectsPanel.swift:214–330; FilmLab.swift `filmOwnsTheGrain`] |
| Stock model | `FilmCharacteristic{gamma RGB, dMin RGB, dMax RGB, logOffset RGB}` per stage, symmetric logistic `D = Dmin + (Dmax−Dmin)·σ(k·(log10 E + off))`, `k = γ/(0.25·span)`; `FilmCrossover{shadowTint, highlightTint, pushTint, interlayer 0…0.6, coupler −0.5…0.5}`; halation `{strength RGB, default, redness}`; grain `{default, sizeScale RGB, pitchMicrons, gateLongEdgeMM}` | [code: FilmLab.swift:45–200] |
| Stocks shipped (6) | Portra 400 (γ .545/.550/.560, print γ 2.48, pitch 12 µm, halation 35, grain 45), Gold 200 (γ .605/.590/.578, 14 µm, 45, 55), Ektar 100 (γ .665/.665/.670, 7 µm, 15, 15), Tri-X 400 (mono, γ .62, print γ 2.35, 18 µm, 20, 70), Velvia 50 (reversal, γ 1.72/1.75/1.80, Dmax 3.4–3.5, 6 µm, halation 0, grain 12), Cine 250D (γ .50/.505/.51, print γ 2.62, gate 24.9 mm, 10 µm, 30, 30) | [code: FilmLab.swift:214–420] |
| Chain per pixel | scene × 2^exposure → (mono: Rec.2020 luma) → × filmGain → negative sigmoid → 3×3 coupling (DIR `interlayer` spreads channels from their mean; `coupler` rotates about neutral, rows sum 1) → shadow/highlight tints weighted by the sigmoid's own tone (`1−smoothstep(0,.6,t)`, `smoothstep(.4,1,t)`) → T = 10^−D → × printGain → print sigmoid → T → normalise between paper white and max black → × displayWhite. Mid-grey gains solved by bisection so 0.18 → 0.18 per channel. Blended against the recipe's own solved display transform by Strength (the docs/31 #2 discontinuity is fixed). Baked to a 3-D LUT over LumenLog (65³ export / 33³ interactive). | [code: FilmLab.swift `FilmChain.render`, `solveGains`, `bakeLUT`; RenderPlan.swift:251–272] |
| Push | negative γ × (1 + 0.18·push·(1 + (0.03, 0, −0.03))); shadow tint += pushTint·push; grain amount × (1+0.35·push); pitch × (1+0.15·push). No fog rise, no speed/exposure coupling. | [code: FilmLab.swift `build`, `FilmGrainProfile.init(stock:)`] |
| Halation (S13) | On scene-linear after vignette, before formation. GPU energy = `max(E − 0.25·clip, 0) × 2^0.3`; CPU reference = smoothstep gate over the 4 EV below clip × up to 0.3 stop boost (the two are matched at the half-power point, not identical). Three Gaussians σ₁·√k, k=1..3, σ₁ = 65 µm·size/gate·px (4.6 px at 2560 px/36 mm; 14.4 px at 8000), raw weights 1, .5, .25 (sum 1.75, not normalised on the apply path), per-channel strength = stock (0.05, 0.015, 0) mixed toward pure red by Redness × Amount. Full working-res blur; the "quarter-res" of docs/14 §5.7 is not visible in `applyHalation`. | [code: FilmLab.swift `HalationProfile`; RenderGraph.swift:1320–1360; ReferenceRenderer.swift:473–505] |
| Grain (post-formation) | On the FORMED display-linear picture, after S14 and the local-curve tap, before output encoding: `D = −log10(max(v,1e-5))`, `p = D/Dmax`, `D' = D + amount·√(p(1−p))·n`, `v' = 10^−D'`. `amount` = grain/100 × 0.12 density units (peak). `Dmax` = mean print dMax (Portra 2.2 → peak at v = 0.079); creative grain uses Dmax 4.0 (peak at v = 0.01 — 87 % of peak still at v = 0.001; harmless on screen, wrong in principle). | [code: Kernels.swift:578–590 `lumenGrain`; ReferenceRenderer.swift:521–560; FilmLab.swift `grainDMax`, `creativeDMax`] |
| Plate | 128² value noise, 4 octaves, base 8 lattice cells across the plate (features 2–16 plate px), persistence 0.5 (Roughness 0.25–0.75), Hermite, renormalised to unit variance, SplitMix hash, `defaultPlateSeed`; 3 seeds (colour stock) or 1 (mono/creative); `CIAffineTile` at `plateScale = pitch_µm × longEdgePx / (gate_mm × 1000)` px per plate pixel, per-channel × (0.8, 1.0, 2.0), **floored at 0.5 px**. | [code: FilmLab.swift `plate`, `plateScale`; PipelineRenderer.swift:1452–1500; RenderGraph.swift:1405–1450] |
| Export | Grain deferred (`deferGrain: true`), applied after the resize on the delivered grid with `plateLongEdge = decode × delivered ÷ cropped`. | [code: PipelineRenderer.swift:610, 680–700] |
| Tests that exist | amplitude parity σ(400) vs σ(1200→400) (`ScaleHonestyTests:272`), delivered-grid parity (`KernelGoldenTests:1211`), three-layer/one-layer plates, determinism/unit variance, gate-not-print anchoring, 0.5-px floor saturation (`EngineIntegrationTests:1075–1330`). **None** checks pattern identity (per-pixel correlation) or spectrum across sizes. | [code: Tests/…] |

**Two findings from the arithmetic, not from taste:**

1. **The 0.5-px floor breaks preview↔export parity for the fine stocks.** Floor hits when
   `longEdge < 0.5 × gate × 1000 / pitch`: Portra 1500 px, Gold 1286, Cine 1245, Tri-X 1000 —
   fine at a 2560 working edge — but **Ektar 2571 px and Velvia 3000 px**: at the 2560-px
   working edge those two are always floored, so the preview shows coarser grain at a
   different spatial frequency from the export (the "22 % and a different frequency" the
   test comment admits). [code: `plateScale`, `RenderGraph.workingLongEdge` per the comment in `creativePitchMinMicrons`]
2. **Colour stocks grow coloured blotches at export that the preview never shows.** Portra at
   2560 px: R 0.68 / G 0.85 / B 1.7 px cells — sub-pixel, reads as luminance. At 8000 px:
   R 2.1 / G 2.7 / **B 5.3 px** independent full-amplitude fields — the same rainbow the owner
   rejected in the creative grain, arriving in the film path only at export. The fix is a
   chroma fraction (spec C.2.3), not three seeds or one.

### C.1 Film emulation — the science, then a spec

#### C.1.1 Where the look comes from

| Mechanism | What it does to the picture | Source |
|---|---|---|
| Negative H&D curve per layer | Density vs log10 exposure: long toe (shadows compress gently, lifted then crushed under push), straight line with slope γ ≈ 0.5–0.65 for colour negatives (status M), short shoulder. Latitude: 5+ stops over, ~2 under. The three layers are near-parallel on the pro stocks (Portra) and diverge on consumer stocks (Gold/Ultramax) — divergence = crossover: a cast that changes sign between toe and shoulder. | [knowledge]; datasheets below publish the three curves per stock; Lumen's `logOffset`/`gamma` per channel already express this [code] |
| Spectral sensitivity vs the camera | Each layer's log-sensitivity curve (published 380–780 nm) overlaps its neighbours and differs from the camera's CFA; the mismatch is a per-stock 3×3 (plus a small non-linear residue) between camera RGB and layer exposures. It is the source of "film's greens/blues" that a curve can't make. Absent from Lumen: layers are driven by Rec.2020 RGB directly. | [fetch: github.com/andreavolpato/spektrafilm — profiles carry `log_sensitivity` 81 samples 380–780 nm]; [knowledge] |
| Inter-layer effects (DIR couplers) | Developing silver in one layer releases an inhibitor that diffuses (σ ≈ 20 µm + a 200 µm tail) into neighbours: raises saturation (channel densities spread from their mean) and produces edge micro-contrast — film's built-in clarity. Lumen's `interlayer` is the flat-field half (a 3×3); the spatial half (a small unsharp-mask on the density triple at ~20 µm) is absent. | [docs/03 §7.7 verified constants: same-layer gammas .341/.324/.273, σ 20 µm + 200 µm]; [code: `couplingMatrix`] |
| Masking couplers / orange mask | Coloured couplers correct the unwanted absorptions of the cyan and magenta dyes; the residue is the orange Dmin (status M ≈ R 0.2 / G 0.6 / B 0.9 on C-41). Lumen's `coupler` is a small rotation about neutral; the mask itself is irrelevant to Lumen because `solveGains` neutralises any global cast — a consequence worth stating: **Lumen's stocks cannot carry an overall warmth; every colour lives in divergence and tints.** | [knowledge]; [code: `solveGains`] |
| Print stage | Paper (Endura/Crystal Archive, γ ≈ 2.5–3.0) or print film (2383, γ ≈ 3.2–3.6, Dmax > 4) is where the S-curve comes from; the enlarger's Y/M filtration neutralises the mask (verified neutral defaults Y=55 M=65 CC); print grades (B&W papers 0–5) set the print γ from ~1.5 to ~4. Lumen: one print curve per stock, γ 2.35–2.62, gains solved = auto-neutral enlarger. | [docs/03 §7.7]; [knowledge]; [code] |
| Dye density → viewing | T = 10^−D per layer makes colour subtractive: saturated colours darken as they saturate. Lumen has it. | [docs/14 §5.7]; [code: `render`] |

#### C.1.2 The three routes

| Route | Fidelity | Cost / licence | Verdict for Lumen |
|---|---|---|---|
| (a) 3-D LUT from real scans (Dehancer "profiled at three exposure states", RNI, Mastin) | Highest for the sampled exposure; falls apart ±1.5 EV outside the sampled states; no spatial physics; per-camera drift | Needs the film, a lab and a scanner per stock; proprietary data | Not for Lumen: nothing to bake from, and it can't express Film Exposure/Push. |
| (b) Curve + matrix fitted to datasheets (Lumen today; darktable/RT have nothing comparable — RawTherapee "Film Simulation" is HaldCLUT only) | Right tonal physics (latitude, subtractive darkening, print S), crossover as authored, no spectral hue skews | Zero runtime cost (LUT bake); datasheets are public PDFs | **Keep, and finish it**: replace authored γ/offset with fitted per-layer curves (asymmetric toe/shoulder), add a per-stock 3×3 sensitivity remap, add paper families. |
| (c) Spectral simulation (spektrafilm: spectral upsampling → layer sensitivities → density curves → DIR couplers → diffusion → halation → grain → paper → enlarger; Filmbox: "dense datasets … spectral radiance") | The ceiling: hue skews, coupler saturation, edge micro-contrast all emerge | ~10 s / 6 MP on CPU (offline only); code GPLv3, profiles CC BY-SA 4.0, LUTs "no resale"; must be re-implemented clean-room from the datasheets | Phase 2: an offline baker that produces the 65³ LUT per stock × print × push; runtime unchanged. Not in 24 h. |

[fetch: github.com/andreavolpato/spektrafilm README + `src/spektrafilm/model/{couplers,density_curves,develop,diffusion,glare,grain,parametric,stocks}.py` listing]; [search: videovillage.com/filmbox]; [search: dehancer.com/learn/article/film-profiles]

**Public datasheets with the three characteristic curves (verified by search unless tagged):**
Portra 400 E-4050 (2010/2016/2025 editions; spektrafilm digitised the 2016 one), Portra 160
E-4051, Ektar 100 E-4046 (log H ref −0.84), Gold 200 E-7022, Ultramax 400 E-7023 (log H ref
−1.44), Vision3 500T 5219 and 250D 5207 (kodak.com PDFs, with RMS-granularity-vs-density
curves), Tri-X F-4017 (RMS 17 diffuse, 48 µm aperture — forum copies say 16), T-Max 100/400
F-4016/F-4043 (RMS 8/10), HP5 Plus (Harman tech sheet Nov 2018, curves at EI 400…3200),
Superia X-TRA 400 AF3-0217E (fujifilm.com). Fuji Pro 400H, Provia 100F, Velvia 50, Astia:
in the Internet Archive "fujifilm_datasheets" collection [search: archive.org/details/fujifilm_datasheets]
— individual links not returned; [knowledge] that each carries curves and RMS (Velvia 50 ≈ 9,
Provia 100F ≈ 8, Astia ≈ 7). Portra 800 E-4040 publishes normal / push-1 / push-2 curves
[knowledge; consistent with spektrafilm shipping `kodak_portra_800_push1/push2`]. CineStill
800T has no curve datasheet: it is 5219 with the rem-jet removed [search: cinestillfilm.com]
— use the 5219 curves + strong halation. Ilford Delta 100/400/3200, FP4+: tech sheets exist
[knowledge].

**Spektrafilm's 28 profiles (CC BY-SA 4.0 data, listed for scope, not for copying):** Kodak
Portra 160/400/800 (+push1/push2), Ektar 100, Gold 200, Ultramax 400, Vision3 50D/200T/250D/
500T, Ektachrome 100, Kodachrome 64, Verita 200D; papers 2383, 2393, Endura Premier, Portra
Endura, Supra Endura, Ultra Endura, Ektacolor Edge; Fuji C200, Pro 400H, Provia 100F, Velvia
100, X-TRA 400, Crystal Archive Type II. [fetch: github.com/andreavolpato/spektrafilm/tree/main/src/spektrafilm/data/profiles]

#### C.1.3 Spec — the model additions, then ~10 stocks

**Model additions (in priority order; each one line to the auditor):**

1. **Asymmetric curve.** Replace the symmetric logistic with a two-slope logistic that is C¹
   at the centre: `x = k·(log10 E + off)`, `S = σ(x·(1 − t))` for `x<0`, `σ(x·(1 + s))` for
   `x≥0`, with `toe t ∈ [0, 0.6]`, `shoulder s ∈ [−0.3, 0.5]` per layer (negatives: t ≈ 0.35,
   s ≈ 0.1; slides: t ≈ 0.1, s ≈ 0.3). Fit t, s, γ, off, Dmin, Dmax per layer by least squares
   to the digitised datasheet curve (WebPlotDigitizer, 30–40 points per curve, residual target
   < 0.03 D). `FilmCharacteristic` gains two RGB fields; `FilmStage.response` gains two
   multiplies. [derivation]
2. **Sensitivity remap.** A per-stock 3×3 `sensitivity: Mat3` applied to scene RGB before
   `filmGain` (rows sum to 1 so the grey solve is undisturbed). Derive offline: integrate the
   datasheet log-sensitivity curves against the Rec.2020 primaries' spectra (or a reference
   camera SSF) and normalise to D55; first-order values [knowledge]: Portra family mild
   (off-diagonals ≈ 0.05–0.10, green layer picks up red); Velvia stronger green→red
   crosstalk (its famous foliage). Until fitted, ship identity. [derivation]
3. **Fog under push.** `dMin += 0.04·push` (all layers) and `logOffset −= 0.15·push` (the
   ~½-stop real speed gain); expose Push as "underexpose + overdevelop" by lowering the
   effective film exposure by `0.5·push` EV. Today push only steepens. [knowledge: C-41 push
   yields ~⅓–½ stop true speed, contrast +10–15 %/stop, fog +0.03–0.05 D/stop]
4. **Paper families** instead of one paper per stock: Type-C (Endura-class, γ 2.6), Fuji
   Crystal Archive (γ 2.8, cooler shadows), 2383 print film (γ 3.3, Dmax 4.0, for the cine
   stocks), B&W grades 1–4 (γ 1.8/2.35/2.9/3.5). `printCurve` becomes a reference into a
   paper table; a Print Stock row appears in the panel (docs/05 already lists it).
5. **Spatial DIR term** (later, needs a stage, not a LUT): unsharp mask on the density triple
   at σ = 20 µm at the gate (1.4 px at 2560/36 mm), gain = `interlayer × 0.5`. It is the
   "film clarity"; Lumen's texture tool is the cheap stand-in.

**Per-stock parameters — values or a derivation, with confidence.** γ is the straight-line
slope in status-M density per log10 exposure; Dmin is over base for the negative model
(Lumen's solve makes absolute mask values moot); Dmax is the span the sigmoid reaches;
crossover as `logOffset`/`shadowTint` direction; halation as Amount/Redness/σ₁ multiplier
vs Lumen's 65 µm; grain as pitch µm / Amount on Lumen's 0–100. RMS = diffuse RMS granularity
× 1000 at 48 µm aperture; PGI = Kodak Print Grain Index (not comparable to RMS).

| Stock | Kind | γ R/G/B | toe t / shoulder s | Dmin, Dmax (neg) | Crossover / colour | Halation A / red / σ× | Grain pitch / Amount (RMS or PGI) | Confidence |
|---|---|---|---|---|---|---|---|---|
| Portra 160 | C-41 neg | .52/.53/.54 | .35/.10 | 0.05/0.12/0.20, 2.0 | parallel layers, slight warm shadows; lowest saturation of the family | 25 / 25 / 1.0 | 8 µm / 30 (PGI ≈ 27 [knowledge]) | γ medium (E-4051 curves are near-parallel), grain medium |
| Portra 400 | C-41 neg | .55/.56/.57 (Lumen .545/.55/.56 — keep) | .35/.10 | as Lumen | as Lumen | 35 / 25 / 1.0 | 12 µm / 45 (PGI 36 [search: E-4050]) | high for shape, medium for numbers |
| Portra 800 | C-41 neg | .55/.57/.58; push1 ×1.12, push2 ×1.25 | .40/.10 | +0.05 fog per push stop | push walks shadows cool-green, highlights warm (Lumen's `pushTint` sign matches) | 40 / 30 / 1.0 | 14 µm / 60 (PGI ≈ 47 [knowledge]); push1 ×1.3, push2 ×1.7 | medium; E-4040 push curves make it high once digitised |
| Ektar 100 | C-41 neg | .66/.66/.67 (keep) | .30/.15 | as Lumen | red layer slightly steeper than blue → warm highlights, cyan-leaning shadows; interlayer 0.26 (keep) | 15 / 15 / 1.0 | 7 µm / 20 (PGI < 25 [search: E-4046 "finest grain"]) | high |
| Gold 200 | C-41 neg | .61/.59/.575 (keep) | .40/.10 | as Lumen | real crossover: golden highlights, cool shadows (keep Lumen's tints) | 45 / 35 / 1.0 | 12 µm / 40 (PGI ≈ 39 [knowledge]) | medium |
| Ultramax 400 | C-41 neg | .62/.60/.58 | .40/.10 | 0.06/0.14/0.22, 2.1 | strongest consumer crossover; saturation above Gold (interlayer 0.22, coupler 0.10) | 50 / 40 / 1.0 | 14 µm / 55 (PGI ≈ 44 [knowledge]) | low-medium (E-7023 exists; not digitised) |
| Vision3 250D → 2383 | ECN-2 neg, Super 35 | .50/.505/.51 (keep); 2383 γ 3.3, Dmax 4.0 | .30/.05 (very long straight line) | 0.10/0.20/0.30, 2.0 | neutral; cine "teal shadow" is the print's, not the negative's | 30 / 20 / 1.0 | 9 µm at 24.9 mm gate / 30 (granularity curve in 5207 sheet [search]) | medium |
| Vision3 500T → 2383 | ECN-2 neg, tungsten | .52/.525/.53 | .35/.05 | 0.12/0.22/0.32, 2.0 | tungsten balance: under daylight without 85 filter blue layer overexposes ~2 stops → `logOffset.b −0.6` variant | 35 / 25 / 1.0; **800T variant: 90 / 85 / 2.5 with strength ≈ (0.35, 0.10, 0.02)** | 12 µm at 24.9 mm / 50 | medium; 800T halation numbers are a derivation (no rem-jet ⇒ 6–10× base return) |
| Velvia 50 | E-6 reversal | 1.72/1.75/1.80 (keep) | .10/.30 | 0.12, 3.5 (keep) | magenta-leaning shadows, green crosstalk (sensitivity remap matters most here) | 0 | 6 µm / 12 (RMS 9 [knowledge]) | shape high, sensitivity low |
| Provia 100F | E-6 reversal | 1.55/1.55/1.55 | .10/.25 | 0.10, 3.6 | neutral, slightly cool | 0 | 6 µm / 12 (RMS 8 [knowledge]) | medium |
| Tri-X 400 | B&W neg, grade 2 | .62 (CI 0.56–0.62 in D-76 [knowledge]) | .45/.05 | 0.25, 2.2 | none; print grade sets γ | 20 / 0 / 1.0 (neutral) | 18 µm / 70 (RMS 17 [search: F-4017 via forum; sheet says 17]) | high |
| HP5 Plus | B&W neg | .60 at EI 400; EI 1600 ×1.2, 3200 ×1.3 (curves published) | .45/.05 | 0.25, 2.3 | none | 20 / 0 / 1.0 | 18 µm / 70 (no RMS published; visually ≈ Tri-X) | medium-high |
| T-Max 400 / Delta 400 | B&W T-grain | .60 | .30/.10 (straighter) | 0.20, 2.5 | none | 15 / 0 / 1.0 | 12 µm / 45 (RMS 10 [search: F-4043]) | high |
| Delta 3200 / P3200 | B&W push stock | .65 at EI 3200 | .50/.05 | 0.35, 2.2 | none | 20 / 0 / 1.0 | 26 µm / 100 (RMS ≈ 25–30 [knowledge]) | low-medium |

**Method that makes every row "high":** digitise the three curves of the named datasheet;
fit (γ, off, Dmin, Dmax, t, s) per layer; store as `Resources/film/<stock>.json` (Lumen's own
data, no CC BY-SA contamination); halation/grain from the table above; test that the fitted
curve reproduces the digitised points within 0.03 D and that `solveGains` still lands 0.18.

#### C.1.4 Push / pull — what changes physically → parameter deltas

Physics: longer development raises γ in all layers (upper layers develop faster → the
divergence), raises fog (Dmin), gains only ⅓–½ stop of true speed (the toe barely moves —
hence crushed shadows), coarsens grain (bigger developed clumps), and shifts colour
(for C-41: shadows toward green/cyan, highlights warmer). Pull does the reverse: lower γ,
lower saturation, finer grain, muddier. [knowledge]; [docs/03 §7.7: spektrafilm ships push1/push2 as distinct datasheet-derived profiles]

| Parameter | Per stop of push (pull is the negative, halved) | Lumen today |
|---|---|---|
| Negative γ | ×1.12 with divergence (+0.03, 0, −0.03) | ×1.18 with the same divergence — slightly strong |
| Dmin (fog) | +0.04 D | none |
| Effective film exposure | −0.5 EV (push = underexpose 1, regain ½) | none — push only steepens |
| Grain amount | ×1.30 | ×1.35 |
| Grain pitch | ×1.10 | ×1.15 |
| Shadow tint | += stock `pushTint` | present |
| Saturation (interlayer) | ×1.10 | none |

#### C.1.5 Halation — physics and parameters

Light that passes through the emulsion reflects off the film base back into the layers;
the anti-halation undercoat (rem-jet on cine stock, dyed layer on stills) absorbs most of
it; what survives is red-orange because red penetrates deepest. Radius ∝ base thickness
and scatters as a sum of Gaussians (base is not a single-scale scatterer); energy ∝ the
highlight energy above the film's clip, so it must be computed on scene-linear before the
curve. Slides have effective backing → ~0. CineStill 800T = 5219 with the rem-jet removed
→ the large red halo. [docs/03 §7.7 verified: (0.05, 0.015, 0) RGB, σ₁ 65 µm, 3 bounces, decay 0.5]; [knowledge]

| Product | Controls | Source |
|---|---|---|
| Lumen | Amount 0–100; Size 0.5–2× and Redness 0–100 exist in `HalationProfile` but not in the recipe or panel; GPU threshold 2^−2 of clip, boost 2^0.3 | [code] |
| Dehancer | Per-film halation profiles incl. "No Remjet" variants; Source Limiter (brightness threshold — low = more), Background Gain, Smoothness; halo size follows the film format (smaller gate → larger relative halo); Bloom is a separate print-side glow with Threshold / Highlights / Details | [search: blog.dehancer.com/articles/halation, dehancer.com film-profiles] |
| Filmbox | One Halation Radius slider ("relative to the preset", also drives the "Aura" big halation in some presets); Grain Amount; Gate Weave; Dust; Flicker | [search: videovillage.com/filmbox] |
| Resolve Film Look Creator | Halation Amount / Size / Threshold / Colour (hue), Bloom, Grain, Vignette in one panel | [knowledge]; [docs/03 §7.6] |

**Spec:** add `halationSize 0.5–2.0` (default 1) and `halationRedness 0–100` (default per
stock) to `FilmLab` wire format (already tolerant-decoded pattern), two rows in the panel;
add the 800T variant as a stock (strength ×7, σ₁ ×2.5, a 4th bounce, redness 85);
normalise the bounce weights on the apply path (`normalizedWeights` exists, `applyHalation`
uses raw) so Amount means the same across bounce counts; make the GPU energy gate the
smoothstep form (one `log2` per pixel is nothing at S13) so the two renderers stop
disagreeing at the foot of the ramp. Stage: unchanged (S13, scene-linear, after vignette).

#### C.1.6 Bloom vs halation vs glow; diffusion; light leaks

| Phenomenon | Physics | Chroma | Radius denominated in | Stage | Belongs in |
|---|---|---|---|---|---|
| Halation | base back-reflection | red-orange | µm at the gate | S13 pre-curve, scene-linear | Film Lab (present) |
| Bloom / lens diffusion (Pro-Mist) | scatter in the lens/filter, energy-preserving: `out = (1−f)·in + f·G_σ(in)` | achromatic (Pro-Mist slightly warm) | % of frame | before halation, scene-linear | Effects › Diffusion (docs/06), not Film Lab |
| Print-side bloom (Dehancer "Bloom") | scatter in the print/projection | achromatic | % of frame | after the print curve | optional, low priority |
| Glow (display-referred, post-curve additive) | none | — | px | — | never (Law 1); `lumenAddGlow` is only halation's adder, fine |
| Light leak | stray light fogs the negative through the base/edge | red-orange gradient | frame | S13 additive pre-curve so it follows the toe | Effects, later; not in 24 h |
| Gate weave / dust / flicker | transport, lab | — | — | video-only | out of scope |

### C.2 Grain — the science, then a spec

#### C.2.1 Models

| Model | Mechanism | Envelope vs tone | Cost | Source |
|---|---|---|---|---|
| Newson–Delon–Galerne 2017 (Boolean model) | Grains = discs, centres a Poisson process, radius log-normal (μ_r, σ_r; code default r = 0.1 px, σ_r = 0); density per unit area `λ(u) = −log(1−u) / (π(μ_r² + σ_r²))` (code: `lambda = −(ag²/(π(μR²+σR²)))·log(1−u)`, `ag = 1/ceil(1/r)`, `u = i/(MAX+ε)`); output pixel = Monte Carlo (N = 800) estimate of the coverage seen through a Gaussian of σ_filter = 0.8 px (`x + σ_filter·g/s`); resolution-free because the model is continuous, `zoom` just changes px per grain. Per-pixel seeded (`2016·offset`). | Coverage variance is binomial in transmittance: σ² ∝ u(1−u)·(grain area / pixel area) — the physical origin of the p(1−p) shape, in the **coverage** domain | 800 samples/pixel: seconds on GPU per MP, minutes CPU — export-grade, not one-frame | [fetch: raw.githubusercontent.com/alasdairnewson/film_grain_rendering_gpu/master/src/film_grain_rendering.cu]; [search: onlinelibrary.wiley.com cgf.13159]; GPLv3 code (algorithm is published maths) |
| Nutting / Selwyn granularity (the datasheet's number) | For random grains of mean area ā in aperture A: `σ_D = √(0.434·ā·D / A)` — RMS rises as √D, saturating toward Dmax; Kodak's Vision3 sheets plot exactly this curve vs density; "RMS granularity" = σ_D × 1000 at a 48 µm aperture, at D ≈ 1.0 | √D on the negative; through the paper: σ_print = (dD_print/dD_neg)·σ_neg → peaks in print mid-tones, asymmetric (print highlights/skies grainier than print shadows for a negative; reversed for a slide) | closed form — a 1-D LUT | [knowledge]; [search: Vision3 5207/5219 sheets "granularity curve", Wikipedia film grain: 48 µm aperture] |
| spektrafilm (per-layer particle counting) | `p = D/Dmax`, `n = pixel_area/particle_area` (0.2 µm² × per-layer scale), Poisson seeds → Binomial(p) developed → density = count × od_particle, Gaussian blur `blur_particle·√od_particle`, per-layer `particle_scale` (0.8/1.0/2.0 docs/03) | Binomial: σ_D ∝ √(p(1−p)) in density with Dmax ≈ 4 → for a negative (D ≤ 2.5, p ≤ .6) this is ≈ √D, i.e. Nutting | offline | [fetch: …/spektrafilm/model/grain.py]; [docs/03 §7.7] |
| darktable `grain` | 3-octave simplex noise (f = .491/.944/1.728, a = .234/.785/1.215 "to match power spectrum of real grain scans"), on Lab L only, strength × 0.15, scale 20–6400 ISO-equivalent / 213.2, `zoom = (1 + 8·scale/100)/800` relative to the short edge (gate-anchored, resolution independent), paper-response LUT with `midtones_bias` suppressing shadows/highlights; rank-1 lattice down-sampling when zoomed out (anti-alias) | paper LUT | one frame | [fetch: raw.githubusercontent.com/darktable-org/darktable/master/src/iop/grain.c]; GPLv3 — facts only |
| AV1 film-grain synthesis | 64×64 auto-regressive noise template (lag L ≤ 3, coefficients define the spectrum → band-limited by construction), random 32×32 crops with overlap blending, `Y' = Y + f(Y)·g` with a piecewise-linear scaling function f, chroma with an extra AR coefficient correlating to luma | piecewise-linear vs intensity | trivially one frame; identical at every decoder — the codec's answer to "same grain everywhere" | [search: norkin.org/research/film_grain, aomedia.org CWG-C051o]; [fetch: github.com/ncherel/film-grain-synthesis] |
| Noise-texture multiply (LR, most apps) | scanned/generated luminance texture blended at constant σ, screen-space size | none | trivial | [docs/02: LR Grain Amount/Size/Roughness, screen-space] |

Per-layer vs luminance: the three dye layers are physically independent, so a grey-card scan
does show coloured speckle at pixel scale, but eye chroma resolution is low and the layers'
clouds overlap, so it reads as luminance grain with a faint colour texture. Full-amplitude
independent fields at ≥ 2 px read as rainbow (the owner's verdict, and finding C.0-2). The
honest parameter is a **chroma fraction χ**: `n_c = n_L + χ·(n_c⁽ⁱⁿᵈ⁾ − n_L)`, χ ≈ 0.3 colour
negative, 0.15 slide, 0 B&W. [knowledge + code observation]

Print scaling: pitch in µm at the gate → `px = pitch × longEdgePx / (gate_mm × 1000)`; the
print size cancels (Lumen's `plateScale` comment is right); a crop enlarges the grain on the
print by the crop factor (Lumen's `plateLongEdge` is right). What the gate does: Super 35
(24.9 mm) grain is 1.45× coarser per frame than 35 mm stills; 120 (56 mm) 0.64×; half-frame
2×. `printSize` in the recipe therefore does nothing observable and should be replaced by
**Format** (35 mm / half-frame / Super 35 / 120 / 4×5), which docs/05 already lists.

#### C.2.2 Resolution independence

What makes grain identical at 1024–2560 px preview and 8000 px export:
(1) the pattern is defined in gate space (µm), not pixels — Lumen: yes; (2) the phase is
locked to the frame origin, not the tile — Lumen: `CIAffineTile` from the extent origin, and
export crops before graining, so the phase relative to the picture differs between a cropped
preview and its export by the crop offset mod the tile — **untested**; (3) the preview is the
band-limited (low-passed) version of the export — Lumen: no; the 0.5-px floor changes the
frequency instead (finding C.0-1), and value noise scaled below 1 px aliases through the
tile's bilinear sampler; (4) one seed — Lumen: yes (`defaultPlateSeed`, per channel offsets).

darktable's answer: gate-anchored frequency + rank-1 lattice averaging when zoomed out.
AV1's answer: a fixed template with a defined spectrum, so every decoder draws the same
field. Newson's answer: a continuous model, so any zoom is a re-integration.

#### C.2.3 Spec — the ONE grain system

**Merge.** One `Grain` block at `look.grain`, and `FilmLab.grain` goes away (decoded and
migrated on read: `size_slider = 100·log2(stockPitch·size/7)/3`, amount carried over).

```
Grain {
  amount    0–100   default: stock.grainDefault when a stock is loaded, else 0
  size      0–100   pitch = 7·2^(3·size/100) µm at the gate (7…56 µm; stock default → slider via the log map)
  roughness 0–100   persistence 0.25…0.75 (unchanged)
  chroma    0–100   χ = chroma/100; default 30 colour negative, 15 reversal, 0 B&W / bw.enabled
  format    35mm | halfFrame | super35 | 120 | 4x5   (replaces printSize; sets gate_mm)
  envelope  stock | neutral   (which 1-D amplitude LUT; stock when a chain is live)
}
```
Stated reason for ONE system: identical kernel, plate, plan, panel rows and tests; the
"who owns the grain" predicate (`filmOwnsTheGrain`, four call sites once) disappears — a
stock supplies defaults into the same block, and a user who pulls Strength to 0 keeps the
grain untouched. The film chain still contributes its envelope LUT and pitch default.

**Amplitude calibration** (why 0.12 and 0.5 are numbers, not facts): at the datasheet's
48 µm aperture, RMS 17 (Tri-X) is σ_D 0.017 at D 1.0; at a 12 µm render pixel (3000 px on
36 mm) σ_D = 0.017·48/12 = 0.068 on the negative; through a grade-2 paper (γ 2.35) ≈ 0.16
on the print. Lumen's amount 100 gives ≤ 0.06 print density — about a third of physical at
export size. Define `amount 100 ≡ σ_D,print 0.20 at the envelope peak` and the stock
defaults below become derivations: `amount = 100·(RMS/25)`.

**Envelope LUT** (`g(v)`, 256 entries, per stock, built at bake time by the CPU chain):
walk grey scene E over 12 stops → `D_neg(E)` → `σ_neg = √(D_neg − Dmin)·(1 − p_neg)^{1/2}`
(Nutting with saturation) → multiply by the local print slope `dD_print/dD_neg` → key by
the chain's output `v`. Gives the asymmetric, physically-derived peak for free; the
"neutral" envelope is the current `√(p(1−p))` with `Dmax = 2.2` (print, not 4.0). Reversal
stocks come out with grain in the shadows by construction.

**GPU kernel** (per pixel, no Monte Carlo):
```
D   = -log10(max(v, 1e-5))                       // formed display-linear, per channel
g   = envelopeLUT(luma(v))                        // 1-D texture, or √(p(1-p)), p = D/2.2
nL  = plate.a (luminance field)                   // one band-limited field, unit variance
nc  = plate.rgb (three decorrelated fields)       // sampled at pitch × (0.8, 1.0, 2.0)
n   = nL + chroma * (nc - nL)                     // chroma fraction
D'  = D + amountD * g * n                         // amountD = 0.20 * amount/100
v'  = 10^-D'
```
Stage: unchanged — after the print curve/local-curve tap, before output encoding, on
display-linear (the LUT bake forbids in-chain grain; the envelope LUT recovers the
negative-vs-print difference). Cost: one texture fetch + one LUT fetch + `exp2/log2` — the
present kernel's cost.

**Plate, band-limited and clump-shaped** (replaces the 0.5-px floor):
- Keep the 128² value-noise plate and seed, but choose the octave set from the render:
  drop any octave whose cell size is < 1 render pixel (`octaveCellPx = plateScale × 128/(8·2^o)`),
  and renormalise. A 2560-px preview then IS the low-pass of the 8000-px export — what a
  resample produces — instead of a re-pitched pattern. Plate build stays ~65 k evals.
- Clumping without Monte Carlo: add one cellular octave at the pitch (Worley F1, softened
  `smoothstep(0.2, 0.8, 1−F1)`) at weight 0.4, and skew the field `n' = (e^{0.3n} − E)/σ`
  so dense clumps are bigger than clear ones (positive density skew ≈ 0.3, kurtosis > 3 —
  measurable on the plate). Persistence still redistributes energy, not amplitude.
- Encode: unchanged (`plateEncodeScale` 8, RGBAf, alpha carries nL).

**The parity test that proves it** (`GrainParityTests`, LumenCore reference path, and one
GPU golden):
1. Flat 0.18 field, Portra 400 (and Velvia 50 — the floored case), rendered at 1024, 2560,
   6000 px; each box-downsampled to 512 px.
2. Assert per-pixel Pearson correlation of (render − mean) between every pair > 0.95, σ ratio
   within ±10 %, and the radially averaged power spectrum (cycles per frame) within 1 dB up
   to 200 cycles/frame (the 1024's Nyquist). Today the 6000-vs-2560 Velvia pair fails on
   frequency by construction.
3. Crop case: crop the 6000 to its central 50 %, render, compare against the same crop of
   the full render — correlation > 0.95 proves phase lock. (Absent today.)
4. Colour: on a colour stock at 8000 px, the chroma σ (a*b* of the downsampled grain) must
   be < χ × luminance σ — the rainbow gate.

#### C.2.4 Defaults per family (derivation: RMS at 48 µm → amount = 100·RMS/25; pitch from the stock table)

| Family | RMS (48 µm) / PGI | pitch µm | amount | chroma | roughness | envelope | Source |
|---|---|---|---|---|---|---|---|
| Colour neg ISO 100 (Ektar) | PGI < 25 ≈ RMS 9 | 7 | 35 | 25 | 45 | stock | [search: E-4046]; equivalence [knowledge] |
| Colour neg ISO 160 (Portra 160) | PGI 27 | 8 | 40 | 30 | 50 | stock | [knowledge] |
| Colour neg ISO 200 (Gold) | PGI 39 | 12 | 55 | 35 | 50 | stock | [knowledge] |
| Colour neg ISO 400 (Portra 400 / Ultramax) | PGI 36 / 44 | 12 / 14 | 60 / 70 | 30 / 40 | 50 | stock | [search: E-4050 PGI 36]; Ultramax [knowledge] |
| Colour neg ISO 800 (Portra 800, 800T) | PGI 47 | 14 | 75; push +1 ×1.3, +2 ×1.7 | 30 | 55 | stock | [knowledge] |
| Cine 250D / 500T (Super 35) | granularity curves | 9 / 12 at 24.9 mm | 40 / 60 | 25 | 50 | stock (2383 slope) | [search: 5207/5219 sheets] |
| Slide ISO 50–100 (Velvia, Provia) | RMS 9 / 8 | 6 | 35 / 30 | 15 | 45 | stock (reversal) | [knowledge] |
| B&W 100 (FP4+, T-Max 100) | RMS 8 | 9 | 32 | 0 | 50 | stock (grade) | [search: F-4016 RMS 8] |
| B&W 400 conventional (Tri-X, HP5+) | RMS 17 | 18 | 70 | 0 | 55 | stock | [search: F-4017] |
| B&W 400 T-grain (T-Max 400, Delta 400) | RMS 10 | 12 | 40 | 0 | 45 | stock | [search: F-4043] |
| B&W 3200 (Delta 3200, P3200) | RMS ≈ 25–30 | 26 | 100 | 0 | 65 | stock | [knowledge] |
| No stock ("creative") | — | 20 (size 50) | 0 | 20 (0 if bw) | 50 | neutral | Lumen's existing defaults |

Lumen would need (area C, one line): `Sources/LumenCore/Engine/FilmLab.swift` (asymmetric
curve, sensitivity Mat3, fog/push coupling, paper table, envelope LUT builder, band-limited +
cellular plate), `RecipeLook.swift` + `Recipe.swift` (one `Grain`, `halationSize/Redness`,
`format`), `Kernels.swift` `lumenGrain` (envelope texture + chroma mix), `RenderGraph.swift`/
`PipelineRenderer.swift` (plate builder takes the octave set from `plateScale`; halation weight
normalisation + smoothstep gate), `LookPanel.swift`/`EffectsPanel.swift` (rows), new
`Tests/LumenCoreTests/GrainParityTests.swift`.

---

## D Looks/presets & effects

| Capability | How it works | Source | Lumen would need |
|---|---|---|---|
| Film Look Creator pattern (Resolve 19) | one panel, preset-first, sliders behind a disclosure: format presets, tone/split-tone, halation, bloom, grain, vignette | [docs/03 §7.6] | Film Lab stock cards with hover preview (docs/05) — today a menu picker [code: LookPanel.swift:1097] |
| Diffusion / bloom | energy-preserving wide Gaussian, achromatic, scene-linear, before halation (C.1.6) | [knowledge]; [search: Dehancer Bloom Threshold/Highlights/Details] | an Effects › Diffusion row {amount, radius % frame}; reuse `gaussianBlur` + `lumenAddGlow` with `(1−f)` on the source |
| Light leaks, dust, gate weave | video-grade extras in Filmbox/Dehancer | [search: videovillage.com] | not for a stills editor in this cycle |
| Stock-as-preset | picking a stock seeds halation/grain defaults (`FilmChain.defaultRecipe`) | [code] | keep; with the merged `Grain`, seeding writes `look.grain` |

## E Denoise & sharpening
Only the interaction: grain must be applied after denoise/sharpen (it is — S3/S8 precede
S14; export sharpen `applyOutputSharpen` runs AFTER grain [code: PipelineRenderer.swift:700],
which sharpens the grain — Lightroom does the same; darktable's `grain` sits after
sharpen too [fetch: grain.c iop order by group]). Lumen would need: nothing, or move output
sharpen before grain if the sharpened-grain look is judged wrong. Otherwise Not applicable.

## F Masks — Not applicable
(grain is global; a local grain is not asked for anywhere in the field.)

## G UI/UX
Film Lab is 7 rows in the Look panel plus 2–3 in Effects; docs/05 specifies stock cards +
hover live-preview, Halation Size/Redness rows, Grain Format. Lumen would need: cards (a
`LumenMenuPicker` today), the two halation rows, a Format picker replacing the dead
`printSize`. [code: LookPanel.swift:946–1010, 1097]

## H Viewer & scopes — Not applicable
(A grain-on/off compare is covered by the ordinary before/after.)

## I Pipeline & performance

| Point | Finding | Source |
|---|---|---|
| Chain cost | Film chain is a 3-D LUT (33³ interactive / 65³ export) — free; halation = 3 full-res Gaussians (σ up to 25 px at 8000 px) + 4 kernel passes; grain = 1 kernel + a 128² plate per channel | [code: `bakeLUT`, `applyHalation`, `applyGrain`] |
| Quarter-res halation | docs/14 §5.7 promises quarter-res glow; `applyHalation` blurs at working res | [code: RenderGraph.swift:1320–1360] |
| Preview↔export | amplitude test exists; pattern/frequency parity fails for pitch < 7 µm × (2560/longEdge) (C.0-1); colour blotching at export on colour stocks (C.0-2) | [code: tests listed in C.0] |
| GPU/CPU disagreement | halation energy gate differs (pedestal vs smoothstep), weights raw vs `normalizedWeights` unused | [code: `HalationProfile.threshold/boost`, `applyHalation`] |

Lumen would need: the band-limited plate (C.2.3), halation at half/quarter res with
upsample, one energy gate.

## J Library/culling/export/ingest — Not applicable
(export grain deferral is covered in C.0/I.)

## K Crop/lens/geometry
Only `plateLongEdge = decode × delivered ÷ cropped` (correct) and the untested tile-phase
after crop (C.2.2 item 2). Otherwise Not applicable.

## L State/undo — Not applicable

## M Recipe/serialization/sidecars

| Item | Today | Spec |
|---|---|---|
| Two grain structs | `FilmLab.grain: FilmGrain{size (relative 0.5–2), amount}` and `look.grain: CreativeGrain{amount, size 0–100, roughness}`; precedence "a live chain wins"; `CreativeGrain.isIdentity` prunes the subtree | one `Grain{amount, size, roughness, chroma, format, envelope}` at `look.grain`; `FilmGrain` decoded for old sidecars and migrated (`size_slider = 100·log2(stockPitch·size/7)/3`) |
| Halation | `halation: Double` only; Size/Redness are constructor args, not wire | add `halationSize`, `halationRedness` with tolerant decode (defaults 1.0 / per stock) so old sidecars are byte-stable |
| `printSize: String?` | parsed to inches, cancels algebraically, no panel row | replace by `format` enum (gate mm); keep decoding `printSize` and ignore |
| Stock ids | `"lumen/<stock>"`, unknown → neutral render (never a substitute stock) | keep; new ids `lumen/portra160`, `lumen/portra800`, `lumen/ultramax400`, `lumen/cine500t`, `lumen/cine800t`, `lumen/provia100f`, `lumen/hp5`, `lumen/tmax400`, `lumen/delta3200` |
| Stock data | Swift literals in `FilmLab.swift` | `Resources/film/<id>.json` (fitted curves, Lumen-authored) loaded once; a test pins that each JSON fits its digitised points |

---

## Buildable in 24 h (priority order; what the owner sees first)

1. **Halation Size + Redness on the wire and in the panel, weights normalised, one energy
   gate, and an 800T stock.** Immediately visible (the red CineStill halo is the demo
   everybody asks for). Files: `RecipeLook.swift` (two fields, tolerant decode),
   `FilmLab.swift` (`cine800T` stock; `applyHalation` callers pass size/redness;
   `normalizedWeights` on the apply path; smoothstep gate in `lumenHighlightEnergy`),
   `RenderGraph.swift:1320`, `ReferenceRenderer.swift:473`, `LookPanel.swift:990`. ~3 h.
2. **Chroma fraction in the grain kernel + `Dmax 2.2` for creative grain.** Kills the rainbow
   at export on colour stocks and gives creative grain a colour texture without blobs.
   Files: `Kernels.swift` `lumenGrain` (mix `nL`/`nc`), `FilmLab.swift`
   (`FilmGrainProfile.chroma`, `creativeDMax = 2.2`), `RenderGraph.creativeGrainPlate` and
   `PipelineRenderer.grainPlate` (alpha carries the luminance field), `ReferenceRenderer.applyGrain`,
   `EffectsPanel.swift` (Chroma row). ~4 h.
3. **Band-limited plate instead of the 0.5-px floor + the parity test.** Ektar/Velvia
   previews stop lying about export. Files: `FilmLab.swift` `plate(size:seed:sigma:persistence:octaves:)`
   with the octave set chosen from `plateScale`; both plate builders; new
   `Tests/LumenCoreTests/GrainParityTests.swift` (C.2.3 test 1–2). ~4 h.
4. **Push coupling: fog + half-stop exposure loss + γ ×1.12.** One-line deltas in
   `FilmChain.build`; the pushed look stops being "more contrast" and becomes "pushed film".
   ~1 h, plus re-baseline of the film goldens.
5. **Asymmetric toe/shoulder** (two RGB fields, two multiplies in `FilmStage.response`) with
   authored t/s from the C.1.3 table — the shadows stop looking like a logistic. ~2 h.
6. **Four more stocks from the table** (Portra 160, Portra 800, HP5+, T-Max 400) as literals,
   marked authored-not-fitted. ~2 h. Digitising the datasheets is the W5 stream's first day,
   not this one.
7. **Merge the two grain structs** (M): the migration is mechanical but touches the sparse
   serializer, `renderIdentity`, `filmOwnsTheGrain`, the panel and ~12 tests — do it after
   1–3 land, not before.

---

## New relative to docs/02–03

- Lumen's `solveGains` neutralises every global cast, so stocks can only differ by
  divergence/tints — a model limit not written anywhere.
- The 0.5-px plate floor makes Ektar and Velvia previews always differ in grain frequency
  from export at the 2560-px working edge (thresholds computed per stock).
- Colour-stock grain at ≥ 6000 px export shows blue 5-px independent blobs the preview can't
  show; the chroma-fraction fix and the rainbow gate test.
- Nutting/Selwyn √D granularity and the print-slope propagation as the derivation of the
  envelope (asymmetric, reversal-correct), replacing the symmetric `√(p(1−p))` on print density.
- RMS-to-amount calibration: Lumen's amount 100 ≈ ⅓ of physical Tri-X at 3000 px.
- Newson λ(u) formula, defaults (r 0.1, σ_filter 0.8, N 800) and per-pixel seeding, read from
  source; darktable's octave table, `zoom` formula, paper LUT and constants, read from source.
- AV1 film-grain synthesis as the codec's proof that "same grain at every size" is a
  band-limited template with locked phase — a design pattern, not a research problem.
- spektrafilm's real profile inventory (28), its licence split (GPLv3 code / CC BY-SA 4.0
  profiles / no-resale LUTs), and which datasheet edition each profile digitised.
- Dehancer's halation control grammar (Source Limiter, Background Gain, Smoothness, format
  dependence, No-Remjet profiles) and Filmbox's single Halation Radius + Aura.
- Datasheet inventory with document numbers; Portra 400 PGI 36, Ektar PGI < 25, Tri-X RMS 17,
  T-Max 400 RMS 10, T-Max 100 RMS 8 confirmed; the Vision3 sheets carry granularity-vs-density
  curves (exactly the envelope Lumen needs).
- Spectral route cost and scope quantified as a phase-2 offline baker, not a runtime change.

## Could not verify

- Dehancer/Filmbox control ranges and defaults (domains blocked; search summaries only).
- The IPOL paper's recommended parameter ranges and timings (ipol.im and lirmm.fr blocked;
  code defaults used instead).
- Per-layer γ values for every stock in the table except Lumen's own six — authored from
  memory of the curves ([knowledge]); confidence stated per row; the digitisation method is
  the fix.
- PGI values for Portra 160/800, Gold 200, Ultramax 400; RMS for Velvia/Provia/Astia/Delta 3200.
- spektrafilm's default `particle_area_um2`, `grain_uniformity`, `blur_particle` and the
  halation/DIR numbers (profile JSONs fetched carry only sensitometry; the model defaults sit
  in code not fetched); docs/03 §7.7's constants stand as the verified set.
- Whether the export tile phase matches the preview's after a crop (no test; C.2.3 test 3).
- Whether `lumenGrain` runs at quarter or full res anywhere (grep found full-res only).
