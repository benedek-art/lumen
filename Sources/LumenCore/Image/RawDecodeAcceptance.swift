// RawDecodeAcceptance.swift
// Whether what a RAW decoder handed back is a picture, or a refusal it did not say.
//
// R-2 says a file lands in exactly one of two states: refused, or an image with a
// finite, non-empty extent. `CIRAWFilter` has a third answer it gives without being
// asked: on a file it cannot really read (the corpus's Sigma X3F, a 512-byte stub of
// a CR2 header) `init(imageURL:)` succeeds with `nativeSize` 0 x 0, and `outputImage`
// is NOT nil — it is an image whose extent is `CGRect.null`, printed as
// (inf, inf, 0, 0). `AppleRawSource.decode` only checked for nil, so that image went to
// the graph, which is how an allocation of infinite size starts.
//
// The rule lives here, pure, so a lane without a Mac can run it; `AppleRawSource`
// calls it on every decode it would otherwise cache and return.

import Foundation

public enum RawDecodeAcceptance {

    /// True only for a decode that can be a picture: a finite extent at least one pixel
    /// on each side, from a source that knows its own size. Anything else must be
    /// refused through the decode's existing nil path, never passed on.
    ///
    /// - `extent`: the decoded image's extent (`CIImage.extent`). `CGRect.null`,
    ///   `CGRect.infinite`, any non-finite component and anything under one pixel on
    ///   either side are rejected.
    /// - `nativeSize`: the source's native size as captured at open
    ///   (`CIRAWFilter.nativeSize`). Zero or non-finite means the decoder did not
    ///   understand the file, whatever `outputImage` returned.
    public static func accepts(extent: CGRect, nativeSize: CGSize) -> Bool {
        guard !extent.isNull, !extent.isInfinite,
              extent.origin.x.isFinite, extent.origin.y.isFinite,
              extent.size.width.isFinite, extent.size.height.isFinite,
              extent.size.width >= 1, extent.size.height >= 1
        else { return false }
        return nativeSize.width.isFinite && nativeSize.height.isFinite
            && nativeSize.width >= 1 && nativeSize.height >= 1
    }
}
