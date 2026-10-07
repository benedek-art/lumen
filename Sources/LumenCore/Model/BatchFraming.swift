// BatchFraming.swift
// A crop, angle or ratio write over a multi-selection, computed per photograph.
//
// S-11 / KG-01. The crop is stored as fractions of the USABLE frame — the inscribed
// rectangle at the current straighten angle — so every write that changes its shape
// (carry it through an angle change, refit it to a ratio, turn it on its side) needs the
// photograph's own pixel dimensions. Every one of those writers took them from the
// PRIMARY selection and ran the same arithmetic on every target: on a landscape primary
// and a portrait second frame, a 0° → 5° straighten left the portrait's rectangle at
// 0.5675:1 where it had been 0.6667:1 — a 15 % aspect error on a photograph nobody
// touched, from the operation K-023 was closed to make safe, with its padlock still
// reading locked.
//
// The arithmetic is unchanged and already tested (`CropGeometry.reangled`, `refit`,
// `swappingOrientation`). What lives here is the rule for applying it to one target:
// against THAT target's frame, and not at all when its frame is unknown or cannot hold
// the requested shape. "Not at all" leaves the photograph exactly as it was — the
// conservative answer, since the alternative is computing its crop against some other
// photograph's frame, which is the defect.

import Foundation

public enum BatchFraming {

    /// A photograph's frame in pixels, the way up the picture is.
    public struct Frame: Equatable, Sendable {
        public var width: Double
        public var height: Double

        /// Nil for a frame the crop arithmetic cannot use.
        public init?(width: Double, height: Double) {
            guard width > 0, height > 0, width.isFinite, height.isFinite else { return nil }
            self.width = width
            self.height = height
        }
    }

    /// A frame from the catalog's metadata row: the stored pixel extent, turned on its
    /// side when the EXIF orientation says the picture is (5…8 are the four orientations
    /// that transpose). The stored extent is the sensor readout's, which is why a
    /// portrait exposure needs the turn — the same fact `FrameOrientation` reconciles for
    /// the primary selection from its delivered frame.
    public static func catalogFrame(width: Int?, height: Int?, exifOrientation: Int?) -> Frame? {
        guard let width, let height else { return nil }
        let transposed = (5...8).contains(exifOrientation ?? 1)
        return transposed
            ? Frame(width: Double(height), height: Double(width))
            : Frame(width: Double(width), height: Double(height))
    }

    /// A framing write that depends on the frame it lands on.
    public enum Edit: Equatable, Sendable {
        /// Set the straighten angle, carrying the crop through it (slider, rotate drag,
        /// ruler).
        case angle(Double)
        /// Refit the crop to a pixel ratio (ratio menu, custom ratio).
        case aspect(Double)
        /// Turn the crop between portrait and landscape.
        case swapOrientation
    }

    /// The geometry one target should hold after `edit`, computed against ITS frame —
    /// or nil, meaning leave this target untouched: its frame is unknown, or (for a
    /// ratio) it cannot hold the shape, which M12 established must be declined rather
    /// than written as some other ratio.
    public static func apply(_ edit: Edit, to geometry: Geometry, frame: Frame?) -> Geometry? {
        guard let frame else { return nil }
        var next = geometry
        switch edit {
        case .angle(let degrees):
            guard degrees.isFinite else { return nil }
            next.crop = CropGeometry.reangled(geometry.crop, sourceWidth: frame.width,
                                              sourceHeight: frame.height,
                                              from: geometry.angle, to: degrees)
            next.angle = degrees
        case .aspect(let ratio):
            guard CropGeometry.canHold(aspect: ratio, sourceWidth: frame.width,
                                       sourceHeight: frame.height,
                                       degrees: geometry.angle) else { return nil }
            next.crop = CropGeometry.refit(geometry.crop, aspect: ratio,
                                           sourceWidth: frame.width,
                                           sourceHeight: frame.height,
                                           degrees: geometry.angle)
        case .swapOrientation:
            guard let crop = CropGeometry.swapIfRepresentable(geometry.crop,
                sourceWidth: frame.width, sourceHeight: frame.height,
                degrees: geometry.angle) else { return nil }
            next.crop = crop
        }
        return next
    }
}
