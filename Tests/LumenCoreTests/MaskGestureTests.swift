// MaskGestureTests.swift
// The first minute of masking, as arithmetic.
//
// `MaskHandlesTests` pins the grammar a press resolves to. This pins the four things
// that were still missing from it once that grammar was in, all of them found by walking
// the canvas rather than by reading a list:
//
//   1. THE GRADIENT HAD NO WAY TO BE TURNED. The radial was given a rotate band out of
//      its `newShapeClearance` buffer, with the argument written above that constant —
//      "rotating is the better answer for a press OUTSIDE a shape whose inside already
//      moves it" — and the gradient, whose buffer is the same buffer, was left behind.
//      Turning one meant grabbing a 380 pt² endpoint dot that also changes the spread
//      and pivots on the far end, so "turn this five degrees" swung the whole gradient
//      across the frame. The owner's report is the one sentence: there is a rotate band
//      he expects to grab and cannot find.
//
//   2. TWO OVERLAPPING HANDLES WERE RESOLVED BY SOURCE ORDER. The two endpoint dots were
//      tested one after the other, so on a gradient shorter than one grab radius — which
//      the create gesture makes from a 4 pt drag — a press dead on the far dot answered
//      `.startHandle`. Which end you got depended on which `if` came first.
//
//   3. ANOTHER MASK'S PIN OUTRANKED EVERY HANDLE. Both are 11 pt discs; the tie was
//      broken by which test the canvas ran first, so a pin sitting inside the ellipse
//      you were editing — pins sit at their mask's centre, so two masks over one subject
//      do exactly this — ate the press on the rim and changed the selection instead.
//
//   4. ⌥ MEANT "FROM THE CENTRE" ON ONE SHAPE AND NOTHING ON THE OTHER.
//
// Everything here is view points, which is the space `MaskHandles`' header argues for
// and the space the canvas hands it: the screen is what the hand is aiming at.
import XCTest
@testable import LumenCore

final class MaskGestureTests: XCTestCase {

    // The gradient `MaskHandlesTests` uses, so the two files describe one shape: 0% at
    // y = 800, 100% at y = 300, band lines 500 pt apart and horizontal across a
    // 1600×1100 preview.
    private let start = CGPoint(x: 800, y: 800)
    private let end = CGPoint(x: 800, y: 300)

    private func grab(_ x: Double, _ y: Double) -> MaskHandles.LinearGrab {
        MaskHandles.linearGrab(press: CGPoint(x: x, y: y), start: start, end: end)
    }

    // MARK: 1 — the rotate band the gradient did not have

    /// The reported defect, as one assert per side.
    ///
    /// Just past each band line's own 11 pt grab band and still inside the buffer, the
    /// press turns the gradient. Before this the whole span answered `.move`, so there
    /// was no press anywhere on the picture that turned a gradient without also moving
    /// an end of it.
    func testTheGradientHasARotateBandAndNotOnlyItsTwoEndDots() {
        for offset in stride(from: MaskHandles.grabRadius + 1,
                             through: MaskHandles.newShapeClearance, by: 4) {
            XCTAssertEqual(grab(800, 800 + offset), .rotate,
                           "\(offset) pt past the 0% line must turn the gradient")
            XCTAssertEqual(grab(800, 300 - offset), .rotate,
                           "\(offset) pt past the 100% line must turn the gradient")
        }
    }

    /// And it is a BAND, not a dot: the band lines are drawn all the way across the
    /// frame and the rotate band runs beside them for their whole length. This is the
    /// half of the fix that answers "a real hit target, not a 2 pt line" — the target is
    /// 22 pt deep and as wide as the photograph.
    func testTheRotateBandRunsTheWholeWidthOfThePicture() {
        for x in [4.0, 200.0, 800.0, 1400.0, 1596.0] {
            XCTAssertEqual(grab(x, 820), .rotate, "at x = \(x) past the 0% line")
            XCTAssertEqual(grab(x, 280), .rotate, "at x = \(x) past the 100% line")
        }
    }

    /// Rotation may not eat the two answers on either side of it. The band line still
    /// changes the falloff, the strip still moves, and clear space still draws a new
    /// gradient — if rotation had swallowed any of the three it would have traded one
    /// missing gesture for a missing one.
    func testTurningStealsNeitherTheBandLineNorTheStripNorTheNewGradient() {
        XCTAssertEqual(grab(800, 800), .startHandle, "the dot on the 0% line")
        XCTAssertEqual(grab(60, 806), .startBand, "6 pt off the 0% line is still it")
        XCTAssertEqual(grab(60, 294), .endBand, "and the same at the far end")
        XCTAssertEqual(grab(800, 700), .move, "inside the strip")
        XCTAssertEqual(grab(800, 800 + MaskHandles.newShapeClearance + 4), .create)
        XCTAssertEqual(grab(800, 300 - MaskHandles.newShapeClearance - 4), .create)
    }

    // MARK: The turn itself

    /// Both ends swing, the middle stays, and the length is untouched — which is what
    /// makes this a rotation rather than a second way to move the gradient.
    func testTurningSwingsBothEndsAboutTheMidpointAndKeepsTheLength() {
        let pivot = CGPoint(x: 800, y: 550)
        let turned = MaskHandles.turnedLine(start: start, end: end, pivot: pivot,
                                            from: CGPoint(x: 900, y: 550),
                                            to: CGPoint(x: 800, y: 650))
        XCTAssertEqual(Double((turned.start.x + turned.end.x) / 2), 800, accuracy: 1e-9)
        XCTAssertEqual(Double((turned.start.y + turned.end.y) / 2), 550, accuracy: 1e-9)
        XCTAssertEqual(Double(hypot(turned.end.x - turned.start.x,
                                    turned.end.y - turned.start.y)),
                       500, accuracy: 1e-9,
                       "a turn that changes the length is changing the falloff too")
        // A quarter turn: the axis was straight up the frame, so it is now across it.
        XCTAssertEqual(Double(turned.start.x), 550, accuracy: 1e-6)
        XCTAssertEqual(Double(turned.end.x), 1050, accuracy: 1e-6)
    }

    /// THE SWEPT ANGLE, NOT THE POINTER'S OWN. Taking the pointer's absolute angle would
    /// snap the axis under the finger on the first event of every rotate drag — a jump
    /// of up to 180° for a gesture whose entire purpose is a few degrees.
    func testTurningTracksTheSweepRatherThanThePointersAbsoluteAngle() {
        let pivot = CGPoint(x: 800, y: 550)
        // A press well round the shape from the axis, moved by two degrees.
        let from = CGPoint(x: 800 + 300 * cos(0.9), y: 550 + 300 * sin(0.9))
        let to = CGPoint(x: 800 + 300 * cos(0.9 + 0.0349),
                         y: 550 + 300 * sin(0.9 + 0.0349))
        let turned = MaskHandles.turnedLine(start: start, end: end, pivot: pivot,
                                            from: from, to: to)
        let before = atan2(Double(end.y - start.y), Double(end.x - start.x))
        let after = atan2(Double(turned.end.y - turned.start.y),
                          Double(turned.end.x - turned.start.x))
        XCTAssertEqual((after - before) * 180 / Double.pi, 2, accuracy: 0.01,
                       "two degrees of hand must be two degrees of gradient")
    }

    /// ⇧ lands the AXIS on a multiple of fifteen, not the sweep. Snapping the sweep
    /// would measure the stops from wherever the gradient happened to start, so ⇧ would
    /// mean something different on every gradient on the photograph — and 0 and 90,
    /// which are the two answers anyone has learned, would be unreachable from an axis
    /// that was not already on a stop.
    func testShiftSnapsTheAxisAndNotTheSweep() {
        // An axis at 5.71°, which is on no stop at all.
        let a = CGPoint(x: 0, y: 0)
        let b = CGPoint(x: 100, y: 10)
        let pivot = CGPoint(x: 50, y: 5)
        let turned = MaskHandles.turnedLine(start: a, end: b, pivot: pivot,
                                            from: CGPoint(x: 60, y: 5),
                                            to: CGPoint(x: 60, y: 15), snap: true)
        let axis = atan2(Double(turned.end.y - turned.start.y),
                         Double(turned.end.x - turned.start.x)) * 180 / Double.pi
        // 5.71° swept 45° is 50.71°, and the nearest stop to THAT is 45. Snapping the
        // sweep instead would have turned it by a whole 45 and left the axis on 50.71,
        // which is on no stop at all — so this number is the difference between the two
        // rules rather than a restatement of one of them.
        XCTAssertEqual(axis, 45, accuracy: 1e-9,
                       "⇧ left the gradient off every stop, which means it snapped the "
                           + "hand's sweep rather than the gradient's angle")
        XCTAssertEqual(Double(hypot(turned.end.x - turned.start.x,
                                    turned.end.y - turned.start.y)),
                       Double(hypot(b.x - a.x, b.y - a.y)), accuracy: 1e-9,
                       "the snap may change the direction and nothing else")
    }

    /// The stops are the same twenty-four the create drag and the ellipse use. One key,
    /// one meaning, across every shape on the canvas.
    func testEveryConstrainedTurnLandsOnTheSameStopsAsEveryOtherConstraint() {
        let pivot = CGPoint(x: 0, y: 0)
        for degrees in stride(from: 0.0, to: 360.0, by: 7.0) {
            let a = degrees * Double.pi / 180
            let turned = MaskHandles.turnedLine(
                start: CGPoint(x: -60, y: 0), end: CGPoint(x: 60, y: 0), pivot: pivot,
                from: CGPoint(x: 100, y: 0),
                to: CGPoint(x: 100 * cos(a), y: 100 * sin(a)), snap: true)
            let axis = atan2(Double(turned.end.y - turned.start.y),
                             Double(turned.end.x - turned.start.x)) * 180 / Double.pi
            let remainder = abs(axis
                .truncatingRemainder(dividingBy: MaskHandles.angleSnapDegrees))
            XCTAssertTrue(remainder < 1e-6
                            || abs(remainder - MaskHandles.angleSnapDegrees) < 1e-6,
                          "swept \(degrees)° and landed on \(axis)°")
        }
    }

    /// A press ON the pivot has no angle. `atan2(0, 0)` is 0 rather than an error, so
    /// without the guard the first event of a drag begun at the midpoint would measure
    /// its sweep from the positive x axis and swing the gradient there.
    func testATurnWithNothingToMeasureLeavesTheGradientAlone() {
        let pivot = CGPoint(x: 800, y: 550)
        let onPivot = MaskHandles.turnedLine(start: start, end: end, pivot: pivot,
                                             from: pivot, to: CGPoint(x: 900, y: 550))
        XCTAssertEqual(onPivot.start, start)
        XCTAssertEqual(onPivot.end, end)

        let poisoned = MaskHandles.turnedLine(start: start, end: end, pivot: pivot,
                                              from: CGPoint(x: CGFloat.nan, y: 550),
                                              to: CGPoint(x: 900, y: 550))
        XCTAssertEqual(poisoned.start, start)
        XCTAssertEqual(poisoned.end, end)
        XCTAssertTrue(poisoned.end.x.isFinite,
                      "a poisoned press may not produce a poisoned gradient")
    }

    // MARK: 2 — which of two overlapping handles wins

    /// THE NEARER DOT, and it used to be whichever was written first.
    ///
    /// A gradient this short is not hypothetical: `drawsShape` lets a create drag lay
    /// one down from 4 pt of travel, and the band drags clamp the two ends no closer
    /// than one grab radius — so both dots inside one tolerance is the ordinary end of
    /// the range rather than a corner of it. A press dead on the far dot answered
    /// `.startHandle`, which is the end you were not pointing at.
    func testTheNEARERDotWinsWhenBothAreWithinOneGrabRadius() {
        let a = CGPoint(x: 400, y: 400)
        let b = CGPoint(x: 410, y: 400)
        XCTAssertEqual(MaskHandles.linearGrab(press: b, start: a, end: b), .endHandle,
                       "a press dead on the far dot took the near one")
        XCTAssertEqual(MaskHandles.linearGrab(press: a, start: a, end: b), .startHandle)
        // And at the floor the band drags actually clamp to, where the two tolerances
        // still overlap by their whole width.
        let c = CGPoint(x: 400 + MaskHandles.grabRadius, y: 400)
        XCTAssertEqual(MaskHandles.linearGrab(press: c, start: a, end: c), .endHandle)
    }

    /// The long gradient still resolves the same way it always did: the dot beats the
    /// band line it sits on, because the dot is the smaller and more deliberate target.
    func testTheDotStillBeatsItsOwnBandLineOnAGradientWithRoom() {
        XCTAssertEqual(grab(806, 797), .startHandle)
        XCTAssertEqual(grab(795, 304), .endHandle)
    }

    // MARK: 3 — a handle against another mask's pin

    /// Which press is more specifically about what.
    ///
    /// A named handle is a target: there is nothing else a press within 11 pt of a rim
    /// or a band line could plausibly mean, and losing it costs the drag. `.move` is a
    /// REGION — a gradient's strip can be most of the photograph — so a pin inside it is
    /// still the more specific thing to have aimed at and keeps the press.
    func testANamedHandleOutranksAPinAndARegionDoesNot() {
        for grab in [MaskHandles.LinearGrab.startHandle, .endHandle,
                     .startBand, .endBand, .rotate] {
            XCTAssertTrue(MaskHandles.outranksPin(grab), "\(grab) is a target")
        }
        for grab in [MaskHandles.LinearGrab.move, .create] {
            XCTAssertFalse(MaskHandles.outranksPin(grab), "\(grab) is a region")
        }
        for grab in [MaskHandles.RadialGrab.resizeMajor, .resizeMinor,
                     .feather, .rotate] {
            XCTAssertTrue(MaskHandles.outranksPin(grab), "\(grab) is a target")
        }
        for grab in [MaskHandles.RadialGrab.move, .create] {
            XCTAssertFalse(MaskHandles.outranksPin(grab), "\(grab) is a region")
        }
    }

    /// The rule as the canvas will use it: a press on the rim of the ellipse being
    /// edited keeps the press even with another mask's pin under the pointer, and a
    /// press in its middle does not. Stated against real geometry rather than against
    /// the enum, because the enum is only half the claim.
    func testPressingTheRimOfTheShapeYouAreEditingIsNotAPinPress() {
        let centre = CGPoint(x: 800, y: 550)
        let major = CGPoint(x: 1280, y: 550)
        let minor = CGPoint(x: 800, y: 880)
        let onRim = MaskHandles.radialGrab(press: CGPoint(x: 1280, y: 550),
                                           centre: centre, majorHandle: major,
                                           minorHandle: minor)
        XCTAssertTrue(MaskHandles.outranksPin(onRim),
                      "a pin that happened to sit on the rim would have eaten this drag")
        let inside = MaskHandles.radialGrab(press: CGPoint(x: 820, y: 560),
                                            centre: centre, majorHandle: major,
                                            minorHandle: minor)
        XCTAssertFalse(MaskHandles.outranksPin(inside),
                       "the interior is a region, and a pin in it is still reachable")
    }

    // MARK: 4 — the modifiers on a new gradient

    /// ⌥ CENTRES THE NEW GRADIENT ON THE PRESS, which is what the same key has always
    /// done on the ellipse and did nothing at all on the gradient.
    func testOptionDrawsAGradientFromItsCentre() {
        let press = CGPoint(x: 100, y: 100)
        let pointer = CGPoint(x: 200, y: 140)
        let plain = MaskHandles.drawnLine(from: press, to: pointer,
                                          fromCentre: false, snap: false)
        XCTAssertEqual(plain.start, press, "without ⌥ the press is still one end")
        XCTAssertEqual(plain.end, pointer)

        let centred = MaskHandles.drawnLine(from: press, to: pointer,
                                            fromCentre: true, snap: false)
        XCTAssertEqual(Double((centred.start.x + centred.end.x) / 2),
                       Double(press.x), accuracy: 1e-9)
        XCTAssertEqual(Double((centred.start.y + centred.end.y) / 2),
                       Double(press.y), accuracy: 1e-9)
        XCTAssertEqual(Double(hypot(centred.end.x - centred.start.x,
                                    centred.end.y - centred.start.y)),
                       2 * Double(hypot(pointer.x - press.x, pointer.y - press.y)),
                       accuracy: 1e-9,
                       "drawing from the centre spends the drag on both halves")
    }

    /// ⇧ constrains the direction, and it is the same `snapped` every other constrained
    /// drag on the canvas goes through.
    func testShiftConstrainsANewGradientToTheSameFifteenDegreeStops() {
        let press = CGPoint(x: 0, y: 0)
        let pointer = CGPoint(x: 100, y: 10)
        let snapped = MaskHandles.drawnLine(from: press, to: pointer,
                                            fromCentre: false, snap: true)
        XCTAssertEqual(Double(snapped.end.y), 0, accuracy: 1e-9)
        XCTAssertEqual(Double(snapped.end.x),
                       Double(hypot(pointer.x - press.x, pointer.y - press.y)),
                       accuracy: 1e-9,
                       "the constraint turns the drag, it does not shorten it")
    }

    /// AND THE TWO COMPOSE. The snap is applied before the reflection, so ⇧⌥ is a
    /// snapped gradient centred on the press — not a snapped one whose mirrored half has
    /// drifted off the stop, which is what applying them the other way round produces.
    func testShiftAndOptionComposeIntoOneGesture() {
        let press = CGPoint(x: 40, y: 90)
        let both = MaskHandles.drawnLine(from: press, to: CGPoint(x: 140, y: 100),
                                         fromCentre: true, snap: true)
        XCTAssertEqual(Double((both.start.x + both.end.x) / 2), 40, accuracy: 1e-9)
        XCTAssertEqual(Double((both.start.y + both.end.y) / 2), 90, accuracy: 1e-9)
        let axis = atan2(Double(both.end.y - both.start.y),
                         Double(both.end.x - both.start.x)) * 180 / Double.pi
        XCTAssertEqual(axis, 0, accuracy: 1e-9,
                       "a 5.7° drag with ⇧ down lands on the horizontal, centred or not")
    }

    // MARK: The lasso's spacing, which was a fraction of the frame

    /// A TOLERANCE IN VIEW POINTS, like every other number in this file.
    ///
    /// The lasso thinned its recorded vertices at 0.002 of the SOURCE frame, which is a
    /// different distance on screen at every magnification: two points at fit-to-window
    /// on a 6000 px frame, and forty-eight at 4:1. The tool got coarser exactly as the
    /// photographer zoomed in to be careful. The range below is the whole claim — a
    /// screen distance a hand cannot hold inside, and well under one grab radius, so
    /// thinning can never merge two vertices a press could tell apart.
    func testTheLassoRecordsVerticesAtAScreenDistance() {
        XCTAssertGreaterThanOrEqual(MaskHandles.traceStep, 1,
                                    "below a point the thinning stops thinning and a "
                                        + "sweep of the hand becomes thousands of "
                                        + "vertices the rasterizer walks per pixel")
        XCTAssertLessThan(MaskHandles.traceStep, MaskHandles.grabRadius,
                          "a lasso whose vertices are further apart than a grab radius "
                              + "records corners you cannot then take hold of")
    }
}
