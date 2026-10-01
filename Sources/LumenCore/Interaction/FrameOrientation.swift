// FrameOrientation.swift
// Whether the size a photograph REPORTS and the frame the renderer DELIVERS agree
// about which way up the picture is.
//
// The owner, opening the crop tool on a vertical photograph: "it's stretching my entire
// image out into a horizontal landscape photo, not a vertical photo like it is, as well
// as the whole crop tool is kind of broken in a sense where this is happening."
//
// The mechanism. Every overlay that has to place something in the PHOTOGRAPH's
// coordinates — the crop rectangle, the mask handles, the eyedropper — is laid out
// against `AppState.primaryFrameSize`, which comes from the source's reported native
// pixel size. A camera sensor is landscape; a portrait exposure is a landscape sensor
// readout plus an EXIF orientation of 6 or 8. The DECODED image has that orientation
// applied (the non-RAW path says so explicitly, `.applyOrientationProperty: true`), so
// the delivered frame is portrait while the reported size is landscape. The crop canvas
// then sizes its plate from the reported size and draws the portrait picture into a
// landscape rectangle — which is the stretch, exactly.
//
// This file does NOT guess which layer is wrong, because that guess cannot be checked
// on a machine that compiles neither the pipeline nor the app. It reconciles against
// GROUND TRUTH instead: the frame the renderer actually delivered is what is on screen,
// so if the reported size disagrees with it about portrait-versus-landscape, the
// reported size is the one that gets transposed. Where the two already agree — which is
// every landscape photograph, and every photograph at all if the source is ever fixed
// to report an oriented size — every function here is the identity, so the reconciliation
// can never introduce the defect it exists to remove.
//
// The one thing it must not do is read a CROP as a rotation. Cropping a landscape frame
// to a vertical strip legitimately delivers a portrait frame from a landscape source, and
// transposing on that would be the same defect wearing the other hat. So the comparison
// is only ever offered a delivery the caller knows is the WHOLE frame — the crop tool
// renders uncropped by construction (`showingUncropped`), which is why the answer is
// learned there and then remembered for the photograph.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum FrameOrientation {

    /// Whether `reported` is the same frame as `delivered` seen sideways.
    ///
    /// True only when the two disagree about which axis is longer AND transposing
    /// resolves the disagreement — a squarer-than-either mismatch is a different
    /// problem and answers false rather than making the picture worse.
    ///
    /// `delivered` MUST be a whole-frame delivery. See the header: a crop can turn a
    /// landscape frame portrait honestly, and this cannot tell that from a rotation.
    public static func isTransposed(reported: CGSize, delivered: CGSize) -> Bool {
        let rw = Double(reported.width), rh = Double(reported.height)
        let dw = Double(delivered.width), dh = Double(delivered.height)
        guard rw > 0, rh > 0, dw > 0, dh > 0,
              rw.isFinite, rh.isFinite, dw.isFinite, dh.isFinite else { return false }
        guard (rw > rh) != (dw > dh) else { return false }
        // A frame this close to square is the same either way round: transposing it
        // moves the plate by less than `squareTolerance` and the answer would be a coin
        // flip dressed as a decision. An exact square is the limiting case of the same
        // argument, so one guard covers both.
        let reportedAspect = rw / rh
        guard abs(log(reportedAspect)) > log(squareTolerance) else { return false }
        // …and transposing has to actually help. `|log(a/b)|` rather than a ratio so
        // the comparison is symmetric: 3:2 against 2:3 must be the same distance
        // whichever is named first.
        let deliveredAspect = dw / dh
        let asIs = abs(log(reportedAspect / deliveredAspect))
        let swapped = abs(log((rh / rw) / deliveredAspect))
        return swapped < asIs
    }

    /// How far from square a reported frame must be before its orientation is a fact
    /// worth acting on. 5% — below that, turning the plate sideways changes what is
    /// drawn by less than the rounding already in the layout, so the reconciliation
    /// would be noise with a sign.
    public static let squareTolerance: Double = 1.05

    /// `reported`, turned the way the delivered frame says the photograph is.
    public static func transposed(_ size: CGSize) -> CGSize {
        CGSize(width: size.height, height: size.width)
    }

    /// The source frame an overlay should lay itself out against: `reported`, transposed
    /// if `transposed` says so. The one call site shape, so no consumer has to remember
    /// which way round the swap goes.
    public static func sourceSize(reported: CGSize, transposed flag: Bool) -> CGSize {
        flag ? transposed(reported) : reported
    }

    /// Whether a delivery made under `geometry` is the whole photograph, so its extent
    /// may be compared with the reported size. `cropToolLive` strips the crop AND the
    /// angle from the render; otherwise an identity crop with no straighten is the same
    /// guarantee. A flip does not change the extent's shape.
    public static func deliversWholeFrame(_ geometry: Geometry, cropToolLive: Bool) -> Bool {
        cropToolLive || (geometry.crop == Crop() && geometry.angle == 0)
    }

    /// The reconciliation, remembered PER PHOTOGRAPH (KG-03).
    ///
    /// It used to be one flag on `AppState`, reset to false on every selection change
    /// and learned only from a whole-frame delivery. A portrait exposure whose recipe
    /// already carries a crop or an angle never delivers a whole frame outside the crop
    /// tool, so the flag sat at false for the whole visit: the overlays, the mask
    /// conversions, the eyedropper and the crop arithmetic of every framing write were
    /// laid out against the landscape sensor while the renderer and export — which take
    /// the decoded, oriented extent — drew the portrait picture. Opening the crop tool
    /// repaired it until the next selection change threw the answer away.
    ///
    /// Two kinds of evidence, neither of which a crop can confuse:
    /// - a WHOLE-FRAME delivery (ground truth: it is what is on screen), and
    /// - the catalog's frame — the stored extent turned by the EXIF orientation, the
    ///   same `BatchFraming.catalogFrame` every non-primary target of a framing write is
    ///   computed against — which describes the whole photograph by construction.
    /// A delivery outranks the catalog (a stale row cannot overrule the screen); a
    /// cropped delivery is never evidence and leaves whatever is known untouched.
    public struct Memory: Equatable, Sendable {

        private enum Evidence: Equatable, Sendable {
            case catalog(Bool)
            case delivery(Bool)

            var transposed: Bool {
                switch self { case .catalog(let t), .delivery(let t): return t }
            }
        }

        private var answers: [URL: Evidence] = [:]

        public init() {}

        /// What is known about `url`: nil when nothing has answered yet.
        public func transposed(for url: URL) -> Bool? { answers[url]?.transposed }

        /// The frame an overlay or a framing write should place itself against for
        /// `url`. With no answer this is `reported` unchanged — the old default — so a
        /// photograph nothing has spoken for takes exactly the path it always took.
        public func sourceSize(for url: URL, reported: CGSize) -> CGSize {
            FrameOrientation.sourceSize(reported: reported,
                                        transposed: transposed(for: url) ?? false)
        }

        /// Offer a delivery. Admissible only when `wholeFrame`; returns whether the
        /// remembered answer changed.
        @discardableResult
        public mutating func learn(_ url: URL, reported: CGSize, delivered: CGSize,
                                   wholeFrame: Bool) -> Bool {
            guard wholeFrame, Self.usable(reported), Self.usable(delivered) else {
                return false
            }
            let next = Evidence.delivery(FrameOrientation.isTransposed(reported: reported,
                                                                       delivered: delivered))
            guard answers[url] != next else { return false }
            let changed = answers[url]?.transposed != next.transposed
            answers[url] = next
            return changed
        }

        /// Offer the catalog's frame for `url` (stored extent turned by EXIF). It never
        /// overrules a delivery; returns whether the remembered answer changed.
        @discardableResult
        public mutating func learn(_ url: URL, reported: CGSize,
                                   catalog: BatchFraming.Frame) -> Bool {
            if case .delivery = answers[url] { return false }
            guard Self.usable(reported) else { return false }
            let frame = CGSize(width: catalog.width, height: catalog.height)
            let next = Evidence.catalog(FrameOrientation.isTransposed(reported: reported,
                                                                      delivered: frame))
            let changed = answers[url]?.transposed != next.transposed
            answers[url] = next
            return changed
        }

        private static func usable(_ size: CGSize) -> Bool {
            size.width > 0 && size.height > 0
                && Double(size.width).isFinite && Double(size.height).isFinite
        }
    }
}
