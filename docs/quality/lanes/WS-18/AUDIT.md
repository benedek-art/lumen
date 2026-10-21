# WS-18 / WS-17 audit: creative and capture sharpening (lane T3)

Auditor, branch `quality/t3-sharpening`. No Swift source was changed. Everything below
was measured on the CPU reference (`lumen-render`, `ReferenceRenderer`); GPU findings
come from reading the code.

- Measurement script: `docs/quality/lanes/WS-18/measure.py` (header documents every metric)
- Raw results: `/tmp/claude-0/ws18/results/*.json`; sweep sheets and tiles:
  `/tmp/claude-0/ws18/sweeps/<frame>/<key>/` (hard_edge, zone_plate_blur1, 6929, 2348,
  2545, 1840, 4694, 983); native 1024 px crops: `/tmp/claude-0/ws18/nc/`
- Evidence (100 % or nearest-neighbour enlarged crops): `docs/quality/lanes/WS-18/evidence/before_*.png`

Caveats on method:
- No `--iso` was passed to the synthetic measurements. Corpus sweeps for 6929/2348 and
  the native crops ran with `--iso` on the binary from before the S4 rebuild, so that adds
  only the default Classic chroma NR. 2545/1840/4694/983 were re-run without `--iso`
  after the S4 rebuild.
- **Sharpen sigma depends on the render size** (finding 1): σ = radius × longEdge / 2560.
  hard_edge/edge2ev render at 1600 px (σ = 0.625·r), zone_plate at 2048 (0.8·r),
  flat_grey at 1024 (0.4·r), corpus at 2400 (0.94·r). Every synthetic number therefore
  describes sharpening that is smaller than on a real 24–45 MP export.
- hard_edge's plateaus (0.005 / 4.0) clip to codes 0 / 255 after the display transform, so
  its edge-halo numbers stay at 0–0.8 % whatever the setting and are not informative. I
  added `edge2ev_blur1` (the same 5° square, 0.09 on 0.36, σ1 blur), which does not
  clip. Its numbers are the edge MTF/halo figures used below. The grey band's 1/2/4 px
  lines on hard_edge are informative.
- The halo % values are quantised at about 1.3 % (1 code over a 75-code step).

## Identity

PASS. With amount 0, all five test frames (hard_edge, hard_edge_blur1, zone_plate_blur1,
edge2ev_blur1, flat_grey_noise) render byte-identical to the default recipe
(`--check-identity`). The default amount is 0 (Lightroom's raw default is 40).

## Measured numbers

Blurred test frames (σ 1 px optical blur). Gains are relative to the same frame with
sharpening off. Base settings unless varied: amount 70, radius 1, detail 25, masking 0,
halo 0. The "amt" rows use radius 1 / detail 25 / masking 0.
"1px line ring" = flank trench/halo next to the pristine 1 px bright (+4.5 EV) / dark (−5 EV) line on the 0.18 band,
as a % of the off render's line contrast. "noise gain" = std ratio on flat 0.18 + N(0, 0.012) at 1024 px.

| config | MTF50 edge on/off (gain) | MTF50 zone on/off (gain) | zone mod gain f=.1/.2/.3 | halo 2EV edge bright/dark % | 1px line ring bright/dark line % | 4px line ring (blur1) % | noise gain | hard_edge MTF50 gain |
|---|---|---|---|---|---|---|---|---|
| amt0 | 0.191/0.191 (1.000) | 0.207/0.207 (1.000) | 1.0/1.0/1.0 | 0.0 / 0.0 | 0 / 0 | 0.0 / 0.0 | 1.000 | 1.000 |
| amt40 | 0.209/0.191 (1.097) | 0.228/0.207 (1.100) | 1.038/1.169/1.292 | 0.0 / 1.0 | 11 / 18 | 1.5 / 1.0 | 1.138 | 1.042 |
| amt70 | 0.221/0.191 (1.160) | 0.243/0.207 (1.170) | 1.057/1.249/1.484 | 1.0 / 1.8 | 20 / 30 | 2.2 / 1.9 | 1.241 | 1.071 |
| amt100 | 0.233/0.191 (1.222) | 0.257/0.207 (1.239) | 1.080/1.333/1.672 | 1.0 / 2.6 | 29 / 42 | 5.2 / 3.9 | 1.345 | 1.111 |
| amt150 | 0.249/0.191 (1.308) | 0.275/0.207 (1.324) | 1.115/1.446/2.038 | 3.1 / 4.2 | 40 / 60 | 10.4 / 7.8 | 1.519 | 1.179 |
| rad0.5 | 0.209/0.191 (1.096) | 0.225/0.207 (1.084) | 1.031/1.151/1.195 | 0.8 / 1.0 | 6 / 10 | 2.2 / 1.9 | 1.159 | 1.048 |
| rad1 | 0.221/0.191 (1.160) | 0.243/0.207 (1.170) | 1.057/1.249/1.484 | 1.0 / 1.8 | 20 / 30 | 2.2 / 1.9 | 1.241 | 1.071 |
| rad2 | 0.243/0.191 (1.276) | 0.257/0.207 (1.237) | 1.104/1.364/1.619 | 2.8 / 4.1 | 26 / 37 | 8.2 / 7.8 | 1.558 | 1.179 |
| rad3 | 0.250/0.191 (1.311) | 0.256/0.207 (1.234) | 1.138/1.395/1.672 | 5.9 / 6.3 | 21 / 31 | 14.1 / 14.6 | 1.628 | 1.299 |
| det0 | 0.211/0.191 (1.107) | 0.240/0.207 (1.156) | 1.038/1.206/1.484 | 0.0 / 0.1 | 19 / 30 | 0.7 / 0.0 | 1.109 | 1.033 |
| det25 | 0.221/0.191 (1.160) | 0.243/0.207 (1.170) | 1.057/1.249/1.484 | 1.0 / 1.8 | 20 / 30 | 2.2 / 1.9 | 1.241 | 1.071 |
| det50 | 0.230/0.191 (1.205) | 0.246/0.207 (1.187) | 1.074/1.283/1.525 | 2.1 / 3.0 | 21 / 31 | 5.2 / 4.8 | 1.374 | 1.123 |
| det100 | 0.245/0.191 (1.287) | 0.254/0.207 (1.222) | 1.105/1.341/1.619 | 4.7 / 5.2 | 23 / 33 | 11.8 / 11.7 | 1.639 | 1.245 |
| det100 rad0.5 = rad3 | identical to det100 in every number (Radius is dead at Detail 100) | | | 4.74 / 5.21 | | 11.85 | 1.639 | |
| mask0 | 0.221/0.191 (1.160) | 0.243/0.207 (1.170) | 1.057/1.249/1.484 | 1.0 / 1.8 | 20 / 30 | 2.2 / 1.9 | 1.241 | 1.071 |
| mask50 | 0.221/0.191 (1.160) | 0.243/0.207 (1.170) | 1.057/1.249/1.484 | 1.0 / 1.8 | 20 / 30 | 2.2 / 1.9 | 1.121 | 1.071 |
| mask100 | 0.207/0.191 (1.086) | 0.243/0.207 (1.171) | 1.057/1.249/1.098 | 0.0 / 1.0 | 20 / 30 | 2.2 / 1.9 | 1.000 | 1.071 |
| halo0 (amt100) | 0.233/0.191 (1.222) | 0.257/0.207 (1.239) | 1.080/1.333/1.672 | 1.0 / 2.6 | 29 / 42 | 5.2 / 3.9 | 1.345 | 1.111 |
| halo50 | 0.233/0.191 (1.222) | 0.257/0.207 (1.239) | 1.080/1.333/1.672 | 1.0 / 2.6 | 29 / 23 | 5.2 / 3.9 | 1.345 | 1.110 |
| halo100 | 0.233/0.191 (1.222) | 0.257/0.207 (1.239) | 1.080/1.324/1.672 | 1.0 / 2.6 | 29 / 7 | 5.2 / 3.9 | 1.345 | 1.111 |

The off zone-plate MTF50 is 0.207, against 0.187 analytic for the σ1 blur. The display
transform adds a little apparent contrast, which is why everything is reported as a ratio.

Corpus sweeps (2400 px). Whole-frame mean linear-luminance shift `meanLinearLuminanceDeltaEV` and mean/p95 CIEDE2000 against the reference tile:

| frame / key | values → (ΔE mean, ΔEV) |
|---|---|
| 6929 amount 40/70/100/150 | 0.65 +0.031 · 1.11 +0.057 · 1.55 +0.084 · 2.27 **+0.131 EV** |
| 2545 amount 40/70/100/150 | 1.12 +0.033 · 1.90 +0.061 · 2.64 +0.091 · 3.82 **+0.146 EV** |
| 2348 amount 40/70/100/150 | 0.38 +0.016 · 0.65 +0.030 · 0.91 +0.046 · 1.36 +0.080 EV |
| 6929 radius 0.5/2/3 (amt 70, vs r1) | −0.028 · +0.043 · +0.073 EV |
| 6929 / 2348 halo 50/100 (amt 100) | −0.022/−0.045 · −0.016/−0.029 EV |
| 6929 / 2348 masking 50 (amt 70) | ΔE 0.03 / 0.05 (essentially inert); masking 100: 0.24 / 0.21 |
| zone_plate halo 50/100 | ΔE 0.00 / 0.00 |

Real-photo noise (high-pass std of encoded luma, codes):
- 2348 jacket shadow, 2400 px (mean code 17.7): amounts 0/40/70/100/150 give
  5.31 / 7.43 / 9.12 / 10.90 / 14.07 (×2.65 at 150), and the mean rises 17.7 → 20.3 codes.
  Amount 70 + masking 100 gives **9.09**, i.e. masking does nothing here.
- 1840 dusk sky: 0.391 → 0.467 / 0.585 / 0.690. Masking 100 brings it back to 0.391 (works on a bright flat area).
- 6929 native crop at the same location:
  - full 7008 px frame, amount 70 (export-equivalent, σ 1.92 px): 2.83 → **4.30**
  - same pixels rendered as a 1024 px crop (σ 0.4 px): amount 100 gives 3.63, amount 150 gives 4.04

## Findings, ranked

### S1. Blocks the lane

**F1. Radius is a fraction of the frame, not a pixel radius, so an export can never get
fine sharpening and every preview size gets a different amount.** `frameDenominatedSigma`
gives σ = radius·longEdge/2560 (`SpatialOps.swift:461`; CPU `DetailEngine.swift:599`, GPU
`RenderGraph.swift:1466`). On a 7008 px A7 IV export, Radius 1.0 is σ 2.74 native px and
the minimum, 0.5, is σ 1.37 px. In Lightroom, Radius 1.0 means about one source pixel.
The fine 1–2 px scale that capture/creative sharpening exists for is therefore out of
reach on every frame larger than 2560 px, and the default already produces 3–4 px-wide
dark rings: `evidence/before_6929_native_fullframe_a0_a70_vs_crop_a100.png`, where the
white sky gaps in the middle panel are rimmed. The other way round, a 1024 px crop or a
small preview gets σ 0.4 px. The same 6929 pixels show high-pass std 4.30 at amount 70
when the full frame is rendered, but only 4.04 at amount **150** when rendered as a crop.
"Same look at fit and at export" was the goal (E2-04), but the photographic definition is
the other way round. Proposal: σ = radius × (render long edge / source long edge), so the
export gets `radius` source pixels and a downscaled preview gets proportionally less,
which is what Lightroom shows.

**F2. Sharpening brightens the picture.** It works on log2 luminance and is applied as a
2^Δ ratio (`applyLumaRatio`). For zero-mean Δ, the mean of 2^Δ is above 1 (Jensen's
inequality), so every textured or noisy area lifts. The whole frame rises by **+0.084 EV**
at amount 100 and **+0.131 EV** at 150 on 6929, and +0.146 EV on 2545. 2348's shadows rise
17.7 → 20.3 codes (+15 %). Halo damping, which is one-sided, pulls it back down by
−0.045 EV. Sharpening must be tone-neutral. Lightroom's sharpening does not move mean
exposure.

**F3. Masking does not behave like Lightroom's at any setting.**
- (a) It scales the mask by the slider (`v *= mix(1, edge, masking)`), so at masking 50
  flat areas keep 50 % of the sharpening. Flat 0.18 noise gain is 1.241 at masking 0,
  1.121 at 50 and 1.000 at 100. On real photos masking 0→50 is effectively inert
  (ΔE 0.03 on 6929, 0.05 on 2348). In Lightroom, Masking 50 already leaves flat areas
  black in the mask (unsharpened).
- (b) The gate is a gradient in EV/px, and shadow noise is large in EV. Flat noise at
  0.01 linear (20 % noise) gives noise gain 1.248 at masking 0, **1.246 at 50** and 1.114
  at 100. On 2348's shadows masking 100 changes nothing (9.12 → 9.09):
  `evidence/before_2348_shadow_noise_a0_a150_a70mask100.png`. Masking fails exactly
  where it is needed, in noisy dark areas.
- (c) Masking 100 also masks real edges. On a clean 2 EV σ1 edge the MTF50 gain drops
  from 1.160 to 1.086, and the zone-plate gain at f = 0.3 drops from 1.484 to 1.098. In
  Lightroom, Masking 100 keeps strong edges fully sharpened.

**F4. Halo damping does not damp the halos you can see.** On the 2 EV edge the
overshoot is 1.0 % bright / 2.6 % dark at halo 0, 50 and 100 alike. On the zone plate
ΔE = 0.00. It acts only on extreme contrast: next to the −5 EV line on grey, the bright
flank goes 42 % → 23 % → 7 %, but only on the adjacent pixel (codes 166 → 118; the second
pixel stays at 126). The gate is `smoothstep(0.15, 0.60, usm)` at the same pixel, while
the visible rim sits 1–3 px further out. This is the pinned defect in
`FieldBaselineProbeTests.testHaloSuppressionCurrentlyMissesTheRimItExistsToDamp`, now
measured end-to-end. 1840 treeline: `evidence/before_1840_treeline_a0_a150_halo100.png`.
The dark-side trench is never damped, by design (finding F5).

### S2. Wrong response or behaviour that differs from Lightroom

**F5. Overshoot scales with scene log-contrast up to the ±2 EV clamp, not with display
contrast.** For a 1 px +4.5 EV line on 0.18 grey (pristine hard_edge), the neighbouring
pixel goes 118 → 103 / 91 / 78 / 64 codes at amount 40/70/100/150 (40 % of the line
contrast at 150). A −5 EV line's flank goes 118 → 139 / 153 / 166 / 187. Highlights
above display white (speculars, sky through foliage) therefore cut black trenches.
6929's sky gaps at 2400 px: `evidence/before_6929_foliage_a0_a150_r3_d100.png`. Grey
band: `evidence/before_hardedge_lines.png` (columns: a0, a40, a150, a100+halo100,
a70 r3). A display-referred (gamma) sharpener bounds this by the displayed step.

**F6. Detail is a broadband gain and halo widener, not Lightroom's Detail, and it turns
Radius off.** `v = amount·mix(usm, fine, detail)`, and `fine` is a fixed à-trous band
(d0 + ½d1, about 1–3 px) that does not depend on Radius. At Detail 100 Radius is dead:
radius 0.5 and radius 3 give identical numbers (MTF50 gain 1.287, halo 4.74/5.21 %, noise
1.639). Going from Detail 0 to 100 raises noise gain 1.109 → 1.639, the 2 EV halo
0/0.1 → 4.7/5.2 %, and the 4 px-line ringing 0.7 → 11.8 %, while the ratio of gain at
high to low frequency hardly moves (f.3/f.1 1.43 → 1.47). Below 2560 px the "fine"
band is coarser than the USM's σ (0.6–0.9 px), so raising Detail makes halos wider:
4 px dark line flanks go 153,119,118 at det 0 and 181,149,132,124 at det 100. Lightroom's
Detail runs from halo-suppressed at 0 to deconvolution-like, finest-texture emphasis at
100, always at the chosen Radius.

**F7. Radius 2 → 3 adds halos and noise, not sharpness.** Zone MTF50 gain is
1.237 → 1.234 (flat), the 2 EV halo goes 2.8/4.1 → 5.9/6.3 %, noise 1.558 → 1.628.
Radius 0.5 at small render sizes is σ ≤ 0.3 px and close to inert (dE 0.38 vs r1 on the
zone plate). Monotonic otherwise. Amount is monotonic and smooth 0 → 150 on every metric.

**F8. CPU and GPU disagreements visible in the code** (CPU: `DetailEngine.applySharpen`
+ `ReferenceRenderer.swift:79-126`; GPU: `RenderGraph.applySharpen:1420`, `Kernels.swift:194-320`):
1. **What the gate and fine band are computed from.** The CPU builds `d.gradient` and
   `d.details` once at S8 from the S7 output, before Texture/Clarity/Dehaze, S9 colour,
   S10 grade and S11 local masks. The GPU computes `localStructure` and `fineDetailBand`
   from the S12 input. Any Clarity, Texture, grade or local edit therefore moves the GPU
   mask and band but not the CPU's. Units agree: both are EV/px (GPU: Sobel/8 × `range`).
2. **The log domain in deep shadows.** The CPU uses `safeLog2`, floored at −20 EV with no
   toe, so zero or negative noise pixels read as −20 EV and every delta near them hits
   the ±2 EV clamp. The GPU uses `LumenLog.encode` on luminance floored at 0, which is
   linear below 1.24e-4 (−10.5 EV) and compresses those contrasts. Shadow noise
   amplification and the masking gate differ between preview and export there.
3. **Gradient operator.** The GPU uses a Sobel, which includes a [1,2,1] cross-smoothing;
   the CPU uses a central difference. The structure radius is `Int(longEdge·0.02)/4`,
   floored at 1, on the CPU and `rounded()/4`, floored at 2, on the GPU, so they differ
   by one at boundaries (e.g. 2375 px gives 11 vs 12) and on small previews.
4. **Precision.** The GPU runs at RGBAh working format. The LumenLog plane in [0,1]
   quantises to about 2^-11 × 24 ≈ 0.012 EV, which is the order of the usm values on
   fine texture.
5. **Fallback.** If a kernel is missing, the GPU falls back to `CIUnsharpMask`. That is
   per-channel RGB (colour fringes), uses a pixel radius (`unsharpRadius`, not
   frame-denominated) and has a different amount curve.

### S3. Gaps and UI

**F9. Capture sharpening (WS-17) at the start of this audit.**
- `DetailEngine.captureSharpen` (`DetailEngine.swift:503`) had no caller.
- On Apple RAW the only S4 is `CIRAWFilter.sharpnessAmount = default × strengthFraction`
  (`AppleRawSource.swift:353`).
- `detail.capture.radius` was read by nothing live (the panel says so,
  `DetailPanel.swift:18`).
- The LibRaw corpus has no capture sharpening (CORPUS.md), so all corpus renders are
  softer than Apple's.

The coordinator has since landed an S4 stage behind `--iso`, which this audit did not
measure.

**F10. UI compared with Lightroom.** There are no Alt/Option previews: no white-on-black
Masking edge mask, no greyscale luminance-only Amount preview, and no high-pass
Radius/Detail previews (nothing in `DetailPanel.swift`). Without a mask view, finding
F3 is invisible to the user. The Detail slider is declared `bipolar: true` although it is
0–100 with a default of 25. The "Halo Damping" tooltip itself admits finding F4. The
default amount is 0 (Lightroom raw: 40). That is fine only while S4 supplies the baseline.

**F11. No colour fringing from sharpening.** The luma-ratio recombination works:
983's colour checker and 2348's stripes show none. The purple edges on 2348 are lens CA
and are present at amount 0.

## Lightroom reference (Detail panel, from product knowledge)

| control | Lightroom / ACR | Lumen |
|---|---|---|
| Amount | 0–150, raw default 40, JPEG 0. Option-drag shows a luminance-only greyscale preview | 0–150, default 0. No preview. Brightens the frame (F2) |
| Radius | 0.5–3.0, default 1.0, in **source pixels**. Option-drag shows the high-pass | 0.5–3.0, in **frame fractions** (×longEdge/2560): σ 2.74 px at 7008 px (F1). Dead at Detail 100 (F6) |
| Detail | 0–100, default 25. 0 = strong halo suppression, 100 = deconvolution-like texture emphasis at the same radius. Option-drag preview | Cross-fade to a fixed-scale band; broadband gain and halo widener (F6) |
| Masking | 0–100, default 0. Option-drag shows a white-on-black edge mask; flat areas drop out by ~50, only strong edges remain at 100 | Mask strength scaled by the slider, so 50 keeps half on flats; fails in noisy shadows; attenuates real 2 EV edges at 100 (F3) |
| (none) | — | Halo Damping 0–100 (C1-like). Misses the rim (F4) |
| Capture | Process-version capture sharpening in the raw pipeline | Apple's at-demosaic sharpener × strength only (F9) |

Lightroom sharpens in a perceptual (gamma) luminance space, so overshoot is bounded by
the displayed step and has no exposure-dependent bias. Lumen's log-domain/ratio design
gives exposure invariance but causes F2, F3b and F5.
