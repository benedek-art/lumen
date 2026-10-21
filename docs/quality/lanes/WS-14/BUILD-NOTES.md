# WS-14 Texture & Clarity: build notes

Builder's record for `SPEC.md`. CPU reference: `DetailEngine.applyTexture` / `applyClarity`
(Sources/LumenCore/Image/DetailEngine.swift). GPU twin: `RenderGraph.applyDetailBands`
and helpers (Sources/LumenPipeline/RenderGraph.swift) with the kernels `lumenPresenceEV`,
`lumenPresenceTensor`, `lumenTextureDelta`, `lumenClarityDelta`, `lumenPresenceMeanWeights`,
`lumenPresenceGain` (Sources/LumenPipeline/Kernels.swift).

## 1. Algorithm

One construction at two scales. L is the render's long edge; every σ below is an exact
fraction of L (nothing is rounded except the two min/max window radii, see below).

```
v      = presence log luminance in EV around mid-grey
         = (LumenLog.encode(max(Y, 0)) − LumenLog.encode(0.18)) · 24     (log2(Y/0.18) above the
           shaper's toe at 0.18·2^−10.5, linear below; no −20 EV floor, no image range)
v'     = v                                                      (Texture)
       = ½·(close(open(v)) + open(close(v)))                   (Clarity; square, radius round(0.4·σ1))
fine   = G(σ1)·v'        base = G(σ2)·v'        b = fine − base
c      = √((Jxx−Jyy)² + 4Jxy²) / (Jxx + Jyy + η)              structure tensor of `fine`:
         J = G(σi) · (∇fine · max(σ1, 0.5))²                   central differences, EV per σ1
s      = √(Jxx + Jyy)                                           (Clarity's strength, EV)
gate   = 1 − smoothstep(0.35, 0.75, c)                          (× 1 − smoothstep(0.2, 0.6, s), Clarity)
w      = gate / (1 + (b/τ)²)                                    (× exp(−base²/(2·8²)), Clarity)

Texture:  Δ = k·a·b·w,                        k = 2.0 (a > 0), 1.7 (a < 0)
Clarity:  Δ = 1.95·a'·b·w,  a' = a(1 + 0.4a)  (a > 0), then the overshoot limit:
             o = fine + Δ; outside [min, max] of `fine` over a square of radius round(σ2)
             only 12 % of the excess survives; Δ = o − fine
          Δ = −min(1, |a|·0.95·w)·b           (a < 0: up to the whole band, never more; −100 stays
                                               below saturation so mask Strength 200 still responds)
Both:     Δ −= log2( G_m(2^(0.4(v+Δ))) / G_m(2^(0.4 v)) ) / 0.4    G_m = G(4·σ2): local brightness hold
          out = RGB · 2^clamp(Δ, ±4)          (luma ratio; hue and chroma ratios fixed)
a = clamp(slider, ±100)·clamp(mask strength, 0, 2)/100; a = 0 returns the input (byte-exact).
```

| | Texture | Clarity |
|---|---|---|
| band centre | 750 cpi (8 px@6000) | 60 cpi (100 px@6000) |
| σ1 | 0.153·L/750 = 2.04e-4·L (1.22 px@6000, 0.33 px@1600) | 0.0968·L/60 = 1.61e-3·L (9.7 px@6000, 2.6 px@1600) |
| σ2 | 2·σ1 (2.45 px@6000) | 4·σ1 (38.7 px@6000) |
| tensor integration σi | 3·σ2 | 2·σ2 |
| η (EV²) | 1.2e-3 | 8e-4 |
| τ (EV) | 0.35 | 0.5 |
| DoG peak response | 0.47 | 0.78 |

**Gaussian blur, continuous in σ** (`presenceBlur`, both paths): σ ≤ √2: one separable
9-tap discrete Gaussian of variance σ² (Lindeberg's `e^−t·I_n(t)`, normalised). σ > √2: the
variance-1 9 taps, then a Gaussian of σ' = √(σ²−1). The discrete kernel has the requested
variance at sub-pixel σ and its DoG response never exceeds the continuous peak, so at a 1024
or 512 px preview −Texture cannot reverse the finest frequency (the old D14 sign flip).

**Why each piece exists** (all measured, see §3):
- DoG band at a fixed cpi: puts Texture at 2–8 px@24 MP and Clarity at 37–300 px@24 MP, two
  octaves apart, and makes preview = export (R1–R4).
- Coherence gate: a straight step of ≥ 0.5 EV (λ ≈ 4e-3) closes it; isotropic texture, pores,
  1/f noise and faint gratings (0.05 EV: λ ≈ 3–4e-4) leave it open. In EV per σ1, so the same
  edge is "an edge" at 1600 and 6000 px (the old EV/px gate failed this: D7, D9).
- Range compression 1/(1+(b/τ)²): multi-stop coefficients get almost no gain; `b + k·w·b`
  stays monotone in b for k < 8 (no inversion, no posterisation).
- Clarity prefilter: thin bright/dark lines next to grey were read as mid-scale dips and their
  neighbours darkened/brightened by 40 codes (hard_edge); opening/closing removes features
  narrower than ~0.8·σ1 from what Clarity measures. Pixel detail is never touched.
- Clarity strength gate: junctions of multi-stop edges (two orientations → low coherence).
- Overshoot limit (Clarity +): the ring around soft blobs (D2/H7) without flattening tops.
- Positive slider curve a(1+0.4a): the limiter and the brightness hold bite harder at +100,
  so a linear law delivered +50 at 0.69 of +100's effect (M3 wants ≤ 0.65).
- Brightness hold on the local mean of Y^0.4: a log-domain gain raises the mean through the
  display curve (D11: +1.5–1.9 codes on foliage at Texture +100). Holding the LINEAR mean
  over-corrects (−1.0 / +0.6 codes); Y^0.4 is close to what the display encodes.

## 2. CPU → GPU step map (spec G1)

| # | CPU reference (`DetailEngine`) | GPU (`RenderGraph` / `Kernels.swift`) | difference |
|---|---|---|---|
| 1 | `Decomposition.presenceLogLuminance()` → `presenceEV(Y)` on `source.luminancePlane(.rec2020)` | `logLuminance(image)` (= `LumenLog.encode(max(Y,0))`) → `lumenPresenceEV(lum, encode(0.18), 24)` | none (same formula); GPU intermediates are half float, centred on 0 so midtones keep ≈2e-4 EV |
| 2 | `clarityPrefilter`: `localExtremum` erode/dilate, radius `overshootRadius(0.4·σ1)` | `clarityPrefilter`: `CIMorphologyRectangleMinimum/Maximum`, width `2r+1`, same r, averaged with `lumenBlendMask(…, 0.5)` | Core Image morphology vs van Herk min/max, same window |
| 3 | `presenceBlur(σ)`: `convolve9(presenceKernel(σ²))`, or `convolve9(presenceKernel(1))` + `SpatialOps.gaussianBlur(√(σ²−1))` | `presenceBlur(σ)`: `CIConvolution9Horizontal/Vertical` with the same `presenceKernel` taps, or those + `gaussianBlur` (`CIGaussianBlur`, radius = σ) | above σ' = 8 the reference uses three boxes, `CIGaussianBlur` a Gaussian |
| 4 | `fine`, `base` (= `coarse`) | same calls, same σ from `DetailEngine.textureBand/clarityBand.sigmas(longEdge:)` | none |
| 5 | `presenceStructure`: central differences ×max(σ1,0.5), products, `presenceBlur(σi)`, coherence/strength with η | `presenceStructure`: `CIConvolution3X3` ±0.5 taps, `lumenPresenceTensor(gx, gy, norm, 64)`, `presenceBlur(σi)`; coherence/strength formed in the delta kernels | products stored ×64 (half-float subnormals), divided back; CI's vertical gradient sign is flipped (only Jxy's sign, which enters squared) |
| 6 | `textureDelta` | `lumenTextureDelta` | none |
| 7 | `clarityDelta` incl. `clarityShapedAmount` | `lumenClarityDelta`, `a` passed already shaped | none |
| 8 | `localExtremum(fine, round(σ2))` + `overshootLimited` (Clarity a > 0) | `localRange` (CI morphology) + the `limit` lines of `lumenClarityDelta` | as row 2 |
| 9 | `holdLocalBrightness` (window 4·σ2) | `lumenPresenceMeanWeights` → `presenceBlur(4·σ2)` → `lumenPresenceGain` | as row 3 |
| 10 | `applyLumaRatio(limit: 4)` | clamp ±4 + `exp2` in `lumenPresenceGain`, then `lumenMultiply` | none |
| 11 | order Texture → Clarity, both from the pre-Texture `v` | same (one `ev` image before both) | none |

No path uses an image-global statistic. The only rounded quantities are the two min/max
window radii (`overshootRadius`), identical on both paths.

## 3. Spec table (measured, real renderer, CPU reference; render set in scratch `build/r8`)

46 of the 51 measurable lines pass (spec_eval over the full render_all.sh set, real renderer, CPU reference). Failing: M7, P1, P2, B3, R5; see §5.
Visual sheets: evidence/V1_skin, V2_lantern, V3_preview (_before = base commit, _after = this build, r8).

| ID | result | measured (r8) |
|---|---|---|
| S1 | PASS | peak_cpi t+100 867, t-100 867 |
| S2 | PASS | coarse_ratio max 0.015 |
| S3 | PASS | fine_ratio max 0.078 |
| S4 | PASS | g750 +100 1.872, -100 0.249 |
| S5 | PASS | peak_cpi c+100 55, c-100 55 |
| S6 | PASS | fine1500 max 0.023 |
| S7 | PASS | g60 +100 1.789, -100 0.335 |
| S8 | PASS | centroid ratio 11.92 (633/53) |
| M1 | PASS | monotone {'t': 'True', 'c': 'True'} {'t': 'True', 'c': 'True'} |
| M2 | PASS | t+25 0.218 t-25 0.187 c+25 0.297 c-25 0.165 |
| M3 | PASS | t+ 0.50/0.25 t- 0.50/0.25 c+ 0.64/0.38 c- 0.50/0.25 |
| M4 | PASS | ok (neg gmin 0.238, pos gmin 0.966) |
| M5 | PASS | yes yes |
| M6 | PASS | max 1 codes |
| M7 | FAIL | min /gT-1/ 0.015 (983), min /gC-1/ 0.008 (2348) |
| M8 | PASS | all monotone |
| P1 | FAIL | t+100 min 1.063 (983) med 1.345; t-100 max 0.940 (983) med 0.694 |
| P2 | FAIL | c+100 min 1.058 (2348) med 1.210; c-100 max 0.969 (2348) med 0.885 |
| P3 | PASS | texture /gC-1///gT-1/ max 0.017; clarity /gT-1///gC-1/ max 0.453 |
| B1 | PASS | worst /dLuma/ -0.14 (k6000 t100), worst zoneP 1.00 (k6000 t-100) |
| B2 | PASS | worst /dLuma/ 0.33 (3437 c100) |
| B3 | FAIL | worst zoneB 2.42 (1569 c100) |
| B4 | PASS | worst /dLuma/ 0.67 ('6929', 'c100'), zoneB 0.60 ('6929', 'c100') |
| C1 | PASS | texture /chroma/ max 0.69%, clarity chroma [-0.54, 0.27]% |
| C2 | PASS | whole-frame /hue/ max 0.22 deg, worst sector 1.46 deg |
| C3 | PASS | /hue/ max 0.11, /chroma/ max 0.27% |
| H1 | PASS | texture worst over/under 0.0% |
| H2 | PASS | texture width max 0.00% L (6000:t100 0.00, 6000:t-100 0.00, 1600:t100 0.00, 1600:t-100 0.00) |
| H3 | PASS | t-100 rise growth 0 / 0 px |
| H4 | PASS | clarity worst over/under 3.3% |
| H5 | PASS | clarity rise growth max 0 px, width max 0.00% L |
| H6 | PASS | max 20 codes, >8 codes 0.003% |
| H7 | PASS | worst ring 2.4% |
| Q1 | PASS | slope ratio ±100 max 2.18, +50 max 1.49 |
| Q2 | PASS | c100:1.12/1.23/r1.09/j0.13 c-100:0.83/0.87/r1.04/j0.05 c50:1.05/1.13/r1.07/j0.08 c-50:0.90/0.93/r1.03/j0.03 t100:1.33/1.42/r1.07/j0.14 t-100:0.61/0.64/r1.05/j0.05 t50:1.14/1.21/r1.05/j0.07 t-50:0.79/0.82/r1.04/j0.03 |
| Q3 | PASS | vs_maxdiff c+100 0.0, c-100 0.0 |
| Q4 | PASS | new gaps [0, 0, 0, 0, 0] |
| N1 | PASS | t+100 x1.11 |
| N2 | PASS | c+100 x1.00 |
| K1 | PASS | pores t-100 x0.44, t-50 x0.70 |
| K2 | PASS | mottle t-100 x0.96 |
| K3 | PASS | t-100 x1.00/+0.0 t-50 x1.00/+0.0 c-100 x1.00/+0.0 |
| K4 | PASS | t-100 rise 3->3 o0.3 u0.2 c-100 rise 3->3 o0.1 u0.0 |
| K5 | PASS | c-100 mottle x0.64 pores x1.00 |
| K6 | PASS | c+100 pores x1.00 mottle x1.47 |
| K7 | PASS | t+100 pores x1.73 mottle x1.06 lip 0.4/1.1%; c+100 lip 0.2/0.6% |
| R1 | PASS | 1600c100 0.98/0.98 1600c-100 0.99/0.98 1600c25 1.01/0.95 1600c-25 1.08/0.89 3200c100 1.00/0.98 3200c-100 1.00/0.98 3200c25 1.02/0.95 3200c-25 1.06/0.87 |
| R2 | PASS | 6929c100 1.01/0.99 6929c-100 1.02/0.99 2545c100 1.01/0.96 2545c-100 1.04/0.97 983c100 0.99/1.00 983c-100 1.00/0.99 |
| R3 | PASS | t100 0.99/0.96 t-100 0.99/0.96 t25 1.04/0.87 t-25 1.05/0.84 |
| R4 | PASS | t100 0.90/0.96 t-100 0.90/0.96 |
| R5 | FAIL | 6929t100 1.05/0.92 6929t-100 1.04/0.93 2545t100 1.18/0.84 2545t-100 1.18/0.87 983t100 1.18/0.64 983t-100 1.25/0.61 |
| G1 | (verifier reads) | step map in §2; one algorithm, primitive-level differences listed |
| G2 | pending macOS CI | assertions added/tightened: TEXSPEC [0.85,1.15], new CLARSPEC [0.85,1.15], SPATIALPARITY per-stage ratios [0.80,1.25] |
| G3 | PASS | LumenCoreTests incl. LocalStageReferenceContractTests and GlobalPresenceClampReferenceTests (§4) |
| G4 | PASS | 6929 @1600, dehaze ±50: max difference base vs head 0 codes |
| G5 | PASS | changed tests listed in §4 with reasons |

## 4. Tests

Added `Tests/LumenCoreTests/PresenceBandTests.swift`, U1–U10 of spec §12, each driving
`Decomposition` + `DetailEngine.apply` like `ReferenceRenderer`.

Changed (spec G5; the reason is in each test's doc comment too):

| test | change | why |
|---|---|---|
| `ScaleHonestyTests.testTheClarityPyramidTracksTheLongEdge` | replaced by `testThePresenceBandsTrackTheLongEdgeContinuously` | it pinned the rounded local-Laplacian pyramid depth (the reach jump at 3620 px that D5 names); the new test pins σ ∝ L exactly, continuity across the old rung, and the band centres |
| `ScaleHonestyTests.testTheSharpenRadiusTracks…` | first assertion `spatialReferenceLongEdge == DetailEngine.pyramidReferenceLongEdge` → `== 2560` | presence no longer has a reference frame (bands are in cpi); sharpening's own reference is still pinned |
| `RobustnessTests.testPositiveTextureDoesNotRimAHardEdge` | frame 128 → 2048 px, ripple period 12.6 → 3 px | Texture is a band of the picture (375–1500 cpi); at 128 px it is above Nyquist and does nothing, so the "it still moves the flats" half could not hold. Bars unchanged |
| `RobustnessTests.testPositiveTextureKeepsItsAuthorityOnFineDetail` | frame 2048 px; lines are a 0.05 EV log-sinusoid (spec U2's probe) instead of ±15 %; coherence read from `presenceStructure` against `textureBand.gateLow` | same frame reason; the gate is new. A perfectly regular ±15 % grating now reads as parallel edges (see §5) |
| `EngineIntegrationTests.testTextureChangesLocalContrastWithoutMovingTheMean` | 48×16 → 1536×32, period 5 → 3.2 px | same frame reason; the 5 % mean bound is unchanged |
| `KernelGoldenTests.testTextureGainClampsAtFourEVLikeTheReference` (macOS) | drives `lumenPresenceGain` (±12 EV delta → 16 / 1/16) | the clamp moved from the old `detailGain`/`detailGainGated` kernels (removed) to the gain kernel |
| `KernelGoldenTests.testGraphMatchesTheReferenceRendererWithTheSpatialStagesOn` (macOS) | per-stage Texture/Clarity frames sized to the bands (1536 / 1024 px, rendered at their own long edge); ratios additionally asserted in [0.80, 1.25] (spec G2c) | at 64 px both bands are above Nyquist |
| `TextureSpectrumProbeTests` (macOS) | 2048 px frame, Texture ±100 gpu/ref asserted in [0.85, 1.15] at every period; new `testClarityFrequencyResponseOnBothPaths` (8–128 px) | spec G2a/b |
| `GlobalPresenceClampTests` (macOS) | frame 128² → 1024×64 with a 3 px ripple | liveness of Texture at 128 px |
| `LocalStageReferenceContractTests.testTextureAndClarityKeepRespondingAboveOneHundredStrength` | frame 96² → 1024×48 with 2-D ripples (2.5 px and 20 px, x·y products) | at 96 px Texture's band is above Nyquist, so Strength 100 vs 200 differed by float noise (3e-6); 1-D ripples would be gated as parallel edges. Assertion unchanged |
| `RobustnessTests.testEveryLocalSliderThePanelOffersChangesThePicture` | the texture and clarity rows run on a 1024×48 frame with 2-D in-band ripples, like the softening row already does | same reason as the row above; bar (1e-4) unchanged |
| Proof: `ProofRegistry` detail.texture / detail.clarity, `ProofFrames.presenceTexture`, records `detail.texture.json` / `detail.clarity.json` | both controls moved from the 256 px `fineTexture` (regular ±20 % strips) to a new 2048×64 isotropic 1/f frame; floors unchanged (27 / 13); the two records re-recorded (authority 27.6 / 24.3) | on `fineTexture` Texture's band is above Nyquist and the strips are gated as edges, so the smoke sentinel `detail.clarity` measured 4.4 against its floor of 13. Same move `wideFineTexture` made for sharpening. `ControlProofTests` (nightly) other records untouched |

Nothing was skipped or disabled.

**Gate:** `swift test --scratch-path .build612 --parallel --filter LumenCoreTests --skip ControlProofTests`
(Swift 6.1.2, Linux): 3054 tests, 0 failures (3044 on the base commit plus the 10 new U-tests).
`swift build -c release --product lumen-render` clean. `scripts/check-swift-surface.py`: no
finding that the base commit does not also have. The spec numbers in §3 come from the spec's own
tools (`render_all.sh`, `identity.sh`, then every `tools/*.py` the spec names), collected by a
scratch wrapper that applies the SPEC.md thresholds.

## 5. Known limits / not met

- **P2 / M7 (Clarity authority on photos).** c+100 median 1.21 (needs 1.25), minimum 1.058 on
  2348 (needs 1.15); c−100 median 0.885 (needs 0.80), max 0.969 on 2348 (needs 0.88). Per photo
  c+100 / c−100: 6929 1.37/0.78, 6933 1.36/0.77, 2545 1.26/0.85, 3437 1.29/0.82, 4694 1.16/0.93,
  1569 1.13/0.94, 983 1.08/0.96, 2348 1.06/0.97. Baseline was 1.00–1.02 / 0.98–1.00, i.e. the
  control now works on photos, but not to the spec's level. Measured cause: on the weakest
  frames roughly half the 20–160 cpi energy sits in coherent edges and multi-stop structure,
  which the edge gate, the strength gate and the range compression deliberately leave alone.
  Opening any of them to reach P2 brought back what H4–H7, H6 and K5–K7 forbid (rims on
  0.5–1 EV steps, 40–70 code junction halos on hard_edge, rings round blobs); I explored a
  guided-filter base and a looser gate (2348 c+100 up to 1.16) and both cost 4–8 synthetic
  lines. Negative Clarity is also held at k = 0.95 so that a mask at Strength 200 still does more
  than one at 100 (G3, `LocalStageReferenceContractTests`); a saturating k = 2 law reached a
  c−100 median of 0.80 on the photos but made Strength 200 identical to 100 on even texture.
  M7 fails on the same frames at ±25 (|gC−1| 0.008 on 2348) and for Texture on 983.
- **P1 (Texture on 983).** 983 (lantern still life) has almost no fine texture: its 375–760 cpi
  energy at 1600 px is the anti-aliased edges of the lantern, which the coherence gate protects
  (H3 requires edges not to blur). t+100 1.063 / t−100 0.940 on 983; the other seven photos are
  1.32–1.41 / 0.63–0.71, so the t+100 median is 1.345 (needs 1.40); t−100 median 0.694 (needs 0.60).
- **B3 (block brightness).** 1569 at Clarity +100: one L/10 block moves −2.4 codes (limit 1.0); the
  whole-frame mean moves −0.01. Strong local contrast in a block of dark foliage and bright sky;
  the Y^0.4 hold is a fixed approximation of the display curve and does not cancel the
  block-level Jensen shift exactly. Baseline passed only because baseline Clarity did nothing.
- **R5 (983 preview vs export, Texture).** Ratio 1.18–1.25 (OK), correlation 0.64 / 0.61 on 983
  only (needs 0.70; 6929 and 2545 pass at 0.84–0.93). The effect on 983 is tiny (see P1) so the
  8-bit effect map is dominated by quantisation. Baseline 0.53 / 0.45.
- **Strong regular gratings.** A perfectly regular high-contrast grating (≥ ~0.1 EV, e.g. the old
  ±15 % test lines) is, to a structure tensor, a run of parallel edges, so Texture leaves it
  alone (audit D13 remains for such patterns). Faint gratings (0.05 EV, spec U2) and real
  textures pass (U2 8 px gain ≥ 1.5).
- **G2 is pending macOS CI.** Nothing in `LumenPipeline` can be compiled on Linux. The GPU code
  was parse-checked (`swiftc -parse`) and passes `scripts/check-swift-surface.py` (no new
  findings vs the base commit; kernels pass the reserved-word pass), and every Core Image call
  mirrors an idiom already in RenderGraph (`CIConvolution3X3`, `CIMorphologyRectangle*`,
  `CIGaussianBlur` via `gaussianBlur`) except `CIFilter.convolution9Horizontal/Vertical`, new to
  this file (CIFilterBuiltins, macOS 10.15+, `weights: CIVector`, `bias: Float`).
- **Debug test time.** U3 (three sizes × two controls × six values plus sign checks on
  6000 px strips) and U8 (4096 px) take tens of seconds in a debug build, not "a second or two";
  the long edges are what the spec prescribes. Decompositions are reused across slider values.
