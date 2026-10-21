# Lane T3 report: WS-18 creative sharpening + WS-17 capture sharpening

Branch `quality/t3-sharpening`. Audit `AUDIT.md`, spec `SPEC.md`, verifier `VERIFY.md`,
cross-lane asks `NEEDS.md`. Measurement scripts `measure.py` (S12) and
`measure_capture.py` (S4).

## For the owner

1. Capture sharpening is Lumen's own deconvolution now, after noise reduction, on RAW only; Apple's sharpener is off. Look at a few RAWs at 1:1 against the last build: edges should be crisper and noise no coarser.
2. Sharpening Radius is real sensor pixels, as in Lightroom, so at fit view sharpening is barely visible (same as your exported file seen at fit). Judge it at 1:1. If you would rather the fit preview exaggerate it, say so — that is a design call, not a bug.
3. Hold ⌥ while dragging Masking: the viewer shows the edge mask (white = sharpened). Please try it by hand; CI cannot drag a slider.
4. Default Amount 70–100 no longer draws dark outlines round leaves or lifts the picture (+0.094 EV → +0.013 EV on the A7 IV frame).
5. Masked local Sharpness (brush/gradient) still uses the old radius scale until the mask lane passes the decode scale (NEEDS.md #1).

## Best evidence

- `evidence/after_6929_canopy_100pct_off_before_after.png` — A7 IV foliage at 100 %, Amount 100: before draws a dark outline round every leaf; after is crisp without it.
- `evidence/capture_2348.png` — G9 ISO 3200: S4 crisps the wire shelf and leaves the wall and the jacket fabric's noise alone.
- `evidence/after_2348_masking.png` — Masking 50 holds the ISO 3200 wall to its capture-only grain (std ×1.006) while the wires stay sharp.

## Decision: what capture sharpening is

Lumen's own Richardson–Lucy deconvolution (`CaptureStage`, LumenCore/Image/CaptureSharpening.swift; GPU twin CaptureSharpenGPU.swift), run as S4 right after S3 on both renderers, RAW only (a plan without a capture ISO has no S4; every rendered source reports `iso: nil`). `AppleRawSource` holds `sharpnessAmount` at 0 and its decode cache no longer keys on capture strength, so dragging capture Amount reuses the demosaic. Reasons: Apple's ran before S3 (noise sharpened before the noise model saw it), took no radius, and could not be rendered or measured off a Mac. `detail.capture.radius` is now live: PSF σ in native pixels, 0.4–2.0, default 0.8, with a panel row. The auto-σ estimator was not adopted: it read 0.78 on noisy fabric and 1.58 on a σ1 target, and a per-frame estimate the GPU cannot reproduce would split the renderers; the default is stated as a default, and the panel no longer claims a measurement.

Pieces: 8 RL rounds on a shared 13-tap Gaussian; a halo clamp in log2 luminance that holds every pixel to its 3×3 range except genuine one- or two-pixel peaks that stand 8–16 profile σ above their neighbours (edges get 0 % overshoot, texture keeps its gain, noise spikes do not grow); a noise gate on the box-averaged |∇| of VST luminance with knees at 4/7 σ of the ISO's profile; luminance-ratio recombination.

## What changed in creative sharpening (S12)

`SharpenStage` (LumenCore/Image/CreativeSharpening.swift; GPU SharpenGPU.swift) replaces the log-luminance USM:
radius in native pixels × decode scale (was radius × longEdge/2560: 2.74 px at Radius 1 on a 7008 px export); cube-root perceptual domain (brightening 7× smaller on the full frame); Detail = how much overshoot past the halo bound is let back in, plus how far texture peaks may grow (Lightroom's Detail; the old one ignored Radius at Detail 100); Halo Damping scales the bright overshoot past the bound (it used to damp mid-edge — the pinned defect in FieldBaselineProbeTests, now promoted to a contract); Masking on |∇√Y| where shot noise is level-independent (the old EV/px gradient read shadow noise as edges); both renderers read the S12 input itself (the CPU used to read the S8 decomposition). New ⌥-drag Masking view (`SharpenMaskView`, `SharpenStage.maskPreview`). Detail slider no longer `bipolar`.

## Verdict per spec line

Numbers from `measure_capture.py`, `measure.py`, full-frame renders and unit tests on Linux; GPU lines from macOS CI.

| line | verdict | measured |
|---|---|---|
| C1 restores a blurred edge | PASS | MTF50 ×1.39 slanted edge, ×1.36 zone plate |
| C2 no halo | PASS | 0.0 % / 0.0 % at Amount 150 Radius 2, blurred and sharp edges |
| C3 flat noise untouched | PASS | std ×1.000 matched profile, ×1.000 at 1.6× profile |
| C4 fine texture keeps gain | PASS | `testItRestoresFineTexture` (4 px grating ≥ ×1.2) |
| C5 Amount/Radius live, monotone | PASS | `testAmountAndRadiusAreLiveAndMonotone` |
| C6 identity | PASS | off / Amount 0 / no ISO byte-identical; default recipe without `--iso` byte-identical to base build |
| C7 no hue shift | PASS | R/G, B/G to 1e-5 |
| C8 GPU = CPU | PASS | `CaptureSharpenParityTests` green on macOS (run 39541024187, round-2 kernels) |
| C9 real photos | PASS | acutance ×1.28 ivy, ×1.21 canopy; 2348 wall std ×1.000 |
| C10 Radius row live | PASS | `CaptureSharpenScopeTests`, `SliderEvidenceTests`; UI layout lane green on macOS |
| C11 high-ISO fabric | PASS | jacket specks ×1.11 (6345 → 7035), +0.010 EV |
| S1 identity | PASS | Amount 0 byte-identical on all five frames |
| S2 sharpens, monotone | PASS | edge MTF50 ×1.129 / 1.227 / 1.334 / 1.495 at 40/70/100/150; zone ×1.202 at 70 |
| S3 no halo at normal settings | PASS | 2 EV edge 0.0 / 1.0 % at Amount 100; blurred 1 px line 1.6 / 0.0 % at 70 |
| S4 Detail = halo suppression | PASS | Detail 0: 0.0 % halo, 0.0 % pristine-line ringing; halo non-decreasing 0/25/50/100; noise ×1.40 → ×1.59 |
| S5 Radius native and live | PASS | σ = radius × scale (`ScaleHonestyTests`); MTF ×1.06 / 1.23 / 1.44 / 1.52 at 0.5/1/2/3; Detail 100: ×1.21 r1 vs ×1.33 r3 |
| S6 Halo Damping hits the rim | PASS | bright rim 1.4 → 0.6 → 0.0 % at 0/50/100, dark side 3.2 % unchanged |
| S7 Masking protects flat areas | PASS | noise ×1.003 at 50; 2348 wall ×1.006; 2 EV edge keeps ×1.239 vs ×1.227 unmasked |
| S8 ⌥-drag mask | PASS (unit) / owner to try | `testTheMaskPreviewShowsEdgesWhiteAndFlatBlack` |
| S9 no brightening | PASS | 6929 native full frame, Amount 100: +0.013 EV (base +0.094) |
| S10 no hue shift | PASS | `testItCannotShiftHue` |
| S11 GPU = CPU | PASS | `SharpenParityTests` green on macOS (run 39541024187) |

Verifier: round 1 FAIL (B1: capture sharpening grew ISO 3200 fabric specks ~7×); round 2 PASS on every Linux-runnable line (C11 specks ×1.12, +0.0099 EV), with two one-line doc fixes (capture Radius tooltip, a stale kernel comment) applied after it. Release ControlProofTests pass locally on the round-2 code.

## Things a human must judge, and limits

- **Fit view shows little sharpening** (verifier B4): at decode scale 0.15 Amount 150 changes no pixel. That is the native-pixel radius working as designed; Lightroom also asks you to judge at 1:1.
- **Over-sized capture Radius softens a sharp edge** (verifier B2): Radius 2 on an already-sharp edge drops MTF50 0.615 → 0.486 (stair-stepping, gaps close) without any overshoot. The tooltip now names this; the default 0.8 is on the safe side.
- **S12 brightening on crops** (verifier B3): +0.037 EV on a foliage crop at Amount 100 (full frame +0.013). Pure noise keeps a residue: +0.030 EV vs the old +0.048 on a 17 % noise field. Masking removes it.
- **S4 at high ISO** is conservative: the gate is set for sensors up to ~2.5× noisier than the generic seed profile, so ISO 3200 fabric is mostly left alone and wires gain ×1.03 rather than more. Per-body noise profiles would let it do more.
- **Proof records changed deliberately**: Amount and Radius are swept on a σ1 soft step (on an ideal step a halo-free sharpener only adds halo; the old floor of 29 was a halo), Halo Damping at Detail 100, Masking on texture beside a noise ramp. New floors 18/19/19/19 at ~80 % of the readings; records regenerated.
- **Tests changed because they encoded the old behaviour**: `ScaleHonestyTests` (frame-denominated radius → native), `FieldBaselineProbeTests` halo record (Equal → LessThan; its "mechanism runs" floor 0.01 → 0.005 because the damp now touches only the rim), `CaptureSharpenScopeTests` (AppleRawSource is no longer the reader), `SliderEvidenceTests` (capture keys now Linux contracts), `LayoutMetricSupport` (+1 slider).
- **Outside owned functions** (minimal, flagged): one call each in `RenderGraph.colorStageInput`, `PipelineRenderer.renderReference`, `ReferenceRenderer.render` (S12 call site, `Inputs.decodeScale`), `RenderPlan.init` (+`capture`), lumen-render CLI (`--native-long-edge`, S4), `AppState` (+`sharpenMaskDragging`), `LoupeView` (overlay insertion), `SpatialOps` comment. Left in place but unused by the render: `fineDetailBand`, `estimatePSFSigma`, `SpatialOps.richardsonLucy` (tests pin them).
- **Pre-existing**: Linux 6.0.3 cannot parse two trailing commas in `CompareView.swift` (6.1 syntax), so local test runs used an uncommitted patch. `ControlProofTests` takes > 25 min in debug on base and branch alike.

## Tests

Linux, every LumenCore/LumenRender class except ControlProofTests, branch and base: all pass (branch adds CaptureStageTests, SharpenStageTests). ControlProofTests: pass (release, local and CI).

CI on 88dcf1d: GPU parity green (CaptureSharpenParityTests incl. the round-2 delta uniforms, SharpenParityTests), Proof sweep green, UI layout green, UI snapshots green, CI test-fast / build-macos / engine-linux / app-bundle green. CI `fixtures-linux` → `check-swift-surface.py` red: pre-existing on the base (same `CommandLine`, `Metrics`/`RecipeKeys` init, `set(_:forKey:)` label and `Font` findings with the lane removed). The lane's only addition to it, `M_LN2`, is replaced by the literal in the final commit, after which the checker's findings equal the base's.
