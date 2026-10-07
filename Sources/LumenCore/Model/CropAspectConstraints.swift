import Foundation

extension CropGeometry {
    /// Continuous pixel-aspect domain of a crop whose two normalized edges both
    /// remain in `minimumCropFraction...1`. This is source- and straighten-aware;
    /// the text parser's domain is deliberately a different constraint.
    public static func representableAspectRange(sourceWidth: Double, sourceHeight: Double,
                                                degrees: Double) -> ClosedRange<Double>? {
        guard sourceWidth.isFinite, sourceHeight.isFinite, degrees.isFinite,
              sourceWidth > 0, sourceHeight > 0 else { return nil }
        let size = usableSize(width: sourceWidth, height: sourceHeight, degrees: degrees)
        return aspectRange(frameAspect: size.width / size.height)
    }

    private static func aspectRange(frameAspect: Double) -> ClosedRange<Double>? {
        let lower = frameAspect * minimumCropFraction
        let upper = frameAspect / minimumCropFraction
        guard lower.isFinite, upper.isFinite, lower > 0, upper >= lower else { return nil }
        return lower...upper
    }

    /// Checked entry points for NEW UI requests. The legacy geometry functions keep
    /// interpreting existing recipes exactly as before, including their extent floor.
    public static func refitIfRepresentable(_ crop: Crop, aspect: Double,
                                           sourceWidth: Double, sourceHeight: Double,
                                           degrees: Double) -> Crop? {
        guard aspect.isFinite,
              let range = representableAspectRange(sourceWidth: sourceWidth,
                  sourceHeight: sourceHeight, degrees: degrees), range.contains(aspect)
        else { return nil }
        return refit(crop, aspect: aspect, sourceWidth: sourceWidth,
                     sourceHeight: sourceHeight, degrees: degrees)
    }

    public static func swapIfRepresentable(_ crop: Crop, sourceWidth: Double,
                                          sourceHeight: Double, degrees: Double) -> Crop? {
        guard let range = representableAspectRange(sourceWidth: sourceWidth,
                  sourceHeight: sourceHeight, degrees: degrees),
              let aspect = displayedAspect(crop, sourceWidth: sourceWidth,
                  sourceHeight: sourceHeight, degrees: degrees), range.contains(1 / aspect)
        else { return nil }
        return swappingOrientation(crop, sourceWidth: sourceWidth,
                                   sourceHeight: sourceHeight, degrees: degrees)
    }

    /// Read-only session eligibility. Source changes, straightening, undo, and old
    /// invalid locks must never force a different crop merely because the UI reads it.
    public static func effectiveLockedAspect(_ requested: Double?, crop: Crop,
                                            frameAspect: Double) -> Double? {
        guard let requested, requested.isFinite,
              let range = aspectRange(frameAspect: frameAspect), range.contains(requested)
        else { return nil }
        let actual = normalized(crop)
        let aspect = actual.w / actual.h * frameAspect
        guard abs(aspect - requested) <= requested * 1e-9 else { return nil }
        return requested
    }
}
