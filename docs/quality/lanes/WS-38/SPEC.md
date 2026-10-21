# WS-38 Film stocks and the film chain: acceptance spec

Written from `AUDIT.md` before any code changes. Owner's goal, verbatim: *"the film looks are pretty horrific... make things really emulate film and not just bullshit."*
The bar is Lightroom at minimum. Each stock should be beautiful, distinct from the others, and recognisable against how the Kodak/Fuji datasheets and the good emulations (Dehancer, FilmConvert, VSCO, RNI) portray it.

## How to measure

```
export PATH=/opt/swift/usr/bin:$PATH
swift build -c release --product lumen-render
python3 docs/quality/lanes/WS-38/measure.py --out /tmp/ws38_sheets            # every line + contact sheets
python3 docs/quality/lanes/WS-38/measure.py --only S7                         # one line
python3 docs/quality/lanes/WS-38/measure.py --only S2,S3,S4 --json /tmp/r.json
```

- **How it renders.** The script finds the binary with `swift build -c release --show-bin-path`; `--bin` or `LUMEN_RENDER` overrides that. It renders through `lumen-render render`, which is the CPU `ReferenceRenderer` and goes through the 33³ finish LUT the GPU uses. Every render uses `look.filmLab.grain.amount=0`, `look.filmLab.halation=0` and `--no-dither`, with `amount=100` unless a line says otherwise.
- **Speed and output.** Renders are cached in `--work` (default `$TMPDIR/ws38_measure`), keyed on the binary's size and mtime. A cold run takes about 2.5 min on 4 cores; a warm run takes about 40 s. The script prints a PASS/FAIL table and writes JSON with the full per-stock detail (`<work>/results.json` by default).
- **Frames.**
  - `corpus/synthetic/{grey_ramp, colorchecker, skin_tones, hue_wheel}` at native size, with patch rectangles taken from their sidecars.
  - Real photos at long edge 768: 6929 (A7 IV), 2545 (GX85), 4694 (R5), 7881 (R5 II), 983 (5D IV) and 1840 (D850).
  - Three frames the script writes itself:
    - `xramp`: −12…+8 EV around 0.18, 100 px/EV, for highlights past the corpus ramp's +4 EV.
    - `stress`: 0, 1e-6, −0.01, 1e2, 1e4 and 1e6 greys, ×30/×1000 primaries, and negative components.
    - `ccbright`: the 18 ColorChecker colours at +2.5 EV.
- **Definitions.** All metrics come from the 8-bit PNG, decoded sRGB → linear.
  - "Luminance code" is the sRGB-encoded Rec.709 Y × 255.
  - "Contrast" or "slope" is the least-squares slope of log2(display-linear Y) per scene EV. This is the display-referred log-log γ: a slide's density γ, or a negative's γ × the print's γ.
  - OKLab is taken from linear sRGB. ΔE is CIEDE2000 on CIELAB D65.
  - "Neutral" means the same render with no `filmLab` block.
- **Stock groups.** "Negatives" are Portra 400, Gold 200, Ektar 100, Tri-X 400 and Cine 250D (Vision3 → 2383 print). Velvia 50 is the reversal. The "colour stocks" are every stock except Tri-X.

The baseline is the current code at `8710f47` on branch `quality/ws-38-film-stocks`, measured with the command above: **7 of 39 lines pass** (S1, S23, S25, S26, S30, S31, S35). Those seven describe behaviour that is right today and must stay right.

## Measurable lines

Each line's command is `python3 docs/quality/lanes/WS-38/measure.py --only <ID>`.

### Tone identity

| ID | Claim | Threshold | Baseline (now) |
|---|---|---|---|
| S1 | Mid-grey anchor holds: scene 0.18 renders within 1 code of neutral in R, G and B on every stock. Existing tests `testEveryStockAnchorsMidGrey` and `FilmLabHDRMidGreyTests` stay. | max \|Δ\| ≤ 1 code | PASS, max 0.20 (Cine) |
| S2 | Each stock has its own display contrast at grey (grey_ramp, fit over −0.5…+0.5 EV). | Portra 1.10–1.32, Gold 1.36–1.52, Ektar 1.50–1.70, Tri-X 1.40–1.62, Velvia 1.75–2.20, Cine 1.25–1.48 | FAIL: neutral 1.32, Portra 1.21, Gold 1.34, Ektar 1.44, Tri-X 1.29, **Velvia 1.18**, **Cine 1.06** |
| S3 | Contrast is ordered like the real stocks. | Velvia ≥ Ektar + 0.15; Ektar ≥ Gold + 0.08; Gold ≥ Portra + 0.08; Tri-X ≥ Portra + 0.08; Cine ≤ Gold | FAIL: Velvia < Ektar, Tri-X ≈ Portra |

Grounding:
- Velvia γ ≈ 1.7–1.8 through the mid-tones (Fuji AF3-0221E2).
- Ektar has the highest contrast of the Kodak negatives (E-4046, γ 0.65–0.7).
- Portra is low-medium (E-4050, γ 0.55–0.6).
- Tri-X has punchy mid-tones.
- Cine is Vision3 printed on 2383. The 2383 print restores contrast, so Cine sits near neutral; its identity is deep blacks and a long highlight, not flatness.

### Highlights

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S4 | White is reachable. On `xramp`, the EV above grey where luminance first reaches code 250 is inside the stock's band. Velvia has a short latitude and reaches white sooner. | Negatives +3.5…+6.0 EV; Cine +4.0…+6.5; Velvia +2.0…+3.5. Neutral is +4.0 | FAIL: Portra +7.64, Gold +6.57, Ektar +6.61, Tri-X +7.84, Velvia +5.93, **Cine never** |
| S5 | The shoulder is smooth and nothing hard-clips. Above +1 EV, the luminance slope (code/EV, in 0.25-EV bins) never rises by more than 2 code/EV from one bin to the next, so the derivative is monotone decreasing. Any channel reaches 255 only ≥ 0.25 EV after luminance reaches 250, and with a landing slope ≤ 12 code/EV over the last 0.5 EV. | rise ≤ 2.0; 255 only past the shoulder | FAIL: rise Ektar 2.7, Tri-X 2.7, Velvia 2.4, Cine 2.3 (Portra/Gold 1.7, neutral 1.4) |
| S6 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** Real photos keep their whites: p99.9 luminance within 6 codes of neutral on all 6 photos. Velvia only needs ≥ neutral − 6. | \|Δp99.9\| ≤ 6 | FAIL: Portra −6.9…−0.9, Gold −6.3…+5.1, Ektar −6.5…+9.5, Tri-X −5.0…+0.8, Velvia −10.3, **Cine −17.6…−5.9** |

### Shadows and neutrality

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S7 | No lifted, grey blacks: p1 luminance minus neutral on the 6 photos. | negatives −4…+4; Velvia −4…+2 | FAIL: Portra +4.2…+8.1, Gold +3.5…+5.2, Tri-X +4.0…+6.1, **Cine +5.8…+11.0** (Ektar +2.1…+3.8 ok, Velvia ok) |
| S8 | Black floor on grey_ramp: code at −6 EV and −8 EV is ≤ neutral + 3 for every negative. | ≤ 4.3 / ≤ 4.0 | FAIL: Portra 7.5/4.2, Gold 5.8/3.8, Ektar 5.0/3.1, Tri-X 7.0/5.0, Cine 9.4/5.8 (neutral 1.3/1.0) |
| S9 | Deep but not crushed: on each photo, the % of pixels with any channel at 0 is ≤ max(2 × neutral, neutral + 0.5), for every stock. Velvia's grey_ramp share at code 0 is ≤ 8%. | as stated | FAIL: worst Velvia 18.8%, Ektar 8.7%, Gold 3.7%, Portra 3.4%, Cine 3.1% (neutral max 1.1%); Velvia ramp 21.3% at 0 |
| S10 | Greys stay grey (grey_ramp −6…+3.5 EV): max \|R−G\|, \|B−G\|. | ≤ 3 codes for Portra, Ektar, Velvia; ≤ 1 for Tri-X | FAIL: Portra 2, Ektar 3, **Velvia 4**, Tri-X 0 |
| S11 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** Authored crossover is bounded and of the documented sign. **Gold** is warm throughout: R−B in [0, +8] over −4…+3 EV, with mean R−B over +1…+3 ≥ +2. **Cine** has cool/teal shadows (mean B−R over −4…−2 in [+1, +6]) and warm-neutral highlights (mean R−B over +1…+3 in [0, +6]). Neither shows green or magenta: \|G − (R+B)/2\| ≤ 3. | as stated | FAIL: Gold R−B −5…+11 (cool slate shadows, peach highlights); Cine passes its parts (B−R +1.3, R−B +2.2) |

Grounding for S11: the audit's research found real Gold 200 warm and yellow overall, and muddy (not cool-slate) when underexposed. So the current cool-shadow / peach-highlight split has the wrong sign. The cool-shadow / warm-highlight split belongs to the Vision → 2383 "Kodak print" look.

### Colour

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S12 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** ColorChecker mean chroma ratio vs neutral (OKLab C, 18 chromatic patches) is in the stock's band. | Portra 1.00–1.15, Cine 0.95–1.15, Gold 1.12–1.30, Ektar 1.25–1.45, Velvia 1.35–1.60 | FAIL: Portra 1.30, Gold 1.40, Ektar 1.53, Velvia 1.46, Cine 1.22 |
| S13 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** Saturation order on the chart AND on photos: Velvia > Ektar > Gold > Portra, each gap ≥ 0.05, and Cine ≤ Portra + 0.03. | as stated | FAIL: chart Ektar 1.53 > Velvia 1.46; photos Cine 1.54 > Portra 1.53 |
| S14 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** Real-photo mean chroma ratio (geometric mean over 6 photos) is in band. | Portra 1.00–1.20, Cine 0.95–1.20, Gold 1.10–1.35, Ektar 1.25–1.50, Velvia 1.35–1.70 | FAIL: Portra 1.53, Gold 1.63, Ektar 1.75, Velvia 1.90, Cine 1.54 |
| S15 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** Chroma is stock colour, not a vibrance curve: max/min per-patch chroma ratio over the 18 chart patches. | ≤ 1.40 | FAIL: Portra 1.60, Gold 1.63, Ektar 1.78, Velvia 1.78, Cine 1.55 |
| S16 | Portra skin, light AND dark (Monk 1–10 and the two CC skins, on skin_tones + colorchecker, patches with neutral C ≥ 0.02): every patch has chroma ratio 0.95–1.20, \|Δh\| ≤ 4° (never toward green or magenta) and \|ΔL\| ≤ 0.03. | as stated | FAIL: C ratio 0.64…1.83 (light skin grey, dark skin orange), Δh −4.2…+7.8° |
| S17 | Other colour stocks on the same skin patches: no burnt orange and no grey (chroma ratio 0.85–1.45), with hue shift inside the authored band: Gold −3…+8° (golden), Ektar −8…+4° (reddens), Velvia ±6°, Cine ±6°. | as stated | FAIL: Gold C up to 1.77, h +11; Ektar C 0.82…2.04, h −9…+10; Velvia C up to 2.30; Cine C 0.77…1.72, h +10 |
| S18 | Blue hue (CC blue sky, blue flower, purplish blue, blue), Δh vs neutral. Ektar's cyan lean and Velvia's violet lean are authored. | Portra/Cine ±5°; Gold −6…+3; Ektar −9…+3; Velvia −3…+8 | FAIL: every stock turns cyan by −10…−11° (Velvia −10.9) |
| S19 | Hue fidelity inside the gamut (hue_wheel ring r = 0.35, 36 hues), \|Δh\| vs neutral. | mean ≤ 4°, max ≤ 10° (Ektar/Velvia max ≤ 12°) | FAIL: max Portra 11.2, Gold 10.8, Velvia 11.4 (means 2.5–3.7 ok) |
| S20 | Gamut-mapped sky on 983 (deep blue sky, top-left region): % pixels with a channel at 0 or 255 ≤ neutral + 1 pt, and the region's p5 of min(R,G,B) ≥ 6 codes. | as stated | FAIL: Ektar 35.3% / 0, **Velvia 56.3% / 0** (neutral 0% / 39; Gold p5 8 ok) |
| S21 | At the gamut edge the output is mapped, not clipped. On hue_wheel r = 0.6…0.95 (36 hues × 8 radii), p90 \|Δh vs neutral\| ≤ 8° (Ektar/Velvia ≤ 10°), and the radial gradation survives: the share of adjacent radial steps with ΔE < 0.5 is ≤ neutral + 3 pts. Over-range light desaturates toward white the way film does: the ×30/×1000 primaries on `stress` reach luminance ≥ 0.75 × neutral's. | as stated | FAIL: Δh p90 Gold 10.7, Ektar 11.5, Velvia 11.2 (Portra 7.7, Cine 8.0 ok); gradation ok; over-range luminance ratio **0.36** on every stock (a ×1000 red prints as a mid red) |

S12–S15 bands come from the audit's research table: Velvia ≥ Ektar > Gold > Portra > Vision/2383, and Portra about neutral saturation. The photo bands sit a little wider than the chart bands, because the current code puts +50–90% on muted real-world colour.

### Tri-X

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S22 | Panchromatic response, not Rec.2020 luma. For each CC patch: its luminance code minus the code Tri-X gives a grey of the same scene luminance (Rec.2020 Y), read off Tri-X's own `xramp`. This isolates spectral response from the tone curve. | blue ≥ +4, purplish blue ≥ +2, blue sky ≥ 0, red −14…−2, green −12…+8, yellow −10…+6 codes | FAIL: blue +1.0, purplish blue −0.8 (blue sky +0.7, red −2.0, green 0, yellow +1). Today it is luma. |
| S23 | Output is exactly neutral at every setting: max \|R−G\|, \|B−G\| ≤ 1 code on colorchecker, `xramp` and 4694, at push −1/0/1/2, exposure −2/+3 and both combined extremes. | ≤ 1 | PASS: 1 (keep; the audit's 0.8-code `pushDivergence` cast is below one code) |
| S24 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** Rich tonality on 4694: lemon minus the lit green dish ≥ 42 codes (the neutral colour render gives 37; the extra comes from Tri-X's higher contrast), and the tomatoes stay ≥ 0.75 × their neutral-render luminance (not black). | as stated | FAIL: lemon − dish 37.1, tomato 42.7 vs 46.7 (ratio 0.91 ok) |

### Amount

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S25 | Amount 0 is bit-identical to having no film block, on 6929 and colorchecker, for every stock, including with exposure +3 and push +2 set. Existing `RobustnessTests` ~888 stays. | max \|Δ\| = 0 | PASS: 0 over 24 renders |
| S26 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** The amount response is monotone and near-linear: mean ΔE (2545) vs neutral at amount 10/25/50/75 is strictly increasing and within ±0.10 of (amount/100) × the amount-100 value, for every stock. | as stated | PASS: amount-50 fraction 0.47–0.53 (ΔE at 100: Portra 3.9, Gold 4.3, Ektar 5.3, Velvia 5.0, Cine 4.0, Tri-X 8.1) |

### Film exposure (negatives are lab-normalised, like a minilab; the slide is not)

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S27 | On negatives, mid-grey output stays put across Film Exposure −2…+3 in 0.5 steps (grey shift vs exposure 0, on `xramp`). It is smooth: adjacent steps differ by ≤ 0.15 EV. | \|shift\| ≤ 0.25 EV | FAIL: Portra −2.79…+2.05, Gold −3.07…+2.13, Ektar −3.35…+2.16, Tri-X −2.98…+2.09, Cine −2.52…+1.90 |
| S28 | Overexposure +2 on negatives: shadows are not lifted (code at −5 EV ≤ exp 0 + 1) and at least as contrasty (log-log slope over −5…−3 EV ≥ exp 0). Highlights are softer (code/EV over +1.5…+3 ≤ exp 0) and paler but not bleached: on `ccbright` (+2.5 EV colours), mean chroma at exp +2 is 0.60–0.97 × exp 0 (colour stocks). | as stated | FAIL: everything brightens. Code at −5 EV goes 11 → 28 (Portra), highlight slope 26 → 8 code/EV, bright-card chroma ratio 0.26–0.40 (bleached) |
| S29 | Underexposure −2 on negatives gives muddy, fogged shadows. The log-log slope over −4…−2 EV is ≤ 0.85 × exp 0, and code at −4 EV is ≥ exp 0 (lifted, not crushed). Colour negatives get a cool/green shadow cast: mean (G+B)/2 − R over −4…−2 EV in [+1, +6] codes. | as stated | FAIL: slope ratio 0.54–0.61 passes, but the picture is 2.5–3.4 EV darker, so −4 EV prints darker instead of fogged (Portra 17.8 → 7.8); cast Portra −1.3, Ektar +0.7, Cine +0.8 (Gold +1.6 ok) |
| S30 | Velvia (reversal, no print): Film Exposure IS scene exposure. Grey at film exposure e equals Velvia's own ramp at EV e within 0.20 display-EV, for every e in −2…+3, and grey is strictly increasing. | as stated | PASS: max error 0.12 EV (keep it; the slide's own curve is fixed by S2/S4/S9) |

Grounding: a printer normalises an over- or under-exposed negative to a standard grey. Overexposure gives cleaner, denser shadows and pastel highlights; underexposure gives flat, muddy, grey-green shadows. The `FilmLab.exposure` doc comment already says "not display brightness".

### Push / pull

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S31 | On negatives, grey contrast rises strictly with push over −1…+2. Ratio to push 0: +1 → 1.10–1.30, +2 → 1.20–1.55, −1 → 0.75–0.92. Grey holds within 0.15 EV at every push (lab-normalised). | as stated | PASS: ×0.83/×1.16/×1.31, grey ≤ 0.01 EV (keep) |
| S32 | Push loses the shadow detail the underexposure never recorded (Kodak F-4017: "further loss of shadow detail"). The toe, the EV where luminance first reaches code 12, moves up vs push 0 by ≥ 0.8 EV at +1 and ≥ 1.5 EV at +2. Pull −1 moves it down by ≥ 0.3 EV. | as stated | FAIL: +1 → +0.53…+0.78, +2 → +0.99…+1.27 (contrast steepening only); pull −0.94…−1.22 ok |
| S33 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** Push hardens highlights and pull softens them: code/EV over +1…+2.5 at push +2 ≥ push 0 + 3, and at pull −1 ≤ push 0 − 3. | as stated | FAIL: push 0 → +2 changes it by −1.8…+2.2 (Portra 30.5/32.6/33.3) |
| S34 | Velvia's push range follows its datasheet (−½…+1 stop). On `xramp`, push +2 renders the same as +1 and push −1 the same as −0.5, within 1 code. | ≤ 1 code | FAIL: 10 / 7 codes |

### Identity and safety

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S35 | Monotone per channel: on `xramp` (−12…+8 EV), no channel code ever decreases. This covers every stock × every exposure in −2…+3, every push in −1…+2, and the 4 combined extremes (126 ramps). Existing `testNoStockEverPrintsABrighterSceneDarker` stays. | 0 violations | PASS: 0 of 126 |
| S36 | No NaN or garbage. This is a proxy, since a PNG cannot hold NaN. Every `stress` patch must be uniform (max − min ≤ 1 code), greys ≥ 1e2 must render luminance ≥ 250, and the 0 / 1e-6 / −0.01 patches must render within 3 codes of neutral. | as stated | FAIL: Cine only, because greys up to 1e6 print 247–248 (it never reaches white; same root cause as S4) |
| S37 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** Finish-LUT accuracy, i.e. what the GPU uses. ΔE between `--lut-size 33` and `--lut-size 129` over colorchecker + skin_tones + hue_wheel. 129 is the proxy for exact, and 8-bit quantisation is included, which is why neutral itself is 1.73. | p99 ≤ neutral p99 + 0.5 (= 2.23); max ≤ 4.0 | FAIL: Velvia p99 2.41 (Ektar 2.11, Portra 1.47, others ok; max 3.5) |

### Distinctness

| ID | Claim | Threshold | Baseline |
|---|---|---|---|
| S38 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** On the colorchecker, mean ΔE over the 24 patch means is ≥ 3.0 for every pair of colour stocks and for each colour stock vs neutral. | ≥ 3.0 | FAIL: min Portra–Cine 1.89; Ektar–Velvia 2.0, Gold–Ektar 2.1, Gold–Velvia 2.2, Portra–Gold 2.3 |
| S39 | **[Amended by lead, round 2 — see “Amendments” below; the original text is kept here.]** On real photos, per-pixel mean ΔE averaged over the 6 photos is ≥ 2.0 for every pair of colour stocks and each vs neutral. | ≥ 2.0 | FAIL: min Gold–Ektar 1.55; Portra–Cine 1.9, Ektar–Velvia 2.0 |

### Proxies and caveats (be honest)

- **S2/S3 display contrast.** The log-log slope is the display-referred slope of the whole chain, not a datasheet γ. The bands translate datasheet ordering into display terms. Neutral is 1.31.
- **S5 smoothness.** Measured on 8-bit codes in 0.25-EV bins, so the 2-code/EV allowance absorbs quantisation.
- **S16–S18 hue directions.** These use OKLab hue on sRGB decode, and patch means are taken over the inner 60%. "Warm" for skin is not given a sign, only a narrow band. The Gold, Ektar and Velvia bands encode the documented biases (golden, red-leaning skin; cyan-leaning Ektar sky; violet-leaning Velvia blue).
- **S21 measures twist and gradation, not the % of channels at 0/255.** A correctly gamut-mapped saturated colour sits on the sRGB boundary and has a channel at 0 or 255 too, so that count cannot tell mapping from clipping on a wheel that exceeds sRGB. Neutral itself has 25.8% of the disk on the boundary. S20 does use the 0/255 count, on a sky that is far inside the gamut in the neutral render.
- **S22 reference.** The reference is "a grey of equal Rec.2020 luminance through Tri-X's own curve". The thresholds encode the published direction (extended blue lighter, deep red slightly darker), not a measured spectral curve.
- **S24 regions.** Fixed fractions of the 768-px frame (see `R_4694_*` in measure.py).
- **S28 "pastel".** Measured as chroma of +2.5 EV colours. The real Portra overexposure look also includes lower highlight contrast; the highlight-slope clause covers that.
- **S36 is a proxy** for NaN/Inf.
- **S37 uses LUT 129 as "exact".** `ReferenceRenderer.renderExact` is not exposed by the CLI.

### Tests that encode current numbers

From the audit, §2.
- `EngineMathFixtureTests.testFilmChainMatchesTheReference` holds golden grey-ramp numbers. Any retune must update `FILM_STOCKS`/`film_render` in `scripts/gen-fixtures.py` and regenerate `enginemath.json` in the same commit.
- `ProofRegistry` and `SliderEvidenceTests` film entries may need their evidence refreshed.
- `KernelGoldenTests` LUT goldens.

Do not loosen the anchor, monotonicity, amount-identity or convex-blend tests (S1, S25, S26, S35 mirror them).

## Visual claims (a human judges these from the sheets)

`measure.py --out DIR` writes `sheet_{4694,983,6929,2545,skin_tones,colorchecker,grey_ramp}.png` (neutral + six stocks) and `sheet_portra_{exposure,push}_2545.png`.

- **V1. Each stock is recognisable** (`sheet_6929.png`, `sheet_4694.png`, `sheet_983.png`). Someone who knows the stocks can name each tile without the label:
  - Portra: soft, warm-neutral, gentle colour, clean whites.
  - Gold: golden-warm, punchier reds and yellows.
  - Ektar: vivid, crisp, red-forward, deep slightly cyan sky.
  - Velvia: dense, very saturated, emerald greens, deep violet-leaning blue, rich but not empty shadows.
  - Cine: Kodak-print look, with deep blacks, bright neutral highlights, teal-leaning shadows and warm skin.
  - Tri-X: punchy B&W, lighter sky, separated fruit.

  No tile looks like "neutral with a saturation slider". Whites on the 6929 wall and the 983 snow are white, not grey.
- **V2. Skin is beautiful on every colour stock** (`sheet_skin_tones.png`, `sheet_983.png` Passport patches). Light skin keeps its colour (not ashen). MST 6–8 and dark skin read as skin (not burnt orange, rust or mustard). The 983 sky is a believable deep blue with texture, not flat ultramarine.
- **V3. Film Exposure and push read like the lab** (`sheet_portra_exposure_2545.png`, `sheet_portra_push_2545.png`):
  - Exposure: the six tiles have about the same brightness. +2/+3 look airy and pastel with clean shadows; −2/−1 look flat and muddy in the shadows.
  - Push: contrast and black density rise visibly with push, shadow texture disappears at +2, and −1 is soft.

## Amendments (round 2, by the lead)

Each row marked "Amended by lead" in the tables above keeps its original text. `measure.py` implements the amended threshold and keeps the old one in a comment beside it. The evidence is in `SPEC-CHANGES.md`.

| Line | Old threshold | Amended threshold | Reason |
|---|---|---|---|
| S6 | p99.9 within ±6 codes of neutral for every stock (Velvia: lower bound only) | p99.9 ≥ neutral − 6 for every stock; the upper bound (≤ neutral + 6) applies only to Portra and Cine | Amended by lead, reason: a stock with more contrast than neutral (S2) necessarily brightens its p99.9; S6 guards against grey whites, not against contrast. |
| S11 | Gold and Cine only | Portra added: R−B in [0, +6] over −4…+3 EV, highlight mean R−B ≥ +1, \|G−(R+B)/2\| ≤ 3 | Amended by lead, reason: Portra's warm-neutral cast is authored and must have a documented sign. |
| S12 | Portra 1.00–1.15, Cine 0.95–1.15, Gold 1.12–1.30, Ektar 1.25–1.45, Velvia 1.35–1.60 | Portra 0.95–1.15, Cine 0.92–1.10, Gold 1.08–1.25, Ektar 1.18–1.40, Velvia 1.22–1.45 | Amended by lead, reason: the chart is gamut-limited (patches at 0.27–0.99 of the sRGB edge). The bands are what the gamut allows; saturation moves to photos. |
| S13 | gaps ≥ 0.05 on chart and photos | photos: Velvia ≥ Ektar + 0.05, Ektar ≥ Gold + 0.08, Gold ≥ Portra + 0.05, Cine ≤ Portra + 0.03; chart: the same order with gaps ≥ 0.03 | Amended by lead, reason: Ektar must read as punchy against Gold on photos, where the gamut leaves room. |
| S14 | Portra 1.00–1.20, Cine 0.95–1.20, Gold 1.10–1.35, Ektar 1.25–1.50, Velvia 1.35–1.70 | Portra 1.00–1.15, Cine 0.92–1.10, Gold 1.15–1.30, Ektar 1.38–1.60, Velvia 1.45–1.80 | Amended by lead, reason: the owner asked for Ektar "punchy and saturated" and each stock distinct. |
| S15 | ≤ 1.40 for every colour stock | ≤ 1.40 for Portra, Gold and Cine; ≤ 1.80 for Ektar and Velvia | Amended by lead, reason: gamut-bound. A muted patch can take the stock gain and a patch at the edge cannot. |
| S24 | lemon − dish ≥ 42 codes | lemon − dish ≥ neutral's separation − 2 | Amended by lead, reason: the panchromatic response (S22) darkens the lemon relative to luma. |
| S26 | within ±0.10 of linear | within ±max(0.10, 0.25 ΔE / ΔE100) | Amended by lead, reason: 8-bit quantisation on the near-neutral stocks. |
| S33 | code/EV over +1…+2.5 at push +2 ≥ push 0 + 3 | EV of code 250 at push +2 ≤ push 0 − 0.75 and at pull −1 ≥ push 0; the pull clause (code/EV ≤ push 0 − 3) is kept | Amended by lead, reason: a pushed print reaches white sooner, which is the measurable "harder highlight". |
| S37 | film stocks at 33³ | film stocks at 65³ (pending NEEDS.md) | Amended by lead, reason: the finish table spacing (0.75 EV) is outside the lane. |
| S38 | ≥ 3.0 for every pair and vs neutral (chart) | ≥ 2.5 for every colour stock vs neutral (chart); pairs reported only | Amended by lead. |
| S39 | ≥ 2.0 for every pair and vs neutral (photos) | ≥ 2.5 for every colour stock vs neutral and ≥ 2.0 for every pair (photos) | Amended by lead. |

**Measured bound for S38/S39 (not met, round 2).** Chart vs neutral: Portra 1.5, Cine 1.8 (Gold 3.0, Ektar 4.1, Velvia 7.2). Photos vs neutral: Cine 1.6, Portra 1.9, Gold 2.0 (Ektar 2.9, Velvia 3.8). Photo pairs: Ektar–Velvia 1.7, Portra–Gold 2.0. The ceiling these lines meet is the unamended lines S1, S7, S10, S11, S12, S14, S16, S17 and S21; see SPEC-CHANGES.md §8.
