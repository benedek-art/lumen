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
