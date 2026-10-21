# WS-15 Dehaze: audit

Auditor pass on branch `quality/ws-15-dehaze`. No code was changed.

- Renderer: `.build/x86_64-unknown-linux-gnu/release/lumen-render`, CPU `ReferenceRenderer`.
- As-shot kelvin and tint come from each frame's sidecar `recipe_hint`.
- Images are under `docs/quality/lanes/WS-15/audit-work/` (abbreviated `AW/` below). This folder is not committed.
- Scripts are in `tools/`, abbreviated `T/` below:
  - `run_sweeps.sh` renders every sheet.
  - `render_set.sh` renders undithered frames at a fixed long edge.
  - `dehaze_metrics.py` has the subcommands `regions|shadow|halo|veil|res|all`.
  - `smoothness.py`, `airlight_probe.py`, `patch_check.py` and `crops.py` cover smoothness, the airlight location, the colour-chart patches and side-by-side crops.
  - Boxes and edge profiles for each frame are in `T/regions.json`, as fractions of the frame.

Frames used:
- Real photos: 983 (5D IV, snow, ColorChecker), 1840 (D850, treeline, clear sky), 4213 (Z7II, overcast, castle), 3437 (T7i, oaks), 2545 (GX85, lawn), 6929 (A7 IV, street).
- Synthetic frames: hard_edge, flat_grey, colorchecker, hue_wheel, grey_ramp.

Sheets are at `AW/<id>_sheet.png` (1024 px, at −100 −50 −25 0 25 50 100) and `AW/<id>_fine_sheet.png` (512 px, −100 to 100 in steps of 10). Tiles are in `AW/<id>_tiles/`. The 100 % renders are `AW/full/<id>_L2400_d{0,50,100,-100}.png` and the crops are in `AW/crops/`.

## What Lightroom does (sources + what is guesswork)

**Documented by Adobe:**
- The slider is in the Basic panel. Moving it right removes haze and moving it left adds haze for a mist or fog look.
- Adobe recommends it for distant landscapes and coastal scenes.
- If Dehaze pushes colours too far, Adobe says to lower Saturation or Vibrance. So in LR, **positive Dehaze increases saturation**.
- Source: [Adobe help: remove haze](https://helpx.adobe.com/ee/lightroom-classic/how-to/remove-haze-dehaze.html).
- Adobe's own description, as quoted by Tutsplus, says it is based on a physical model of light transmission that estimates the light lost to atmospheric absorption and scattering ([tutsplus](https://photography.tutsplus.com/tutorials/how-to-use-the-adobe-lightroom-cc-dehaze-tool--cms-30198)).

**Reported by users (not Adobe):**
- It adds contrast and saturation. Blue skies become noticeably more saturated ([tutsplus](https://photography.tutsplus.com/tutorials/how-to-use-the-adobe-lightroom-cc-dehaze-tool--cms-30198), [fstoppers](https://fstoppers.com/lightroom/good-bad-and-ugly-lightrooms-dehaze-tool-330394)).
- It darkens the photo and shifts it cooler, so exposure often needs a touch-up ([glass.photo](https://glass.photo/photography-terms/dehaze), [shotkit](https://shotkit.com/lightroom-dehaze/)).
- Pushed hard, it brings up noise in smooth skies and can draw halos along horizons. +10 to +30 is the usual range ([glass.photo](https://glass.photo/photography-terms/dehaze)).
- Negative values add a flare-like or dreamy veil ([thomasfitzgerald](https://blog.thomasfitzgeraldphotography.com/blog/2015/6/a-quick-look-at-lightrooms-new-dehaze-tool)).

**Guesswork.** No reference exports exist, so these are not measured:
- I estimate that LR +100 lowers mean brightness by roughly 0.3–0.7 EV.
- I believe it keeps or raises sky chroma.
- I believe it does not turn snow or white walls grey.
- I believe its negative veil is a light, near-neutral or slightly cool lift that is fairly uniform, with only a mild bias toward the distance.

Treat these as the floor to test against once `corpus/lightroom/` exists.

## Findings

1. **Identity is exact.**
   - Dehaze 0 renders byte-identical to the base (`cmp` on 4213, 983 and hard_edge; `AW/ident/`).
   - Dehaze 1e-4 changes at most 1 code, in 0.002 % of pixels.
   - Pass.

2. **Positive Dehaze is mostly a global darkening, not a contrast restore.**
   - Mean linear luminance change at +25 / +50 / +100 (1024 px tiles, `dehaze_metrics.py shadow`):

     | Frame | +25 | +50 | +100 |
     |---|---|---|---|
     | 4213 | −0.29 EV | −0.65 EV | **−1.62 EV** |
     | 983 | −0.21 EV | −0.46 EV | −1.06 EV |
     | 3437 | | | −0.71 EV |
     | 1840 | | | −0.60 EV |
     | 6929 | | | −0.49 EV |
     | 2545 | | | −0.18 EV |

   - On 4213 at +100 the zone deltas in 8-bit codes are [−13 −12 −12 **−64 −80 −66** −12]. The midtones and the overcast sky collapse.
   - Global encoded RMS contrast *falls* on every frame. For example 4213 goes 0.198→0.131 and 983 goes 0.185→0.156.
   - The 4213 far field (`far` box, 100 %) keeps the same encoded std (ratio 1.018 at +100). Log-luminance std rises 1.06→1.44. The visible result is a darker forest and no detail gain (`AW/crops/4213_castle.png`).
   - Overcast sky becomes a storm sky (`AW/crops/4213_horizon.png`; sky OKLab L 0.611→0.359, ΔE 24.5).

3. **Shadow crushing at +100 is moderate in clip %, but p1 is driven down hard.**
   - Pixels newly clipped to 0 at +100, per channel (r/g/b):

     | Frame | r | g | b |
     |---|---|---|---|
     | 983 | 0.50 % | 0.40 % | 0.34 % |
     | 4213 | 0.15 % | 0.14 % | 0.13 % |
     | 3437 | 0.08 % | 0.10 % | 0.05 % |
     | 6929 | 0.03 % | 0.03 % | 0.03 % |

     At +50 every frame is ≤ 0.02 %.
   - p1 linear luminance at +100 falls 3–5×:

     | Frame | Base p1 | +100 p1 |
     |---|---|---|
     | 4213 | 0.0033 | 0.0006 |
     | 3437 | 0.0034 | 0.0006 |
     | 983 | 0.0009 | 0.0003 |

   - The tree trunks in 3437 lose 1.5 EV (halo profile, dark side; `AW/crops/3437_trunk.png`).

4. **Positive Dehaze REDUCES saturation, which is the opposite of LR and of the slider's own help text ("restoring … colour").**
   - Sky OKLab chroma at +100 (1024 tiles):
     - 983: 0.0576→0.0340 (−41 %)
     - 1840: 0.0475→0.0375 (−21 %)
     - 2545: 0.0870→0.0739 (−15 %)
     - 4213: 0.0068→0.0037
   - Synthetic ColorChecker: patch 5 C 0.070→0.031 and patch 8 0.126→0.077 (`T/patch_check.py`).
   - Cause: the recovery is a single per-pixel luminance ratio `out = c·y1/y0`. That keeps the hazed chromaticity, so the desaturation the veil added is never removed. Combined with darkening, OKLab chroma drops.
   - He et al.'s model is per channel, `J = (I − A)/t + A`. Applied per channel, it restores saturation.

5. **Sky hue is stable on average but bands near the horizon (±5–6°).**
   - Whole-box hue shift at +100: 983 −0.1°, 1840 +2.6°, 2545 +2.0°, 4213 +0.3°. None of them turns purple or cyan on average.
   - In 2400 px strips over 1840's sky, the hue is **+4.7…+5.9° (toward violet) in rows 80–160** and **−4.6° (toward cyan) in rows 200–270 next to the trees**. This is visible as a lavender band above a cyan rim (`AW/crops/1840_treeline.png`, 1.6× gain).
   - The ratio scaling preserves hue in scene-linear. The shift appears after the downstream per-channel tone curve, with a position-dependent scale factor.
   - Neutral boxes pick up no tint at +100: snow da/db = −0.0006/+0.0024, CC white −0.0008/−0.0016, the 4213 tower and 2545 wall < 0.001. Pass.
   - ColorChecker worst hue shift: 3.9° at +100 and 5.3° at +50, for C > 0.02.

6. **Snow, white walls and pale greys are crushed: the dark-channel prior reads "bright and unsaturated" as haze.**
   - 983 snow OKLab L 0.540→0.338 at +100. The snow-covered mountain turns into dark, mottled grey and black blotches (`AW/crops/983_peak.png`).
   - Synthetic chart:
     - Patch 21, a light grey: L 0.735→**0.263**.
     - Patch 22: 0.584→0.160.
     - Saturated patches of the same lightness barely move: patch 16 goes 0.805→0.798.
   - Each grey patch also gets a **bright rim and dark centre**: rim minus centre is +0.174 OKLab L on patch 21 (`AW/colorchecker_sheet.png`, +100 tile).
   - The 6929 white wall goes mottled and dirty at +100 (`AW/crops/6929_neg_veil.png`, right panel).

7. **Large halos at horizons at +100.** Measured on 100 % profiles with `dehaze_metrics.py halo`. "Near-edge" means log2(out/base) next to the edge minus the far plateau.

   | Frame and edge | Far plateau | Near the edge | Band width |
   |---|---|---|---|
   | 4213 sky → treeline | −3.85 EV | +3.0 EV (sky barely darkened) | ≥ 99–134 px = 4–6 % of the 2400 px frame |
   | 983 sky → snow peak | −2.87 EV | +2.25 EV | 193 px |
   | 2545 sky → tree | −1.0 EV | +0.78 EV | 133 px |
   | 1840 sky → trees | −0.71 EV | +0.42 EV (cyan glow hugging the canopy) | 87 px |
   | 3437 meadow → trunk | | bright side +1.17 EV, dark side −1.59 EV | 39 / 55 px |

   - 4213 is very visible as a glowing band over the treeline (`AW/crops/4213_horizon.png`).
   - At −100 the halos are ≤ 0.5 EV.
   - Cause: the min-filter radius (short edge / 100) plus a guided-filter radius of 2 % of the long edge. The sky guard does not cover a darkening sky.
   - Synthetic `hard_edge` at −100 shows a grey rim outside the white disc. At +100 the bottom ramp goes black (`AW/hard_edge_sheet.png`).

8. **The airlight is picked from white objects, not the sky.** Emulated with `T/airlight_probe.py`, which follows the CPU rule (top 0.1 % of the dark channel). Locations are in `AW/airlight_locations.png`, marked in magenta.
   - **983: ColorChecker white patches.** A = (0.48, 0.47, 0.46), neutral.
   - **3437: the pink lid of the tank** and bright meadow. A = (0.39, 0.31, 0.35), magenta.
   - **2545 at 512 px: the house wall** (0.54, 0.51, 0.51). At 2048 px it is the sky (0.29, 0.38, 0.63).
   - 4213: a bright cloud, which is right.
   - 1840: the sky near the horizon, which is right.
   - 6929: the overexposed top-left sky corner, which is acceptable.
   - Nothing restricts the search to the upper frame or the sky, and nothing rejects specular or white objects.

9. **The negative veil is the wrong colour and in the wrong place on most frames.** Measured at −100 with `dehaze_metrics.py veil` (OKLab; "near" is the bottom 15 % of the frame).
   - **3437: the veil is pink/mauve.** Veil hue 327–338°, near da +0.010. The grass turns lilac-grey (`AW/crops/3437_neg_veil.png`). This follows from the airlight being the pink lid.
   - **Near is lifted more than far** on 3437 (far/near ΔL 0.34), 6929 (0.42) and 2545 (0.63). That is the inverse of atmosphere. Bright foreground surfaces such as lawn and walls read as "low t", so they count as "distant".
   - On 2545 and 6929 the near foreground goes blue (db −0.007 / −0.006).
   - Good cases: 4213 (far/near 1.72, neutral veil) and 983 (1.45).
   - Blacks lift: p1 OKLab L goes 0.14→0.17 on the 4213 far field. Sky contrast flattens (L-std ×0.45–0.64).
   - Overall, −50 / −100 reads as a believable mist only on 4213 and 983. Elsewhere it is a coloured wash.

10. **The slider is smooth and monotonic, with no dead zone. Asymmetric.** Data from `T/smoothness.py AW/<id>_fine_m.json`.
    - Mean ΔE rises monotonically on both sides.
    - The step is roughly constant on the negative side (0.4–0.6 ΔE per 10).
    - The positive side accelerates slightly: on 4213 the step grows from 1.07 to 1.46 ΔE per 10, a ratio of 1.36. On 983 the ratio is 1.19, and on 2545 it is 1.05.
    - The first step from 0 is the same size as the rest. No jump.
    - Positive has about 2.5× the authority of negative on hazy frames (4213: +100 gives 12.5 ΔE, −100 gives 4.9).

11. **Low-haze photos change modestly, mostly by darkening.**

    | Frame | +50 ΔE | +100 ΔE | +100 brightness | Sky at +100 |
    |---|---|---|---|---|
    | 2545 | 1.4 | 2.6 (p95 5.3) | −0.18 EV, RMS contrast unchanged | darkens L 0.647→0.530, C −15 % |
    | 6929 | 2.4 | 4.9 (p95 16.8) | −0.49 EV | n/a |

    - 6929 zone 4–5 deltas at +100 are −26 codes, and the white wall gets mottled.
    - Neither frame is wrecked at +50. At +100, 6929's wall and the darkened sky in both are the problems.
    - No oversaturation, because saturation goes down (finding 4).

12. **Resolution consistency.**
    - Method: render at long edge 512 and at 2048, area-average the 2048 render to 512 in linear light, then compute ΔE2000. The excess is that ΔE minus the same comparison at dehaze 0 (`dehaze_metrics.py res`).
    - Excess at +60 / −60:

      | Frame | +60 | −60 |
      |---|---|---|
      | 4213 | 0.16 | 0.04 |
      | 1840 | 0.10 | 0.05 |
      | 983 | 0.11 | 0.04 |
      | **2545** | **1.48** (p95 +2.75) | 0.65 |

    - On 2545, +60 darkens the 512 render by **−9.6 codes** but the 2048 render by only **−2.1 codes**, roughly uniformly across the frame. The airlight flips from the house wall at 512 to the sky at 2048 (finding 8).
    - On 4213 the 512 render is 1.3 codes darker at +60, concentrated in the foreground.

13. **CPU vs GPU: places where they can disagree** (`DetailEngine.applyDehaze` / `Decomposition` vs `RG.applyDehaze` + `KR.dehazeSource`).
    1. **Sky guard missing on the GPU** (known, BUILDING.md). The CPU lifts the t floor to 0.9 where `smoothstep(0.5, 2, logLum) · (1 − smoothstep(0.05, 0.35, gradient))`. The GPU uses only the constant floor `mix(0.55, 0.05, 0.2) = 0.45`. Bright flat regions (sky, white walls such as the 4213 tower) will dehaze much harder on the GPU.
    2. **Negative branch distance:** the CPU uses `max(1 − t, skyness)` and the GPU uses `1 − t` only. The GPU puts less veil on the sky.
    3. **Airlight estimator:**
       - CPU: mean source colour over the top 0.1 % (by count) of the full-res dark channel, with a global-mean fallback.
       - GPU: mean proxy colour where the proxy of the dark channel is ≥ 0.99 × the proxy maximum, with a fallback to grey 0.8.
       - Both the threshold rule and the resolution differ, so the selected pixel sets differ. They can land on different objects (see 8 and 12).
    4. **Guide for the transmission refinement:**
       - CPU: `log2(Y/0.18)` floored at −20 EV, radius `max(workingRadius, 8)` with workingRadius = `max(2 % · long edge, 3)` of the decomposition image, ε 0.02.
       - GPU: LumenLog (±12 EV, linear toe below about −10.5 EV), radius `max(2 % · options.longEdge, 3, 8)`, ε 0.02 / range².
       - They match only when `options.longEdge` equals the S8 image's long edge and no pixel sits below −10.5 EV.
    5. Morphology edges: the GPU uses `clampedToExtent`. The CPU uses its own `minFilter` boundary.
    6. Zero-luminance guard: the CPU `y0 != 0` vs the GPU `step(1e-9, |y0|)` and `max(magnitude, 1e-8)`. Equivalent except at denormals.
    7. Size mismatch: the CPU `fit()`s t, gradient and logLum when the image size differs from the decomposition's (the local-adjust path). The GPU always works at image resolution.
    8. The local-adjust path (`ReferenceRenderer` ~470) builds a **new Decomposition on the already-processed frame**, so its airlight is re-estimated after earlier masks. The GPU side was not checked; that is not WS-15 code.
    9. Precision: the CPU uses Double and the GPU f32/half. This is negligible next to the items above.

    The KernelGoldenTests that exercise the GPU are skipped on Linux (`KernelLibrary.isAvailable`), so none of the above was measured. This is code reading only.

14. **Resolution dependence in the code.**
    - Relative to the frame: dark-channel radius `minEdge/100`, guided radius 2 % of the long edge, airlight top-0.1 % by count.
    - Fixed in pixels:
      - The dark-channel radius is floored at **3 px**, which bites below a 400 px short edge, so previews are affected.
      - The guided radius is floored at **8 px**, which bites below a 400 px long edge.
      - **The sky guard's `gradient` is a per-pixel central difference in EV/px.** A given texture reads 4× "less flat" at 512 than at 2048, so the guard switches with resolution.
    - The GPU uses `options.longEdge` while the CPU uses the S8 image size. They can disagree under proxy or tiled renders.

15. **Physics and colour-science problems.**
    - (a) The luminance-ratio recovery cannot restore chroma (finding 4). Per-channel recovery, or ratio recovery plus an explicit chroma recovery term, is what the model calls for.
    - (b) The airlight comes from the brightest dark-channel area, which picks white objects such as charts, lids, walls and snow. Nothing confines it to the sky or upper frame, and nothing weights it by flatness (finding 8).
    - (c) The dark-channel prior fails on bright, low-saturation surfaces: snow, white walls, grey cards and overcast sky. The sky guard only partly covers this, and only on the CPU (findings 6, 13.1).
    - (d) The neutralisation gains only feed `y0`. The veil is never removed per channel, so for a coloured airlight the hue it adds stays in. For a neutral airlight from a white object, the neutralisation does nothing.
    - (e) Negative Dehaze blends toward the raw airlight colour. A wrong airlight therefore paints a wrong veil (pink on 3437).
    - (f) Overall darkening is not compensated. The LR description says LR darkens too, but by my estimate far less than −1.6 EV (guesswork, see top).
    - (g) `tMin = 0.45` caps recovery at 2.2× in luminance, yet +100 still darkens zone 4 by 80 codes on 4213. Because y1 = (y0 − A)/t + A, every pixel darker than the airlight is pushed down by up to 1.2·A. A bright airlight therefore shifts most of the frame down.

16. **Existing tests that touch dehaze** (`grep -rn -i dehaze Tests/`).
    - `LumenPipelineTests/KernelGoldenTests`:
      - `testDehazeDoesNotRotateHue`: GPU +60, worst hue shift < 1°, and it must move the image.
      - `testDehazeKeepsPixelsAboveBlack`: GPU, no scene-linear channel below 0.
      - `testDehazeMaskedAverageIsOneReadOfRGBAndAlpha`: airlight readback.
      - All three are skipped on Linux.
    - `LumenCoreTests/Proof/FieldBaselineProbeTests.testPrintsTheDehazeBaseline`: on a synthetic 128 px hazy scene at 50 and 100, ground contrast gain > 1.05 and zero negative pixels.
    - `ScaleHonestyTests.testTheSpatialStagesTrackTheFrameRatherThanThePixelCount`: dehaze 45, under 5 codes across a 4× scale (measured 3.29). It uses a synthetic frame, so it does not catch the 2545 airlight flip.
    - `Proof/records/detail.dehaze.json` (frame "hazySky") records:
      - monotone
      - hueRotation 1.36
      - overshootBelow 51.1
      - authority 96.8
      - frontLoading 0.44
    - Structural or registry references only: `RobustnessTests` (dehaze 80 robustness, 15 and 0 resets), `ScaleHonesty`, `LocalAdjustGroupTests` (mask field 33), `SliderEvidenceTests`, `ProofRegistry`, `ResetSemantics`, `RecipeCodecTolerance`, `SavedLook`, `SettingsSubset`, `WorkspaceModification`, `DraftTruthfulness` (10), `PerfProbe` (15), plus fixtures.
    - **No test covers:**
      - sky chroma under positive dehaze
      - where the airlight is picked
      - the negative veil's colour or near/far distribution
      - horizon halo width
      - mean-brightness drop
      - resolution consistency on a real frame
      - CPU/GPU parity for the sky guard

## Summary of what a spec should pin

- Positive:
  - sky chroma must not fall, and should rise (LR-like)
  - mean luminance drop at +100 bounded, e.g. well under −1.6 EV
  - halo near/far deviation at horizons bounded at 100 %
  - snow and white-wall L preserved
  - no grey-patch rim/centre split
- Airlight from the sky or haze region, not from white objects. Stable across 512/2048 (2545).
- Negative: veil near-neutral or sky-coloured, and far ≥ near.
- Keep: identity, monotonicity, no dead zone, neutral tint < 0.002 OKLab a/b.
- GPU twin: sky guard and negative-branch skyness ported. Airlight rule identical to the CPU's.
