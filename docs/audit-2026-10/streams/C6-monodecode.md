# C6-monodecode: Leica M Monochrom Typ 246 DNG (corpus 1087) decodes black

Based on `origin/claude/jolly-sagan-k7ch7z` @ 40d5689. Not pushed. Follows P20 item 3 and C4-mono.

## What the logs say (run 36841530238, 82de27d merge of C4-mono)

Every line for 1087:

- `corpus-open: 1087 opened E=5976x3992 N=5976x3992 … pin=6`. The per-file default decoder is
  `6`; supported are `6.dng,7.dng,8.dng,6`.
- `corpus-wb: 1087 neutralTemperature=5454.0087890625 neutralTint=-12.993514060974121
  … decode-mean-rgb=-0.004212895971145073 (×3) nonfinite=0/2805760`. The neutral is finite, so
  C4's NaN hypothesis is disproved. The decode is black, and slightly negative, BEFORE S6.
- `corpus-measure: 1087 … mean=0.0000 p5=0.0000 p95=0.0000 black=1.0000`. R-6 fails three ways.
- `raw-pixel-check: pin6/7/8/999999 corpus1087 … maxAbsolute=0.00024 normalized=0.089`, and
  `default … maxAbsolute=0.000117 normalized=0.067`.

## Why P20's "the decode matches an independent CIRAWFilter" proved nothing

`AuditRawAccuracyTests.oracle` writes the same flat options that `AppleRawSource.decode`
writes: neutralTemperature/neutralTint, boostAmount 0, boostShadowAmount 0,
localToneMapAmount 0, isGamutMappingEnabled false, contrastAmount 0, exposure 0,
extendedDynamicRangeAmount 1, and sharpening, NR and lens correction off. It is
independent of Lumen's cache and materializer, but not of Lumen's option choice. Agreement
to 1.2e-4 means both decodes are black in the same way. P20 read the error as "half a
half-float ULP in [0.25, 0.5)". That does not follow: the normalized figure is a maximum over
samples, and a 1e-4 delta near zero gives the same number.

All three decoder versions (6, 7, 8) agree with the oracle under the same options. So
choosing between those decoders is not the cause.

## What the file contains (fetched here, sha256 matches the manifest)

From tifffile + imagecodecs on the raw SubIFD:

- PhotometricInterpretation LinearRaw (34892), SamplesPerPixel 1, 12-bit, lossless JPEG,
  5984x4000, crop 5976x3992.
- BlackLevel 0, WhiteLevel 3750. IFD0 has BaselineExposure 0/1, LinearResponseLimit 1,
  ShadowScale 1, and DNGVersion 1.3.
- No ColorMatrix, CameraCalibration, AsShotNeutral or CalibrationIlluminant.
- Raw samples: min 0, max 3947, mean 266.6, p5 39, p50 186, p95 657. So mean/WhiteLevel is
  **0.0711**. A correct linear decode of this frame averages about 0.07 (BaselineExposure is
  0). The decode Lumen gets, -0.0042, is not a dark version of the image. The content has
  been scaled to almost nothing, and a small constant has been subtracted.

## Cause: narrowed, NOT pinned

These are ruled out by the logged values:

- NaN neutral: the neutral is finite.
- Black-level subtraction: BlackLevel is 0, and raw p5 is 39/3750 = 0.010. Subtracting the
  black level cannot take the mean from 0.071 to below zero.
- Baseline exposure in the file: it is 0.
- Choosing between decoder versions: 6, 7 and 8 all agree.

Prime suspect, from source reasoning: the `neutralTemperature`/`neutralTint` WRITE. It is
the only flat option that goes through the camera colour matrices. Apple turns a
temperature/tint into a camera neutral through XYZ→camera, which comes from ColorMatrix.
This file has no ColorMatrix. A zero or degenerate matrix there would give a near-zero
gain. Equal R=G=B rules out a per-channel WB error and fits a scalar collapse.

The small negative constant would then be a bias Apple applies after scaling. Lumen never
writes `shadowBias`, so its per-camera default stays in place. That bias is invisible on a
normally exposed frame.

The readback of 5454 K / -13 is what Apple synthesizes for a file with no neutral. Writing
it back is NOT obviously a no-op, because a write switches the source of the neutral.

Second suspect: `extendedDynamicRangeAmount = 1` or `boostAmount = 0` taking a linear path
that is not implemented for 1-plane LinearRaw.

None of this can be decided without running CIRAWFilter. So no production code changed.

## Item

| # | Item | Status | Commit |
|---|------|--------|--------|
| 1 | Diagnostic: CIRAWFilter option sweep and property readback on mono corpus files | FIXED (diagnostic) | d9638f1 |
| 2 | Fix 1087 black decode | NOT-FIXED (cause narrowed, not pinned) | — |

### 1. `RawCorpusTests.testMonochromeDecodeOptionSweep`

This runs on the corpus lane for every `mono` row. Each decode uses a fresh `CIRAWFilter`
at scaleFactor 0.125, draft off, and the per-file decoder. It emits:

- `corpus-mono-props: <id> state=default|lumen-flat …`: every CIRAWFilter property read
  back. These are `baselineExposure`, `shadowBias`, `exposure`, `boostAmount`,
  `boostShadowAmount`, `contrastAmount`/`isContrastSupported`,
  `localToneMapAmount`/`isLocalToneMapSupported`, `extendedDynamicRangeAmount`,
  `isGamutMappingEnabled`, `isLensCorrectionEnabled`/`isLensCorrectionSupported`,
  `sharpnessAmount`/`isSharpnessSupported`, `detailAmount`/`isDetailSupported`, both NR
  amounts and their `is…Supported`, `moireReductionAmount`/`isMoireReductionSupported`,
  `neutralTemperature`, `neutralTint`, `neutralChromaticity`, `linearSpaceFilter`,
  `decoderVersion`, `supportedDecoderVersions` and `nativeSize`.
- `corpus-mono-sweep: <id> variant=… extent=… mean-rgb=r,g,b r-min r-max r-std
  nonfinite-pixels`. The variants are:
  - `apple-default`: nothing written.
  - `lumen-flat`: the full flat set.
  - `flat-without-<option>` for each of the 12 options.
  - `default-with-only-<option>` for each of the 12 options.
  - `flat-plus-shadowBias-0` and `flat-plus-baselineExposure-0`.
  - `imageio`: `CGImageSourceCreateThumbnailAtIndex` with
    `kCGImageSourceCreateThumbnailFromImageAlways`. This is Apple's pipeline with no Lumen
    setter. A black result here would mean Apple cannot decode the file at all.

It asserts only that the manifest has a mono row and that the no-options decode formed an
image, so the sweep cannot silently measure nothing. It is a diagnostic, not an invariant,
and it says so in its doc comment. The flat set is replicated, as the oracle replicates it.
The comment says to keep it in step with `AppleRawSource.decode`.

How to read the next run:

- If `apple-default` gives about 0.07 and `lumen-flat` about -0.004, the cause is the
  flat-without/default-with-only variant that flips. If that variant is the neutral write,
  the fix is a no-colour-matrix branch that does not write `neutralTemperature`/
  `neutralTint`, so Apple's own neutral handling stays. Detecting that case needs a
  signal; the props line will show whether `neutralChromaticity` or a support flag tells
  it apart.
- If `apple-default` and `imageio` are also black, Apple's decoder cannot decode this file
  on the runner OS, and the right outcome is a refusal, as for the IIQ.

Red/green: none possible. The test needs the corpus and macOS, so it is source-verified.
`check-swift-surface.py` exits 0, and `swift build --build-tests` is clean (the file is
`#if os(macOS)`).

## Proof records that move
None. No production code changed.

## DECISIONS
- No fix landed, on purpose. The obvious candidate is "don't write the neutral". If it were
  applied to every file, it would change CFA decodes: Apple's AsShotNeutral path and a
  temperature/tint round trip are not bit-identical. The brief forbids that. A
  monochrome-only branch needs a detection signal that the sweep will show.

## FOUND-WHILE-FIXING
- `AuditRawAccuracyTests.oracle` is not independent of Lumen's option choice, because it
  replicates the flat set. It catches cache, materializer and pin defects, not
  option-choice defects. P20's conclusion that "the decode is not black" came from
  reading it as independent of the options. An option-free comparison
  (`apple-default`) belongs in that test once the 1087 cause is known.
