// MaskCanvasGestureTests.swift
// The half of the mask canvas's gesture work that is a fact about `MaskCanvas.swift`
// itself rather than about a rule in LumenCore.
//
// The arithmetic — which handle a press takes hold of, how a rotate drag turns a
// gradient, where a ⇧⌥ create drag puts its two ends, which of two overlapping targets
// wins — is `MaskHandles` and is tested for real in `LumenCoreTests/MaskGestureTests`,
// on a machine with no window server. What is left here is three kinds of claim that
// cannot be made there:
//
//   · The brush store's ladders, which are ordinary code in this file and testable as
//     ordinary code.
//   · The tolerances the canvas states in its OWN namespace, which must be the ones
//     `MaskHandles` owns rather than copies that happen to agree today. The file's own
//     header records what happens otherwise: `handleRadius` was a 9 pt copy that drifted
//     from the rule and cost a photograph's worth of masking.
//   · A set of ABSENCES and one presence that no API can be called for — a spacing that
//     is no longer a fraction of the source frame, a move filter that no longer
//     multiplies a normalized delta by a displayed extent, a pin test that no longer
//     runs ahead of every handle, and the hover feedback that answers the reported
//     defect. An absence has no API to call, so those are read out of the source as
//     text.
//
// `withoutComments` is ported unchanged from `CullScaleTests`, and it is not optional
// here for exactly the reason that file gives: every property asserted below is one this
// file's prose and the canvas's own comments name, so a scan over unstripped text would
// find the words arguing FOR the fix and pass whether or not the fix was there.
#if os(macOS)
import XCTest
@testable import LumenApp
import LumenCore

final class MaskCanvasGestureTests: XCTestCase {

    // MARK: Reading the source

    /// The repository, from this file's own path — the route every scanning test in this
    /// package takes. `Bundle.module` carries resources, not sources.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
    }

    /// `MaskCanvas.swift` with its comments blanked out.
    private func canvasCode() throws -> String {
        let url = Self.repositoryRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("LumenApp", isDirectory: true)
            .appendingPathComponent("MaskCanvas.swift")
        return Self.withoutComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// Comments blanked, string bodies kept, length and newlines preserved — so every
    /// offset stays valid and a line number can still be counted off the result. Ported
    /// verbatim from `CullScaleTests`; see its header for why the two constructs have to
    /// be handled in one pass rather than by two regexes.
    private static func withoutComments(_ text: String) -> String {
        var out = Array(text)
        var i = 0
        let n = out.count
        func blank(_ from: Int, _ to: Int) {
            for k in from..<to where out[k] != "\n" { out[k] = " " }
        }
        while i < n {
            let c = out[i]
            let next: Character? = i + 1 < n ? out[i + 1] : nil
            if c == "/" && next == "/" {
                var j = i
                while j < n && out[j] != "\n" { j += 1 }
                blank(i, j)
                i = j
            } else if c == "/" && next == "*" {
                var j = i + 2
                while j + 1 < n && !(out[j] == "*" && out[j + 1] == "/") { j += 1 }
                let end = Swift.min(j + 2, n)
                blank(i, end)
                i = end
            } else if c == "\"" {
                var j = i + 1
                while j < n {
                    if out[j] == "\\" { j += 2; continue }
                    if out[j] == "\"" { j += 1; break }
                    if out[j] == "\n" { break }
                    j += 1
                }
                i = j
            } else {
                i += 1
            }
        }
        return String(out)
    }

    // MARK: The tolerances are the ones MaskHandles owns

    /// EVERY GRAB RADIUS ON THIS CANVAS IS THE SAME ONE.
    ///
    /// Three targets here were written as bare literals — a similarity point's ring, a
    /// mask pin, a lasso corner's click slop — each with a comment claiming it was "the
    /// same 11 pt `MaskHandles` uses". A comment is not a link: that is precisely the
    /// arrangement `handleRadius` had before it was deleted, and the recorded history of
    /// this project is two constants drifting apart in two files. Widen the grab radius
    /// for the whole app and these used to stay where they were.
    func testTheCanvasHasNoTolerancesOfItsOwn() throws {
        XCTAssertEqual(Double(MaskCanvas.pointRingGrab), MaskHandles.grabRadius,
                       "a colour-pick point's ring has stopped agreeing with every "
                           + "other target on the canvas")
        XCTAssertEqual(Double(MaskCanvas.pinGrab), MaskHandles.grabRadius,
                       "a mask pin has stopped agreeing with every other target")
        XCTAssertEqual(Double(MaskCanvas.outlineClickSlop),
                       MaskHandles.minimumDrawTravel,
                       "how far a press may travel and still be a click is one question "
                           + "and must have one answer")

        // And the literals really are gone, rather than the constants merely agreeing
        // by arithmetic today. This is the half that goes red on a revert.
        let code = try canvasCode()
        XCTAssertFalse(code.contains("pointRingGrab: CGFloat = 11"),
                       "the ring tolerance is a copy of MaskHandles.grabRadius again")
        XCTAssertFalse(code.contains("pinGrab: CGFloat = 11"),
                       "the pin tolerance is a copy of MaskHandles.grabRadius again")
        XCTAssertFalse(code.contains("outlineClickSlop: CGFloat = 4"),
                       "the click slop is a copy of MaskHandles.minimumDrawTravel again")
    }

    // MARK: Screen points, not fractions of the source frame

    /// THE LASSO'S VERTEX SPACING IS A SCREEN DISTANCE.
    ///
    /// It was `outlineTraceStep`, 0.002 of the SOURCE long edge, compared against a
    /// source-normalized delta — a fixed fraction of the photograph, which is a
    /// different number of screen points at every magnification. At fit-to-window on a
    /// 6000 px frame that is a shade over two points and the thinning is invisible; at
    /// 4:1 the same fraction is forty-eight screen points, so the lasso recorded one
    /// vertex every 48 points and came back a coarse polygon — the tool got less
    /// accurate exactly as the photographer zoomed in to be more accurate.
    ///
    /// The constant is gone rather than reworded, and the comparison goes through
    /// `viewPoint`, which is what puts it in the same space as every tolerance in
    /// `MaskHandles`.
    func testTheLassoThinsInScreenPointsAndNotInFractionsOfTheFrame() throws {
        let code = try canvasCode()
        XCTAssertFalse(code.contains("outlineTraceStep"),
                       "the lasso is thinning by a fraction of the source frame again, "
                           + "so its accuracy depends on the zoom")
        XCTAssertTrue(code.contains("MaskHandles.traceStep"),
                      "the lasso's spacing must come from the rule that states it in "
                          + "view points")
    }

    /// AND SO IS THE BRUSH'S "did the pointer actually move" FILTER.
    ///
    /// It multiplied a SOURCE-normalized delta by the DISPLAYED rect's extent, which is
    /// the mismatch three separate branches of this file already carry a paragraph
    /// about. On a 0.35 crop the product understates the pointer's real travel by about
    /// 2.9×, so samples that had moved nearly three times the distance the filter was
    /// told to keep were dropped; and multiplying x by the width and y by the height
    /// makes the threshold elliptical on a non-square preview, so the same movement was
    /// worth different amounts in different directions.
    func testTheBrushMeasuresMovementInViewPointsLikeEverythingElse() throws {
        let code = try canvasCode()
        XCTAssertFalse(code.contains("(last.x - point.x) * Double(imageRect.width)"),
                       "the brush's move filter is measuring a source-normalized delta "
                           + "against the displayed rect again")
        XCTAssertFalse(code.contains("(last.y - point.y) * Double(imageRect.height)"))
    }

    // MARK: A pin no longer outranks the handle you were aiming at

    /// The pin test used to be the FIRST thing every press met, unconditionally.
    ///
    /// A pin and a handle are both 11 pt discs, so the tie was being broken by which
    /// test ran first rather than by which target the hand was aiming at. Pins sit at
    /// their own mask's centre, so two masks placed over one subject put one pin
    /// squarely inside the other's shape: reach for that ellipse's rim, land within
    /// 11 pt of the pin, and the selection changed under you and the drag was gone.
    ///
    /// `MaskHandles.outranksPin` is the rule and `pressTakesAHandle` is the canvas's one
    /// call to it, so the guard has to be on the pin branch itself.
    func testAPinNoLongerBeatsAHandleOfTheMaskBeingEdited() throws {
        let code = try canvasCode()
        XCTAssertTrue(code.contains("!pressTakesAHandle(at: value.startLocation)"),
                      "the pin branch is unguarded again, so a pin under a rim eats "
                          + "the drag")
        XCTAssertTrue(code.contains("MaskHandles.outranksPin("),
                      "the precedence between a pin and a handle must be the rule in "
                          + "LumenCore rather than a second opinion here")
    }

    // MARK: The canvas answers a hover

    /// NOTHING ON THIS CANVAS USED TO ANSWER A HOVER.
    ///
    /// Every handle has an 11 pt tolerance around ink drawn at 3 to 4.5 pt — the right
    /// ratio, and invisible: the picture gave no sign the pointer was over anything
    /// until the button went down and the shape moved. The rotate band is the extreme
    /// case, 22 points of live target with no ink at all on either shape, which is
    /// exactly the report: a rotate band you expect to grab and cannot find.
    ///
    /// The fix is one hit test asked twice — once for the press and once for the hover —
    /// so a second copy of the tolerances cannot draw an affordance where nothing can be
    /// grabbed. These pin that the two shapes both draw the turn mark, that the cursor
    /// is armed off the same answer, and that the answer comes from `MaskHandles`.
    func testBothShapesShowTheRotateBandAndTheCursorAgrees() throws {
        let code = try canvasCode()
        XCTAssertTrue(code.contains("private var liveLinearGrab"))
        XCTAssertTrue(code.contains("private var liveRadialGrab"))
        XCTAssertEqual(code.components(separatedBy: "rotateGlyph(&context, at: hover)")
                           .count - 1, 2,
                       "the turn mark must be drawn by BOTH the gradient and the "
                           + "ellipse — a rotate band with ink on only one of the two "
                           + "shapes is the defect half-fixed")
        XCTAssertTrue(code.contains(".lumenClickCursor(hoverIsOnANamedHandle)"),
                      "the cursor no longer says there is something here to grab")
        XCTAssertTrue(code.contains("case .rotate:"),
                      "the gradient's drag has no rotate branch, so the hit test can "
                          + "return an answer the drag cannot carry out")
    }

    /// AND THE POINTER IS TRACKED WHILE A BUTTON IS DOWN.
    ///
    /// `onContinuousHover`'s tracking area answers `mouseMoved`, and AppKit stops
    /// sending that the instant a button goes down — the view that took the press gets
    /// `mouseDragged` instead. So the stored hover froze where the press landed for the
    /// whole of every drag: the brush's cursor ring, whose entire job is to say where
    /// the next stamp will land, sat at the start of the stroke while the paint went
    /// somewhere else, and the turn mark and the lit handles were stale with it.
    func testTheDragKeepsThePointerPositionUpToDate() throws {
        let code = try canvasCode()
        XCTAssertTrue(code.contains("hover = value.location"),
                      "the brush cursor and the hover affordances go stale for the "
                          + "length of every drag again")
    }

    // MARK: The brush's own ladders

    /// `[` and `]` step the brush on a GEOMETRIC ladder, because size is a fraction of
    /// the long edge spanning two and a half decades: a fixed step is either uselessly
    /// small at the top or unusably coarse at the bottom.
    func testTheBrushSizeLadderIsGeometricAndReversible() {
        let brush = MaskBrushStore()
        brush.size = 0.05
        brush.nudgeSize(up: true)
        XCTAssertEqual(brush.size, 0.05 * 1.15, accuracy: 1e-12)
        brush.nudgeSize(up: false)
        XCTAssertEqual(brush.size, 0.05, accuracy: 1e-12,
                       "one press up and one press down must land back where it was")
    }

    /// And it stops at both ends rather than walking off them. A brush of zero paints
    /// nothing and a brush of half the frame is not a brush.
    func testTheBrushSizeLadderStopsAtBothEnds() {
        let brush = MaskBrushStore()
        for _ in 0..<60 { brush.nudgeSize(up: false) }
        XCTAssertEqual(brush.size, 0.002, accuracy: 1e-12)
        for _ in 0..<200 { brush.nudgeSize(up: true) }
        XCTAssertEqual(brush.size, 0.5, accuracy: 1e-12)
        // Forty presses end to end, which is the claim `nudgeSize` makes about the feel
        // of the ladder and the only reason 1.15 is the number. The exact figure is
        // log(250)/log(1.15) = 39.506, so the fortieth press is the one that reaches the
        // ceiling and is clamped there — 1.15^39 lands at 0.466, short of 0.5.
        //
        // This assertion said 39, and its note said seventeen; both were written on a
        // lane that cannot run this test. Two wrong numbers guarding one constant is
        // worse than none, because the next person to change 1.15 would have trusted it.
        let steps = (log(0.5 / 0.002) / log(1.15)).rounded()
        XCTAssertEqual(steps, 40, "the ladder's length has changed under its own note")
    }

    /// Feather is a PERCENTAGE of the stamp, so its ladder is linear — and clamped, so
    /// ⇧] held down cannot leave it above 100 where the cursor's core ring would invert.
    func testTheFeatherLadderIsLinearAndClamped() {
        let brush = MaskBrushStore()
        brush.feather = 50
        brush.nudgeFeather(up: true)
        XCTAssertEqual(brush.feather, 60, accuracy: 1e-12)
        for _ in 0..<20 { brush.nudgeFeather(up: true) }
        XCTAssertEqual(brush.feather, 100, accuracy: 1e-12)
        for _ in 0..<20 { brush.nudgeFeather(up: false) }
        XCTAssertEqual(brush.feather, 0, accuracy: 1e-12)
    }

    /// A STROKE RECORDS THE SETTINGS IT WAS DRAWN WITH, which is what makes the brush
    /// store session state with nothing to migrate: changing the size afterwards must
    /// not reach back into paint that is already down.
    func testAStrokeCarriesTheSettingsInForceWhenItWasDrawn() {
        let brush = MaskBrushStore()
        brush.size = 0.08
        brush.feather = 30
        brush.flow = 60
        brush.density = 90
        brush.erase = true
        brush.automask = true
        let stroke = brush.stroke(points: [BrushPoint(x: 0.5, y: 0.5, pressure: 1, t: 0)])
        XCTAssertEqual(stroke.size, 0.08, accuracy: 1e-12)
        XCTAssertEqual(stroke.feather, 30, accuracy: 1e-12)
        XCTAssertEqual(stroke.flow, 60, accuracy: 1e-12)
        XCTAssertEqual(stroke.density, 90, accuracy: 1e-12)
        XCTAssertTrue(stroke.erase)
        XCTAssertTrue(stroke.automask)

        brush.size = 0.4
        XCTAssertEqual(stroke.size, 0.08, accuracy: 1e-12,
                       "a stroke already drawn changed width when the brush did")
    }

    /// Flow may not be zero. A stroke that deposits nothing is indistinguishable from a
    /// stroke that was never recorded, and the brush store's own clamp is the only thing
    /// standing between a digit key and that.
    func testAStrokeAlwaysDepositsSomething() {
        let brush = MaskBrushStore()
        brush.flow = 0
        brush.size = 0
        let stroke = brush.stroke(points: [BrushPoint(x: 0.5, y: 0.5, pressure: 1, t: 0)])
        XCTAssertGreaterThan(stroke.flow, 0)
        XCTAssertGreaterThan(stroke.size, 0)
    }
}
#endif
