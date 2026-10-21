# WS-19 / WS-20 / WS-21 report (lane T4: classic NR, hot pixels, NR mode and ISO defaults)

## For the owner

- Colour noise now actually goes at default: on your high-ISO test frames flat-area colour noise drops 72 to 88 % (the old default managed 46 to 75 % and left the G9 jacket purple and green).
- The watercolour look came from the engine assuming white noise; real demosaiced noise sits at 2 to 8 px, so Luminance removed fine grain and left the mottle. Fixed, and at the same noise cut it now keeps more texture than before.
- Hot Pixels removes about 93 % of stuck pixels at 50 (the old pass left half of every one) and leaves stars and speculars alone.
- Not done: noise is still judged from ISO alone, so a full-frame body gets about 1.5× more smoothing than it needs (A7C) and a small sensor slightly less. Fixing that needs the camera model passed to the renderer (NEEDS.md #1).
- Look at: `evidence/2348-jacket.png`, `evidence/hot-pixels.png`, `evidence/sim-a7iv-luma.png`.

## Verdict

All spec lines PASS on Linux (measured below). Verifier round 1 FAILED the lane on eight existing tests and the missing report; both fixed in round 2 (see "Verification"). GPU parity runs on macOS CI only; status in "CI".

## What was wrong (audit)

Measured on native-resolution LibRaw decodes of the five high-ISO frames (2348 G9 ISO 3200, 2062 Kiss X9 6400, 1192 X-T10 4000, 2242 GX850 2000, 4144 A7C 2000) plus three more bodies, and on ground-truth sims: a clean low-ISO RAW (A7 IV, R5, GX85) decoded twice through the same LibRaw path, once with Poisson-Gaussian noise injected on the mosaic.

1. The noise model read real sensors 1.75× too quiet in σ (seed vs measured, 8 bodies: 1.13 to 2.00). Every threshold is a multiple of that σ.
2. The thresholds assumed white noise. Demosaicing moves noise from the finest band into 2 to 8 px; chroma noise in bands 1 to 3 was 3.6 to 5.8× what the thresholds assumed, consistent across six Bayer bodies. Colour could not reach the blotches at any setting; Luminance stripped grain and left mottle.
3. Colour NR moved luminance: the equal-weight Y0U0V0 basis is not luminance-free, so Colour 25 alone cost 4 % of fine texture.
4. The luma edge map fired on noise over half the frame; the chroma edge map (built on chroma magnitude) almost never fired, so Colour Detail moved edge error by 0.02 ΔE: a dead control.
5. The guided blotch pass bled colour across equal-luminance edges and, once bands are calibrated, removed nothing (2.22 vs 2.22 ΔE).
6. Hot pixels: after demosaic a defect is a single-channel 3×3 blob (red/blue site) or a 1 to 3 px white streak (green site). The old pass replaced only the centre with its 8-neighbour median, so half of every blob survived, stars lost 18 to 33 % of their peak, and at 100 it changed 9.8 % of plain noise pixels.

## What changed

All in `Sources/LumenCore/Image/DenoiseEngine.swift` (CPU definition) with the GPU twin in `RenderGraph.applyDenoise/applyHotPixels/edgePlane` and `Kernels.swift`, changed together.

- `NoiseProfile.corpusVarianceScale = 3`: the ISO curve scaled to the corpus median.
- Thresholds = slider scale × per-band weight × measured band noise (`lumaBandNoise`, `chromaUBandNoise`, `chromaVBandNoise`). Luma weights fall with scale (picked against ground truth: best texture at every matched noise level); chroma weights zero the finest band and fall to 0.5σ. U and V get separate thresholds (new `GPUPlan.chromaVThresholds`).
- Oblique basis: luma along the neutral axis measured with Rec.2020 luminance weights, chroma in the zero-luminance plane. Colour NR no longer touches luminance; luma noise adds no colour.
- Chroma edge map from the joint gradient of both chroma planes (new kernel `lumenChromaEdgeMap`), full protection at Colour Detail ≥ 50. Luma edge knees 3/12 → 0.75/3 σ so the map protects texture.
- Sliders: Luminance linear to 3σ; Detail in octaves (×2 to ×0.5); Contrast reaches the mid bands (√coarse); Colour = (c/25)^0.75; Colour Detail tilts the fine chroma bands and sets edge protection; Smoothness tilts toward the coarse bands. Blotch pass mix 0.
- Hot pixels: background from the distance-2 ring, flag only single-channel or too-sharp extrema, fill the whole 3×3 smear; gate 8 to 24σ (was 2 to 12σ). Two kernels (`lumenHotPixel` detect, `lumenHotPixelFill`); receptive field 79 → 81 px.
- ISO defaults: Colour 25 at every ISO (Lightroom's; a climbing default double-counted gain once thresholds are in band noise); sub-sliders 50/0/50/50 at every ISO; Luminance 0 at ≤ 400, 11 at 1600, 16 at 6400, 25 at ≥ 25600.
- Tooltips for Colour Detail, Smoothness and Hot Pixels rewritten to match (`DetailPanel.noiseControls`).

## Spec lines (final numbers, `tools/measure.py all`, Swift engine via nrtool)

| # | Measured | |
|---|---|---|
| 19.1 | model/measured σ: 1.01, 0.91, 0.87, 0.98, 1.53 (A7C), 0.87, 1.28, 0.95: 7 of 8 in [0.7, 1.4] | PASS |
| 19.2 | real flat chroma ΔE*ab, input → new (shipped): 2348 9.02 → 2.12 (4.57); 2062 8.95 → 1.98 (4.60); 1192 6.67 → 1.24 (1.68); 2242 4.85 → 1.37 (2.60); 4144 2.74 → 0.34 (0.79). Sims −75 / −74 / −81 % | PASS |
| 19.3 | equal-luminance step width 2.05 → 1.97 px, 2 px line keeps 93 % (unit test); sim colour-edge error a7iv 6.09 → 4.27, r5 8.50 → 3.02, r5bg 9.57 → 2.06 | PASS |
| 19.4 | Colour 25 alone: texRet 0.976 → 0.975 (a7iv), 0.935 → 0.940 (r5); flat L +0.8 %, +2.3 % | PASS |
| 19.5 | at −35 % flat L noise: texRet 0.926 vs shipped 0.902, mid 0.982 vs 0.950 (a7iv); 0.755 vs 0.733, 0.944 vs 0.912 (r5). Max cut 64 % / 77 % vs shipped 51 % / 54 % | PASS |
| 19.6 | texRet 0.975 → 0.794 in steps of 0.015 to 0.02; r5bg flat L falls 3.36 → 1.01 over 0 to 60 | PASS |
| 19.7 | Detail 0/50/100 texRet 0.795 / 0.877 / 0.925 | PASS |
| 19.8 | Contrast 0/50/100 midRet 0.874 / 0.900 / 0.928 | PASS |
| 19.9 | Colour Detail 0/50/100: grass edge error 8.08 / 7.23 / 6.66; speckle 1.47 / 1.50 / 1.65 | PASS |
| 19.10 | Smoothness 0/50/100: 2.00 / 1.81 / 1.74 | PASS |
| 19.11 | all sliders 0 → bit-identical | PASS |
| 19.12 | thresholds and knees in `GPUPlan` equal the reference's; basis is an exact inverse (unit tests) | PASS (GPU: CI) |
| 19.13 | Luminance 100 + Colour 100: dark-tone ΔL* +0.74 | PASS |
| 20.1 | Hot Pixels 50: 92.9 % of 155 hot pixels at ≤ 30 % of peak (median 2 %) | PASS |
| 20.2 | stars σ ≥ 0.7 px keeping ≥ 90 % of peak: 97.5 % at 25, 50, 100 | PASS |
| 20.3 | speculars: 100 % | PASS |
| 20.4 | noise pixels changed: 0.05 % at 50, 0.52 % at 100 | PASS |
| 20.5 | 0 is identity, count non-decreasing (unit test) | PASS |
| 21.1 | Colour 25 at every ISO (unit test) | PASS |
| 21.2 | default flat L cut: 2348 −21 %, 2062 −25 %, 1192 −41 %, 2242 −11 %, 4144 −32 % | PASS |
| 21.3 | sub-sliders 50/0/50/50 at every ISO (unit test) | PASS |
| 21.4 | every frame meets 19.2 at its ISO default | PASS |
| 21.5 | mode semantics unchanged (existing tests) | PASS |

The spec's 21.2 originally named anchor values (0 at 800, 10 at 3200); measurement showed the GX850 at ISO 2000 got only 6 % from them, so the anchors moved. The measurable bound (10 to 45 %) did not.

## Lightroom comparison

No Lightroom exports were available, so this is from knowledge of Lightroom's behaviour, not measured. Lightroom's Colour 25 default removes colour noise on most raws up to ISO 6400 with a slight softening of fine colour; Lumen's default now does the same job (72 to 88 % removed) with colour edges no wider than the noise-free twin. Lightroom's Luminance defaults to 0 at every ISO; Lumen keeps a gentle ISO-adaptive default (11 to 41 % of flat noise), which is a deliberate departure. The Detail and Contrast sliders now have the Lightroom-style trade (Detail keeps texture and noise, Contrast keeps mid-frequency structure at the cost of mottle) with measurable authority.

## Tests

- New: `ClassicNRDemosaicedTests` (7 tests on mosaic + noise + demosaic frames: colour default, bleed, luminance untouched, basis, Luminance on mottle, hot pixels vs stars and speculars, noise false positives). Generator shared in `DemosaicedFrames.swift`.
- Changed, with reasons in the code:
  - `DenoiseTests`: Smoothness now tilts (finest band moves down by design); hot-pixel gate 12/8; receptive field +2; ISO-default test pins the new curve; GPU-plan test uses an explicit read-noise profile because base ISO no longer needs a rescale, and now checks the V thresholds.
  - `DenoiseQualityTests`: the full-deflection and top-of-travel claims are scored on a demosaiced twin of the same frame with noise from the engine's profile (the old frame's white noise at its own σ is what no camera produces); bars unchanged. The ceiling test is restated in band-noise σ (3σ max).
  - `EngineIntegrationTests`, `ResetSemanticsTests`: new ISO defaults.
  - `ProofRegistry` `denoise.hotPixels`: declared plateau 19 → 17 (the gate now ramps over the frame's spikes instead of flipping at one step), and the seven `denoise.*` proof records regenerated. Authority rose for Luminance 9.6 → 20.2, Detail 6.8 → 15.1, Contrast 0.75 → 2.05, Colour 16.2 → 51.6, Colour Detail 11.8 → 91.4; Smoothness fell 6.8 → 4.9 against a floor of 4 (the blotch pass is gone); Hot Pixels unchanged at 171. The records' worst-pixel hue rotation rose for Colour Detail (5.1° → 55.7°) and Colour (10.6° → 23.2°): the metric is the single worst pixel on a noisy frame, and a noise reducer that now removes the colour speckle rotates those speckle pixels by design. Colour Detail's front-loading is now 1.0 (most of its effect in the first step of travel).
- Full Linux suite (release, `-enable-testing`): base commit 3058 tests, 0 failures; final tree 3065 tests, 0 failures.
- Note: on the Swift 6.0.3 toolchain the brief installs, `swift test` cannot build `LumenApp` (`CompareView.swift` trailing commas, pre-existing). Tests were run with that file patched locally and not committed (NEEDS.md #4).

## Verification

- Round 1 (fresh verifier, spec + diff only): FAIL. All 19 measured lines and V1 to V3 passed, and the line-by-line GPU vs CPU review found no mismatch. Failures: 8 existing tests broken, REPORT.md missing, and one wrong comment (it claimed Colour 25 cannot touch an ISO 100 photo).
- Fixed: the tests above; this report; the comment now states the measured low-ISO effect (A7 IV ISO 250 speckle 1.26 → 0.34 ΔE, indistinguishable at 3×; colour-edge detail kept better than shipped on A7 IV and GX85).
- Round 2 (same verifier, diff d26c5f4): PASS. Full Linux release suite 3065 tests, 0 failures; 19 of 19 lines and V1 to V3 pass. Its residual notes: the restated quality tests draw noise from the engine's own profile, so they no longer test a misjudged σ (real for the A7C, see NEEDS.md #1); the chroma ceiling was only a pin, now also bounded at 8σ in the bands that carry colour detail.

## What I could not fix, and what a human must judge

- Per-camera noise (NEEDS.md #1): ISO alone over-smooths full frame (A7C read 1.53× noisy) and under-reads some small sensors.
- Single-frame hot-pixel ambiguity: a star of PSF σ 0.5 px landing on one red or blue photosite is removed, because after demosaic it is a hot pixel. Fixing it needs the CFA-domain pass (NEEDS.md #2).
- A filled hot pixel leaves a faint flat patch the size of the smear (visible at 3× in `hot-pixels.png`).
- Hot pixels on the outermost 1 px row or column of the frame are not removed (the clamped neighbour is itself). Same on CPU and GPU.
- Grass and foliage: Colour at default slightly lowers fine colour variation in dense grass (GX85 sim colour-edge error 6.86 → 7.23; Colour Detail 100 brings it to 6.66). Judge on your own foliage shots.
- Band-noise tables were measured on LibRaw AHD (and checked against X-Trans, which runs about 30 % lower in the finest bands). Apple's demosaic was not measurable here; if Apple's decode carries less correlated noise, Colour will be slightly stronger than intended. Worth one look at a high-ISO frame on the Mac.
- Tooltip text changed; the UI snapshot run shows layout only.

## Evidence (`evidence/`)

- `2348-jacket.png`: G9 ISO 3200, input / shipped default / new default. Jacket colour noise gone, stripe edge clean.
- `hot-pixels.png`: rows hot pixels / stars / speculars on the same spots; shipped leaves the red blobs, new removes them; stars and speculars intact.
- `sim-a7iv-luma.png`: ground truth, noisy / shipped / new / clean at the ISO 3200 defaults.
- Also `2062-poppy.png`, `1192-glass.png`, `2242-puzzle.png`, `4144-leaf.png`, `sim-r5-colour-edge.png`.

## Reproduce

`bash docs/quality/lanes/WS-19/tools/prepare.sh` (about 15 min), then `python3 docs/quality/lanes/WS-19/tools/measure.py all` and `python3 docs/quality/lanes/WS-19/tools/evidence.py`.
