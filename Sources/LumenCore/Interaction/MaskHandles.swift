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
        /// Drag the INNER ellipse — the feather boundary, which is already drawn and
        /// was already the only thing on this shape you had to leave the picture to
        /// change.
        ///
        /// The owner's words: "the feather I should be able to change without having to
        /// go through the sliders". The linear gradient has always worked this way — its
        /// two falloff lines are draggable — so the radial was the odd one out rather
        /// than the ordinary case.
        case feather
        /// Turn the ellipse. Only ever returned for a press on the handle drawn beyond
        /// the major axis; there is no bare-rim gesture for it, because every one that
        /// suggests itself collides with resize.
        case rotate
        /// Discard this ellipse and draw a new one from the drag. Only ever returned
        /// for a press with clear space around it.
        case create
    }

    /// How far beyond the rim the rotation handle sits, in points, measured along the
    /// major axis.
    ///
    /// Far enough that its 11 pt grab circle clears the rim's: at 24 the two centres are
    /// 24 apart and the bands meet at 12 from the rim, so a press is never ambiguous
    /// between "resize" and "turn". Close enough that it reads as belonging to the
    /// ellipse rather than floating beside it.
    public static let rotateHandleOffset: Double = 24

    /// The band of inner-ellipse fractions the feather ring can be grabbed in.
    ///
    /// Below the floor the ring is inside the centre dot and a grab would fight the move
    /// gesture for a target a few points wide. Above the ceiling it has fused with the
    /// rim, and the rim's answer — resize — is the one a press there almost certainly
    /// means. Outside the band, Feather stays a slider, which is honest: a control with
    /// no room to be dragged should not pretend it has some.
    public static let featherRingFloor: Double = 0.16
    public static let featherRingCeiling: Double = 0.9

    /// Which part of a radial a press at `press` takes hold of.
    ///
    /// `centre`, `majorHandle` and `minorHandle` are the three points the canvas draws:
    /// the ellipse's centre, and the ends of its two axes, all in view points and all
    /// carrying whatever the crop and the straighten did to them.
    ///
    /// Answers in order of what the press is most specifically about: the rim before the
    /// interior, the interior before the empty canvas, and — first of all — the inner
    /// half, which is a move under every circumstance.
    /// `feather` is the component's 0…100, and `hasGeometry` is false for an ellipse
    /// that has not been drawn yet — a mask created from the picker no longer arrives
    /// with one, so the first drag on the picture is what makes it.
    public static func radialGrab(press: CGPoint, centre: CGPoint,
                                  majorHandle: CGPoint, minorHandle: CGPoint,
                                  feather: Double = 50,
                                  hasGeometry: Bool = true,
                                  rotateHandle: CGPoint? = nil)
        -> RadialGrab {
        // Nothing drawn yet: every press draws, wherever it lands. Without this the
        // fallback geometry a nil centre resolves to would sit under the pointer and
        // the drag would MOVE an ellipse that does not exist.
        guard hasGeometry else { return .create }
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

        // THE ROTATION HANDLE FIRST, and it is a plain point test rather than anything
        // in the ellipse's frame: it sits outside the rim, where the only other answer
        // is `.create`, so getting it wrong would draw a new shape over the one being
        // turned. A press claims it or it does not.
        if let rotateHandle {
            let rx = Double(press.x - rotateHandle.x)
            let ry = Double(press.y - rotateHandle.y)
            if rx.isFinite, ry.isFinite,
               (rx * rx + ry * ry).squareRoot() <= grabRadius {
                return .rotate
            }
        }

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

        // The FEATHER RING, before the interior shortcut, because at Feather 60 the
        // ring sits at 0.4 and the shortcut would swallow it whole. Checked after the
        // rim below? No — the rim test is further down and returns first for a press
        // that is on both, which is the right precedence: the two only overlap on a
        // barely-feathered ellipse, where the rim is what a press means.
        let ring = Num.clamp(1 - Num.clamp(feather, 0, 100) / 100, 0, 1)
        // AND IT HAS TO HAVE ROOM IN POINTS, not only as a fraction. On an ellipse
        // drawn 30 pt across, a ring at 0.5 sits seven points from the centre — inside
        // its own grab band, so it would swallow the move target whole and leave a tiny
        // shape resize-and-feather only. That is the trap `testSmallEllipseStillMoves
        // FromItsMiddle` was written for from the other side, and it caught this.
        //
        // Two grab radii of clearance: enough that the ring's band and the centre's
        // move region do not overlap at all. Below that, Feather stays a slider, which
        // is honest — a target you cannot hit is worse than one that is not offered.
        let shortestAxis = Swift.min((ux * ux + uy * uy).squareRoot(),
                                     (vx * vx + vy * vy).squareRoot())
        if ring * shortestAxis >= 2 * grabRadius,
           ring >= featherRingFloor, ring <= featherRingCeiling {
            // The ring point along this ray sits at screen distance `ring · distance/rho`.
            let gap = distance - ring * distance / rho
            if abs(gap) <= grabRadius, abs(distance - distance / rho) > grabRadius {
                return .feather
            }
        }

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
    /// The angles a constrained drag is allowed to land on, in degrees.
    ///
    /// Fifteen, not ninety. What shipped constrained a gradient to the horizontal or the
    /// vertical and nothing else, which covers a level horizon and a straight-down sky
    /// and abandons the photographer for every other picture — a gradient raked along a
    /// hillside or a shaft of window light is the ordinary case, and it was the one case
    /// Shift could not help with. Twenty-four stops around the circle includes both old
    /// answers, so nothing anyone had learned stopped working, and adds the diagonals,
    /// the thirds and the sixths.
    ///
    /// Not five degrees, which is fine enough that the snap stops being felt and the
    /// control stops being a constraint; not thirty, which cannot say 45.
    public static let angleSnapDegrees: Double = 15

    /// `point` moved onto the nearest snapped ray from `anchor`.
    ///
    /// The distance from the anchor is PRESERVED, not projected onto the ray: a
    /// projection shortens the gradient as the hand moves off-axis, so a drag held near
    /// 44° while Shift is down would shrink the band as well as turning it, and the
    /// photographer would be fighting a control that changes two things when they asked
    /// it to change one. Rotating keeps the length the hand chose and changes only the
    /// direction, which is the whole of what a constraint should do.
    ///
    /// Degenerate by design at zero travel: a press that has not moved has no angle to
    /// snap, and returning the anchor is the only answer that is not invented.
    public static func snapped(_ point: CGPoint, anchor: CGPoint,
                               step: Double = angleSnapDegrees) -> CGPoint {
        let dx = Double(point.x - anchor.x)
        let dy = Double(point.y - anchor.y)
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-9, dx.isFinite, dy.isFinite, step > 0 else { return anchor }
        let degrees = atan2(dy, dx) * 180 / Double.pi
        let snappedDegrees = (degrees / step).rounded() * step
        let radians = snappedDegrees * Double.pi / 180
        return CGPoint(x: anchor.x + CGFloat(cos(radians) * length),
                       y: anchor.y + CGFloat(sin(radians) * length))
    }

    /// A pin's place on screen when the mask it belongs to is off the visible picture.
    ///
    /// Zoom to 1:1 on a corner and every mask anchored elsewhere leaves the frame; a
    /// gradient dragged off the edge does the same at any zoom. The pin was simply
    /// DROPPED then — so the one control that selects a mask from the photograph
    /// disappeared exactly when the mask list is the only way left, which is the moment
    /// the pins exist to avoid.
    ///
    /// Docked, it clamps to the edge and says so. That distinction is the whole of the
    /// honesty here: a docked pin is a SIGNPOST, not a position — the mask is not there,
    /// it is that way — so the caller draws it differently, and a pin drawn the same
    /// either way would be a picture claiming a mask sits in a corner it does not.
    ///
    /// `inset` keeps the whole dot on screen rather than half of it.
    public static func dockedPin(_ point: CGPoint, in size: CGSize,
                                 inset: Double = pinDockInset)
        -> (point: CGPoint, docked: Bool)? {
        guard point.x.isFinite, point.y.isFinite,
              size.width.isFinite, size.height.isFinite,
              size.width > 1, size.height > 1 else { return nil }
        // A frame narrower than two insets has no room to dock in; the midpoint is the
        // only answer that is inside it.
        let lo = CGFloat(Swift.max(inset, 0))
        let hiX = Swift.max(size.width - lo, lo)
        let hiY = Swift.max(size.height - lo, lo)
        let x = Swift.min(Swift.max(point.x, lo), hiX)
        let y = Swift.min(Swift.max(point.y, lo), hiY)
        let moved = abs(x - point.x) > 1e-9 || abs(y - point.y) > 1e-9
        return (CGPoint(x: x, y: y), moved)
    }

    /// How far in from the edge a docked pin sits: its own radius plus a little, so the
    /// dot is whole and its grab circle is not half off the picture.
    public static let pinDockInset: Double = 10

    public static func drawsShape(from: CGPoint, to: CGPoint) -> Bool {
        let dx = Double(to.x - from.x)
        let dy = Double(to.y - from.y)
        guard dx.isFinite, dy.isFinite else { return false }
        return (dx * dx + dy * dy).squareRoot() >= minimumDrawTravel
    }
}
