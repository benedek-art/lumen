// ExposureMatch.swift
// Match Total Exposures: Lightroom's batch fix for a sequence shot with the exposure
// triangle moving under it (auto ISO at an indoor game, a timelapse of an astro
// session through dusk, aperture priority across a stadium's patchy floodlights).
//
// The rule is Lightroom's and it is pure arithmetic on the capture metadata: the light
// a frame recorded is proportional to shutter × ISO ÷ f-number², so two frames that
// differ by one stop in that product get Exposure sliders one stop apart, and the
// reference frame's own slider is the anchor. No pixels are read, which is what makes
// it instant across eight hundred frames and also its limit: it equalizes what the
// camera DID, not what the scene was. A frame missing any of the three numbers is left
// alone rather than guessed at.

import Foundation

public enum ExposureMatch {

    /// The Exposure slider's range (docs/04): the result is clamped into it.
    public static let sliderRange: ClosedRange<Double> = -5...5

    /// log2 of the light a frame recorded, relative to 1 s at ISO 100 and f/1.
    /// Nil when any of the three is missing or not positive.
    public static func capturedStops(iso: Int?, shutterSeconds: Double?,
                                     aperture: Double?) -> Double? {
        guard let iso, iso > 0, let t = shutterSeconds, t > 0,
              let n = aperture, n > 0 else { return nil }
        return log2(t * Double(iso) / 100 / (n * n))
    }

    public static func capturedStops(_ metadata: PhotoMetadata) -> Double? {
        capturedStops(iso: metadata.iso, shutterSeconds: metadata.shutterSeconds,
                      aperture: metadata.aperture)
    }

    /// The Exposure slider value that makes `target` render as bright as the reference
    /// frame does at `referenceExposure`: a target that recorded one stop LESS light
    /// gets one stop MORE. Nil when either frame lacks the metadata.
    public static func matchedExposure(referenceExposure: Double,
                                       reference: PhotoMetadata,
                                       target: PhotoMetadata) -> Double? {
        guard let r = capturedStops(reference), let t = capturedStops(target) else {
            return nil
        }
        let value = referenceExposure + (r - t)
        // Rounded to the slider's 0.01 EV resolution so the number in the panel is the
        // number that was written.
        let rounded = (value * 100).rounded() / 100
        return Swift.min(Swift.max(rounded, sliderRange.lowerBound), sliderRange.upperBound)
    }
}
