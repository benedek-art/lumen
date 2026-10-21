# WS-38 spec lines the builder could not meet, and why

Builder pass. None of these thresholds was changed in `SPEC.md` or `measure.py`. Each case
below says what the line asks, what the build measures, and why the builder thinks the line
is wrong or in conflict with other lines. The verifier and the owner decide.

All numbers come from `python3 docs/quality/lanes/WS-38/measure.py` on the builder's final
commit: 28 of 39 lines pass. The sheets are in the builder's scratchpad (`after/`).

## 1. S6 upper bound vs S2 for the high-contrast stocks (Gold, Ektar, Tri-X)

- **The line asks:** p99.9 luminance within ±6 codes of neutral on all six photos.
- **Measured:** Portra −0.0…+6.0, Cine −0.0…+4.9, Gold +2.4…+12.7, Ektar +4.4…+16.1, Tri-X −0.0…+16.4. The lower bound (the "grey whites" complaint) passes everywhere.
- **The conflict.**
  - S2 requires a grey slope of ≥ 1.36 (Gold), ≥ 1.50 (Ektar) and ≥ 1.40 (Tri-X), against neutral's 1.32.
  - On these photos p99.9 sits at +1.4…+2.5 EV (codes 186…220).
  - A curve that leaves grey at slope 1.5 and is still within 6 codes of neutral at +1.5 EV has to bend from slope 1.5 to about 0.6 within half a stop of grey. That gives flat, compressed highlights, which is the opposite of what Ektar is.
  - The builder fitted the print curves with both targets weighted. The trade-off is continuous: each 0.05 of grey slope costs about 2–3 codes at +1.5…+2.5 EV.
- **Proposal:**
  - For stocks whose S2 band starts above neutral (Gold, Ektar, Tri-X, Velvia), keep only the lower bound (≥ neutral − 6), as Velvia already has.
  - Or allow +18 codes for those stocks.
  - A punchy stock prints brighter highlights. That is the stock, not a defect.

## 2. S12 / S13 / S14 / S15 with the gamut lines (Velvia, Ektar)

- **The lines ask:** chart chroma ratio Velvia 1.35–1.60 and Ektar 1.25–1.45 (S12), photos Velvia ≥ 1.35 (S14), max/min per-patch ratio ≤ 1.40 (S15), Velvia ≥ Ektar + 0.05 (S13), and no clipping or radial collapse at the gamut edge (S20, S21).
- **Measured:**
  - S12 chart: Portra 1.04, Gold 1.12, Ektar 1.24, Velvia 1.28, Cine 0.95.
  - S14 photos: Portra 1.12, Gold 1.23, Ektar 1.26, Velvia 1.33, Cine 0.98.
  - S15: Ektar 1.44, Velvia 1.61.
  - S13: the order is right on both. Only the chart Velvia−Ektar gap is 0.04 instead of 0.05.
- **Why the lines cannot all hold.**
  - The 18 chart patches already sit at 0.27…0.99 of the **sRGB** chroma boundary in the neutral render: `0.37 0.33 0.27 0.51 0.33 0.60 0.82 0.46 0.57 0.41 0.80 0.88 0.50 0.67 0.73 0.92 0.57 0.99` (measured).
  - A patch at x of the boundary can only gain 1/x without clipping. The cyan patch can gain ×1.01, yellow ×1.09, orange-yellow ×1.14.
  - If S15 (max/min ≤ 1.40) holds and nothing clips (S20/S21, the owner's "electric navy" sky), the chart mean tops out near 1.28–1.30. That is what the build reaches.
  - The old code reached 1.46 by clipping. Its 983 sky had R = 0 and its hue-wheel edge twisted 11°.
  - Velvia's S15 of 1.61 is the price of its low-chroma colours getting the full ×2.26 while its saturated ones are held at the boundary. Holding it to 1.40 makes Velvia less saturated than Ektar.
- **Proposal:**
  - Velvia chart band 1.22–1.50, photos 1.28–1.70.
  - Ektar chart band 1.18–1.45.
  - S15 ≤ 1.65 for Velvia, or measure S15 only over patches below 0.6 of the sRGB boundary.
  - Keep S20/S21 as they are. They are the ones that encode the owner's complaint.

## 3. S24 (Tri-X lemon vs dish) vs S22 (panchromatic)

- **The line asks:** lemon − lit green dish ≥ 42 codes on 4694.
- **Measured:** 36.4. The tomato line passes (37.0 ≥ 35.0).
- **The conflict.**
  - S22 asks for real panchromatic response: blue ≥ +4, purplish blue ≥ +2 and red −14…−2 against a luminance-equal grey. The build gives blue +22, purplish blue +20, red −4.9 and green −10.8.
  - The dish is a cyan-leaning green and the lemon is a yellow with almost no blue. Every unit of blue sensitivity S22 asks for lifts the dish relative to the lemon.
  - The builder scanned weights from (0.22, 0.56, 0.22) to (0.28, 0.44, 0.28), with up to +6 % contrast. Lemon − dish stayed at 33.7–37.3 throughout.
  - Real unfiltered Tri-X does compress yellow against blue-green. That is why B&W shooters use a yellow filter.
- **Proposal:** lemon − dish ≥ neutral − 2 (separation not lost), and keep S22 as it is.

## 4. S26 for the near-neutral stocks (Portra, Cine)

- **The line asks:** the amount-10 ΔE fraction is within ±0.10 of 0.10.
- **Measured:** Portra 0.243, Cine 0.227. Every other point and every other stock passes. Amount 50 is 0.56 and 0.59.
- **Why.**
  - ΔE at amount 100 is only 1.62 (Portra) and 1.25 (Cine), because those stocks are by design close to neutral (S10, S12, S16 and S19 pin them there).
  - At amount 10 the 8-bit encode moves many pixels by one code, which adds a fixed ~0.25 ΔE floor. 0.25 / 1.62 ≈ 0.15 of the full value comes from rounding.
  - The blend itself is linear: it is a display-linear mix, and S25 and the convex-blend test hold.
- **Proposal:** measure S26 on the float render, or use an absolute tolerance (±0.25 ΔE) in place of the ±0.10 fraction when ΔE at amount 100 is < 2.5.

## 5. S33 (push hardens highlights, measured as code/EV over +1…+2.5 EV)

- **Measured** (pull −1 / push 0 / push +2):
  - Portra 35.0/38.7/36.7
  - Gold 36.4/38.9/32.5
  - Ektar 36.2/37.9/29.2
  - Tri-X 36.9/38.8/31.1
  - Cine 34.3/38.0/36.2
- **The conflict.**
  - S31 requires push +2 to multiply the grey slope by 1.20–1.55. The build gives ×1.49–1.53.
  - Once grey is that steep, +1 EV already prints near 190 and +2.5 EV near white.
  - The +1…+2.5 window then lies in the shoulder, where a harder print shows as white arriving *sooner*. A steeper code/EV across that window cannot show it.
  - The EV where luminance reaches code 250 moves from push 0 to push +2 as follows (that is "harder highlights"):
    - Portra 4.11 → 2.47
    - Gold 3.65 → 2.22
    - Ektar 3.52 → 2.12
    - Tri-X 3.55 → 2.14
    - Cine 4.25 → 2.57
  - Pull −1 moves it the other way: Portra 5.29, Gold 4.81, Ektar 4.65, Tri-X 4.60 and Cine 5.51.
  - Pull softens the window as the line asks: −3.7…−1.7 code/EV.
- **Proposal:** push +2 moves EV(250) down by ≥ 0.75 EV and pull −1 moves it up (or keeps it), and keep the pull half of S33 as it is.

## 6. S37 (33³ finish-table accuracy) for the steep stocks

- **Measured** (p99 / max):
  - neutral 1.73/3.0
  - Portra 1.56/3.8, Tri-X 1.19/1.6 and Cine 2.17/3.7: all pass
  - Gold 2.10/**5.1**
  - Ektar **2.62/6.9**
  - Velvia **3.19/7.2**
- **Why.**
  - The finish table spaces its nodes 0.75 EV apart (24 stops over 33 points).
  - Velvia's tone alone, with its colour stage switched off, already measures p99 2.8 in the builder's mirror. A slope of 1.8 between nodes 0.75 EV apart is past what linear interpolation follows within 2.2 ΔE.
  - The rest is the stock saturation, which is gamut-relative. It was made as smooth as the builder could make it: the gamut reach uses a deliberately coarse 30° × 0.2 L sRGB boundary. The exact boundary measured p99 4.8 on Velvia.
  - The old Velvia passed only because its contrast was below neutral's.
- **Proposal:** the fix belongs to the finish table, not the stock. See `NEEDS.md`.

## 7. S38 / S39 (distinctness ≥ 3.0 ΔE on the chart, ≥ 2.0 on photos)

- **Measured minimums:**
  - chart: neutral–Portra 1.63, neutral–Cine 1.6, Portra–Cine 1.9
  - photos: Portra–Gold 1.36, neutral–Portra 1.5, neutral–Cine 1.6, Ektar–Velvia 1.6, Gold–Ektar 1.9
  - Every other pair passes.
- **The conflict.** The other lines define Portra and Cine as close to neutral:
  - S10: casts ≤ 3 codes
  - S12: chroma 1.00–1.15 and 0.95–1.15
  - S16: skin hue ±4°, ΔL ≤ 0.03
  - S19: mean hue ≤ 4°
  - S2: Cine contrast 1.25–1.48 around neutral's 1.32
- **What the build does.** It pushes Portra's and Cine's authored differences (contrast, warm/teal crossover, olive greens, cyan-leaning sky) to the edges of those bands, and the remaining distance is what those bands allow. A 3.0 ΔE2000 mean against neutral is a large visible shift on every patch. It cannot coexist with "Portra skin within 4° and 1.20× of neutral".
- **Proposal:** distinctness ≥ 3.0 between the saturated stocks and ≥ 1.5 for pairs involving Portra, Cine or neutral. Or drop the neutral column.

---

# Round 2

The lead accepted §1 (S6), §3 (S24), §4 (S26), §5 (S33) and §6 (S37 at 65³, pending NEEDS.md). The lead rejected §2 and §7 as written and set new targets. SPEC.md ("Amendments") and `measure.py` record every amendment, with the old threshold kept visible. Final measurement: **36 of 39 lines pass**. S37, S38 and S39 fail.

## 8. S38 / S39 at the lead's amended bar (≥ 2.5 vs neutral; photo pairs ≥ 2.0): the measured bound

- **Measured, final build** (mean ΔE2000):
  - chart vs neutral: Portra 1.5, Cine 1.8 (Gold 3.0, Ektar 4.1, Velvia 7.2 pass)
  - photos vs neutral: Cine 1.6, Portra 1.9, Gold 2.0 (Ektar 2.9, Velvia 3.8 pass)
  - photo pairs: Ektar–Velvia 1.7, Portra–Gold 2.0; every other pair is ≥ 2.3
- **Where the photo distance lives.** The six photos are dark, and the pixels below L* 25 carry 60–90 % of every stock's ΔE (per-photo decomposition in the builder's mirror). That band is held by lines the lead did not amend:
  - S1: mid-grey within 1 code
  - S7: p1 within ±4 codes
  - S8: black floor
  - S10: Portra casts ≤ 3 codes over −6…+3.5 EV
  - S11: Gold R−B ≤ 8, now at 7. Cine shadow B−R ≤ 6, now at 5.5. Portra R−B ≤ 6.
  
  The colour lines bound the rest:
  - S14: Gold ≤ 1.30 and ≤ Ektar − 0.08; Portra ≤ 1.15; Cine ≥ 0.92
  - S16: Portra skin within 4° and 1.20×
  - S17: Gold skin hue ≤ +8°, now at +7.7
  - S21: gamut-edge hue, p90 ≤ 8°
- **Experiments, each run on all lines** (results in the builder's mirror, which reproduces the CLI):

  | change | S39 effect | what it broke |
  |---|---|---|
  | Gold chroma 1.9 → 2.1, stronger warm lobes | Gold vs neutral 1.9 → 2.2 | S14 (Gold 1.31 > 1.30), S17 (Gold skin +9°), S19 |
  | Gold shadow tint ×1.4 | +0.1 | S9 (crushed shadows) |
  | Cine chroma 1.15 → 1.05, teal-green shadow, warmer skin | Cine 1.6 → 1.95 | S11 (shadow B−R 6.5 > 6), S12 (0.90 < 0.92), S17 (Cine skin +7°), S21 (dh90 8.6) |
  | Portra stronger warm/olive/cyan lobes, pastel 0.3 | Portra 1.9 → 2.0 | S16 (skin dh −6.6), S19, S21 |
  | Portra γ × 0.90 (round-2 probe) | Portra 2.5 | S7 (p1 +6.7 codes) |
  | Velvia hue lobes stronger | Ektar–Velvia 1.7 → 1.8 | S13/S14 (Velvia 1.44), S18 (blue +9.5° > +8) |

- **What the build keeps.** Each stock sits at the edge of the lines above: Gold's R−B 7 of 8, Cine's shadow 5.5 of 6, Gold skin +7.7 of 8, Portra p1 +3.7 of 4. Ektar–Velvia is close on photos because both are saturated stocks in dark scenes. They are 4.5 apart on the chart, and the sheets tell them apart: Velvia is denser, violet in the sky and emerald in the greens.
- **Proposal.** Keep S38/S39 at the lead's bar for Gold, Ektar and Velvia. For Portra and Cine, the bar is reachable only if S1/S7/S10/S11/S16 move: a visible global cast, or a lower Portra contrast. The measured bound is chart ≥ 1.5 and photos ≥ 1.6 vs neutral, and photo pairs ≥ 1.7. That decision is the lead's.

## 9. S37 at 65³ for Velvia

The lead's amended S37 at 65³ passes for every stock except Velvia: p99 1.04 (passes), max **4.9**, where the bar is 4.0. The photo saturation the lead asked for (Velvia ≥ 1.45 on photos) needs a muted-colour gain of 3.4. The cube spreads that gain over a 0.375-EV cell, and the max error comes from near-neutral pixels in that cell. The lane tapered the hue and chroma lobes near neutral (`FilmColor.lobeChromaTaper`), which took Ektar from 4.7 to 3.8 (now passing) and Velvia from 5.5 to 4.9. A lower `saturationFalloff` would interpolate better but collapses the radial gradation at the gamut edge (S21: 12–25 % against neutral's 7.9 %). The mirror measures Velvia at 97³ against the exact chain as max 3.04. NEEDS.md now asks for 97³ for film plans with a saturating stock.

## Round-2 changes in the lane

- **Saturation is gamut-relative headroom.** The gain is `1 + (k − 1)(1 − x)^saturationFalloff`, where x is the share of the sRGB edge already used. Muted colours get the full stock gain and colours at the edge get none, so photos read punchy while skies keep their gradation (S20/S21 pass).
- **`highlightPastel`.** Portra (0.22) and Cine (0.10) take part of the gain back in the light tones: soft, pastel highlights.
- **`lobeChromaTaper`.** Ektar and Velvia fade their hue and chroma lobes toward the film's own hue below OKLab C 0.05 / 0.04 (S37).
- **Pull has its own rates** (`FilmPushResponse.pullGammaPerStop`, `printToePerPullStop`). Pull −1 prints a softer highlight roll-off (S33 pull clause): 0.82 × the push gamma rate and a 0.32 print toe per stop.
- **`FilmChain.neutralBlackSpan` 15 → 20.** Paper black stays neutral now that Portra's lower contrast leaves scene black a few floors above paper black.
- **Per stock:**
  - Portra: γ × 0.96, warm golden skin lobes, olive greens, softer slightly cyan sky
  - Gold: chroma 1.95, golden lobes
  - Ektar: chroma 2.75 with red/blue/green lobes
  - Velvia: chroma 3.4 with violet/emerald lobes and a light-skin lobe (S17); the blue-sky chroma lobe is at 0.8 (S15)
  - Cine: chroma 1.15, teal greens and shadows, warm skin and highlights
