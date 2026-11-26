# Denoise: findings (area 16, noise reduction half)

Tester: `denoise`. Code under test: integration 805455c0 (render lab run 45745742569).
All relative paths below are under `/tmp/claude-0/-home-user-lumen/7b419a8a-9f16-5bc3-bbad-d84e24161d81/scratchpad/`.

## Verdict: can I trust denoise on a wedding at ISO 6400?

**Partly. For web-size delivery, yes. For full-size files, not without checking each camera at 100% zoom.**

- **Export** is what you can trust. At 1:1, the viewer matches export within about 1 code value in every mode. Classic at its ISO 6400 defaults never made anything waxy, never smeared hair or faces, never banded, never drew worms and never crushed shadows. The D5500 ISO 6400 event frame looks fine at 2048 px.
- **The fit view cannot be trusted** for judging noise. Classic NR is not run at fit, so the viewer shows the un-denoised frame, with about twice the colour noise the export will have. Every Classic slider does nothing there. AI mode does show at fit.
- **How strong the defaults are depends on the camera.** The noise model is one generic curve per ISO:
  - On the two Nikon APS-C files, real noise is 1.6 to 2.1 times the model, so Classic leaves colour speckle at full size. On the D5600 at ISO 12800 it remains even at Luminance 100 / Colour 100.
  - On the Sony A7C the model fits and the defaults are good.
- **Night and dark-venue frames:** in Classic and Off (Off is the same decode as Classic, without the NR), deep shadows on the D5600 at ISO 12800 turn magenta. AI and the camera JPEG keep them neutral.
- **"AI (stand-in)" is not AI.** It switches on Apple's RAW-decoder noise reduction (luminance at 0.6 × Amount, colour at Amount) and zeroes the Classic Luminance and Colour sliders unless you set them by hand. It is excellent on colour noise, weaker on grain, and leaves a maze or painterly texture at 1:1.
- **Practical recipe today:** set Classic Luminance by hand to about 40–60, then switch to AI and leave Amount at 50. The hand-set value survives the switch. This was the cleanest combination on all three files, with neutral shadows. Check one frame at 100% before a batch export.

## Corpus added (this commit should be merged)

Three CC0 high-ISO RAWs from raw.pixls.us. Each was downloaded and sha256-verified here, then verified again by `renderlab/fetch-photos.sh`:

| id | camera | ISO | scene |
|---|---|---|---|
| 4145 | Sony ILCE-7C (full frame) ARW | 12800, 1/8 s | indoor low light: fern, fuzzy succulent, wood bokeh |
| 2260 | Nikon D5600 NEF | 12800, 1/100 s | night street: deep shadows (dark scene) |
| 2127 | Nikon D5500 NEF | 6400, 1/200 s | night graduation under floodlights: faces, hair, satin (wedding proxy) |

No CC0 Canon file on raw.pixls.us sits between ISO 6400 and 25600; the only high-ISO Canon is an R50 at ISO 32000. Branch `claude/loving-cray-d58nrb-test-denoise`, commit abb9baa7 changes `renderlab/photos.tsv` and the `renderlab/README.md` photo table. **This change should be merged.** Plates were built on macOS in run 45745742569 (artifact `renderlab-plates`), and `plates.json` records ISO 12800, 12800 and 6400, so EXIF ISO is read correctly.

## Runs

- **Render lab (macOS shipping path), run 45745742569.** 320 renders: export, settled and compare. Manifest: `findings/denoise/repro/denoise-run1.json`. Output: `run1/artifact/shipping/inline/`.
- **Reference path, run locally on the new plates:**
  - fine slider sweeps: `repro/denoise-ref-local.json`, output `rl-ref/`;
  - noise-model A/B: `repro/profile-test-local.json`, output `rl-profile/` (plates in `plates2/` are identical pixels with only the header ISO changed).
- **Metrics:** `repro/metrics.py`. Columns: Lnoise and ab_noise are the robust σ of the 1.5 px high-pass in flat areas for luminance and colour; ab_blotch is the 2–8 px colour band; edgeEnergy is the mean |Laplacian| on the strongest edges. All ×1000, in OKLab. `repro/plate_noise.py` compares measured σ against signal with `NoiseProfile.forISO`. `repro/plate_dark.py` reads deep-shadow colour on plates.
- **Driver (real app): no result.**
  - Request 42887e3d did not build: it predated the driver branch's `noteTimeline` update by 80 s.
  - Run 45751059192 timed out: my `scrollTo` used a text target that sits inside the collapsed Detail section. That was my scenario's fault.
  - v2, request 75e7d68c (run 45757628351, `repro/driver-nr-v2.json`), was still queued at the wind-down.

---

## Findings (ranked by harm)

### 1. The fit viewer never shows Classic NR; export does, so the Classic sliders are dead at fit (major)
- **Did:** rendered Off, the imported Classic defaults and Classic 100/100, as viewer-at-rest (`settled`) and as export, at 2048, 3072 and 4096 px. Those are the loupe's fit asks; its cap is 4096.
- **Saw:**
  - The viewer frames are **bit-identical** (max Δ 0) across Off, default and 100/100, for all 3 photos at all 3 sizes. The exports at the same size are not.
  - 2260 at 3072: colour noise is 43.8 in the viewer in every mode, against 23.7 in the export at defaults and 14.1 at 100/100. Luminance noise is 32.6 against 18.4 and 9.3.
  - 2127 at 3072: colour noise 28.6 in the viewer against 13.9 in the export.
  - Settled-versus-export mean |Δ| on 2260 at 3072 rises from 3.3 (Off) to 5.1 (default) and 6.8 (100/100), from `compare.tsv`. That rise is the NR the viewer skipped.
- **Image:** `findings/denoise/fit3072-2260-viewer-vs-export.png`. Top row: viewer (Off, default, 100/100), all identical. Bottom row: export.
- **Why:** `ClassicalDenoise.scaled` turns the bands off when the decode scale satisfies s² ≤ 0.5. A 6000 px sensor reaches that at 4243 px, above the 4096 cap. So no sensor of 24 MP or more ever shows Classic NR at fit, whatever the screen.
- **Also:** AI mode IS visible at fit, because it runs in the decode (2260 at 2048: colour noise 2.11 in the viewer against 2.12 in export). Switching Classic → AI at fit therefore exaggerates the difference.
- **Zoom (inference from code, not proven):** after integration's zoom fix 0d9337f1, a zoom below 1:1 asks for zoom × native, so Classic NR should appear only above about 71% zoom. The driver v2 run was meant to measure this.
- **Correct:** fit noise that matches the export at that size, or at least a panel cue that Classic NR is shown at 100% only. Lightroom shows its NR at fit.
- **Repro:** jobs `fit2048`, `fit3072`, `fit4096`. Run 45745742569. **Confidence: high.**

### 2. One generic noise model per ISO. Real noise on the Nikon APS-C files is 1.6–2.1× the model, so Classic under-cleans and colour speckle survives 100/100 (major)
- **Did:** measured σ against signal in flat 8×8 blocks on native crop plates. Compared with `NoiseProfile.forISO`, which `RenderPlan` uses for every camera; `NoiseProfile.estimate(from:)` is not on the render path. Then an A/B on identical D5600 pixels: the profile told ISO 12800 (as shipped) against ISO 51200 (σ ×2).
- **Saw:**
  - Measured σ over model σ: **A7C ISO 12800: 1.05–1.20. D5600 ISO 12800: 1.84–2.13. D5500 ISO 6400: 1.57–1.75.**
  - At the imported defaults (1:1 export):
    - A7C fern: colour noise 11.6 → 1.9, luminance 8.2 → 2.5.
    - D5600 car: colour noise 38.8 → 14.7, luminance 31.2 → 14.2.
    - D5600 at Classic 100/100: colour noise still 7.9 and blotch 6.2, with red/green/blue speckle in every shadow. AI 50 gets 1.8 on the same crop.
  - The A/B, with the same sliders: colour noise 11.8 → 4.2, blotch 8.8 → 4.2, luminance 11.0 → 4.3. So the model limits the clean-up, not the slider travel.
- **Images:** `findings/denoise/car-modes-1to1-2x.png`, `car-road-shadow-blotches.png`, `profile-test-2260-2x.png`, `hair-luma-sweep-2x.png` (D5500 at Luminance 100 is still grainy).
- **Correct:** NR strength that tracks each camera's real noise. docs/07 §2 promises self-calibrating per-(camera, ISO) profiles.
- **Repro:** `repro/plate_noise.py` on `plates/*-crop*.plate`; `repro/profile-test-local.json`; jobs `modes-car`, `modes-faces`, `modes-fern`. Run 45745742569 plus the local reference runs. **Confidence: high.**

### 3. Night frame: deep shadows are magenta in Classic and Off; AI and the camera JPEG are neutral (major; possibly the same root as the known Nikon Z 30 cast)
- **Saw (green ÷ mean of red and blue, on dark pixels of the 1:1 exports, D5600 ISO 12800):**

  | crop | Off | Classic default | Classic 100/100 | AI 50 | AI 100 |
  |---|---|---|---|---|---|
  | wall | 0.69 | 0.60 | 0.56 | 0.87 | 0.86 |
  | bus | 0.61 | 0.54 | 0.51 | 0.74 | 0.76 |
  | car | 0.65 | 0.57 | 0.54 | 0.73 | 0.74 |

  - Wall in Classic default: RGB (11.2, 6.3, 9.9). The camera JPEG has (13.5, 13.5, 13.5) there.
  - The plate (decoder NR forced to 0, as in Off and Classic) already has it: darkest band mean linear RGB (0.0101, 0.0038, 0.0086), with negatives not clipped. So it comes from the decode with Apple's NR zeroed, not from Lumen clipping.
  - The D5500 crowd shadows show it more weakly: 0.91 in Classic against 0.97 in AI.
- **Image:** `findings/denoise/shadow-magenta-2260-bus.png` (×4 brightness).
- **Correct:** neutral shadows in every NR mode. Today the default mode is the magenta one.
- **Repro:** jobs `modes-wall`, `modes-bus`, `modes-car`; `repro/plate_dark.py`. Run 45745742569. **Confidence: high** for the D5600. Not tested on Sony at high ISO (4145 has no deep shadows).

### 4. AI (stand-in) = Apple decoder NR. At Amount 50 it leaves 2.6–3.5× more grain than the Classic defaults it replaces, with maze/painterly texture (minor)
- **What it does today:** `Denoise.appleStandIn` sets `luminanceNoiseReductionAmount = 0.6 × Amount/100` and `colorNoiseReductionAmount = Amount/100`. `ISODefaults.coupled` zeroes Classic Luminance and Colour unless they were hand-set. Hot Pixels and the sub-sliders carry over. There is no model, no cache and no splice.
- **Saw:**
  - Colour noise is excellent: 1.1–1.9 on every crop.
  - A7C luminance noise: AI 50 gives 14.5 (succulent) and 11.2 (wood), against 4.1 and 3.2 for the Classic defaults.
  - The remaining grain is crinkled into a maze/worm pattern on smooth areas (`wood-specks-5x.png`) and looks painterly on grass and hair at 100 (`hair-luma-sweep-2x.png`).
  - Amount does most of its work in the first half: 0→50 changes 6.3–10.4 code values, 50→100 only 1.0–2.0.
  - The hand-set Luminance survives the switch, as docs/07 says: AI 50 + Luminance 60 gives luminance noise 2.9 against 18.3 (car crop).
- **Repro:** `modes-*`, `sw-aiAmount-*`. Run 45745742569. **Confidence: high.**

### 5. Colour Detail and Luminance Contrast barely do anything over their whole range (minor)
- **Colour Detail**, swept 0→100 at Colour 80, changes the picture by a mean ≤ 0.04 code values on the A7C and D5600 crops and 0.32 on the D5500 crop (reference path). On the shipping path it is 0.02–0.35.
- **Luminance Contrast**, swept 0→100 at Luminance 60, changes it by 0.21–0.41.
- For comparison, Luminance Detail moves 0.8–1.5 and Smoothness 1.2–1.6.
- **Image:** `run1/artifact/shipping/inline/sheets/sw-colorDetail-fern__4145__export.png`, `sw-lumaContrast-car__2260__export.png`.
- **Repro:** `sw-colorDetail-*`, `sw-lumaContrast-*`, `ref-colorDetail`, `ref-lumaContrast`. **Confidence: high** on these frames.

### 6. Hot Pixels acts as a despeckle at high ISO, not "only extremes" as its tooltip says (minor)
- **Saw:** on the ISO 12800 car crop, Hot Pixels 50 changes 5.1% of pixels by more than 8 codes and 100 changes 12.7% (21.5% by more than 2). On the D5500 faces: 2.6% and 7.2%. No artefacts are visible (`hotpixels-car-1to1-3x.png`).
- **Inference:** single-pixel catch-lights or sparkle are at risk at high settings.
- **Repro:** `sw-hot-*`. **Confidence: medium.**

## Taste
- The Classic defaults on the A7C ISO 12800 are a little smooth on fuzzy textures: edge energy 13.3 against 19.7 for Off (`succ-modes-1to1-2x.png`).
- The Colour slider does about 70% of its work in the first 10 units, which matches its documented 2.5σ bound.
- AI 100 on grass reads as "watercolour".

## Tested and working
- EXIF ISO is read and the ISO defaults are applied (12800, 12800, 6400).
- At 1:1 the viewer matches export in all modes. Mean |Δ| is 0.45–0.95 on the Nikon crops. The A7C crops show 0.71 once aligned top-left: the lab compare resamples the 1-px-taller region and reports 2.4–5.3, which is an artefact of the comparison.
- Off is off, including the decoder NR.
- A hand-set Luminance survives the switch to AI.
- Luminance, Colour and Luminance Detail sweeps (11 steps) are smooth and monotonic, with no jumps.
- No banding, no worms in Classic, no waxy faces or hair, and no midtone colour cast from any mode (OKLab a/b shift ≤ 0.0013).
- Shadows are not crushed: zero-clipped pixels fall as NR rises, and the dL of −0.9 to −2.3 in deep shadow is the clipping bias of the noise going away.

## Not finished / not tested (one line each)
- Driver v2 (request 75e7d68c, run 45757628351, `repro/driver-nr-v2.json`): the real-app zoom level where Classic NR appears, the cost of dragging AI Amount (re-decode per step), and panel UI screenshots. It was queued at wind-down; fetch with `driver/tools/results.py 75e7d68cd30f76e70c079a4ad74f3c75ff4ba9ef`.
- Sony deep-shadow colour at high ISO: there is no suitable frame in the corpus.
- A Canon high-ISO file: none available under CC0 between ISO 6400 and 25600.
- Local (masked) NR, and AI mode on JPEG/HEIC: not reachable in the lab or out of scope.
