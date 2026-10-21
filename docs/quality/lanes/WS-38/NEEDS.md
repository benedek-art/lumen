# WS-38 needs from code outside the lane

## Finer finish table for film plans (RenderPlan finish LUT; owner: the plan / LUT lane)

- **The problem.** The finish table is 33³ over `LumenLog`'s 24 stops, so its nodes sit 0.75 EV apart. Linear interpolation across that spacing cannot follow a slide-film curve.
  - On Velvia 50, at the gamma its datasheet gives (spec S2: 1.75–2.20), the interpolation error between the interactive 33³ table and the 129³ proxy is p99 3.19 / max 7.2 ΔE2000 (S37 asks ≤ 2.23 / ≤ 4.0).
  - On Ektar it is 2.62 / 6.9, and on Gold the max is 5.1.
  - About 2.8 p99 of Velvia's error is the tone curve alone, with no colour stage: measured in the WS-38 mirror with the colour stages switched off.
- **The request.** Bake film plans' finish table at 49³ (or the 65³ export size) for interaction too. Alternatively, sample the film chain through a 1-D log-luminance pre-LUT so the cube only carries chroma.
  - Neither is in `FilmChain`. The chain bakes whatever size the plan asks for (`bakeLUT(size:)`, `RenderPlan` `lutSize`).
  - The export path is already 65³.
- **Evidence.** ΔE2000 against the 129³ proxy over colorchecker + skin_tones + hue_wheel (`lumen-render --lut-size N`), p99 / max:

  | table | neutral | Velvia 50 | Ektar 100 |
  |---|---|---|---|
  | 33³ | 1.73 / 3.0 | 3.19 / 7.2 | 2.62 / 6.9 |
  | 49³ | 1.20 / 2.2 | 1.77 / 5.4 | 1.80 / 4.7 |
  | 65³ | 1.15 / 1.9 | 1.12 / 3.5 | 1.38 / 3.5 |

  At 65³ both steep stocks meet S37's bar, and 49³ meets the p99 half of it.
