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

## First run (RAW corpus run 39388911265, head cdf1d92)

A7 IV (6929) and GX85 (2545) pass every existing invariant: decode, dimensions
(7008x4672 and 4592x3448, no tile padding leaks), orientation, preview correlation
(r = 0.9956 and 0.9936), non-blank, neutral patch (chroma median 5.96 and 16.85, under
the 20 ceiling), export reopen, metadata, decoder pins (8 and 7). The lane's five
failures are the three already open on main and reported in benedek-art/lumen#10
(Nikon 5812 and GH5S 2607 neutral chroma 39.28 and 23.22, Leica 1087 all-black).

| File | baselineExposure (gain measured) | shadowBias (green shift if zeroed) | max R,G,B | % pixels ≥ 1.0 | % any channel < 0 | moire default |
|---|---|---|---|---|---|---|
| A7 IV 6929 | +0.30 (log2 gain 0.301) | 3 (+0.0032) | 2.8997 ×3 | 0.321 | 0.000 | 1.0 |
| GX85 2545 | +0.10 (0.100) | 3 (+0.0027) | 0.72, 0.68, 0.72 | 0.000 | 0.049 | 0.5 |
| EOS 5D 1346 | +0.25 (0.251) | 3 (+0.0032) | 1.16, 1.14, 1.12 | 0.319 | 9.061 | 0.0 |
| Z 30 5812 | +0.25 (0.251) | 3 (+0.0033) | 1.23, 1.25, 1.30 | 0.043 | 4.381 | 0.6 |
| GH5S 2607 | +0.35 (0.351) | 3 (+0.0029) | 2.9649 ×3 | 4.901 | 0.016 | 0.55 |
| OM-1 5283 | +0.40 (0.401) | 3 (+0.0030) | 2.7872 ×3 | 4.244 | 0.003 | 0.5 |

Conclusions:

- **As-shot neutral re-assertion is exact.** Worst channel-mean change across 14
  decodable files is 3e-6. No change needed; the test now guards it.
- **Baseline exposure is a pure gain.** It's applied exactly as reported (log2 of the
  measured gain matches to 0.004 EV). The A7 IV gets +0.30 from Apple, where Adobe's
  profile uses about +0.35, so Lumen at Exposure 0 sits about 0.05 EV under Camera Raw on
  this body. That's too small to justify a per-camera offset table.
- **Shadow bias is a black offset.** Zeroing it raises every file's green mean by
  0.002 to 0.006. On the owner's two bodies it puts at most 0.05% of pixels below
  zero. On the 5D and Z 30 the share is 9% and 4%, so the flat decode isn't linear
  through zero there. Pinning it to 0 changes the look of every render, so it waits for
  a before/after on high-ISO indoor frames.
- **CONFIRMED: the RAW-truth clip ceiling is wrong.** `PipelineRenderer.clippingStatistics`
  counts a sample as clipped at scene-linear 1.0, which is `RawStatistics.compute`'s
  default saturation. The decoder's real ceiling, where blown pixels sit with R = G = B,
  is about 2.9 on the A7 IV, 2.96 on the GH5S and 2.79 on the OM-1. So everything from
  1.0 up to the ceiling, about 1.5 EV of recoverable highlight, is reported as clipped.
  The 5D has no plateau at all (maxima 1.16, 1.14 and 1.12 per channel all differ) and
  is still reported as 0.32% clipped. The fix is to measure the file's own plateau, not
  to guess another constant. Not done in this PR: it changes a persisted measurement
  (`analyzer_rev`), and there was one CI cycle left before the deadline.

## Still open

1. RAW-truth clip ceiling. Detect the decoder's R = G = B plateau per file and pass it
   as `saturation` to `RawStatistics.compute`. Report 0% clipped when there's no plateau.
   Bump `RawStatistics.currentAnalyzerRevision`. Test it against 5D 1346 (must read 0%
   clipped) and A7 IV 6929 (must read the plateau share, not the ≥ 1.0 share).
2. `shadowBias = 0`, after a visual before/after on high-ISO frames.
3. Demosaic, levels and highlight reconstruction at Camera Raw quality need a decoder
   Lumen controls. That's a separate project.
