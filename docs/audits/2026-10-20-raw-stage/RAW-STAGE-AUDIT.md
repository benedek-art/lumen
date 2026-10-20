# RAW stage audit, A7 IV and GX85 (2026-10-20)

Scope: `Sources/LumenPipeline/AppleRawSource.swift` and the LumenCore code it calls.
Codex's open draft (benedek-art/lumen#10) rewrites the decode cache and materializer in
the same file; nothing here touches those lines.

## Who owns each step today

Lumen has no CFA reader. Every sensor-side step in the brief happens inside Apple's
`CIRAWFilter`, and the public API exposes none of them as a parameter.

| Step | Owner | Lumen control | Notes |
|---|---|---|---|
| ARW lossless LJPEG / RW2 unpack | Apple | none | |
| Per-channel black and white level | Apple | none | `shadowBias` is the only black-side knob, and it is a post-black offset, not a level |
| GX85 values stored above `white_level` | Apple | none | Clipping or rescaling is Apple's choice; Lumen cannot see the mosaic |
| Demosaic (zipper, maze, false colour) | Apple | `isDraftModeEnabled`, `moireReductionAmount`, `detailAmount` | Draft only for interactive frames. Moire and detail are left at Apple's per-camera defaults |
| Highlight reconstruction | Apple | `extendedDynamicRangeAmount = 1` keeps values above 1.0 | No public on/off for reconstruction |
| Camera matrix / profile | Apple | none | Apple's per-camera DB. No DCP, no dual-illuminant interpolation Lumen can audit |
| As-shot neutral | Apple, re-set by Lumen | `neutralTemperature`/`neutralTint` | Re-set on every decode; tested below |
| Baseline exposure | Apple | `baselineExposure` left default | Decides where Lumen's Exposure 0 sits relative to Lightroom's |
| Default crop, orientation | Apple | none needed | Corpus R-3/R-4 already check dimensions and orientation on real files |
| Lens corrections | Apple | `isLensCorrectionEnabled` = recipe `lens.profile` (default on) | Matches Lightroom's built-in Sony corrections |

What follows from that: matching Camera Raw on demosaic quality, per-channel levels or
GX85 over-white handling is not a change to `AppleRawSource`. It is a second decoder
(LibRaw or an in-tree CFA path behind the existing `ImageSource` protocol). That is a
project, not a night's fix, and nothing in this PR pretends otherwise.

## What this PR adds

1. The owner's two bodies in the CC0 corpus (`raw-corpus.yml` manifest): raw.pixls.us
   6929 (ILCE-7M4, 14-bit lossless compressed ARW) and 2545 (DMC-GX85, 12-bit RW2).
   Every existing invariant (decode-or-refuse, dimensions vs EXIF, orientation, preview
   correlation, non-blank, neutral patch, export reopen, metadata, decoder pin) now runs
   on them.
2. `RawDevelopDefaultsTests`, its own step in the corpus lane:
   - logs, per file, the four develop defaults Lumen never pins (`baselineExposure`,
     `shadowBias`, `moireReductionAmount`, `detailAmount`) plus the neutral as
     temperature/tint and as xy chromaticity;
   - measures the gain `baselineExposure` actually applies and the black shift
     `shadowBias` applies on the flat decode, plus per-channel maxima and the share of
     pixels at or above 1.0 and below 0;
   - asserts that re-setting the reported as-shot neutral as temperature/tint (what
     `AppleRawSource.decode` does on every call) moves no channel mean by more than 0.1%.

## Decisions waiting on the first run's numbers

- If the neutral identity fails on any file: stop re-asserting temperature/tint (the
  filter is private to the source and opens at the as-shot neutral), or re-assert
  `neutralChromaticity` instead.
- If `pctAnyAtOrAboveOne` is non-zero on unclipped frames, or the A7 IV's per-channel
  maxima sit well above 1.0: `PipelineRenderer.clippingStatistics` measures clipping
  against 1.0 (`RawStatistics.compute`'s default saturation), which then reports
  recoverable highlights as clipped. The fix is a per-file saturation level measured
  from the decode of a fully saturated input, not a guessed constant.
- If `shadowBias` is non-zero and shifts black: the flat decode is not linear through
  zero, which biases the RAW-truth crushed percentage and anything that assumes
  scene-linear black at 0. Pinning it to 0 is a look change and needs a before/after on
  the owner's high-ISO indoor frames first.
