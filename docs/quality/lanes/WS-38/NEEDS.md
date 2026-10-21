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

### Round 2 update: the saturated stocks need 97³

The round-2 colour gives Ektar and Velvia the photo saturation the lead asked for: Ektar ≥ 1.38 and Velvia ≥ 1.45 times neutral's chroma on photos. To get there without clipping, the stock gain on muted colours has to be large (Velvia's `chroma` is 3.4, falling to 1 at the sRGB edge). The cube interpolates that gain across a 0.375-EV cell around near-neutrals, so the 65³ table no longer meets S37's max on Velvia.

- **Measured with `lumen-render`, 65³ against 129³:** Velvia p99 1.04, max **4.9**. Ektar p99 1.85, max 3.8, which passes.
- **Measured against the exact chain in the builder's mirror** (ΔE2000 over colorchecker, skin_tones and hue_wheel, p99 / max):

  | table | neutral | Velvia 50 | Ektar 100 |
  |---|---|---|---|
  | 33³ | 1.73 / 3.07 | 3.47 / 9.55 | 3.84 / 7.82 |
  | 65³ | 1.15 / 1.77 | 1.71 / 5.26 | 2.39 / 3.80 |
  | 97³ | 0.85 / 1.80 | 1.71 / 3.04 | 1.71 / 2.67 |
  | 129³ | 1.21 / 1.73 | 1.71 / 2.18 | 1.22 / 2.00 |

- **What the lane already did.** It tapered the hue and chroma lobes to the film's own hue below an OKLab chroma of 0.04 (Velvia) and 0.05 (Ektar). This is `FilmColor.lobeChromaTaper`. It brought Ektar's max from 4.7 to 3.8 and Velvia's from 5.5 to 4.9. What remains is the isotropic gain itself.
- **The request.** Bake film plans with a saturating stock (Velvia, Ektar) at 97³, or use the 1-D log-luminance pre-LUT described above. Either brings Velvia within the bar.
