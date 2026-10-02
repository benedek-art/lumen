# P20-corpus: the RAW corpus lane's remaining failures

Base: origin/claude/jolly-sagan-k7ch7z at cbe7c66. P18 (460fd83, null-extent refusal) is
on a separate branch and not in this base. My one code commit touches neither P18's hunk
in `AppleRawSource.decode` nor its `oracle` change. `AuditRawAccuracyTests` is touched by
both, in different functions, so the merge should be clean, but check it.

Evidence used: the full logs of runs 36812668902 (064525e) and 36807226195. I also
fetched 1087.DNG and 2767.IIQ (sha256 matches the manifest) and dumped their TIFF IFDs
with tifffile.

The orchestrator stopped the run with time left on the clock. One item is fixed. The
other three are diagnosed only.

## 1. RawCorpusTests:1749: 2767 (Phase One IIQ) decodes with a nil pin

Status: FIXED, commit 6cfd5a6. It was a Lumen defect; the test expectation was right.

- The audit step logs `unpinned corpus2767 decoded default= supported=None`. CIRAWFilter
  opens the file but selects no decoder: the identifier is empty and the supported list
  is `["None"]`.
- The file's IFD0 is an uncompressed 8-bit RGB 296x220 thumbnail (NewSubfileType 0). The
  lane's E, N, D and embedded-preview sizes are all exactly 296x220.
- So the "decode" is ImageIO's thumbnail, and Lumen accepted it as a scene-referred RAW.
  A user would edit and export it as the photograph.
- Fix: `AppleRawSource.init` now throws `.undecodable` unless
  `RawParams.selectsRawDecoder(filter.decoderVersion.rawValue)` (a new LumenCore
  predicate: the identifier carries a decoder number). That is the existing refusal,
  which the loupe already labels and backs with the embedded preview.
- The same rule refuses 1116, 3949, 6001 and the two negatives at open; before, they were
  refused at decode.
- `AuditRawAccuracyTests` (unpinned, native-dimensions, pins) now asserts that refusal
  with `XCTAssertThrowsError` and reports `refused-no-decoder`. Without this, the throw
  would have fallen into `eachFixture`'s catch.

Red/green: `RawDecoderNumberTests.testOnlyANumberedDecoderIsARawDecode` (Linux).
- Predicate set to `true` and the guard set to `guard true`: 4 failures.
- Restored: 4/4 pass.
- The macOS half is source-verified. 2767 now sets `p.openFailure`; the R-2 tests count
  that as refused, and R-11 skips it.

Build clean. `check-swift-surface.py` exits 0.

Proof records that move: none.

## 2. RawCorpusTests:1439: neutral patch on 5812 (39.3) and 2607 (24.2)

Status: NOT-FIXED, undetermined. I did not touch the limit of 20.

What the evidence says:
- Both renders match the camera's own embedded preview structurally: r = 0.9949 (5812)
  and 0.9941 (2607).
- Median chroma is 49.2 and 35.7.
- 5812 is ISO 1800 with mean luma 0.13 and 38% of the frame near black, so a low-light
  scene with no neutral surface is plausible. That is an argument, not a measurement.

The measurement that would decide it: compute the same 16x16 minimum-chroma statistic on
the embedded preview (the camera's own rendering), and log it beside Lumen's.
- If the camera JPEG's most neutral block is about as chromatic, the expectation is wrong
  for these scenes.
- If the JPEG is neutral where Lumen is not, it is a cast and a Lumen defect.

This is a test-only change in `correlateWithEmbeddedPreview`. I did not start it.

## 3. RawCorpusTests:1391: Leica Monochrom DNG (1087) renders black

Status: NOT-FIXED, diagnosed but unverified. Nothing is committed for it.

The decode is not black:
- Lumen's decode matches an independent CIRAWFilter (`raw-pixel-check: default corpus1087
  samples=613120 maxAbsolute=0.000117`).
- That maximum error is half a half-float ULP for values in [0.25, 0.5). For an all-zero
  frame it would be 0.
- The corpus test also reads the decode as finite (0 of 2805760 samples non-finite).

So the delivered frame (mean 0, 100% of pixels within 1/255 of black) is made black
inside Lumen's graph, after the decode. It is a Lumen defect.

What is unusual about this file:
- The raw SubIFD is LinearRaw (34892), SamplesPerPixel 1, WhiteLevel 3750.
- There is no ColorMatrix, AsShotNeutral or CalibrationIlluminant anywhere.
- So `CIRAWFilter.neutralTemperature` / `neutralTint` (Lumen's `asShotTemperature` /
  `asShotTint`) have no defined value for this file.

Prime suspect: a non-finite as-shot neutral. `Num.clamp` passes NaN through
(`Swift.max(NaN, lo)` returns NaN). That makes `WhiteBalanceEngine.init` build a NaN
adaptation matrix, because the `aK == tK` identity test fails on NaN. The S6 matrix is
then NaN in both renderers (the GPU `applyMatrix`, and the reference `plan.linear`), and
an 8-bit render of NaN comes out black.

Proposed fix, not yet made:
- Sanitise a non-finite or non-positive as-shot neutral to the rendered-file reference
  (5500 K, tint 0) in LumenCore `WhiteBalanceEngine`/`RenderPlan`. That is Linux-testable
  and fixes both renderers.
- Keep passing Apple's own value back to the filter in `decode`, so the decode itself does
  not change.
- Add one corpus diagnostic line logging `asShotTemperature`/`asShotTint` and the decode's
  per-channel mean, to confirm this on the next run.

If the neutral turns out to be finite, the next suspect is an exactly achromatic input
reaching a 0/0 somewhere in S3–S15. I found none by reading the denoise kernels.

## 4. The audit step reports 1116 as "decoded" while the corpus step logs N=0x0

Status: NOT-A-DEFECT in Lumen; the audit verdict was misleading. It is superseded by
item 1's refusal.

- In both runs, `native-dimensions` prints `decoded versions=` (an empty decoder
  identifier) for 1116 and also for 6001 and 3949.
- In the same process, the other tests report 6001 and 3949 as `refused-at-decode`.
- The verdict string starts as "decoded". It changes only when a decode returns nil, and
  it never says whether the loop's assertions ran on a usable frame. So "decoded" is not
  evidence that anything decoded. The step still reported 0 failures, which I cannot
  reconcile with `XCTAssertGreaterThan(longEdge, 0)` from the logs alone.
- After 6cfd5a6, all four no-decoder files return `refused-no-decoder` before that loop,
  and the throw is asserted. The contradiction can no longer produce a verdict.

## DECISIONS

- A file CIRAWFilter opens with no RAW decoder (IIQ P65+, X3F, GPR, X-H2 RAF on that
  runner) is now refused at open. The loupe shows the embedded preview, labelled "this
  file could not be decoded", instead of the 296 px thumbnail as an editable photograph.
  The alternative is to route such files through `RenderedImageSource`, editing the
  thumbnail as a rendered file. That is an owner call.

## FOUND-WHILE-FIXING

- `Num.clamp` propagates NaN, and every clamp-as-sanitiser in LumenCore inherits that
  (item 3).
- Running item 3's diagnostic needs a lane run, and I may not push.
