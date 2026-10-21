# WS-18 + WS-17 acceptance spec (lane T3): sharpening

Scope: creative sharpening `detail.sharpen.*` (WS-18) and the decode-stage capture
sharpening `detail.capture.*` (WS-17). Measured with
`docs/quality/lanes/WS-18/measure.py` (creative, display-encoded, relative to the
same render with the stage off) and `docs/quality/lanes/WS-18/measure_capture.py`
(capture). Unit-test twins in `Tests/LumenCoreTests/CaptureStageTests.swift` and
`Tests/LumenCoreTests/SharpenStageTests.swift`; GPU parity in
`Tests/LumenPipelineTests/CaptureSharpenParityTests.swift` and the existing sharpen
goldens in `KernelGoldenTests`.

Test frames (built by the scripts from `corpus/synthetic`): `*_blur1` = σ 1.0 px Gaussian
in linear light (the optics and demosaic a sharpener exists to undo); `flat_grey_noise` =
0.18 + N(0, σ) at the stated ISO's seed-profile σ; real crops are 1024² at native
resolution from `6929` (A7 IV, ISO 250, foliage) and `2348` (G9, ISO 3200).

## Decision: what capture sharpening is

Lumen's own Richardson–Lucy deconvolution (`CaptureStage`), run as S4 directly after S3
in both renderers. Apple's `sharpnessAmount` is held at 0. Reasons: Apple's ran before S3
(noise sharpened before the noise model saw it), took no radius, and could not be
rendered or measured off a Mac. `detail.capture.radius` becomes the PSF σ in native
sensor pixels (live). RAW only: a plan with no capture ISO (every rendered file) has no
S4.

## Capture sharpening (S4)

| # | claim | threshold | command |
|---|---|---|---|
| C1 | restores a blurred edge | MTF50 gain ≥ 1.30× on the σ1 slanted edge and ≥ 1.20× on the σ1 zone plate, default settings | `measure_capture.py` |
| C2 | no halo | encoded overshoot and undershoot < 0.5 % of the step on σ1 and on pristine (sharp) edges, Amount 150, Radius 2.0 | `measure_capture.py --amount 150 --radius 2` + `CaptureStageTests.testItDoesNotHalo` |
| C3 | flat noise untouched | std ratio ≤ 1.01 on `flat_grey_noise` at the matched profile, and ≤ 1.01 with noise 1.6× the profile | `measure_capture.py` + `CaptureStageTests.testItDoesNotSharpenNoiseOnAFlatField` |
| C4 | fine texture keeps its gain | blurred 4 px grating modulation ≥ 1.2× | `CaptureStageTests.testItRestoresFineTexture` |
| C5 | Amount and Radius live, monotone | 10–90 rise strictly decreasing over Amount 25/50/100/150 and Radius 0.5/0.8/1.2 | `CaptureStageTests.testAmountAndRadiusAreLiveAndMonotone` |
| C6 | identity | toggle off, Amount 0, or no capture ISO: output byte-identical to input | `CaptureStageTests.testOffIsTheExactIdentity`, `testARenderedFileGetsNoCaptureStage` |
| C7 | no hue shift | per-pixel R/G and B/G unchanged to 1e-5 | `CaptureStageTests.testItCannotShiftHue` |
| C8 | GPU = CPU | ratio difference < 2e-3 (f32), < 2e-2 (f16) | `CaptureSharpenParityTests` (macOS CI) |
| C9 | real photos | 6929 crops: acutance proxy (mean |∇| over OFF's top-10 % gradient pixels) up ≥ 10 %; 2348 flat wall std ratio ≤ 1.02 | `measure_capture.py --real` |
| C10 | Radius is live in the app | the capture section has a Radius row bound to `detail.capture.radius`; no panel text claims a measurement | `CaptureSharpenScopeTests`, `LayoutMetricSelfTests` (macOS) |

## Creative sharpening (S12)

Baseline numbers are in `AUDIT.md`. "2 EV edge" is `edge2ev_blur1` (0.09 → 0.36, σ1),
"halo" is encoded overshoot in % of the step; all with radius 1, detail 25 unless stated.

| # | claim | threshold | command |
|---|---|---|---|
| S1 | identity | Amount 0 byte-identical to the default recipe on all five frames | `measure.py --check-identity`, `SharpenStageTests.testAmountZeroIsTheExactIdentity` |
| S2 | sharpens, monotone in Amount | MTF50 gain on 2 EV edge ≥ 1.15 at Amount 70, strictly rising 40→70→100→150; zone-plate MTF50 gain ≥ 1.15 at 70 | `measure.py --set …amount=N` |
| S3 | no halo at normal settings | 2 EV edge bright and dark ≤ 1.5 % at Amount ≤ 100; blurred 1 px line ringing ≤ 3 % at Amount 70 | `measure.py`, `SharpenStageTests.testNoHaloAtNormalSettings` |
| S4 | Detail = halo suppression | Detail 0: 2 EV edge halo ≤ 0.5 % and pristine 1 px line ringing ≤ 0.5 % at Amount 70; halo rises monotonically with Detail; noise gain differs between Detail 0 and 100 | `measure.py --set …detail=N`, `SharpenStageTests.testDetailZeroIsHaloFreeAndDetailIsMonotone` |
| S5 | Radius is native pixels and live | σ = radius × decode scale; MTF50 gain strictly rising radius 0.5→1→2→3 at Amount 70; Radius changes the result at Detail 100 | `ScaleHonestyTests.testSharpeningRadiusIsDenominatedInSensorPixels`, `measure.py` |
| S6 | Halo Damping hits the rim | Detail 100 / Amount 100: bright halo on the 2 EV edge falls ≥ 50 % at Damping 50 and to ≤ 0.2 % at 100; dark side unchanged | `measure.py`, `SharpenStageTests.testHaloDampingTakesTheBrightRimAndLeavesTheDarkSide`, `FieldBaselineProbeTests.testHaloSuppressionDampsTheRimItExistsToDamp` |
| S7 | Masking protects flat areas | noise gain ≤ 1.02 at Masking 50 on `flat_grey_noise`; 2348 ISO 3200 wall std ratio ≤ 1.02 at Masking 50, Amount 100; 2 EV edge keeps ≥ 90 % of its unmasked MTF50 gain at Masking 50 | `measure.py`, `SharpenStageTests.testMaskingFiftyLeavesFlatNoiseAloneAndKeepsEdges` |
| S8 | ⌥-drag shows the mask | the view draws `SharpenStage.maskPreview`: flat noise black, edge white at 50 | `SharpenStageTests.testTheMaskPreviewShowsEdgesWhiteAndFlatBlack` (+ owner check by hand) |
| S9 | no brightening | 6929 native full frame, Amount 100: mean linear luminance shift ≤ 0.02 EV (base build: +0.094) | full-frame render pair, REPORT §numbers |
| S10 | no hue shift | R/G, B/G per pixel unchanged to 1e-5 at 150/100 | `SharpenStageTests.testItCannotShiftHue` |
| S11 | GPU = CPU | ratio difference < 2e-3 (f32), < 2e-2 (f16) across four settings incl. masking and scale 0.4 | `SharpenParityTests` (macOS CI) |

## Visual claims (human-judged)

- V3 `evidence/after_6929_canopy_100pct_off_before_after.png` and
  `after_6929_ivy_100pct_off_before_after.png`: at 100 %, Amount 100, the "before" draws a
  dark outline around every leaf (a 2.7 px radius) and lifts the frame; "after" is
  crisper with no outline.
- V4 `evidence/after_2348_masking.png`: Masking 50 leaves the ISO 3200 wall's grain as it
  is with capture only, while the wires stay as sharp as at Masking 0.

- V1 `evidence/capture_6929_ivy.png`: after is crisper on the ivy flowers and leaf edges
  than before, with no bright or dark rim on the wall/ivy boundary.
- V2 `evidence/capture_2348.png`: wire shelf edges crisper, the flat wall and the jacket
  fabric's noise no coarser than before.
