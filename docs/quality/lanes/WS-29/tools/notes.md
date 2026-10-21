# K4 built-in looks: design notes

Photos (rows, in order): 6929_sony-ilce-7m4 (A7 IV, foliage + wall), 2545_panasonic-dmc-gx85
(GX85, sunlit garden, blue sky), 1569_panasonic-dmc-gx80 (pond landscape, high dynamic range),
4694_canon-eos-r5 (fruit, low-key: the warm skin-like tones of potato/apple stand in for skin),
1332_canon-eos-77d (flowers + white porcelain: neutral-white test), 1192_fujifilm-x-t10 (stained
glass, low light, saturated primaries). The corpus has no frame with a person, so skin was
judged on the warm fruit and on porcelain staying neutral; a real portrait check is still owed.

All looks use only the `look` subtree. Rendered with `as-shot` WB/ISO from each sidecar, no
develop changes, so the baseline (None) is the corpus' Neutral render, which runs dark.

| # | Look | Intent | Key settings |
|---|---|---|---|
| 1 | Natural Portrait | gentle, flattering: softer curve, a breath of warmth, quieter colour | render Soft; global wheel hue 60 sat 0.03; high hue 70 sat 0.04; saturation −8 |
| 2 | Vivid Landscape | clear and rich without neon or hue shifts | Punchy, contrast 1.7, skew +0.3 (keeps shadows open); vibrance +35, saturation +5 |
| 3 | Soft Matte | lifted, muted, editorial | Soft, contrast 1.25, blackTarget 0.8 %; saturation −18 |
| 4 | Warm Film | Portra-ish warmth and palette | filmLab lumen/portra400 at 80 %; creative grain 15 |
| 5 | Cool Cinema | restrained split: teal shadows, warm highlights, whites stay white | Film Base; shadows hue 200 sat 0.08; high hue 65 sat 0.05; vibrance −10 |
| 6 | Faded Vintage | aged print: faded blacks, warm-yellow highs, green-cyan shadows, grain | Film Base, blackTarget 1.0 %; shadows 170/0.06; high 80/0.10; saturation −30; vignette −0.5; grain 30 |
| 7 | B&W Classic | neutral panchromatic with a faint yellow-filter lift | bw bands [5,8,5,0,0,−5,0,0]; Neutral contrast 1.65 |
| 8 | B&W High Contrast | red/orange-filter drama, dark skies | bw bands [20,12,0,−5,−10,−25,−10,5]; Punchy contrast 1.85; vignette −0.25 |

Per-tile numbers (mean L*, p99 L*, % clipped ≥254, % crushed ≤1 code) are in metrics.txt.
No look clips (max 0.02 % on the stained glass, None is 0.00). Crush is the trade-off:
B&W High Contrast crushes 6.2 % of 1192 and ~9 % of 4694 (both low-key frames; None is
0.24 % / 2.3 %); every other look stays under 3.2 % on those frames and under 1.2 % elsewhere.

## Things that rendered badly or surprised me (audit input)

- `look.render.blackTarget` is in % of SDR white but on the LINEAR axis: 4 (the obvious
  "4 % lift") reads as a ~22 % code lift and turns the frame milky (first Soft Matte /
  Faded Vintage draft). Useful values are 0.5–1.5. The RecipeLook comment "0…15 % of SDR
  white" is true but the top two-thirds of that range are unusable; worth a perceptual
  mapping or a smaller range (owner: display transform lane, not K4).
- The Punchy preset alone crushes low-key frames: on 4694 Punchy contrast 1.75 crushes
  5.75 % at skew −0.2, 5.0 % at +0.1, 4.6 % at +0.3 (None 2.3 %). Positive skew is what
  keeps shadows open; Vivid uses +0.3.
- B&W at bands all 0 matches the colour render's luminance closely (mean L* within 0.6 on
  three frames), but desaturated dry grass then reads brighter than in colour
  (Helmholtz-Kohlrausch); +15 on orange made the 2545 lawn near-white, hence the small bands.
- The `_partN.png` evidence strips are 256-colour quantized to fit 400 KB; the lemon in
  4694 shows posterization there that is NOT in the render (contact.png is lossless).
