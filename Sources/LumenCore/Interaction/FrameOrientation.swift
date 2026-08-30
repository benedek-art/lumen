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
}
