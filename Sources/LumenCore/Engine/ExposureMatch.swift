// ExposureMatch.swift
// Match Total Exposures (Lightroom's Settings > Match Total Exposures): set each
// selected frame's Exposure slider so that what the camera captured plus what the
// slider adds comes out the same as on the reference frame.
//
// The camera's share is read from the capture settings alone. Image brightness for a
// fixed scene is proportional to t · ISO / N², so in stops
//
//     captured = log2(t · ISO / 100 / N²)
//     total    = captured + exposure slider
//
// and matching a frame to the reference is `exposure = ref.exposure + ref.captured −
// frame.captured`. A frame shot one stop brighter (twice the shutter, or one stop more
// ISO) gets one stop less on the slider. Nothing here looks at pixels: a burst across
// shade and sun in auto-ISO is NOT evened out by this, and is not meant to be — the
// scene really did change. What it evens out is the camera changing its mind.
//
// Pure arithmetic, so it lives here and is tested on Linux; the app reads the EXIF and
// writes the sliders (`AppState+MatchExposure.swift`).

import Foundation

public enum ExposureMatch {

    /// The three capture settings the match needs, as the file states them.
    public struct Capture: Equatable, Sendable {
        public var shutterSeconds: Double?
        public var aperture: Double?
        public var iso: Int?

        public init(shutterSeconds: Double? = nil, aperture: Double? = nil, iso: Int? = nil) {
            self.shutterSeconds = shutterSeconds
            self.aperture = aperture
            self.iso = iso
        }

        public init(metadata: PhotoMetadata) {
            self.init(shutterSeconds: metadata.shutterSeconds,
                      aperture: metadata.aperture, iso: metadata.iso)
        }

        /// Only positive, finite values count. EXIF writes 0 for "unknown" often enough
        /// (an adapted manual lens reports FNumber 0) that zero must read as absent.
        var shutter: Double? { Self.usable(shutterSeconds) }
        var fNumber: Double? { Self.usable(aperture) }
        var isoValue: Double? { Self.usable(iso.map(Double.init)) }

        private static func usable(_ value: Double?) -> Double? {
            guard let value, value.isFinite, value > 0 else { return nil }
            return value
        }
    }

    /// The camera's contribution in stops, relative to 1 s at f/1 and ISO 100, or nil
    /// when shutter, aperture or ISO is missing. Higher is a brighter capture.
    public static func capturedStops(_ capture: Capture) -> Double? {
        guard let t = capture.shutter, let n = capture.fNumber, let iso = capture.isoValue
        else { return nil }
        return log2(t * iso / 100 / (n * n))
    }

    /// The stops `frame` was captured brighter than `reference`, or nil when the two
    /// cannot be compared.
    ///
    /// One allowance: an aperture missing on BOTH frames is taken to be the same
    /// aperture. A manual lens records none, and an astro session on one is the common
    /// case — every frame through the same glass at the same ring setting. Missing on
    /// only one side is still unknown, because then the frames came through different
    /// lenses or settings and nothing says how far apart.
    public static func stopsBrighter(_ frame: Capture, than reference: Capture) -> Double? {
        guard let t = frame.shutter, let iso = frame.isoValue,
              let refT = reference.shutter, let refISO = reference.isoValue
        else { return nil }
        var stops = log2(t / refT) + log2(iso / refISO)
        switch (frame.fNumber, reference.fNumber) {
        case let (n?, refN?): stops += 2 * log2(refN / n)
        case (nil, nil): break
        default: return nil
        }
        return stops
    }

    /// What happened to one frame.
    public enum Outcome: Equatable, Sendable {
        /// The reference itself: left alone, everything else is measured against it.
        case reference
        /// The new slider value. `clamped` is true when the match needed more than the
        /// slider allows, so this frame still differs from the reference.
        case set(exposure: Double, clamped: Bool)
        /// Shutter, aperture or ISO missing; the slider is left alone.
        case skipped
    }

    /// One selected frame going in: its capture settings and its current slider.
    public struct Frame<ID: Hashable & Sendable>: Sendable {
        public var id: ID
        public var capture: Capture
        public var exposure: Double

        public init(id: ID, capture: Capture, exposure: Double) {
            self.id = id
            self.capture = capture
            self.exposure = exposure
        }
    }

    /// The whole command's answer.
    public struct Plan<ID: Hashable & Sendable>: Sendable {
        /// Nil when the reference itself lacks the metadata, in which case nothing can
        /// be matched and every frame is left alone.
        public var outcomes: [ID: Outcome]?

        /// The slider values to write, frames that need no change included.
        public var exposures: [ID: Double] {
            var out: [ID: Double] = [:]
            for (id, outcome) in outcomes ?? [:] {
                if case let .set(exposure, _) = outcome { out[id] = exposure }
            }
            return out
        }

        public var matchedCount: Int { exposures.count }
        public var skippedCount: Int {
            (outcomes ?? [:]).values.filter { $0 == .skipped }.count
        }
        public var clampedCount: Int {
            (outcomes ?? [:]).values.filter {
                if case .set(_, true) = $0 { return true } else { return false }
            }.count
        }
    }

    /// Lightroom's Exposure slider range, which is Develop's (`Tone`'s −5…+5).
    public static let sliderRange: ClosedRange<Double> = -5...5

    /// Match every frame to the one whose id is `referenceID`.
    ///
    /// Values are rounded to a hundredth of a stop, the precision the slider shows, so
    /// 1/250 against 1/500 lands on exactly −1.00 rather than −0.9999999.
    public static func plan<ID>(referenceID: ID, frames: [Frame<ID>],
                                range: ClosedRange<Double> = sliderRange) -> Plan<ID> {
        guard let reference = frames.first(where: { $0.id == referenceID }) else {
            return Plan(outcomes: nil)
        }
        // The reference needs its own settings too; with none, there is no total to
        // match anything to. Aperture alone may be absent (see `stopsBrighter`).
        guard reference.capture.shutter != nil, reference.capture.isoValue != nil else {
            return Plan(outcomes: nil)
        }
        var outcomes: [ID: Outcome] = [:]
        for frame in frames {
            if frame.id == referenceID {
                outcomes[frame.id] = .reference
                continue
            }
            guard let brighter = stopsBrighter(frame.capture, than: reference.capture) else {
                outcomes[frame.id] = .skipped
                continue
            }
            let wanted = ((reference.exposure - brighter) * 100).rounded() / 100
            let clampedValue = min(max(wanted, range.lowerBound), range.upperBound)
            outcomes[frame.id] = .set(exposure: clampedValue, clamped: clampedValue != wanted)
        }
        return Plan(outcomes: outcomes)
    }

    /// The status-bar line for a finished plan. `referenceName` is the reference's
    /// filename, so the photographer can see which frame everything was matched to.
    public static func summary<ID>(_ plan: Plan<ID>, referenceName: String) -> String {
        guard plan.outcomes != nil else {
            return "\(referenceName) has no shutter speed or ISO recorded — "
                + "nothing to match exposures to"
        }
        let matched = plan.matchedCount
        guard matched > 0 else {
            return "No frame could be matched — none records shutter, aperture and ISO"
        }
        var text = "Matched \(matched) photo" + (matched == 1 ? "" : "s")
            + " to \(referenceName)"
        let skipped = plan.skippedCount
        if skipped > 0 {
            text += " — \(skipped) skipped (no shutter, aperture or ISO)"
        }
        let clamped = plan.clampedCount
        if clamped > 0 {
            text += " — \(clamped) at the slider's limit"
        }
        return text
    }
}
