// PickSample.swift
// How big an eyedropper's sample window is, as a function of zoom.
//
// Every picker in the app averaged a 5x5 window of SOURCE pixels, whatever the zoom.
// At Fit in a 1512 pt window one screen point covers about seven source pixels of a
// 24 MP frame, so the window was smaller than one point: it averaged less than the
// photographer could aim at, and on an ISO 3200 grey card two clicks a pixel apart
// solved neutrals ±15 mired apart (docs/quality/lanes/WS-02/AUDIT.md §2).
//
// Lightroom's White Balance Selector averages a 5x5 grid of SCREEN pixels at 100% zoom
// or less, and 5x5 image pixels above 100%. That is the rule here, written as a radius
// (the samplers take `radius`, a window of `2r + 1`):
//
//     r = clamp(ceil((5·s − 1) / 2), 2, 31)      s = source pixels per device pixel
//
// so the window covers at least 5 device pixels at s > 1, is exactly 5x5 image pixels
// at s ≤ 1, and is capped at 63 px — a click on a 100 MP frame at a thumbnail-sized
// zoom still reads a patch, not a region. Measured at Fit on the corpus' ISO 3200
// frames the solved neutral then wanders 2.4–4.6 mired between adjacent clicks instead
// of 9–15 (SPEC.md B3).
//
// Pure arithmetic so the rule is tested on a machine with no viewer; the catcher in
// `ViewerOverlays` computes `s` from the drawn frame and passes the radius with the
// click.

import Foundation

public enum PickSample {

    /// The smallest radius any pick uses: 5x5, the window above 100% zoom.
    public static let minimumRadius = 2
    /// The largest: a 63 px window.
    public static let maximumRadius = 31

    /// The sample window's radius in source pixels for a pick taken at a zoom where one
    /// device pixel covers `s` source pixels. Non-finite or non-positive input — a
    /// frame that has not been measured yet — falls back to the 5x5 minimum.
    public static func radius(sourcePixelsPerDevicePixel s: Double) -> Int {
        guard s.isFinite, s > 0 else { return minimumRadius }
        let wanted = ((5 * s - 1) / 2).rounded(.up)
        // Clamped as a Double first, so a huge `s` cannot trap in the Int conversion.
        let clamped = Swift.min(Swift.max(wanted, Double(minimumRadius)),
                                Double(maximumRadius))
        return Int(clamped)
    }

    /// The side, in points, of the square the catcher draws under the pointer: the
    /// sample window `2r + 1` source pixels, expressed on screen. At s ≤ 1 that is
    /// `5 / s` device pixels — the five image pixels the window really covers — and at
    /// Fit it is about five device pixels, which is the point of the rule above.
    public static func indicatorSidePoints(radius: Int, sourcePixelsPerDevicePixel s: Double,
                                           backingScale: Double) -> Double {
        let side = Double(2 * Swift.max(radius, 0) + 1)
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        guard s.isFinite, s > 0 else { return side / scale }
        return side / s / scale
    }
}
