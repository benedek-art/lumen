// What a press on a mask's geometry takes hold of.
//
// The defect these pin is the owner's: "I can only move the circle when I press the
// complete center, and if I go even a tiny bit out of that center dot, then I have to
// redraw it." The old rule was three 9 pt discs and a `default:` that rewrote the
// ellipse from the drag, so a press one point outside the centre dot destroyed the
// shape — and a press with no travel at all collapsed both radii to the 0.002 clamp,
// which is a click deleting a mask. Every test below is a statement about which presses
// are allowed to be destructive, and the first one is that almost none of them are.
import XCTest
@testable import LumenCore

final class MaskHandlesTests: XCTestCase {

    // A plausible ellipse on a plausible preview: the default a new radial is seeded
    // with (centre 0.5/0.5, radii 0.3/0.3) drawn on a 1600×1100 fit, which puts the
    // centre at (800, 550) and the axes at 480 and 330 points.
    private let centre = CGPoint(x: 800, y: 550)
    private let major = CGPoint(x: 1280, y: 550)
    private let minor = CGPoint(x: 800, y: 880)

    private func grab(_ x: Double, _ y: Double) -> MaskHandles.RadialGrab {
        MaskHandles.radialGrab(press: CGPoint(x: x, y: y), centre: centre,
                               majorHandle: major, minorHandle: minor)
    }

    // MARK: The reported defect

    /// One point outside the centre dot. This is the whole bug report, as one assert.
    func testJustOutsideTheCentreDotStillMoves() {
        for offset in [10.0, 12.0, 20.0, 60.0, 200.0] {
            XCTAssertEqual(grab(800 + offset, 550), .move,
                           "a press \(offset) pt from the centre is inside the ellipse "
                           + "and must move it, not replace it")
        }
    }

    /// The interior, swept. Nothing inside the shape may ever be a create — that is the
    /// property the report is about, and a grid says it about the whole area rather than
    /// about the handful of points a hand-written case would visit.
    func testNothingInsideTheEllipseCreates() {
        var interior = 0
        for i in stride(from: -1.0, through: 1.0, by: 0.05) {
            for j in stride(from: -1.0, through: 1.0, by: 0.05) {
                guard i * i + j * j <= 1 else { continue }
                interior += 1
                let g = grab(800 + i * 480, 550 + j * 330)
                XCTAssertNotEqual(g, .create,
                                  "press at local (\(i), \(j)) is inside the ellipse")
            }
        }
        XCTAssertGreaterThan(interior, 1000, "the sweep actually covered the interior")
    }

    /// How much of the canvas is safe, stated as the number the old rule failed at. The
    /// three 9 pt discs covered 763 pt² of a 1600×1100 preview — 0.043% — and everything
    /// else was a redraw. The move target is now the shape.
    func testMoveTargetIsTheShapeRatherThanADot() {
        var moves = 0
        var creates = 0
        for x in stride(from: 0.0, through: 1600.0, by: 8) {
            for y in stride(from: 0.0, through: 1100.0, by: 8) {
                switch grab(x, y) {
                case .move: moves += 1
                case .create: creates += 1
                default: break
                }
            }
        }
        let total = Double(moves + creates)
        XCTAssertGreaterThan(Double(moves) / total, 0.25,
                             "a quarter of the preview is the ellipse and its buffer; "
                             + "the old rule made 0.043% of it non-destructive")
        XCTAssertGreaterThan(creates, 0, "and there is still somewhere to draw a new one")
    }

    // MARK: The rim

    /// The whole rim resizes — every angle, not two dots. Which axis it drives is the
    /// dominant one in the ellipse's own frame, so the rim is split by its diagonals.
    ///
    /// Swept off the diagonals on purpose: at exactly 45° the two components differ by
    /// less than the rounding in `press − centre`, so which axis wins there is a coin
    /// toss the rule is not claiming to decide. Everywhere else the answer is definite.
    func testWholeRimResizesAndPicksTheDominantAxis() {
        for degrees in stride(from: 2.5, to: 360.0, by: 5) {
            let t = degrees * Double.pi / 180
            let g = grab(800 + 480 * cos(t), 550 + 330 * sin(t))
            let expected: MaskHandles.RadialGrab =
                abs(cos(t)) >= abs(sin(t)) ? .resizeMajor : .resizeMinor
            XCTAssertEqual(g, expected, "rim at \(degrees)°")
        }
    }

    /// The two dots that used to be the only resize targets still are resize targets.
    /// A grammar that widens a target must not move it.
    func testDrawnHandlesStillResizeTheirOwnAxis() {
        XCTAssertEqual(grab(Double(major.x), Double(major.y)), .resizeMajor)
        XCTAssertEqual(grab(Double(minor.x), Double(minor.y)), .resizeMinor)
    }

    /// Just inside and just outside the rim, on both sides of it: the grab band is
    /// symmetric about the edge, because a hand aiming at an edge misses both ways.
    func testRimBandStraddlesTheEdge() {
        XCTAssertEqual(grab(800 + 480 - 8, 550), .resizeMajor, "8 pt inside the rim")
        XCTAssertEqual(grab(800 + 480 + 8, 550), .resizeMajor, "8 pt outside the rim")
        XCTAssertEqual(grab(800 + 480 - 40, 550), .move, "40 pt inside is interior")
    }

    // MARK: Missing, and meaning it

    /// A miss just past the rim never draws a new shape. This is the asymmetry the
    /// clearance constant exists for: mistaking a new shape for a resize costs one undo,
    /// and mistaking a resize for a new shape costs the shape.
    ///
    /// It used to answer `.move` there and now answers `.rotate` — the band outside the
    /// rim turns the ellipse. The property being protected is unchanged and is what this
    /// asserts: whatever the band does, it does not DESTROY. Pinning `.move` instead
    /// would have been pinning the answer rather than the reason.
    func testNearMissOutsideTheRimNeverCreates() {
        for gap in [12.0, 20.0, 30.0, MaskHandles.newShapeClearance - 1] {
            XCTAssertNotEqual(grab(800 + 480 + gap, 550), .create,
                              "a press \(gap) pt past the rim is a miss, not a decision")
        }
    }

    /// Clear space is still clear space: the gesture that places a shape somewhere else
    /// entirely survives, it just has to mean it.
    func testClearSpaceCreates() {
        XCTAssertEqual(grab(800 + 480 + MaskHandles.newShapeClearance + 2, 550), .create)
        XCTAssertEqual(grab(60, 60), .create, "the far corner of the preview")
    }

    // MARK: Drawing it out, feathering it, turning it — without a slider
    //
    // The owner's second round of feedback, and it is one complaint rather than three:
    // "I want to be able to trace it out while holding, just like Lightroom", "the
    // feather I should be able to change without having to go through the sliders", and
    // "rotation, all that stuff". Sliders are slow — read it, press it, move it side to
    // side — and none of that is looking at the photograph.

    /// A radial created from the picker no longer arrives with an ellipse, so the first
    /// press has to DRAW rather than move.
    ///
    /// This is also why being handed one was worse than it looked: `.create` only fires
    /// on a press with clear space around it, and a circle parked in the middle of the
    /// frame meant the draw gesture that has been in this file all along could not be
    /// reached from the middle of the picture — which is where you press.
    func testWithNoEllipseYetEveryPressDraws() {
        for point in [(800.0, 550.0), (100.0, 100.0), (1280.0, 550.0)] {
            XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: point.0, y: point.1),
                                                  centre: centre, majorHandle: major,
                                                  minorHandle: minor,
                                                  hasGeometry: false),
                           .create,
                           "a press at \(point) with nothing drawn must draw")
        }
    }

    func testTheDefaultIsStillThatThereIsGeometry() {
        // `hasGeometry` defaults to true, so every existing caller and every existing
        // test above means what it always meant.
        XCTAssertEqual(grab(800, 550), .move)
    }

    /// The inner ellipse is the feather boundary, it is already drawn, and it was the
    /// only thing on this shape you had to leave the picture to change.
    func testTheInnerRingFeathers() {
        // Feather 50 puts the ring at half the radius: 240 pt along the major axis.
        for offset in [-8.0, 0.0, 8.0] {
            XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 800 + 240 + offset,
                                                                 y: 550),
                                                  centre: centre, majorHandle: major,
                                                  minorHandle: minor, feather: 50),
                           .feather,
                           "\(offset) pt off the ring is still the ring")
        }
    }

    func testTheRingMovesWithTheFeatherRatherThanSittingAtHalf() {
        // At Feather 20 the ring is at 0.8 — 384 pt out — and half-way is a plain move.
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 800 + 384, y: 550),
                                              centre: centre, majorHandle: major,
                                              minorHandle: minor, feather: 20),
                       .feather)
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 800 + 240, y: 550),
                                              centre: centre, majorHandle: major,
                                              minorHandle: minor, feather: 20),
                       .move, "and where the ring ISN'T is not a feather grab")
    }

    func testTheRimStillWinsWhereTheRingHasFusedWithIt() {
        // Feather 5 puts the ring at 0.95, which is 24 pt inside a 480 pt rim — the two
        // bands overlap, and a press there almost certainly means resize.
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 1280, y: 550),
                                              centre: centre, majorHandle: major,
                                              minorHandle: minor, feather: 5),
                       .resizeMajor)
    }

    func testFeatherIsNotOfferedWhereItCannotBeHit() {
        // A 30 pt ellipse at Feather 50 has its ring seven points from the centre,
        // inside its own grab band. Offering it there would take the move target away
        // from a shape that has barely any — the same trap as the reported defect, from
        // the other side.
        let c = CGPoint(x: 300, y: 300)
        let m = CGPoint(x: 315, y: 300)
        let n = CGPoint(x: 300, y: 315)
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 307, y: 300),
                                              centre: c, majorHandle: m, minorHandle: n,
                                              feather: 50),
                       .move)
    }

    func testFeatherZeroAndOneHundredOfferNoRing() {
        // At 0 the ring IS the rim; at 100 it is the centre. Neither is a target.
        XCTAssertNotEqual(MaskHandles.radialGrab(press: CGPoint(x: 1280, y: 550),
                                                 centre: centre, majorHandle: major,
                                                 minorHandle: minor, feather: 0),
                          .feather)
        XCTAssertNotEqual(MaskHandles.radialGrab(press: CGPoint(x: 802, y: 550),
                                                 centre: centre, majorHandle: major,
                                                 minorHandle: minor, feather: 100),
                          .feather)
    }

    /// The whole band just outside the rim turns the ellipse — 360° of it, not a knob.
    ///
    /// There WAS a knob, on a stalk beyond one end of the major axis. The owner asked
    /// for it gone: "I would like to be able to turn it wherever I want, so I can just
    /// grab it in the centre, but on the outside of it… And I just don't want this
    /// little lever at the edge." The lever also had a defect he did not have to name —
    /// it sat at a fixed offset from ONE end of the axis, so turning the ellipse meant
    /// first finding where the handle had rotated to.
    ///
    /// Tested all the way round, because "wherever I want" is the whole claim.
    func testTheBandOutsideTheRimTurnsTheEllipse() {
        // Just past the 11 pt rim band, and still well inside `newShapeClearance`.
        let out = MaskHandles.grabRadius + 6
        for degrees in stride(from: 0.0, to: 360.0, by: 30.0) {
            let a = degrees * Double.pi / 180
            // The rim in this direction, then a little further along the same ray.
            let rimX = Double(centre.x) + cos(a) * 480
            let rimY = Double(centre.y) + sin(a) * 330
            let dx = rimX - Double(centre.x), dy = rimY - Double(centre.y)
            let length = (dx * dx + dy * dy).squareRoot()
            let press = CGPoint(x: rimX + dx / length * out,
                                y: rimY + dy / length * out)
            XCTAssertEqual(MaskHandles.radialGrab(press: press, centre: centre,
                                                  majorHandle: major, minorHandle: minor,
                                                  feather: 0),
                           .rotate, "at \(degrees)°")
        }
    }

    /// The rim still resizes. Rotation takes the band OUTSIDE it, and the two must not
    /// overlap, or an ellipse would become impossible to resize.
    func testTurningDoesNotStealTheRim() {
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 800 + 480, y: 550),
                                              centre: centre, majorHandle: major,
                                              minorHandle: minor),
                       .resizeMajor)
    }

    /// And the inside still moves. Outside turns, inside moves, the rim resizes —
    /// three answers, no modifier, nothing to hunt for.
    func testTheInsideStillMoves() {
        XCTAssertEqual(MaskHandles.radialGrab(press: centre, centre: centre,
                                              majorHandle: major, minorHandle: minor),
                       .move)
    }

    /// Far enough out and it is a new ellipse again, which is the gesture the band was
    /// taken from. If rotation swallowed that, ⌘-drag would be the only way to draw a
    /// second shape on a photograph that already has one.
    func testFarOutsideStillDrawsANewOne() {
        let press = CGPoint(x: Double(centre.x) + 480 + MaskHandles.newShapeClearance + 4,
                            y: Double(centre.y))
        XCTAssertEqual(MaskHandles.radialGrab(press: press, centre: centre,
                                              majorHandle: major, minorHandle: minor),
                       .create)
    }

    func testEveryNewGrabIsRefusedOnAPoisonedShape() {
        // The file's own rule: a shape whose numbers are not numbers is not one a
        // gesture may overwrite.
        let bad = CGPoint(x: CGFloat.nan, y: 550)
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 900, y: 550),
                                              centre: centre, majorHandle: bad,
                                              minorHandle: minor, feather: 50),
                       .move)
    }

    // MARK: Shapes that are hard to hit

    /// A small ellipse keeps a move target. Every tolerance here is absolute, so on a
    /// shape drawn 30 pt across the rim's band would otherwise reach the centre and the
    /// thing would be resize-only — the same trap as the one being fixed, from the other
    /// side.
    func testSmallEllipseStillMovesFromItsMiddle() {
        let c = CGPoint(x: 300, y: 300)
        let m = CGPoint(x: 315, y: 300)
        let n = CGPoint(x: 300, y: 315)
        for offset in [0.0, 2.0, 5.0, 7.0] {
            XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 300 + offset, y: 300),
                                                  centre: c, majorHandle: m,
                                                  minorHandle: n),
                           .move,
                           "the inner half of a 30 pt ellipse is a move at \(offset) pt")
        }
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 315, y: 300),
                                              centre: c, majorHandle: m, minorHandle: n),
                       .resizeMajor, "and its rim still resizes")
    }

    /// The recovery path for an ellipse a previous build's click already collapsed to
    /// the 0.002 radius clamp: it is still grabbable where it is, and drawing a new one
    /// still works from anywhere else. Nothing here traps the user with a shape too
    /// small to see and too small to hit.
    func testCollapsedEllipseIsGrabbableAndReplaceable() {
        let c = CGPoint(x: 400, y: 400)
        let m = CGPoint(x: 400.5, y: 400)
        let n = CGPoint(x: 400, y: 400.5)
        XCTAssertNotEqual(MaskHandles.radialGrab(press: CGPoint(x: 402, y: 400),
                                                 centre: c, majorHandle: m,
                                                 minorHandle: n),
                          .create, "a press on the collapsed shape takes hold of it")
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 700, y: 700),
                                              centre: c, majorHandle: m, minorHandle: n),
                       .create, "and one well away from it starts again")
    }

    /// A shape with no axes at all — radii clamped to zero, or a crop degenerate enough
    /// to flatten them onto each other — answers move where it is drawn and create
    /// elsewhere, rather than dividing by its own determinant.
    func testDegenerateFrameIsSafe() {
        let c = CGPoint(x: 100, y: 100)
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 104, y: 100), centre: c,
                                              majorHandle: c, minorHandle: c), .move)
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 400, y: 400), centre: c,
                                              majorHandle: c, minorHandle: c), .create)
        // Collinear axes: an ellipse with no area.
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 500, y: 500), centre: c,
                                              majorHandle: CGPoint(x: 200, y: 100),
                                              minorHandle: CGPoint(x: 150, y: 100)),
                       .create)
    }

    /// Numbers that are not numbers never destroy anything. A NaN in a recipe is data
    /// loss on its own (`SliderTrack.nudged` says so); a NaN that also authorises a
    /// gesture to overwrite geometry would be data loss twice.
    func testNonFiniteInputsRefuseToCreate() {
        let bad = CGPoint(x: CGFloat.nan, y: 10)
        XCTAssertEqual(MaskHandles.radialGrab(press: bad, centre: centre,
                                              majorHandle: major, minorHandle: minor),
                       .move)
        XCTAssertEqual(MaskHandles.radialGrab(press: CGPoint(x: 800, y: 550),
                                              centre: centre,
                                              majorHandle: CGPoint(x: CGFloat.infinity,
                                                                   y: 550),
                                              minorHandle: minor),
                       .move)
        XCTAssertEqual(MaskHandles.linearGrab(press: bad, start: CGPoint(x: 0, y: 0),
                                              end: CGPoint(x: 100, y: 0)), .move)
    }

    // MARK: The projected frame

    /// The rule reads the ellipse from three points precisely so that a rotation and a
    /// non-square crop come through the projection intact. Here the axes are turned 30°
    /// and scaled differently, which is what a straightened crop does to them: a press
    /// inside the TURNED shape must move it even where it is outside the axis-aligned
    /// one, and a press outside must not.
    func testRotatedAndScaledFrameIsHitTestedAsDrawn() {
        let c = CGPoint(x: 500, y: 500)
        let t = 30.0 * Double.pi / 180
        let rx = 300.0, ry = 80.0
        let m = CGPoint(x: 500 + rx * cos(t), y: 500 + rx * sin(t))
        let n = CGPoint(x: 500 - ry * sin(t), y: 500 + ry * cos(t))
        // 250 pt out along the MAJOR axis: inside the turned ellipse.
        let along = CGPoint(x: 500 + 250 * cos(t), y: 500 + 250 * sin(t))
        XCTAssertEqual(MaskHandles.radialGrab(press: along, centre: c, majorHandle: m,
                                              minorHandle: n), .move)
        // The same 250 pt out along the MINOR axis: far outside a shape only 80 pt wide
        // that way, and clear of the buffer.
        let across = CGPoint(x: 500 - 250 * sin(t), y: 500 + 250 * cos(t))
        XCTAssertEqual(MaskHandles.radialGrab(press: across, centre: c, majorHandle: m,
                                              minorHandle: n), .create)
        // And the rim of the turned shape resizes, all the way round.
        for degrees in stride(from: 0.0, to: 360.0, by: 15) {
            let u = degrees * Double.pi / 180
            let p = CGPoint(x: 500 + rx * cos(u) * cos(t) - ry * sin(u) * sin(t),
                            y: 500 + rx * cos(u) * sin(t) + ry * sin(u) * cos(t))
            let g = MaskHandles.radialGrab(press: p, centre: c, majorHandle: m,
                                           minorHandle: n)
            XCTAssertTrue(g == .resizeMajor || g == .resizeMinor,
                          "rim of the turned ellipse at \(degrees)° answered \(g)")
        }
    }

    // MARK: Linear gradient

    // A gradient across the middle of the same preview: 0% at y = 800, 100% at y = 300,
    // so the band lines are 500 pt apart and horizontal.
    private let lineStart = CGPoint(x: 800, y: 800)
    private let lineEnd = CGPoint(x: 800, y: 300)

    private func lineGrab(_ x: Double, _ y: Double) -> MaskHandles.LinearGrab {
        MaskHandles.linearGrab(press: CGPoint(x: x, y: y), start: lineStart, end: lineEnd)
    }

    /// The strip between the two band lines is the gradient, and pressing it moves it —
    /// including far off the axis, where the band line is still drawn and the old rule
    /// (a 9 pt disc on the midpoint) had nothing at all.
    func testAnywhereInTheBandMoves() {
        for y in stride(from: 320.0, through: 780.0, by: 20) {
            for x in [10.0, 400.0, 800.0, 1200.0, 1590.0] {
                XCTAssertEqual(lineGrab(x, y), .move, "inside the band at (\(x), \(y))")
            }
        }
    }

    /// The band lines adjust the falloff, and they are grabbable across the whole frame
    /// rather than only at their dots — which is what makes the drawn line an affordance
    /// instead of a decoration.
    func testBandLinesAreGrabbableAcrossTheFrame() {
        XCTAssertEqual(lineGrab(60, 800), .startBand)
        XCTAssertEqual(lineGrab(1500, 803), .startBand)
        XCTAssertEqual(lineGrab(60, 300), .endBand)
        XCTAssertEqual(lineGrab(1500, 296), .endBand)
    }

    /// The dots themselves turn the gradient, and they win over the line they sit on:
    /// the smaller, more deliberate target is the more specific intent.
    func testEndpointDotsBeatTheirOwnBandLine() {
        XCTAssertEqual(lineGrab(800, 800), .startHandle)
        XCTAssertEqual(lineGrab(806, 797), .startHandle)
        XCTAssertEqual(lineGrab(800, 300), .endHandle)
        XCTAssertEqual(lineGrab(795, 304), .endHandle)
    }

    /// Outside the band: a miss stays a move, clear space creates.
    func testOutsideTheBandBuffersThenCreates() {
        XCTAssertEqual(lineGrab(800, 820), .move, "20 pt past the 0% line is a miss")
        XCTAssertEqual(lineGrab(800, 800 + MaskHandles.newShapeClearance + 5), .create)
        XCTAssertEqual(lineGrab(800, 300 - MaskHandles.newShapeClearance - 5), .create)
    }

    /// A gradient drawn shorter than two grab radii would have both band bands overlap
    /// and no move target left. The central half of the axis is a move regardless.
    func testShortGradientKeepsAMoveTarget() {
        let a = CGPoint(x: 400, y: 400)
        let b = CGPoint(x: 400, y: 380)
        XCTAssertEqual(MaskHandles.linearGrab(press: CGPoint(x: 400, y: 390),
                                              start: a, end: b), .move)
        XCTAssertEqual(MaskHandles.linearGrab(press: CGPoint(x: 460, y: 391),
                                              start: a, end: b), .move)
    }

    /// A gradient with no length has no strip and no direction; drawing a new one is the
    /// only useful answer, and it still may not happen from on top of the old one.
    func testDegenerateGradient() {
        let a = CGPoint(x: 400, y: 400)
        XCTAssertEqual(MaskHandles.linearGrab(press: CGPoint(x: 404, y: 400),
                                              start: a, end: a), .move)
        XCTAssertEqual(MaskHandles.linearGrab(press: CGPoint(x: 700, y: 700),
                                              start: a, end: a), .create)
    }

    // MARK: Creating

    /// A click is not a shape. This is the guard whose absence turned one click into a
    /// mask two thousandths of the frame across.
    func testAClickDoesNotDrawAShape() {
        let p = CGPoint(x: 100, y: 100)
        XCTAssertFalse(MaskHandles.drawsShape(from: p, to: p))
        XCTAssertFalse(MaskHandles.drawsShape(from: p, to: CGPoint(x: 102, y: 100)),
                       "a 2 pt tremor is a click with a shaky hand")
        XCTAssertTrue(MaskHandles.drawsShape(from: p, to: CGPoint(x: 140, y: 130)))
        XCTAssertFalse(MaskHandles.drawsShape(from: p,
                                              to: CGPoint(x: CGFloat.nan, y: 100)))
    }

    // MARK: The constants themselves

    /// The tolerances, as reasoning rather than as magic numbers.
    func testTolerancesAreOrdered() {
        XCTAssertGreaterThan(MaskHandles.grabRadius, 9,
                             "wider than the 9 pt it replaces — the old one is the "
                             + "defect")
        XCTAssertEqual(MaskHandles.grabRadius, SliderDrag.thumbGrabRadius,
                       "the same hand, the same question: kept equal deliberately")
        XCTAssertGreaterThanOrEqual(MaskHandles.newShapeClearance,
                                    2 * MaskHandles.grabRadius,
                                    "a miss must be able to be a whole target wide and "
                                    + "still not destroy the shape")
        XCTAssertGreaterThan(MaskHandles.interiorMoveFraction, 0)
        XCTAssertLessThan(MaskHandles.interiorMoveFraction, 1)
        XCTAssertGreaterThan(MaskHandles.minimumDrawTravel, 0)
        XCTAssertLessThan(MaskHandles.minimumDrawTravel, MaskHandles.grabRadius,
                          "a deliberate drag must not have to clear a grab radius "
                          + "before it draws anything")
    }
}
