// MaskHandles.swift
// Which part of a mask a press picks up: the rule that decides whether a drag on the
// photograph MOVES the shape already drawn, RESIZES it, or throws it away and draws a
// new one in its place.
//
// Why this exists. The owner, on the radial: "if I use the radial dial and I trace
// something out, I can only move the circle when I press the complete center, and if I
// go even a tiny bit out of that center dot, then I have to redraw it, which is weird.
// I can't just move it around all the time."
//
// That is an exact description of what `MaskCanvas.radialHandle` computed. It measured
// the press against three drawn dots — the centre, the +major end, the +minor end —
// each with a 9 pt grab radius, and returned handle 3 for EVERYTHING else. Handle 3 is
// the branch that rewrites `center` and `radii` from the drag's own start and end. So
// the move target of a radial was one 9 pt disc — 254 pt² of a 1600×1100 preview,
// 0.014% of the canvas. The two resize targets were two more discs of the same size, so
// all three affordances together covered 0.043% of the picture and the remaining 99.96%
// destroyed the ellipse and started over. There was no way to take hold of the rim the
// eye is actually looking at.
//
// It is worse than "you have to redraw it", because the redraw branch does not need a
// drag to fire. A press with no travel writes `radii = [radius(0), radius(0)]`, and
// `radius` clamps to 0.002 — so a single CLICK anywhere but those three dots replaced
// the mask with a shape two thousandths of the frame across, which on screen reads as
// the mask disappearing. The gradient's identically-shaped `lineHandle` escaped that
// only by accident: its caller refuses to commit a line whose two endpoints coincide,
// so the same click there is a no-op. Nothing refused a collapsed ellipse.
//
// The grammar this file replaces it with is the one every editor has agreed on for
// thirty years, and its first rule is the one the defect broke: THE INSIDE OF A SHAPE
// MOVES IT. The rim resizes it — the whole rim, not two dots sitting on it. A press has
// to land clear of the shape, by more than the width of a plausible miss, before it is
// allowed to mean "forget that one and start again". Everything in between is a move,
// because a move is the one answer that cannot lose work: the shape is still there,
// and a wrong move costs one ⌘Z that undoes a translation instead of an erasure.
//
// This lives in LumenCore rather than inline in the view for the reason every rule in
// this directory does — `MaskCanvas` sits in a target with no tests, and hit-testing
// arithmetic is exactly the kind that is wrong in a way nobody notices until a
// photograph's worth of masking is gone.
//
// THE UNIT SPACE IS VIEW POINTS: the geometry as the canvas has already drawn it, after
// the crop, the straighten and the flip. That is the only space in which "close enough
// to grab" means anything — 11 pt of source-normalized fraction is a different distance
// on screen at every zoom level and every crop, and the screen is what the hand is
// aiming at. It also means nothing here has to know what a crop is.
//
// And it is why the ellipse arrives as three POINTS — centre, the end of the major
// axis, the end of the minor axis — rather than as centre/radii/rotation. The map from
// source-normalized coordinates to view points is affine (a per-axis scale for the crop,
// a rotation for the straighten, a sign flip), and the image of an ellipse under an
// affine map is an ellipse whose axes are the images of the original axes. So those
// three points — which the canvas already computes in order to draw the handles — carry
// the whole projected shape exactly, including the fact that a rotated ellipse on a
// non-square crop is no longer axis-aligned on screen. Reconstructing the shape from
// radii here would have to redo the projection and would get that last part wrong.

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum MaskHandles {

    // MARK: - Tolerances
    //
    // All in view points, all named, because the numbers ARE the behaviour: the defect
    // above is a 9 pt constant in a hit test nobody could reach from a test.

    /// How close a press has to land to a drawn affordance — a rim, a band line — to
    /// count as having taken hold of it.
    ///
    /// 11 pt, which is `SliderDrag.thumbGrabRadius`, and deliberately the same number:
    /// it answers the same question about the same hand. A 22 pt target is about what a
    /// pointer places reliably at a glance, and it is more than twice the 4.5 pt the
    /// handle dots are DRAWN at — the drawn dot is a sight, not the target, and a grab
    /// radius that matched the ink would make every affordance in the app fiddly in
    /// exactly the way the owner reported.
    public static let grabRadius: Double = 11

    /// How far OUTSIDE a shape a press must land before it is allowed to mean "discard
    /// this one and draw another".
    ///
    /// Three grab radii. The reasoning is asymmetric on purpose, because the two
    /// mistakes cost different amounts: mistaking "new shape" for "resize" costs one
    /// undone drag, and mistaking "resize" for "new shape" costs the shape. So the rim's
    /// grab band is followed by a buffer two more radii wide in which a press still
    /// MOVES the existing shape rather than replacing it. A hand aiming at the rim and
    /// missing by 30 pt has missed; it has not changed its mind.
    ///
    /// It stays finite, rather than "anywhere outside is a move", because a gesture that
    /// places a shape somewhere else entirely is a real one and the canvas is where it
    /// belongs. Past 33 pt of clear space the press is not about the shape that is there.
    public static let newShapeClearance: Double = 3 * grabRadius

    /// The middle of a shape is always a MOVE, whatever the tolerances above would say
    /// about it — the inner half of a radial's radius, the central half of a gradient's
    /// axis.
    ///
    /// This is the rule that keeps a SMALL shape usable. Every tolerance here is an
    /// absolute distance in points, so on an ellipse drawn 30 pt across the rim's 11 pt
    /// band reaches the centre and swallows it, and the shape becomes resize-only —
    /// which is the same class of trap as the one this file exists to remove, just
    /// arrived at from the other side. Half is the natural split: it leaves the outer
    /// half of the radius, where the rim actually is, to the resize.
    public static let interiorMoveFraction: Double = 0.5

    /// How far a create gesture has to travel before it is allowed to rewrite geometry.
    ///
    /// A click is not a shape. This is the guard whose absence let one click on a radial
    /// clamp both radii to 0.002 (see the header); 4 pt is below the smallest deliberate
    /// drag and above the tremor in a click, so it costs an intentional gesture nothing
    /// and refuses an accidental one everything.
    public static let minimumDrawTravel: Double = 4

    // MARK: - Radial

    /// What a press on a radial component means.
    public enum RadialGrab: Equatable, Sendable {
        /// Translate the whole ellipse. The interior, and every near miss outside it.
        case move
        /// Change the first radius — the axis the `+major` handle is drawn on.
        case resizeMajor
        /// Change the second radius.
        case resizeMinor
        /// Discard this ellipse and draw a new one from the drag. Only ever returned
        /// for a press with clear space around it.
        case create
    }

    /// Which part of a radial a press at `press` takes hold of.
    ///
    /// `centre`, `majorHandle` and `minorHandle` are the three points the canvas draws:
    /// the ellipse's centre, and the ends of its two axes, all in view points and all
    /// carrying whatever the crop and the straighten did to them.
    ///
    /// Answers in order of what the press is most specifically about: the rim before the
    /// interior, the interior before the empty canvas, and — first of all — the inner
    /// half, which is a move under every circumstance.
    public static func radialGrab(press: CGPoint, centre: CGPoint,
                                  majorHandle: CGPoint, minorHandle: CGPoint)
        -> RadialGrab {
        let ux = Double(majorHandle.x - centre.x)
        let uy = Double(majorHandle.y - centre.y)
        let vx = Double(minorHandle.x - centre.x)
        let vy = Double(minorHandle.y - centre.y)
        let dx = Double(press.x - centre.x)
        let dy = Double(press.y - centre.y)

        // A shape whose numbers are not numbers is not one a gesture should be allowed
        // to overwrite: `.move` is the answer that cannot destroy anything, and the
        // recipe gets repaired in the panel rather than by a drag that guessed.
        guard ux.isFinite, uy.isFinite, vx.isFinite, vy.isFinite,
              dx.isFinite, dy.isFinite else { return .move }

        let distance = (dx * dx + dy * dy).squareRoot()
        let det = ux * vy - uy * vx

        // A degenerate frame — both radii clamped to nothing, or two axes drawn
        // collinear by a crop this extreme — has no interior and no rim to speak of.
        // This is also the recovery path for an ellipse that a previous build's click
        // already collapsed: land on it to move it, land away from it to draw a new one.
        guard abs(det) > 1e-9 else {
            return distance <= grabRadius ? .move : .create
        }

        // The press in the ellipse's OWN frame, where the rim is the unit circle.
        // Cramer's rule on `press − centre = a·u + b·v`; the axes need not be
        // perpendicular on screen, and after a straighten on a non-square crop they are
        // not, which is precisely why this is solved rather than projected.
        let a = (dx * vy - dy * vx) / det
        let b = (ux * dy - uy * dx) / det
        let rho = (a * a + b * b).squareRoot()
        guard rho.isFinite else { return .move }

        // The inner half, unconditionally. See `interiorMoveFraction`.
        if rho <= interiorMoveFraction { return .move }

        // Distance from the press to the rim, in points, measured ALONG THE RAY from
        // the centre: the rim point in this direction sits at `distance / rho`, so the
        // gap is `distance − distance / rho`. Negative inside, positive outside.
        //
        // Radial distance, not perpendicular distance, and the difference is worth
        // stating because it is not zero on an eccentric ellipse: the radial measure is
        // never SHORTER than the true one, so the 11 pt band it cuts is contained in the
        // true 11 pt band. The tolerance can therefore read a shade tight near the flat
        // sides of a very stretched ellipse, and can never read loose — a press this
        // says is on the rim really is within 11 pt of it. Erring that way is the point:
        // the neighbouring answers are `.move`, which is harmless, on both sides.
        let gap = distance - distance / rho

        if abs(gap) <= grabRadius {
            // Which axis the rim was grabbed on: the dominant component in the local
            // frame, so the rim is split by its two diagonals and each drawn handle sits
            // in the middle of its own quadrant pair. A diagonal grab has to choose one,
            // and choosing consistently beats a third mode nobody asked for — ⇧ during
            // the drag keeps the ellipse round, which is what a proportional corner drag
            // would have been for.
            return abs(a) >= abs(b) ? .resizeMajor : .resizeMinor
        }
        // Inside, or outside by less than the buffer: still this shape.
        if gap <= newShapeClearance { return .move }
        return .create
    }

    // MARK: - Linear gradient

    /// What a press on a linear gradient means.
    ///
    /// The gradient's geometry is two points, and everything the mask does happens
    /// between them: `MaskRaster.linearPlane` ramps from 0 at `start` to 1 at `end` and
    /// is flat outside both. The canvas draws that as two band lines across the frame
    /// with the axis joining them, so the strip between the lines is not decoration —
    /// it IS the gradient, and it is what the press is about when it lands there.
    public enum LinearGrab: Equatable, Sendable {
        /// Translate the whole gradient, both endpoints together. The strip, and every
        /// near miss outside it.
        case move
        /// The drawn dot at the start end: that endpoint follows the pointer, which
        /// turns the gradient as well as changing its spread.
        case startHandle
        /// The dot at the far end. Same freedom, other end.
        case endHandle
        /// The band line through the start end, away from its dot: the endpoint slides
        /// ALONG the axis, so the falloff widens or narrows and the gradient does not
        /// turn. Dragging a line that is drawn straight across the picture should move
        /// that line, not swing it.
        case startBand
        /// The band line through the far end.
        case endBand
        /// Discard this gradient and draw a new one from the drag.
        case create
    }

    /// Which part of a linear gradient a press at `press` takes hold of. `start` and
    /// `end` are the two drawn endpoints in view points.
    public static func linearGrab(press: CGPoint, start: CGPoint,
                                  end: CGPoint) -> LinearGrab {
        let wx = Double(end.x - start.x)
        let wy = Double(end.y - start.y)
        let px = Double(press.x - start.x)
        let py = Double(press.y - start.y)
        guard wx.isFinite, wy.isFinite, px.isFinite, py.isFinite else { return .move }

        let length = (wx * wx + wy * wy).squareRoot()
        // A gradient with no length rasterizes to nothing and has no strip to grab; it
        // is the one case where drawing a new one really is the only useful answer.
        guard length > 1e-9 else {
            return (px * px + py * py).squareRoot() <= grabRadius ? .move : .create
        }

        // Position along the axis in POINTS from `start`. The perpendicular distance is
        // deliberately not consulted: a band line is drawn all the way across the frame
        // and is grabbable all the way across, and the strip between them is the
        // gradient's whole extent however far off-axis the press lands.
        let along = (px * wx + py * wy) / length

        // The central half of the axis is a move whatever else is true, for the reason
        // `interiorMoveFraction` gives: on a short gradient the two band lines' grab
        // bands overlap and would otherwise leave the thing with no move target at all.
        let t = along / length
        if abs(t - 0.5) <= interiorMoveFraction / 2 { return .move }

        // The dots first, then the lines they sit on. Both endpoints resolve to the same
        // end of the gradient; the dot is the free one and the line is the constrained
        // one, and the dot wins where they overlap because it is the smaller, more
        // deliberate target.
        let toStart = (px * px + py * py).squareRoot()
        let ex = Double(press.x - end.x)
        let ey = Double(press.y - end.y)
        let toEnd = (ex * ex + ey * ey).squareRoot()
        if toStart <= grabRadius { return .startHandle }
        if toEnd <= grabRadius { return .endHandle }
        if abs(along) <= grabRadius { return .startBand }
        if abs(along - length) <= grabRadius { return .endBand }

        // Inside the strip, or outside it by less than the buffer: still this gradient.
        if along > 0, along < length { return .move }
        if along >= -newShapeClearance, along <= length + newShapeClearance {
            return .move
        }
        return .create
    }

    // MARK: - Creating

    /// Whether a create gesture has travelled far enough to be a shape rather than a
    /// click. See `minimumDrawTravel`: below this the caller must leave the component
    /// it already has alone.
    public static func drawsShape(from: CGPoint, to: CGPoint) -> Bool {
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        guard dx.isFinite, dy.isFinite else { return false }
        return (dx * dx + dy * dy).squareRoot() >= minimumDrawTravel
    }
}
