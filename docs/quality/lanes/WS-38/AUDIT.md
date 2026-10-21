# WS-38 Film stocks and the film chain: audit

Auditor pass. No code was changed. Branch `quality/ws-38-film-stocks`.
Every render below has `look.filmLab.grain.amount=0` and `look.filmLab.halation=0` (grain is WS-40, halation is WS-39), with `amount=100` unless stated otherwise.
Images are in the scratchpad, not the repo:
`/tmp/claude-0/-home-user-lumen/587ca752-1c19-5215-9bec-f206d157f8be/scratchpad/audit/` (written `$AUD/` below).
Measurement scripts are in `/tmp/claude-0/-home-user-lumen/587ca752-1c19-5215-9bec-f206d157f8be/scratchpad/scripts/`.
`filmmirror.py` is the film chain lifted verbatim from `scripts/gen-fixtures.py`, which is bit-exact against the Swift code per `EngineMathFixtureTests`. I used it for analytic curves past the corpus range.

## 0. Verdict in one paragraph

The owner is right, though not because the stocks are wildly broken. The real failure is that **all six stocks are the same picture**. Each one is the neutral AgX-class tone curve, within ±10 codes, plus a vibrance-style chroma boost of 1.3–1.6×. That boost hits muted and dark colours hardest and drains light ones. Nothing about it reads as film:

- No stock reaches white. The brightest pixel in a normally exposed photo prints at **203–214** (neutral: 222), so whites look dirty grey.
- Medium and dark skin goes **burnt orange** on every colour stock (chroma ×1.6–2.0). Light skin goes **grey** on Portra (chroma ×0.47–0.66).
- Blue skies go electric navy. They are hard-clipped in sRGB, with R pinned to 0–4 on Ektar and Velvia, because the film output is **never gamut-mapped**.
- Velvia, the stock that should be the most contrasty, has **less mid-tone contrast than the neutral rendering** (log-log γ 1.22 vs 1.31) and crushes 12–18% of pixels to 0.
- Film Exposure is a brightness slider (+3 = +2.06 EV brighter, contrast collapses to 0.24), not a film-lab overexposure.
- Saturation ordering is wrong: Ektar 1.53 > Velvia 1.46 > Gold 1.40 > **Portra 1.30** > Cine 1.22. Portra, the "soft" portrait stock, gets +30–60% chroma.

The model's structure (negative sigmoid → couplers → print sigmoid, grey anchored) is a reasonable skeleton. The parameterisation and the missing pieces (gamut map, print-white placement, stock-specific colour) are what fail.

---

## 1. Where the code is

| What | Where |
|---|---|
| Stock tables (6) | `Sources/LumenCore/Engine/FilmLab.swift` 54–440 (`FilmCharacteristic`, `FilmCrossover`, `FilmStock.portra400…cine250D`) |
| Chain | `FilmLab.swift` ~1452–2002: `FilmStage`, `FilmChain.init/apply/build/couplingMatrix/solveGains/render` |
| Plan wiring | `Sources/LumenCore/Engine/RenderPlan.swift` 267–288 (built only when `amount > 0` and the stock resolves; `film.exposure` is threaded through), and `exactColor` ~662 |
| GPU | **There is no separate GPU film kernel.** `grep -i film Sources/LumenPipeline` finds only halation (`RenderGraph.applyHalation`) and grain (`Kernels.swift` grain kernel, `GrainPlan.film`). The colour chain reaches the GPU only through `FilmChain.bakeLUT` / the finish LUT (`RenderPlan.exactColor` → `filmChain.apply`). A fix to `FilmChain` therefore reaches the GPU automatically. There is no twin to keep in sync, apart from the `LumenPipelineTests/KernelGoldenTests` LUT goldens. |
| Python mirror | `scripts/gen-fixtures.py` ~3706–3900 (`FILM_STOCKS`, `film_render`, `film_solve_gains`). It generates `Tests/LumenCoreTests/Fixtures/enginemath.json` → `"film"` rows. |

How the chain works (`render`):
1. E = scene·filmGain.
2. Negative: D = Dmin + Δ·sigmoid(k(log10E + offset)), with k = γ/(0.25Δ) and grey at the sigmoid centre (s = 0.5).
3. The coupling 3×3 on density.
4. Smoothstep shadow and highlight tints.
5. T = 10^-D.
6. Print sigmoid on T·printGain.
7. Output = (T_print − T_Dmax)/(T_Dmin − T_Dmax), clamped to [0, 1].
8. `apply` mixes it display-linear with the base transform by `amount`.

`printGain`, or `filmGain` for the transparency, is bisected so that 0.18 → 0.18 per channel.

## 2. Tests that lock current behaviour (the spec must not fight these blindly)

| Test | Locks |
|---|---|
| `EngineIntegrationTests.testEveryStockAnchorsMidGrey` | every stock: `apply(0.18)` = 0.18 in **all three channels** ±1e-4 |
| `FilmLabHDRMidGreyTests` (3 tests) | grey 0.18 absolute at display white 1/2/4/8; film picture identical at w = 1 and w = 4 below SDR white; strength does not ramp exposure on HDR |
| `EngineIntegrationTests.testNoStockEverPrintsABrighterSceneDarker` | per-channel monotone, −10…+8 EV, push −1…2, exposure −2…3, amounts 100 and 45 |
| `EngineIntegrationTests.testFilmStrengthStaysBetweenTheTwoRenderingsItBlends` | the amount blend is a convex mix |
| `EngineIntegrationTests.testTheSolvedGainMemoServesTheColdSolveAndNothingElse` | memo correctness (push, grain and white change the key) |
| `RobustnessTests` ~888 | amount 0 → `isIdentity`, bit-equal to the neutral transform (1e-12) |
| `FilmLabDisplayTransformTests` (5) | the blend base is the recipe's solved transform; amount 0→1 moves < 3 codes; amount 100 is the same on any base (<1e-6); Black target survives a 50% blend; the blend is monotone on a Punchy base |
| `EngineMathFixtureTests.testFilmChainMatchesTheReference` | **golden grey-ramp numbers per stock and push, 1e-7**, from `scripts/gen-fixtures.py`. Any curve or stock retune MUST update `FILM_STOCKS` in the Python mirror and regenerate `enginemath.json`. This test encodes current numbers, not desirable behaviour. |
| `EngineIntegrationTests` grain tests, `GrainParityScanTests`, `HalationControlTests`, `CreativeGrainTests` | grain and halation (not this lane), but they construct `FilmChain(defaultRecipe)` and read `grainDMax`, which comes from `printCurve.dMax` |
| `Tests/LumenCoreTests/Proof/ProofRegistry.swift` ~1031–1170, `SliderEvidenceTests` 198–206 | registry entries for `film.<stock>.strength`, `film.exposure`, `film.pushPull` (slider evidence records) |
| `LumenPipelineTests/KernelGoldenTests` | references film (LUT/grain parity) |

The grey anchor (0.18 → 0.18) is compatible with everything recommended below. The fixture golden must simply be regenerated.

## 3. Tone curves on `grey_ramp` (item 1)

Rendered at native 2800 px with `--no-dither`. The top continuous ramp is averaged over rows 20–180.
Sheet: `$AUD/sheet_ramp.png`. The per-stock PNGs are in `$AUD/ramp/`.
The code at EV columns is the green channel, sRGB code ×255.

| EV vs grey | −10 | −8 | −6 | −5 | −4 | −3 | −2 | −1 | 0 | +1 | +2 | +3 | +3.9 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| neutral | 1 | 1 | 1 | 4 | 10 | 20 | 41 | 73 | 118 | 169 | 207 | 235 | 249 |
| Portra 400 | 3 | 4 | 7 | 11 | 18 | 27 | 46 | 76 | 118 | 165 | 202 | 224 | 235 |
| Gold 200 | 3 | 4 | 6 | 9 | 15 | 24 | 42 | 73 | 118 | 170 | 208 | 230 | 239 |
| Ektar 100 | 3 | 3 | 5 | 7 | 12 | 20 | 38 | 70 | 118 | 173 | 211 | 232 | 241 |
| Tri-X 400 | 4 | 5 | 7 | 10 | 16 | 25 | 43 | 74 | 118 | 168 | 205 | 227 | 237 |
| Velvia 50 | 0 | 0 | 1 | 3 | 7 | 18 | 41 | 75 | 118 | 162 | 198 | 222 | 235 |
| Cine 250D | 4 | 6 | 9 | 14 | 21 | 31 | 51 | 80 | 118 | 159 | 191 | 214 | 226 |

Key metrics. The log-log γ is the slope of log2(display-linear) per EV at grey, measured from the render and confirmed by the mirror. "EV to code 250" comes from the mirror, extended to +16 EV.

| stock | log-log γ @grey | code/EV @grey | EV above grey → 240 / 245 / 250 | code @+6 / +10 EV | black floor (−10 EV) | grey position on print sigmoid |
|---|---|---|---|---|---|---|
| neutral | 1.31 | 50 | 3.3 / 3.6 / ~4.0 | – | 1 | – |
| Portra 400 | 1.26 | 47 | +4.45 / +5.50 / **+8.10** | 247 / 251 | 3 (neutral) | 0.34 |
| Gold 200 | 1.39 | 51 | +3.95 / +4.80 / +6.85 | 249 / 252 | 2–3 | 0.35 |
| Ektar 100 | 1.51 | 55 | +3.75 / +4.65 / +6.95 | 249 / 252 | 3 | 0.33 |
| Tri-X 400 | 1.35 | 49 | +4.30 / +5.30 / +8.50 | 247 / 251 | 4 | 0.34 |
| Velvia 50 | **1.22** | **45** | +4.35 / +5.00 / +6.10 | 250 / 255 | **0** (20.7% of ramp crushed) | negative s = 0.775 |
| Cine 250D | **1.09** | 40 | +5.85 / +7.70 / **never** (max 249 at +14) | 241 / 248 | 4 | 0.29 |

Findings:

1. **The six curves are practically one curve.** Mid-grey is pinned at 118 for all (by construction). The slope at grey spans 40–55 code/EV against neutral's 50. Across −3…+3 EV every stock is within ±10 codes of neutral. A photographer flipping stocks sees saturation change, not tonality. Real targets: Velvia is far steeper than Portra, and Cine through a print has deep blacks with a long highlight.
2. **Velvia is backwards.** Its nominal γ is 1.75. But `solveGains` slides grey up the transparency's sigmoid to s = 0.775 (D ≈ 0.88 vs a centre of 1.79), where the local slope is 4·s(1−s) = 0.70 of nominal. Measured γ at grey is 1.22, below neutral's 1.31 and below Ektar's 1.51. Meanwhile the steep part of the curve sits in the shadows: −5 EV prints at 3, −6 EV at 1, and 20.7% of the ramp is code 0. That is the reverse of a slide's shape, which is steep through the mid-tones with a shoulder that holds about 2.5 stops of highlight. The same "nominal γ ≠ actual γ" problem hits every stock, because the grey anchor sits off the print sigmoid's centre (print s = 0.29–0.35). **The `gamma` field does not mean what its comment says** ("dD/dlog10E at mid-grey is exactly γ").
3. **Highlights never reach paper white.**
   - What happens: specular and diffuse-white rendering is dull. Portra needs +8.1 EV over grey to reach code 250, and Cine 250D never gets there. Diffuse white (90% reflectance, +2.3 EV) prints at about 200–218, against neutral's ~215, which is similar. The gap opens above that: at +3 EV the stocks print 214–232 against neutral's 235, and at +3.9 EV 226–241 against 249. Specular and near-white detail never gets to white.
   - On real photos (§5) the brightest pixel lands at 203–214, against neutral's 222.
   - Why: the print stage's toe is a sigmoid tail with grey at 34% of it. `paperWhite` is only an asymptote, and there is no shoulder-to-white placement.
   - The real behaviour: in an RA-4 or 2383 print, diffuse white sits within about 0.1 D of paper white. The real negative has **no shoulder** within +7 stops of grey (Portra 400 E-4050 curves: straight from log H −2.6 to +0.5 with no shoulder in the plotted range; Vision3 250D: white card +2⅓ stops, at least 3½ more stops of specular room). So the highlight roll-off should come from the print's toe reaching paper white at about +3…+4 EV. It should not come from both the negative's sigmoid shoulder and the print's toe compressing at once, which is what the symmetric negative sigmoid does here: negative D only spans 0.38…1.90 of 0.06…2.06 over ±6 EV.
4. **The shadow floor is lifted on all negatives.** Codes 3–4 at −10 EV (neutral 1), and p1 on real photos rises 8–10 codes (§5). A small lift is acceptable for a print, since paper Dmax gives a matte black. Here it is combined with the dim whites, so the picture loses about 15 codes of range at each end. **The result is grey, flat prints.** Velvia's floor is pure 0, and that one crushes.
5. **Neutrality of greys** (|R−G|, |B−G| per EV, in codes):
   - Portra ≤ 2, Ektar ≤ 3, Velvia ≤ 4, Cine ≤ 2. Fine.
   - **Gold 200**: shadows −4…−1 EV at R−G −2, B−G +1 (cool slate). Highlights +1…+3 EV at R−G +4…+6, B−G −3…−5, so an **R−B cast of 9–11 codes** in the highlights. Visible on `$AUD/sheet_ramp.png` as blue-grey shadows and peach highlights. White patch 9.5 renders (223, 217, 212). Real Gold runs warm and yellow overall and goes muddy in shade. A cool-shadow / pink-highlight split is not its signature.
   - **Tri-X** carries a colour cast under push/pull: R−B −0.8 code at +2.5 EV for push −1. The cause is that `pushDivergence` is applied to the monochrome stock. It is tiny, but a B&W stock must be exactly neutral.
6. **Clipping oddities.** Paper white maps to 1.0 only asymptotically, at +8…+14 EV, and Cine never gets there. There is a hard clamp at both ends in `render` (`Num.clamp(v, 0, 1)`), but it is not reachable for neutrals except Velvia's floor. There is no clipping, but there is no white either.

### Published targets vs. what we have

| | Target (datasheets / common knowledge) | Ours |
|---|---|---|
| Portra 400 neg | γ ≈ 0.55–0.6, straight over ≥ 10 stops (E-4050 curve), Dmin R/G/B ≈ 0.22/0.65/0.85, grey card red D 0.77–0.87 | γ 0.545–0.56 but on a symmetric sigmoid with Δ = 2 → visible shoulder from about +3 EV and soft toe from −3 EV |
| Ektar 100 neg | γ ≈ 0.6–0.7, straight to beyond +1.2 log H (E-4046), "ultra-vivid", "highest saturation" of the Kodak negatives | γ 0.665, saturation ×1.53 (only marginally above Gold) |
| Velvia 50 | transparency, γ ~1.7–1.8 through the mid-tones, Dmax ≥ 3.5, ~5 stops usable, "neutral greys, excellent deep shadows", "highest colour saturation" | measured mid γ 1.22 (< neutral), shadows crushed below −4 EV, saturation below Ektar's |
| Tri-X 400 | panchromatic with extended blue (a deep sky renders lighter than eye luminance without a yellow filter), contrast index 0.56 normal; push = underexpose + over-develop → "increase in contrast and graininess with further loss of shadow detail" (Kodak F-4017) | Rec.2020 luminance, so a plain desaturate on the near-neutral curve. Push only steepens. |
| Vision3 250D → 2383 | negative: white card +2⅓ stops, specular +3½ stops beyond, shadows −2⅔ and −2½ more (Kodak 5207 brochure); 2383: steep print (γ ~2.5–3), dense blacks (Dmax ~4), "brighter, neutral highlights" | lowest contrast of the six (γ 1.09), no white (max 249 at +14 EV), lifted 4-code blacks. That is a flat log-ish image, the opposite of a 2383 print. |

## 4. Colour on synthetic targets (item 2)

Sheets: `$AUD/sheet_colorchecker.png`, `$AUD/sheet_skin.png`. Per-patch PNGs: `$AUD/cc/`. Patch centres (inner 60%), OKLab (sRGB display-linear, D65), compared with the neutral render.

### ColorChecker, summary over the 18 chromatic patches

| stock | mean C ratio | min–max | mean \|Δh\| | max \|Δh\| |
|---|---|---|---|---|
| Portra 400 | **1.30** | 1.05–1.68 | 4.2° | 10.8° |
| Gold 200 | 1.40 | 1.10–1.80 | 5.2° | 11.7° |
| Ektar 100 | 1.53 | 1.15–2.04 | 5.2° | 11.1° |
| Velvia 50 | 1.46 | 1.12–1.99 | 4.2° | 10.9° |
| Cine 250D | 1.22 | 1.00–1.56 | 4.7° | 13.2° |

Selected patches (ΔL, C×, Δh°):

| patch (neutral L/C/h) | Portra | Gold | Ektar | Velvia | Cine |
|---|---|---|---|---|---|
| dark skin (.449/.047/46) | +.006 **×1.68** +1 | ×1.73 | **×2.04** | ×1.99 | ×1.53 |
| light skin (.719/.060/40) | ×1.07 **+8°** | ×1.26 **+11°** | ×1.34 +10° | ×1.19 +6° | ×1.00 +10° |
| blue sky (.595/.059/258) | −.026 ×1.39 −6° | ×1.53 −5° | ×1.76 −6° | ×1.53 −7° | ×1.24 −6° |
| foliage (.490/.066/130) | ×1.61 | ×1.80 | ×2.00 | ×1.92 | ×1.53 |
| purplish blue (.517/.126/276) | **−.051** ×1.35 −7° | −.062 −8° | −.066 −11° | −.046 −11° | −.046 −6° |
| blue (.426/.137/274) | −.056 ×1.43 −10° | −.057 −10° | −.049 −9° | −.031 −9° | −.050 −11° |
| orange yellow (.749/.136/80) | +11° | +12° | +11° | +8° | +13° |

Findings:

1. **The chroma boost is a vibrance curve, not film.** Low-chroma and dark colours get ×1.5–2.0 and saturated colours get ×1.0–1.1. Hue wheel (`$AUD/cc/hue_wheel_*.png`): at radius 0.3 every stock is ×1.3–2.0, and at radius 0.9 ×0.95–1.3. Muted earth tones, foliage and dark skin are blown up; already-saturated colours are not. The cause is that the coupling matrix multiplies density differences by a constant (1+a), and the negative's slope is greatest at grey.
2. **Chroma depends on lightness in the wrong direction for skin.** On `skin_tones` (Monk scale):
   - Portra: MST 1–4 (light skin) chroma **×0.47–0.66**. Light skin goes grey and ashen.
   - Portra: MST 6–8 ×1.43–1.83, and Velvia MST 8 ×2.30. Medium and dark skin goes **burnt orange / rust**.
   - Every colour stock does this: MST 6 becomes mustard ochre, and MST 7, MST 8 and "dark skin" become orange-brown. This is the most visibly ugly result in the audit (`$AUD/sheet_skin.png`, second-row patches).
   - Real Portra is the opposite: gentle, slightly warm, and low-saturation on all skin. Ektar's known fault is reddening skin, not orange.
3. **Systematic hue twists, the same on every stock.** Skin, orange and yellow rotate **+8…+13°** toward yellow. Blues and purples rotate **−6…−11°** toward cyan. These come from the shared coupler matrix, which is the same structure for all stocks and only scaled. They also come from the sRGB clip (below). Warm skin toward yellow is not Portra's pinkish-warm. Blue toward cyan is the "Ektar teal sky" in mild form. Here it is applied to every stock, including Velvia, whose blues should stay deep blue and lean violet.
4. **Blues darken.** Purplish blue and blue lose −0.05…−0.066 L, which is subtractive density. That is physically plausible and helps skies look deep, but combined with the chroma boost it pushes sky out of the sRGB gamut (§5).
5. **No gamut mapping on the film path.** `FilmChain.apply` gamut-maps the base (`neutral.apply(c, gamut: Gamut.sharedBoundary)`) but not the film output. The film output is clamped per channel in Rec.2020 and then hard-clipped by the Rec.2020→sRGB encode. On the hue wheel at radius ≥ 0.6, almost every saturated sample in every stock has a channel at 0 or 255 ("CLIP" in the measurement). The ±10–15° twists at radius 0.9 (blue 270 → −11…−15°) are clip twists.
6. **Saturation ordering.** Real stocks: Velvia ≥ Ektar > Gold > Portra > Vision3 250D through 2383, the last being softest and closest to the scene. Ours: Ektar 1.53 > Velvia 1.46 > Gold 1.40 > Portra 1.30 > Cine 1.22. Velvia is under Ektar. More importantly, **Portra is +30% on the chart and +50–65% on real photos**, which makes it a saturated stock. Its signature should be "about neutral saturation, soft".
7. **Tri-X separation.** Encoded luminance (Rec.709 Y of the rendered patch, codes), neutral vs Tri-X:

   | | blue | green | red | yellow | magenta | cyan | purplish blue |
   |---|---|---|---|---|---|---|---|
   | neutral | 76 | 139 | 102 | 191 | 129 | 130 | 102 |
   | Tri-X | **54** | 138 | 90 | 197 | 127 | 127 | **88** |

   Red is −12 (fine; Tri-X is slightly red-shy). **Blue is −22 and purplish blue −14.** That is the wrong direction for Tri-X, which has extra blue sensitivity and renders skies lighter than eye luminance. The cause is that the B&W rule is Rec.2020 luminance, so blue weight is 0.059, and the subtractive chain darkens it further. On real photos the green bowl (4694, 7881) renders almost as light as a lemon, with tomatoes near black.

## 5. Real photographs (item 3)

Eight photos, long edge 1024, all six stocks plus neutral. Contact sheets (7 tiles; 1st row: neutral, Portra, Gold, Ektar; 2nd row: Tri-X, Velvia, Cine):

| id | sheet | scene |
|---|---|---|
| 6929 (A7 IV) | `$AUD/sheet_6929.png` | overcast street, trees, white wall |
| 2545 (GX85) | `$AUD/sheet_2545.png` | lawn, tree, blue sky, hard shadow |
| 4694 (R5) | `$AUD/sheet_4694.png` | fruit bowl on blue cloth, saturated |
| 7881 (R5 II) | `$AUD/sheet_7881.png` | tomatoes, blue bottle, green dish |
| 983 (5D IV) | `$AUD/sheet_983.png` | snow, deep-blue sky, lantern, Passport |
| 1840 (D850) | `$AUD/sheet_1840.png` | field, treeline, sky gradient |
| 1569 (GX80) | `$AUD/sheet_1569.png` | pond, foliage |
| 3437 (T7i) | `$AUD/sheet_3437.png` | meadow, oaks |

100% crops (2400 px render): `$AUD/crops_983sky.png`, `$AUD/crops_983chart.png`, `$AUD/crops_6929wall.png`, `$AUD/crops_2545sky.png`. Full renders: `$AUD/full/`. Per-render metrics JSON: `$AUD/real/*.json`.

### Numbers (encoded luminance codes; "zero%" = pixels with any channel at code 0)

| id | stock | mean OKLab C | zero % | p1 | p50 | p99.9 | max |
|---|---|---|---|---|---|---|---|
| 6929 | neutral | .0247 | 0.00 | 10.5 | 65.8 | 220 | 222 |
| | Portra | .0404 (×1.64) | 0.03 | **18.5** | 70.0 | 213 | **214** |
| | Ektar | .0465 (×1.88) | 1.14 | 12.8 | 63.4 | 222 | 224 |
| | Velvia | .0500 (×2.02) | 2.70 | 8.1 | 69.9 | 210 | 211 |
| | Cine | .0395 (×1.60) | 0 | **21.5** | 74.6 | 202 | **203** |
| 2545 | neutral | .0268 | 0 | 7.4 | 88.2 | 203 | 211 |
| | Portra | .0403 (×1.50) | 0 | 15.2 | 89.6 | 198 | 207 |
| | Ektar | .0482 (×1.80) | 0.06 | 10.1 | 85.2 | 209 | 217 |
| | Cine | .0376 | 0 | 17.9 | 92.9 | 188 | 197 |
| 4694 | neutral | .0197 | 0.22 | 1.0 | 21.1 | 167 | 219 |
| | Velvia | .0368 | **16.3** | 1.0 | 16.9 | 165 | 209 |
| 7881 | neutral | .0171 | 2.16 | 0.7 | 18.1 | 151 | 221 |
| | Velvia | .0334 | **18.0** | 0.0 | 15.0 | 146 | 211 |
| 983 | neutral | .0193 | 0 | 3.0 | 53.0 | 186 | 222 |
| | Ektar | .0377 (×1.95) | **8.7** | 6.6 | 41.9 | 193 | 224 |
| | Velvia | .0379 | **8.9** | 2.0 | 46.5 | 179 | 211 |
| 1840 | Velvia | .0458 | **12.3** | 2.9 | 17.8 | 113 | 115 |
| 1569 | Velvia | .0598 | **11.3** | 2.2 | 47.4 | 211 | 215 |

All 8 × 7 rows are in the measurement output and reproducible with the scripts. A few patterns hold across them:

- **Mean chroma ×1.5–2.0 for every colour stock on every photo**, Portra included.
- **The brightest pixel drops:** Portra and Tri-X about −8 codes, Velvia −11, Cine about −19. The clipped RAW highlights (scene ≈ +2.5 EV) print grey.
- **Shadows lift on the negatives:** p1 +8…+11 codes on Portra, Tri-X and Cine.
- **Velvia zeroes 8–18% of pixels** (crushed shadows plus out-of-gamut skies).

### Sky (OKLab hue and chroma, plus RGB)

- 983, deep sky at top left: neutral (61, 77, 111), h 266, C .062.
  - Ektar (3, 57, 129) h 259 C .134, and Velvia (4, 63, 133) h 257 C .129. **Red is clipped to 0**, chroma has more than doubled, and the hue has turned 7–9° toward cyan.
  - Gold (17, 61, 124), Portra (32, 65, 121).
  - The crop (`$AUD/crops_983sky.png`) reads as a flat electric "Windows XP" ultramarine.
- 2545 sky: neutral (112, 147, 193) h 256. Ektar (75, 153, 208) **h 242 (−14°, toward cyan/azure)** ×1.41; Portra and Gold h 245 (−11°). The sky goes cyan, which is real for Ektar but is applied to Portra and Gold too.

### What I see (honest description)

- **6929 (A7 IV, overcast)**:
  - Every colour stock looks like neutral with a saturation slider.
  - Foliage turns heavier, greener and darker (Ektar and Velvia are dense olive-green).
  - The white rendered wall goes from clean light grey to a dimmer grey (crop `$AUD/crops_6929wall.png`), bricks go pinker, and the red bollard goes neon.
  - Cine is the softest and greyest, with lifted blacks and dull whites. It looks like an ungraded log image, not a 2383 print.
  - Not "horrific", but there is no film character and the picture loses its whites.
- **2545 (GX85)**: Portra, Gold and Ektar are warmer and more saturated on the dry grass (yellow-orange), with a cyan-shifted sky. Ektar is the most "nice" in thumbnail and the closest to a stock. Velvia has a crushed hard shadow and an orange lawn. Tri-X is a flat grey with a mid-grey sky (no blue lift).
- **4694 / 7881 (saturated still lifes)**:
  - Tomatoes go neon red (Velvia and Ektar clip), and the green dish goes highlighter green.
  - Velvia drops large shadow areas to 0 (16–18% of pixels), so the background cloth texture dies.
  - **Tri-X renders the green dish nearly white and the tomatoes nearly black.** The lemon and the bowl merge into the same pale grey. This is the most "wrong" B&W rendering here; real Tri-X gives a mid-grey dish and dark-mid tomatoes.
- **983 (snow, HDR)**:
  - The sky becomes ultramarine (above), and the Passport patches become garish (`$AUD/crops_983chart.png`): magenta and red patches go neon, and the dark green patch goes black-green.
  - Snow highlights go slightly greyer; the lantern glass is 138–148 vs neutral 144.
  - Gold's white patch goes pink-beige.
  - It looks like a "vivid" phone preset, not film.
- **1840 (sky gradient, dark frame)**: The grey-blue sky becomes clean cobalt (Velvia and Ektar). The field becomes muddy dark green with lifted black (Portra, Cine) or crushed black (Velvia). Tri-X is dark, murky and low-contrast.

**Which look nice?** Ektar on 2545 and Portra at +1 Film Exposure (see §7) come closest to pleasing. **Which look bad?** Velvia (crushed and neon), Tri-X (flat, wrong tonal separation), Cine 250D (washed, grey whites), and every colour stock on darker skin tones (orange). Nothing is posterised or banded. The 8-bit gradients on the ramp are smooth.

## 6. Amount (item 4)

Photo 2545. `$AUD/amt/` contains `none.png`, `<stock>_<amount>.png` and `sweep_portra.png`.

- **Amount 0 is bit-identical to no film block**: max |Δ| 0 codes, also with the stock's default grain and halation, because the plan builds no chain and no grain at amount 0. The identity holds.
- **The blend is linear and monotone.** Mean OKLab ΔE×100 from neutral, as a fraction of full:

  | amount | 1 | 5 | 10 | 25 | 50 | 75 | 100 |
  |---|---|---|---|---|---|---|---|
  | fraction (Portra) | 0.016 | 0.069 | 0.120 | 0.267 | 0.515 | 0.759 | 1.000 |
  | fraction (Velvia) | 0.015 | 0.064 | 0.113 | 0.255 | 0.498 | 0.747 | 1.000 |

  There is no jump at small amounts. The zone table (`sweep_portra.png`) moves linearly: z0 +2.0/+3.9/+5.6/+7.2 codes, z7 −0.8/…/−3.4.
- The display-linear mix makes mean chroma rise linearly (.0268 → .0403 for Portra). Because both endpoints share grey and the hue differences are small (≤ 13°), the midpoint is not visibly washed or desaturated. **Not a problem today.** It would become one if a stock gets real hue shifts (> 30°), where a linear-light mix of two differently hued colours dips in chroma. Note also the scale: at amount 100 the whole-image ΔE is only **2.2 OKLab units**. The film look is a small change; the slider is fine but has little to blend.

## 7. Film Exposure and Push/Pull (item 5)

Analytic, from the mirror. Codes are sRGB. Sheets: `$AUD/exp/portra_exposure_2545.png` and `$AUD/exp/portra_push_2545.png`.

### Film Exposure (`look.filmLab.exposure`, −2…+3) does `scene × 2^exp` into a chain whose print gain was solved at exp 0

Portra 400 (Tri-X is within 3 codes of this; Velvia is similar):

| exp | grey code (EV shift) | log-log γ @grey | code/EV | −8 EV | −5 EV | +2.5 EV | +4 EV |
|---|---|---|---|---|---|---|---|
| −2 | 44.6 (**−2.80 EV**) | 1.33 | 22.7 | 3.3 | 5.5 | 142 | 202 |
| −1 | 74.0 (−1.39) | 1.45 | 36.9 | 3.7 | 7.5 | 186 | 224 |
| 0 | 117.6 | 1.27 | 47.6 | 4.4 | 11.2 | 215 | 237 |
| +1 | 165.2 (+1.07) | 0.85 | 43.5 | 5.5 | 17.3 | 232 | 243 |
| +2 | 202.0 (+1.71) | 0.47 | 29.4 | 7.5 | 27.3 | 240 | 247 |
| +3 | 224.4 (**+2.06 EV**) | **0.24** | 16.6 | 11.2 | 44.6 | 245 | 249 |

On 2545 (zone table): +3 brightens zone 2 by +125 codes and zone 7 by +52, and −2 darkens zones 5–7 by −82…−88.

**It is a brightness control.** In a real lab, the printer normalises density: the grader adjusts the enlarger light so mid-grey prints at 18% again. An overexposed negative then prints at about the same brightness, with cleaner, slightly denser shadows (more shadow detail, less grain) and, at +2…+3 stops, slightly compressed, pastel highlights as they ride toward the negative's upper section. An underexposed negative prints at normal brightness but with **muddy, flat, lifted grey-green/cyan shadows and more grain**.

Here, +3 makes the picture 2 stops brighter and almost flat (γ 0.24). −2 makes it 2.8 stops darker (the negative's toe compounds the shift). This contradicts the `FilmLab.exposure` doc comment ("Not display brightness"). It duplicates Develop Exposure with a soft shoulder. The +1 tile does look the nicest of the sheet, but only because it is brighter.

Velvia is the exception: a slide is not printed, so for a transparency "exposure = brightness" is physically right. Even there the slide's ~5-stop window should be the limit, not a 2-EV compressed shift.

### Push/Pull (`look.filmLab.pushPull`, −1…+2)

`push` multiplies the negative γ by `1 + 0.18·push·(1 ± 0.03)` and adds `pushTint·push` to the shadow tint. Grey stays anchored.

| Portra push | log-log γ | code/EV | −8 EV | −5 EV | +2.5 EV | +4 EV | R−B @−5 EV | R−B @+2.5 EV |
|---|---|---|---|---|---|---|---|---|
| −1 | 1.05 | 39.5 | 6.0 | 16.1 | 204 | 229 | +4.1 | −2.9 |
| −0.5 | 1.16 | 43.6 | 5.0 | 13.4 | 210 | 233 | +2.6 | −2.0 |
| 0 | 1.27 | 47.6 | 4.4 | 11.2 | 215 | 237 | +1.3 | −1.3 |
| +1 | 1.48 | 55.5 | 3.6 | 8.1 | 224 | 242 | −0.7 | −0.2 |
| +2 | 1.70 | 63.1 | 3.3 | 6.4 | 230 | 245 | −1.8 | +0.5 |

The direction is right: push gives more contrast and slightly deeper blacks, pull gives less. Problems:

1. The magnitude is mild: +2 stops of push = +34% γ. Real 2-stop push of C-41 or Tri-X gives roughly +30–50% contrast index. That is OK.
2. **Push has no shadow-detail loss.** Real push means the film was underexposed by the push amount and then over-developed. The shadows were never recorded: Kodak F-4017 says "further loss of shadow detail" at each stop. Here push only steepens around a fixed grey, so the shadows get *darker* but keep all their separation (−8 EV still distinct from −5 EV). There is no toe-crush and no lifted, empty shadow with push crossover.
3. The push crossover tints are cosmetic: ≤ 2 codes in the shadows at +2. Real pushed C-41 goes visibly cyan/green-blue in the shadows, with highlights warm-contrasty.
4. Pull lifts blacks (−8 EV: 4.4 → 6.0), which is right in direction.
5. Tri-X gets a colour cast from `pushDivergence` (R−B up to 0.8 code). Minor bug; monochrome must skip it.
6. Velvia: the datasheet allows only −½…+1 stop push/pull with "minimum colour balance variation". Our range is −1…+2 for every stock.

## 8. Research: what each stock should look like (item 6)

Sources are listed at the end. The datasheet facts are from the PDFs I could read (Kodak E-4050 Portra 400, E-4046 Ektar 100, F-4017 Tri-X, Fujifilm AF3-0221E2 Velvia 50, Kodak 5207 brochure). Emulator behaviour (Dehancer, FilmConvert, VSCO, RNI) could not be measured here; vendor pages are marketing copy, so the table summarises the consensus.

| stock | contrast | saturation | hue biases | highlights | shadows |
|---|---|---|---|---|---|
| **Portra 400** | low-medium. Negative γ ≈ 0.55–0.6, straight > 10 stops (E-4050 curves, no shoulder in range) | about neutral, soft; "natural skin tones" is the selling point; lower than Ektar on Kodak's own scale | warm-neutral; skin slightly warm/peach-pink (not yellow); greens slightly muted/olive-teal; slight cyan in underexposed shadows | **long and gentle**: +3 stops over still holds; overexposure → pastel, airy | clean if exposed well; underexposure → muddy, grey-green, grainy |
| **Gold 200** | medium | medium-high, especially reds and yellows | **overall warm/yellow-golden**; skies a little cyan/pastel; greens yellowish | holds in sun but less than Portra | weak in shade, muddy and grainy when underexposed (retailer reviews); not cool-slate |
| **Ektar 100** | medium-high (γ ≈ 0.65–0.7, E-4046) | **highest of the C-41 stocks** ("ultra-vivid") | reds push hard (skin goes red/magenta); blues deep and slightly cyan; greens vivid | good latitude, long straight line | fairly dense; less forgiving than Portra |
| **Tri-X 400** | punchy mid-tones; CI 0.56 normal | – | panchromatic with extra blue sensitivity (skies lighter than visual), slightly reduced deep-red sensitivity | wide latitude, highlights hold | push: "increase in contrast and graininess with further loss of shadow detail" (F-4017) |
| **Velvia 50** | **high**; slide γ ~1.7–1.8 through the mid-tones; ~5 stops usable | **highest** | greens emerald, blues deep (slightly violet, not cyan); magenta cast in open shade is a known trait; reds intense | ½ stop over blows highlights | "excellent deep shadows", rich but not empty below ~−3 EV; underexposure muddies |
| **Vision3 250D → 2383** | negative very low (γ ~0.5–0.6), latitude ~14 stops (white card +2⅓, specular +3½ beyond; shadows −2⅔ −2½); the 2383 print is steep (γ ~2.5–3) with Dmax ~4 | moderate, filmic; less than Ektar | the classic "Kodak print" look: warm skin, cool/teal shadows, slightly warm highlights, hue rotation in saturated reds/oranges | **brighter, neutral highlights** (Kodak on Vision print); long smooth roll-off | **dense, deep blacks** (2383 Dmax), not lifted |

## 9. Ranked problem list (for the spec author)

1. **Stocks are indistinguishable tonally.** The γ at grey spans only 1.09–1.51 around neutral's 1.31; ±10 codes over −3…+3 EV. The cause is a symmetric negative sigmoid with grey at its centre, a grey-anchored print with grey at s ≈ 0.34, and the `gamma` parameter not being the actual slope. The fix is to make the authored γ the measured slope, or to retune so measured γ differs per stock (Velvia ≥ 1.7, Ektar ~1.5, Portra ~1.2, 2383 print look ~1.5 with deep blacks).
2. **No white.** At +3…+4 EV the stocks print 214–241 against neutral's 235–249; the brightest real-photo pixel is 203–214; code 250 needs +6…+8 EV (Cine: never). Real negatives are straight above grey for 7+ stops, and print white is reached at about +3…+4 EV.
3. **Chroma is a vibrance, not stock colour.** ×1.3–2.0 on muted and dark colours, ×1.0 on saturated ones, and ×0.47–0.66 on light skin (Portra). Dark and medium skin goes orange (×1.6–2.3). Portra is +50–65% chroma on real photos. The ordering is wrong (Velvia < Ektar).
4. **No gamut mapping on the film output.** sRGB hard-clips saturated skies and reds (983 sky R = 3; hue wheel CLIP at radius ≥ 0.6 for every stock), giving ±10–15° clip twists. `apply` maps the base but not `film`.
5. **Velvia crushes and is flat in the mid-tones**: zero-channel pixels 8–18% on real photos, ramp floor 0 below −5 EV, mid γ 1.22.
6. **Same hue twists for all stocks**: skin/orange +8…+13° toward yellow, blues −6…−11° toward cyan. The stock tints are 0.005–0.02 D, too small to give stock identity (the Gold split cast is the only visible one, and it has the wrong sign for Gold's character).
7. **Film Exposure is a brightness slider** (+3 → +2.06 EV, γ 0.24; −2 → −2.8 EV). It should be lab-normalised for negatives: grey held about constant, with only the latitude effects.
8. **Push lacks shadow-detail loss** and has only cosmetic crossover (≤ 2 codes). The −1…+2 range applies to Velvia too, where the datasheet allows −½…+1.
9. **Tri-X**: B&W = Rec.2020 luminance gives blue −22 codes (should be lighter), green dish ≈ lemon, a flat curve (max 217 on photos, p1 17), and a slight colour cast under push.
10. **Lifted blacks plus dim whites on the negatives** (p1 +8…+11, max −8…−19 codes) combine into the "grey, flat, muddy" print the owner is describing.

Things that are fine and must be kept: the grey anchor 0.18 → 0.18 in all channels; amount 0 identity (bit-exact); the linear, monotone amount blend; monotonicity in every channel; smooth gradients with no banding; neutral greys on Portra, Ektar, Velvia and Cine (≤ 4 codes).

## 10. Reproduce

```
export PATH=/opt/swift/usr/bin:$PATH; BIN=$(swift build -c release --show-bin-path)/lumen-render
AUD=/tmp/claude-0/-home-user-lumen/587ca752-1c19-5215-9bec-f206d157f8be/scratchpad/audit
SC=/tmp/claude-0/-home-user-lumen/587ca752-1c19-5215-9bec-f206d157f8be/scratchpad/scripts
C="--set look.filmLab.grain.amount=0 --set look.filmLab.halation=0 --set look.filmLab.amount=100"
$BIN render --input corpus/synthetic/grey_ramp.lfi --long-edge 2800 --no-dither $C --set look.filmLab.stock=lumen/portra400 --out $AUD/ramp/portra400.png
python3 $SC/ramp.py $AUD                     # tone table + metrics
python3 $SC/analytic.py $SC                  # mirror: EV->250, gamma, grey positions
python3 $SC/patches.py $AUD colorchecker     # OKLab per patch (also: skin_tones)
```

`sweep` accepts string values only via `--set`, so each stock was rendered with `render` and the contact sheets were assembled with `$SC/sheet.py`.

## Sources

- Kodak Professional Portra 400, Technical Data E-4050 (2016): https://business.kodakmoments.com/sites/default/files/files/products/e4050_portra_400.pdf
- Kodak Professional Ektar 100, Technical Data E-4046 (2016): https://business.kodakmoments.com/sites/default/files/files/products/e4046_ektar_100.pdf
- Kodak Tri-X 400, Technical Data F-4017 (push processing text): https://business.kodakmoments.com/sites/default/files/files/resources/f4017_TriX.pdf
- Fujifilm Velvia 50 [RVP50] Product Information Bulletin AF3-0221E2: https://www.macodirect.de/media/pdf/25/a7/d2/FV504P_Datenblatt_e.pdf
- Kodak VISION3 250D 5207/7207 brochure / technical data: https://www.kodak.com/content/pdfs/KODAK-VISION3-250D-5207-7207-brochure.pdf , https://www.kodak.com/content/products-brochures/Film/VISION3-250D-Technical-Data-EN.pdf
- ASC (Nov 1998) on Kodak Vision print film, "denser blacks, brighter, neutral highlights": https://theasc.com/magazine/nov98/PRODUCTS/page2.html
- Dehancer, print film profiles (2383 print stage): https://blog.dehancer.com/articles/print-film-profiles-in-dehancer/ ; Vision3 250D profile: https://www.dehancer.com/profiles/film/kodak-vision3-250d
- Stock character reviews: https://www.shopmoment.com/articles/top-35mm-and-120-film-stocks , https://www.photrio.com/forum/goto/post?id=2216362 , https://analog.cafe/r/fujifilm-fujichrome-velvia-50-film-review-iv04 , https://www.photrio.com/forum/threads/velvia-50-100.74790 , https://markus-hagner-photography.com/fuji-velvia-50-vs-fuji-provia-100f/
