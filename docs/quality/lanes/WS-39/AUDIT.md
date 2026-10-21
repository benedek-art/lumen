# WS-39 Film halation: audit

Auditor pass on branch `quality/f1-halation`. No source code was changed.
`A` = `look.filmLab.halation` (Amount), `S` = `halationSize`, `R` = `halationRedness`. Every comparison is
against the same stock at A=0. All renders use `--no-dither` and the sidecar `--as-shot-kelvin/--as-shot-tint/--iso` values.
`$IMG` = `/tmp/claude-0/-home-user-lumen/5be701cd-be2f-564e-867a-0d391695747d/scratchpad/audit`.
Diff maps show `128 + 8×(A − A0)` in sRGB codes, so mid-grey means no change and pink means added red.
Helper scripts are in `$IMG/../scripts` (`r.sh` render, `diff.py`, `regions.py`, `radial2.py`, `model.py`).

Typical command:
`scripts/r.sh corpus/lfi/983_canon-eos-5d-mark-iv $IMG/983_p100.png 1600 --set look.filmLab.stock=lumen/portra400 --set look.filmLab.halation=100`

## Findings

**F1. The stage mostly adds a red cast to bright-but-ordinary surfaces. It does not glow around light sources.**
The gate (smoothstep over the 4 EV below clip=1.0) admits anything above about 0.06 linear, so mid-grey gets t≈0.33.
The model in `model.py` re-implements `HalationProfile` on the .lfi data. On the six real frames, 67–95% of the added
red lands on the pixel that produced it, which makes it a pointwise cast rather than a halo
(1192 67%, 3582 95%, 983 95%, 2062 93%, 6929 72%, 2545 80%). 75–100% of the energy comes from pixels more than
1 EV below clip, i.e. walls, lawn, snow and chart patches.
Added colour far from any edge (Portra, A=35 → A=100, sRGB codes; OKLab ΔE×100 at A=100):

| region (1600 px) | base | ΔRGB A35 | ΔRGB A100 | ΔE_ok |
|---|---|---|---|---|
| 983 snow interior | 104,104,110 | +0.9,+0.1,−0.1 | +2.5,+0.2,−0.2 | 0.40 |
| 983 chart E1 white | 184,182,181 | +2.7,+0.2,−0.2 | +7.0,+0.6,−0.6 | 1.01 |
| 983 chart E3 grey | 121,118,115 | +1.5 | +4.2 | 0.65 |
| 2545 sunlit lawn | 158,134,98 | +2.1 | +5.9,+0.2,−0.5 | 0.95 |
| 2545 sky | 90,149,199 | +1.7 | +4.9,+0.7,−0.2 | 0.55 |
| 3582 white wall (indoor) | 156,140,130 | +2.0 | +5.5,+0.3,−0.4 | 0.86 |
| 6929 white wall | 121,121,127 | +1.5 | +4.1 | 0.63 |
| flat_grey 0.18 | 118,118,118 | +1,0,0 | +4,0,−1 | – |

On grey_ramp (native 2800 px, `ramp_native_p*.png`), the A100 cast in R codes is 0 up to −1 EV,
then +4 @0 EV, +7 @+1, +7 @+2, +4 @+3 and +2 @+4 EV. That is +7.4–9.6% in display-linear R across mid-grey to +2 EV.
The cast peaks on midtones and upper midtones, not on highlights. Physically this flat-field term belongs to the stock's
calibrated curve and should be about zero.
Images: `$IMG/pair_2545.png` (whole lawn turns pink in the diff), `pair_3582.png` (white wall), `pair_6929.png`,
`diff_983_p100.png` (snow, chart whites, lantern glass are flat pink fills with no halo outside them),
`crop_3582_wall.png` (100% crop, wall visibly pinker at A100), `crop_983_lantern_amount.png` (white patch E1 turns pink).

**F2. Genuine light sources barely glow, because real files clip at 1.0 and the energy is capped at 1.23.**
Every corpus .lfi tops out at about 1.0 (983/3582/6929 max 1.00, 1192 1.02). Above the clip, `highlightEnergy` adds only
`boostRange` = 0.3 stop, so a street lamp contributes the same as a white wall.
In a synthetic point light (r=8 px on a 0.005 field, `$IMG/../synth/lights.lfi`), a source clipped at 1.0 gives a peak
added R of +18 codes at A35 and +41 at A100, gone by 8–10 px. Even A100, S2, R100 gives only +41 codes, out to 18 px
(1.1% of the long edge) (`crop_lights_clipped.png`). The same disk at 16.0 (+4 EV) gives a convincing red-orange halo of +224 codes
(`crop_lights.png`), but no raw frame ever delivers that.
On 1192 (stained glass at night, the one frame that should glow), A100 changes ΔE00 by a mean of 0.062 (p95 0.317)
(`sweep_1192_halation.png`, `crop_1192_glass.png`). The brightest glass sits at sRGB 180, below the gate's sweet spot,
so there is no halo at any setting.

**F3. Size and falloff: a thin red fringe, with no long tail.**
σ1 = 65 µm/36 mm = 0.18% of the long edge, and σ3 = 0.31% (2.9 and 5.0 px at 1600).
Radial profile outside the hard_edge disk (4.0 on 0.005), added R in codes against distance from the rim as % of the long edge
(`radial2.py`):

| %LE | 0.1 | 0.2 | 0.3 | 0.4 | 0.5 | 0.6 | 0.8 | 1.0 | 1.5 |
|---|---|---|---|---|---|---|---|---|---|
| LE400 A100 | 86 | 75 | 37 | 20 | 11 | 4 | 1 | 0 | 0 |
| LE800 A100 | 109 | 69 | 37 | 18 | 9 | 4 | 1 | 0 | 0 |
| LE1600 A100 | 109 | 67 | 36 | 19 | 9 | 4 | 1 | 0 | 0 |
| LE1600 A35 | 49 | 28 | 15 | 8 | 4 | 2 | 0.3 | 0 | 0 |
| LE1600 A100 S2 | 141 | 120 | 98 | 77 | 58 | 42 | 22 | 10 | 1 |

The profile is resolution independent (it scales with the long edge, as required). The halo itself is a Gaussian: half-max
at about 0.25% of the long edge and zero by 1% (S1) or 1.5% (S2). It has no core-plus-tail shape.
At 100% it reads as a 6–10 px saturated red outline around edges, like lateral chromatic aberration
(`crop_hard_edge_rim.png`, `crop_he_lines.png`). It does not read as a glow. CineStill-style halos come from the extra-large
"aura" radius that appears when the backing is stripped [3], and they need a heavy tail. Even S2+A100 cannot get there on clipped
input (F2).

**F4. Colour: pure primary red, constant per bounce, and it shifts the wrong way with distance.**
By construction, one RGB gain multiplies the summed field, so every bounce has the same colour. In scene-linear the ratio is
G/R = 0.225 for Portra (0.015×0.75/0.05) and B = 0. After the curve, the added light on the hard_edge rim at A100 is
G/R 0.001 at 1 px, 0.04 at 5 px and 0.22 at 10 px, with OKLab hue 30.4° → 33° → 49°.
So the glow is sRGB-primary red at the source and drifts toward orange as it fades. Physics and practice say the opposite:
orange near the overexposed edge where green is also re-exposed, turning red further out [2]. Emulators blur R wider than G
(1.4 : 1.0 : 0.7 for R:G:B) [4].
The negative ΔB (−8 codes on the rim, −0.2 to −1 on flat fields) is the curve's crosstalk, not an input term.

**F5. Controls (sweeps at 1200 px: `sweep_{1192,983}_{halation,halationSize,halationRedness}.png` + `.json`, tiles in `tiles_*`).**
- Identity holds. A=0 is byte-identical to no `halation` key, and A=0 with S=2, R=100 is also identical (`cmp`). The skip happens
  in `ReferenceRenderer` via `halationAmount > 0`.
- Amount is linear and monotone. On 983, ΔE00 mean/p95 is 0.15/0.78 at 25 and 0.59/2.99 at 100, and the zone table shows it lifting
  z4–z7 by 0.9–1.8 codes, which is the cast. On 1192 it is 0.06/0.32 at 100, effectively dead on the frame that should
  respond most. The thumbnails show no visible change at any value.
- Size is nearly dead. On 983 with A=100, S0.5 vs S1 gives ΔE00 p95 0.22 and S2 gives 0.50; on 1192 the figures are 0.10 and 0.17.
  Size only moves the thin fringe, while most of the effect (the cast) is size-invariant. `crop_983_lantern_size.png`
  shows three indistinguishable crops.
- Redness is monotone but small: 983 p95 1.6 at R100 vs R0, and 1192 p95 0.04.
- Velvia's Amount slider does nothing for 0–100 (strength = 0). That is correct physically, but it is a dead control unless the UI disables it.

**F6. Stock defaults (`stk_he_*`, `crop_stocks_default_rim.png`). Rim = hard_edge 1–3 px outside the disk, flat = 983 E1 white.**

| stock | default A/R | rim ΔR | extent | flat ΔR | expected [1–5] |
|---|---|---|---|---|---|
| portra400 | 35/25 | +54 | 9 px | +2.7 | subtle, OK |
| gold200 | 45/35 | +76 | 10 px | +4.3 | a bit more than Portra, OK |
| ektar100 | 15/15 | +15 | 6 px | +0.8 | very subtle, OK |
| triX400 | 20/0 | +17 neutral | 6 px | +0.8 neutral | subtle neutral, OK |
| velvia50 | 0 | 0 | 0 | 0 | none, OK |
| cine250D | 30/20 | **+61** | **14 px** | +2.1 | **wrong**: Vision3 has rem-jet/AHU anti-halation [5], so it should be the least of the colour negatives. It is the strongest and widest of the stocks at default, and its smaller gate (24.9 mm) makes it 1.45× wider |

There is no CineStill-type (backing removed) stock, and per F2/F3 no setting can produce one. The ordering among the
stills stocks is believable, but on real frames every one of them reads as a warm cast rather than a halo.

**F7. GPU vs CPU (`RenderGraph.applyHalation` vs `ReferenceRenderer.applyHalation`): the same formula, with three small divergences.**
- Profile: both call `film.halation(longEdgePixels:)`. The CPU passes the rendered image's long edge, while the GPU passes
  `options.longEdge`, so they match only if the caller sets that to the image's actual long edge.
- Energy: `lumenHalationEnergy` matches `highlightEnergy`: `t = smoothstep(−4, 0, log2(e/clip))`, `t·e·2^(0.3t)`, with e≤0 → 0
  (the GPU gets 0 through t=0 at e=1e−12). Same.
- Blur: CPU `SpatialOps.gaussianBlur` is exact for σ ≤ 8 and a 3-box approximation above that. GPU `CIGaussianBlur` is exact, with
  radius = σ and floored at 0.5. They diverge for σ > 8, e.g. a 6000 px export at S2 has σ3 = 37.5 px, where box tails are
  shorter. CPU skips σ ≤ 0.05; the GPU blurs at 0.5 for σ < 0.5.
- Accumulate and combine: both use raw weights 1, ½, ¼, then `in + fieldGain·field` (`lumenAddGlow`). Same.
- Edges: CPU blur edge mode vs GPU `clampedToExtent` were not verified. Check this in parity on a frame-edge highlight.
- The `HalationProfile` doc says "quarter-res, upsampled". Neither path does that; both run at full resolution.

## Recommended fixes, ranked by visual impact

1. **Remove the flat-field term.** Apply only the spread: `out = in + gain·(Σw·G∗E − E)`, or equivalently gate by local contrast
   (source minus blurred surround). Flat fields and large bright areas then get ΔRGB ≈ 0, and glow appears only where
   bright meets dark. That fixes F1 and makes Size meaningful (F5).
2. **Give clipped sources real energy.** Reconstruct above the clip much more aggressively (several stops, scaled by how large
   and how clipped the region is), or key the halation source on the S1 clip mask. Then a 1.0-clipped lamp produces a halo on
   par with the +4 EV synthetic (`crop_lights.png`), and 1192 glows. Raise the gate floor so mid-grey contributes nothing
   (e.g. start the ramp 1–2 EV below clip, not 4).
3. **Change the PSF shape: tight core plus long tail.** Use larger outer bounces, or add an exponential or 1/r^n tail term,
   reaching about 1.5–3% of the long edge at S1 and more at S2. That makes a soft glow instead of a 6–10 px red outline,
   and makes a CineStill-like "aura" reachable at S2/A100 (consider a dedicated no-backing stock or preset).
4. **Make colour vary with radius.** Use a wider R kernel than G (≈1.4 : 1 [4]), so the inner glow is orange and the outer is red.
   Pull the near-source hue off sRGB primary red (target OKLab hue ≈ 40–55° near, ≈ 30° far).
5. **Fix stock defaults.** Bring cine250D down below Ektar-level (rem-jet/AHU), and keep Portra < Gold. Re-check every default once 1–3 land.
6. **Parity and housekeeping.** Pass the image's own long edge on the GPU, align the blur for σ > 8 (both exact, or both
   box), and fix the "quarter-res" doc line. Disable or hide Amount for zero-strength stocks (Velvia).

## Sources
1. CineStill 800T product and description: remjet removed for C-41, red halo around point lights. https://www.oddworldstudio.com/products/cinestill-800t-120 ; https://www.wikipedia.org/wiki/Cinestill
2. Dehancer, "Halation and its simulation": red layer nearest the base, "at the overexposed border the halos have an orange tint, and as we move away, they become red", stronger with brighter sources and darker backgrounds, and the carbon backing shortens the radius. https://blog.dehancer.com/articles/halation/
3. Video Village FilmBox guide: halation size scales with gauge; "Aura" is an extra-large-radius halo on stock stripped of anti-halation backing (CineStill). https://videovillage.com/learn/filmbox/full-guide/negative/halation
4. Deep Analog (arXiv 2608.14702): per-channel halation radii R 1.4r, G 1.0r, B 0.7r. https://arxiv.org/pdf/2608.14702
5. Kodak VISION3 250D tech data (rem-jet backing), and ASC "Kodak Enhances Vision3" (AHU anti-halation undercoat). https://www.kodak.com/content/products-brochures/Film/VISION3-250D-Technical-Data-EN.pdf ; https://theasc.com/articles/kodak-enhances-vision3
