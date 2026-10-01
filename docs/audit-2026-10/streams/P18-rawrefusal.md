# P18-rawrefusal: the RAW corpus lane's two R-2 failures

## RC-1: a RAW decode with a null extent reached the graph instead of being refused

Status: FIXED. The fix and this report are one commit, the one that adds this file.

Symptom. The RAW corpus lane (raw-corpus.yml, step "Every invariant, against sixteen
real photographs") failed on 064525e in these two places:
- `RawCorpusTests.swift:1618` `testATruncatedFileIsRefusedRatherThanHalfDecoded`: the
  stub decoded to `(inf, inf, 0.0, 0.0)`.
- `RawCorpusTests.swift:1177` `testEveryFileEitherDecodesCleanlyOrRefusesCleanly`:
  1116 (Sigma DP1 X3F) and the stub both delivered an image with an unusable extent.

Mechanism. `CIRAWFilter(imageURL:)` opens both files. The lane logs `N=0x0 pin=-` for
them, so `nativeSize` is zero and `decoderVersion` is empty. Then
`CIRAWFilter.outputImage` returns a non-nil `CIImage` whose `extent` is `CGRect.null`,
which prints as (inf, inf, 0, 0). `AppleRawSource.decode` only checked
`guard let image`. `DecodeMaterializer.materialize` returns nil for it because the
width is under 1, and the non-RAW9 path falls back to the lazy image
(`materialized(image) ?? (image: image, bytes: 0)`). The image is then cached and
returned.

Root cause and when it started. This is not a regression from this run's P8
(6851514, 028f754) or from PR #5's 1965507. The lane shows these exact failures on
every run that got as far as the tests:
- 33702431552 (2026-09-03, claude/photo-editor-design-plan-8ahzmm): 1618 and 1177 for
  1116 and the stub.
- 33811293152 (2026-09-03, main, #3): the same.
- 36807226195 (2026-10-01, df372c0 merge): the same.
- 36812668902 (2026-10-01, 064525e): the same.

The September 22 commit 1965507 falls between these runs and changed nothing about
them. The lane did run before October, but only when raw-corpus.yml itself changed, so
it never ran on 1965507 or on P8's code. It has never been green: the first run on
2026-09-02 was a workflow problem with 0 tests executed, and every run since has these
failures. The defect itself is decode accepting any non-nil `outputImage`. It is
already present in 68d9983 (2026-08-20, `let image = filter.outputImage`), the oldest
commit in this shallow clone, so it most likely goes back to the first
`AppleRawSource`.

Fix.
- LumenCore `RawDecodeAcceptance.accepts(extent: CGRect, nativeSize: CGSize) -> Bool`
  (`Sources/LumenCore/Image/RawDecodeAcceptance.swift`) returns false in these cases:
  - the extent is `isNull`, `isInfinite`, or has any non-finite component;
  - the extent is under 1 px on either side;
  - the native size is zero or non-finite.
- `AppleRawSource.decode` calls it right after the nil check, using
  `originalNativeSize` (captured at open from `CIRAWFilter.nativeSize`). On rejection
  it returns nil, which is the existing R-2 refusal. Nothing is cached, so a cache hit
  cannot return a refused decode.
- `AuditRawAccuracyTests.oracle` (the independent platform decode) applies the same
  rule, with `nativeSize` read before any scaled decode. Without this, 1116 would have
  started failing the audit step with "Lumen refused a decode Apple's filter makes",
  because the oracle counted a null-extent `outputImage` as an image.

Red/green evidence (Linux, `RawDecodeAcceptanceTests`, 5 tests):
- Predicate replaced with `return true` (the old nil-only acceptance): 19 failures
  across 3 tests.
- The guard call removed from AppleRawSource: 1 failure, from the comment-stripped
  source scan.
- Restored: 5/5 pass. `RawDecodeAcceptanceTests` and `RawDecoderNumberTests` together
  pass 10/10.

The macOS integration check is the two corpus tests above. This is source-verified
only: 1116 and the stub now set `p.decodeReturnedNil`, and both tests count that as
refused. That is the same path 6001, 3949 and the truncated file already take.

`swift build --build-tests` is clean, and `check-swift-surface.py` exits 0.

Proof records that move: none. Every file that decodes on the lane has a nonzero
native size and a finite extent (the smallest is IIQ 2767 at 296 x 220), so none of
them is newly refused.

## DECISIONS

None. Refusing a null-extent decode is what the R-2 contract already says.

## FOUND-WHILE-FIXING (not touched; same lane, same runs, all present since 2026-09-03)

- `RawCorpusTests.swift:1749` `testTheDecoderVersionPinIsPresentAndStable`: 2767
  (Phase One IIQ) decodes but `pinnedDecoderVersion` is nil, because the default
  decoder's `rawValue` contains no digits.
- `RawCorpusTests.swift:1439` `testTheMostNeutralPatchInEachFrameIsNeutral`: 5812
  (Nikon Z 30) measures 39.3 and 2607 (GH5S) measures 24.2, against a limit of 20.
- `RawCorpusTests.swift:1391` `testTheRenderIsNeitherBlankNorPoisoned`: 1087 (Leica M
  Monochrom DNG) renders with mean luminance 0. The log shows `mean=0.0000 p95=0.0000`.
  The monochrome DNG decodes to black.
- Unexplained: in the audit step of run 36812668902,
  `testNativeDimensionsDoNotDependOnDecoderScaleDraftOrCache` reported 1116 as
  "decoded" with 0 failures, even though it asserts a native long edge above 0, and the
  corpus step logs 1116 as `N=0x0`. This needs a look on macOS. With this fix, Lumen
  and the oracle both refuse it, whichever way that turns out.

So the lane stays red after this fix, but only on these other items.
