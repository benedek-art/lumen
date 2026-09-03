// ColorPanelReachTests.swift
// Two things in the colour panel that could not be reached, and one that could be
// reached from everywhere.
//
// B3-02 — the mixer's hue ring wore `contentShape(Rectangle())` over its whole 130×130
// box under a `DragGesture(minimumDistance: 0)` and had NO hit test. Every press in that
// square — the hollow middle of the wheel, the four corners outside the circle — ran
// `nearestHandle` and threw one end of the selected band's arc to the clicked angle. The
// centre is the worst of them: the old guard rejected only the exact pixel (0,0), so a
// press one point off centre handed `atan2` two sub-pixel numbers and the handle went
// somewhere arbitrary. The house pattern for gating a press is `SliderDrag.grabsThumb`
// (11 pt); the ring is an ANNULUS, so its gate is two radii and not one.
//
// B3-03 — `PickTarget.pointColor(index:)`, "re-sample an existing swatch", was fully
// implemented on both ends and had ZERO producers. The resolver was correct and
// unreachable, so the only route to fixing a mis-aimed swatch was − then the eyedropper
// again, which appends a fresh swatch at the tail and discards the Hue, Saturation,
// Luminance, Range and Variance already dialled into the old one.
//
// WHY THIS IS A TEXT SCAN. `MixerHueRing.grab`, `ColorPanel.tapSwatch` and
// `AppState.resolvePick` all live in `Sources/LumenApp`, which has no test target that
// runs on this lane. What IS testable as code — `SliderDrag.grabsThumb`, `Num.hueDelta`,
// `PointColor` — is in LumenCore and is exercised for real below. The two halves are a
// proof together and neither is one alone: the scan pins the expressions the shipped
// code decides with, and the arithmetic pins what those expressions decide.
//
// COMMENTS ARE STRIPPED BEFORE EVERY SCAN. Both fixes are heavily commented and their
// comments name the very symbols scanned for here — `nearestHandle`, `PickTarget`,
// `pointColor(index:)`, `SliderDrag.grabsThumb`. Left in, a doc comment would satisfy
// this file's assertions on its own and every substitution proof below would be
// worthless. The stripper is the one `DeliveryNameTests` uses, copied rather than
// shared because these test files are owned separately.

import Foundation
import XCTest
@testable import LumenCore

// MARK: - B3-02, the ring's hit test

final class ColorPanelReachTests: XCTestCase {

    // MARK: The gesture: what the press has to pass, and in what order

    /// The ORDER is the fix. A gate placed after `sliderGestureChanged(true)` would still
    /// open an undo epoch for a press that grabbed nothing, and a gate placed after
    /// `onHandleMoved` would not be a gate at all.
    ///
    /// SUBSTITUTION: move `sliderGestureChanged(true)` back above the `grab` call — the
    /// shape the file had before the fix — and `gate < epoch` is false. It prints
    /// "a press that grabs nothing must not open a gesture epoch".
    func testThePressIsGatedBeforeAnyHandleMovesOrAnyUndoEpochOpens() throws {
        let g = try Self.gesture()
        let reset = try XCTUnwrap(g.range(of: "event.clickCount")).lowerBound
        let gate = try XCTUnwrap(g.range(of: "MixerHueRing.grab(")).lowerBound
        let epoch = try XCTUnwrap(g.range(of: "sliderGestureChanged(true)")).lowerBound
        let write = try XCTUnwrap(g.range(of: "onHandleMoved(")).lowerBound

        XCTAssertLessThan(reset, gate,
                          "the double-click reset has to be decided before the hit test, "
                          + "or the gate swallows the reset from the hollow centre")
        XCTAssertLessThan(gate, epoch,
                          "a press that grabs nothing must not open a gesture epoch")
        XCTAssertLessThan(epoch, write,
                          "the epoch is what makes the drag one undo step")
    }

    /// The gate reads the PRESS point. Gating `drag.location` instead would let a press
    /// that started in the dead centre pick a handle up later by wandering onto the ring,
    /// which is the defect with one more step in it.
    ///
    /// SUBSTITUTION: restore `let handle = grabbed ?? MixerHueRing.nearestHandle(to:
    /// degrees, in: arcList[index])` and delete the guard. The first assertion fails —
    /// "the gesture reaches a handle without passing the gate: `nearestHandle` always
    /// returns one of the four, which is exactly how every press in the box moved one."
    func testNoPressReachesAHandleWithoutPassingTheGate() throws {
        let g = try Self.gesture()
        XCTAssertFalse(g.contains("nearestHandle"),
                       "the gesture reaches a handle without passing the gate: "
                       + "`nearestHandle` always returns one of the four, which is "
                       + "exactly how every press in the box moved one")
        XCTAssertTrue(g.contains("MixerHueRing.grab(at: drag.startLocation,"),
                      "the gate must read the PRESS point; gating `drag.location` lets a "
                      + "press in the centre pick a handle up by wandering onto the ring")

        // A miss must END the event, not fall through it.
        let window = try Scan.between("MixerHueRing.grab(", "sliderGestureChanged", in: g)
        XCTAssertTrue(window.contains("else { return }"),
                      "a press that grabbed nothing has to leave the whole gesture inert")
    }

    /// The reset branch is ahead of the gate on purpose, so a double-click still resets
    /// the arc from anywhere in the box exactly as it did before the fix — including from
    /// the hollow centre, which the gate now rejects. A radius gate that swallowed the
    /// reset would be a NEW defect traded for the old one.
    ///
    /// The branch's own reason is worth restating because it is the trap: a
    /// `minimumDistance: 0` drag claims every press, so an `onTapGesture(count: 2)`
    /// behind it never fires and the reset has to be read out of `NSApp.currentEvent`.
    ///
    /// SUBSTITUTION: hoist the gate above the `clickCount` branch. `head` is then the
    /// slice that ENDS at the gate, so it no longer contains `onResetArc()` and this
    /// fails with "double-clicking the middle of the wheel would stop resetting the arc".
    func testTheDoubleClickResetStillLandsFromAnywhereInTheBox() throws {
        let g = try Self.gesture()
        let head = try Scan.between("if !pressWasReset", "MixerHueRing.grab(", in: g)
        XCTAssertTrue(head.contains("event.clickCount >= 2"),
                      "the reset is read from the click count, because a "
                      + "minimumDistance-0 drag claims the press an onTapGesture(count: 2) "
                      + "would need")
        XCTAssertTrue(head.contains("onResetArc()"),
                      "the reset must be decided BEFORE the annulus gate — "
                      + "double-clicking the middle of the wheel would stop resetting "
                      + "the arc")
        XCTAssertTrue(head.contains("grabbed = nil"),
                      "a reset drops whatever the press was holding")
        XCTAssertTrue(head.contains("pressWasReset = true"),
                      "and swallows the rest of the gesture, so the reset is not "
                      + "immediately re-edited by the same press")
    }

    // MARK: The gate itself

    /// TWO radii. One is a disc, and a disc contains the centre — the arbitrary-`atan2`
    /// case that is the sharp end of B3-02.
    ///
    /// SUBSTITUTION: delete the `>=` line, leaving only the outer bound. The first
    /// assertion fails: "the gate is a DISC — the hollow centre is inside it again, and a
    /// press one point off centre still throws a handle to an arbitrary angle."
    func testTheGateIsAnAnnulusAndNotADisc() throws {
        let body = try Self.grabBody()
        XCTAssertTrue(body.contains("pressRadius >= radius - ringGrabBand"),
                      "the gate is a DISC — the hollow centre is inside it again, and a "
                      + "press one point off centre still throws a handle to an "
                      + "arbitrary angle")
        XCTAssertTrue(body.contains("pressRadius <= radius + ringGrabBand"),
                      "without the outer bound the four corners of the box are in")
        XCTAssertTrue(body.contains("guard radius > ringGrabBand else { return nil }"),
                      "a box too small to have an annulus has no ring to grab, and this "
                      + "is what stops `radius - ringGrabBand` going negative and "
                      + "letting the centre back through the lower bound")

        // The angular half borrows the house rule rather than restating the number.
        XCTAssertTrue(body.contains("SliderDrag.grabsThumb("),
                      "the 11 pt grab distance is `SliderDrag`'s, called and not copied, "
                      + "so the ring and the slider thumb cannot drift apart")
        XCTAssertTrue(body.contains("Num.hueDelta("),
                      "the distance to the handle is a wrapped DELTA: 359° and 1° are "
                      + "two degrees apart, and their arc lengths from a common origin "
                      + "are not")
    }

    /// The hit test and the ink have to be the same circle. The old Canvas computed its
    /// radius inline, so a hit test written beside it would have been a second copy of
    /// the geometry — a gate that drifts off the ring it is gating.
    ///
    /// SUBSTITUTION: put `let bound = Swift.min(size.width, size.height) / 2; let
    /// arcRadius = bound - 5` back in the Canvas. The second assertion fails: "the ink
    /// and the hit test would be two copies of one circle."
    func testTheInkAndTheHitTestShareOneRadiusFunction() throws {
        let source = try Self.colorPanel()
        XCTAssertTrue(
            source.contains("static func arcRadius(box: CGFloat) -> CGFloat { box / 2 - 5 }"),
            "one function decides where the arc is drawn and where it can be grabbed")

        let canvas = try Scan.between("Canvas { context, size in", "let outer =", in: source)
        XCTAssertTrue(canvas.contains("MixerHueRing.arcRadius("),
                      "the ink and the hit test would be two copies of one circle")
        XCTAssertTrue(try Self.grabBody().contains("arcRadius(box: box)"),
                      "and the gate asks the same function the Canvas asked")
    }

    // MARK: What those expressions decide

    /// The numbers this arithmetic runs on, read out of the file rather than remembered.
    /// Without this the test below would be fiction about a box that might not exist.
    func testTheBoxIsOneHundredAndThirtyPointsSquare() throws {
        let source = try Self.colorPanel()
        XCTAssertTrue(source.contains("static let diameter: CGFloat = 118"))
        XCTAssertTrue(source.contains("static let ringGrabBand: Double = 10"))
        XCTAssertTrue(source.contains(
            ".frame(width: MixerHueRing.diameter + 12, height: MixerHueRing.diameter + 12)"))
        XCTAssertTrue(try Self.gesture().contains("let box = MixerHueRing.diameter + 12"),
                      "the gesture measures from the same box the frame reserves")
        XCTAssertEqual(Self.box, 130, "118 + 12, as read above")
        XCTAssertEqual(Self.arcRadius, 60, "box / 2 - 5, as read above")
    }

    /// The four presses named in the finding, run through a faithful transcription of the
    /// two radius guards asserted verbatim in `testTheGateIsAnAnnulusAndNotADisc`.
    ///
    /// This is the assertion that was red for EVERY point in the box before the fix.
    func testTheAnnulusRejectsTheCentreAndTheCornersAndKeepsTheArc() {
        // The centre, and the one point off it that made this an S2 rather than a
        // nuisance: r = 1.41, which is nowhere near the ring, and an `atan2` of two
        // sub-pixel numbers, which is nowhere in particular.
        XCTAssertFalse(Self.annulusAdmits(65, 65), "the dead centre")
        XCTAssertFalse(Self.annulusAdmits(66, 66),
                       "one point off centre — the arbitrary-angle press")

        // The four corners of the 130 pt box, at r = 91.9, outside the circle entirely.
        for corner in [(0.0, 0.0), (130.0, 0.0), (0.0, 130.0), (130.0, 130.0)] {
            XCTAssertFalse(Self.annulusAdmits(corner.0, corner.1), "a corner of the box")
        }

        // The coloured wheel itself is drawn between r = 41 and r = 54 (outer =
        // arcRadius − 6, inner = outer − ringWidth). A press on the ink of the wheel is
        // NOT a press on the arc, and is now inert — which is what leaves that interior
        // free for B3-06's "click a hue to select its band".
        XCTAssertFalse(Self.annulusAdmits(65 + 47, 65), "the wheel's own ink")

        // And the arc keeps its own presses, with 10 pt of forgiveness either side of it.
        XCTAssertTrue(Self.annulusAdmits(65 + 60, 65), "dead on the arc")
        XCTAssertTrue(Self.annulusAdmits(65 + 50, 65), "the inner edge of the band")
        XCTAssertTrue(Self.annulusAdmits(65 + 70, 65), "the outer edge of the band")
        XCTAssertFalse(Self.annulusAdmits(65 + 49.9, 65))
        XCTAssertFalse(Self.annulusAdmits(65 + 70.1, 65))
    }

    /// The angular half, run against the REAL LumenCore functions the gate calls —
    /// `SliderDrag.grabsThumb` and `Num.hueDelta` — so this half is not a transcription
    /// of anything.
    func testTheAngularToleranceIsTheHousesElevenPointsMeasuredAsADelta() {
        XCTAssertEqual(SliderDrag.thumbGrabRadius, 11,
                       "the ring borrows the slider thumb's number; if it moves, the "
                       + "ring's tolerance moves with it, which is the point of calling "
                       + "rather than copying")

        // 11 pt of arc at r = 60 is 10.5°, so a handle 10° away is caught and one 11°
        // away is not.
        XCTAssertTrue(SliderDrag.grabsThumb(pressX: Self.arcLength(degrees: 10), thumbX: 0))
        XCTAssertFalse(SliderDrag.grabsThumb(pressX: Self.arcLength(degrees: 11), thumbX: 0))

        // The wrap. A handle at 359° and a press at 1° are two degrees apart — 2.1 pt of
        // arc — and a subtraction that did not wrap would call them 358° apart and refuse
        // a press that is sitting on the handle.
        let wrapped = abs(Num.hueDelta(359, 1))
        XCTAssertEqual(wrapped, 2, accuracy: 1e-9)
        XCTAssertTrue(SliderDrag.grabsThumb(pressX: Self.arcLength(degrees: wrapped),
                                            thumbX: 0))
        XCTAssertFalse(SliderDrag.grabsThumb(pressX: Self.arcLength(degrees: abs(359 - 1)),
                                             thumbX: 0),
                       "what an unwrapped subtraction would have decided")
    }

    // MARK: - geometry, transcribed under the assertions above

    /// `MixerHueRing.diameter + 12`, pinned by `testTheBoxIsOneHundredAndThirtyPoints…`.
    private static let box: Double = 118 + 12
    /// `arcRadius(box:)` = `box / 2 - 5`, pinned by the same test.
    private static let arcRadius: Double = box / 2 - 5
    /// `ringGrabBand`, pinned by the same test.
    private static let band: Double = 10

    /// A transcription of the two radius guards in `MixerHueRing.grab`, which
    /// `testTheGateIsAnAnnulusAndNotADisc` asserts verbatim against the source. If the
    /// shipped guards change, that test fails first and names what to change here.
    private static func annulusAdmits(_ x: Double, _ y: Double) -> Bool {
        guard arcRadius > band else { return false }
        let dx = x - box / 2
        let dy = y - box / 2
        let r = (dx * dx + dy * dy).squareRoot()
        return r.isFinite && r >= arcRadius - band && r <= arcRadius + band
    }

    private static func arcLength(degrees: Double) -> Double {
        degrees * .pi / 180 * arcRadius
    }

    // MARK: - slices

    private static func colorPanel() throws -> String {
        let raw = try Scan.appSource("ColorPanel.swift")
        return Scan.squeezed(Scan.stripped(raw))
    }

    /// The ring's whole gesture, comments gone and whitespace flattened.
    private static func gesture() throws -> String {
        try Scan.between("DragGesture(minimumDistance: 0)", ".onEnded", in: colorPanel())
    }

    private static func grabBody() throws -> String {
        try Scan.between("static func grab(at point", "static func point(", in: colorPanel())
    }
}

// MARK: - B3-03, the re-pick that had no producer

final class PointColorRePickReachTests: XCTestCase {

    // MARK: The finding

    /// THE ASSERTION THAT WAS RED. `PickTarget.pointColor(index:)` must be CONSTRUCTED
    /// somewhere outside the resolver's own `case`, and one of those constructions must
    /// ARM a pick — because `state.pickTarget == .pointColor(index: i)` also constructs
    /// the value, and a comparison against a target nothing ever sets is still zero
    /// producers dressed up as three.
    ///
    /// SUBSTITUTION (whole fix reverted, chip back to `onTapGesture { selectedSwatch = i }`):
    /// `producers` is empty, the first assertion fails and prints
    /// "`PickTarget.pointColor(index:)` is constructed nowhere: found []".
    ///
    /// SUBSTITUTION (partial — keep the armed paint and the `==` comparisons, delete only
    /// `state.beginPick(.pointColor(index: i))`): the first assertion PASSES with two
    /// sites and the second fails, printing "nothing ARMS it — every site only compares
    /// against a target no code ever sets". That second assertion is the whole finding.
    func testTheResamplePickHasAnArmingProducer() throws {
        let sites = try Self.producersAcrossTheApp()
        XCTAssertFalse(sites.isEmpty,
                       "`PickTarget.pointColor(index:)` is constructed nowhere: "
                       + "found \(sites)")
        XCTAssertTrue(sites.contains { $0.contains("beginPick(") },
                      "nothing ARMS it — every site only compares against a target no "
                      + "code ever sets, which is the resolver still being unreachable: "
                      + "\(sites)")
    }

    /// THE CLASSIFIER, proved on a fixture rather than trusted.
    ///
    /// A producer CONSTRUCTS the case; the resolver's `case .pointColor(let index):`
    /// DESTRUCTURES it, and both spellings contain the same twelve characters. Two
    /// independent marks separate them, and a site must satisfy BOTH to be counted:
    ///
    ///   1. no `case` keyword on the line ahead of the occurrence. This is the
    ///      discriminator that does the work, and its failure direction is safe: a
    ///      producer hidden on a `case` line (a one-line case body) goes UNCOUNTED, which
    ///      makes the test above stricter, never laxer.
    ///   2. the parentheses carry the argument label `index:` and introduce no binding
    ///      (`let`, `var`, `_`). Swift requires the label on a construction and allows a
    ///      pattern to omit it, and a pattern that keeps it must still bind something.
    ///      This is what catches `case .pointColor(index: 0):` — a pattern matching a
    ///      literal, which mark 2 alone would happily call a producer.
    func testTheResolversOwnCaseIsNotCountedAsAProducer() {
        let fixture = """
            case .pointColor(let index):
                updateRecipe { recipe in
            case .pointColor(index: let index):
            case .pointColor(index: 0):
            state.beginPick(.pointColor(index: i))
            let armed = state.pickTarget == .pointColor(index: i)
            """
        let sites = Scan.pointColorProducers(in: fixture, file: "fixture")
        XCTAssertEqual(sites.count, 2,
                       "three pattern spellings must all be rejected and both "
                       + "constructions kept: \(sites)")
        XCTAssertEqual(sites.filter { $0.contains("beginPick(") }.count, 1)
        XCTAssertFalse(sites.contains { $0.contains("case ") },
                       "a `case` line was counted as a producer, which would let the "
                       + "resolver satisfy the reachability assertion on its own — the "
                       + "exact way this test could pass its own substitution proof")
    }

    // MARK: What the re-pick must do once it is reachable

    /// The resolver replaces the SAMPLE. Rebuilding the swatch would discard the five
    /// values the photographer dialled in, which is the cost B3-03 describes and the only
    /// reason re-sampling is worth reaching at all.
    ///
    /// SUBSTITUTION: change the case body to
    /// `recipe.develop.pointColors[index] = PointColor(sample: rgb)`. The third assertion
    /// fails: "a re-pick that rebuilds the swatch throws away exactly the five values
    /// B3-03 exists to keep — it is the − and eyedropper route with fewer clicks."
    func testTheResolverReplacesTheSampleAndRebuildsNothing() throws {
        let body = try Self.resolverCase()
        XCTAssertTrue(body.contains("recipe.develop.pointColors[index].sample = rgb"),
                      "the re-pick writes one field")
        XCTAssertTrue(body.contains("guard recipe.develop.pointColors.indices.contains(index)"),
                      "the armed index can be stale — the swatch it names may have been "
                      + "removed while the pick was waiting for a click")
        XCTAssertFalse(body.contains("PointColor("),
                       "a re-pick that rebuilds the swatch throws away exactly the five "
                       + "values B3-03 exists to keep — it is the − and eyedropper route "
                       + "with fewer clicks")
        XCTAssertTrue(body.contains("updateRecipe"),
                      "one undo step, and the multi-selection fan-out, come from here")
    }

    /// The other half of that proof, as running code: the model really does let the
    /// sample be replaced on its own. Pinned rather than assumed, because a `didSet` or a
    /// computed `sample` would make the resolver's one correct line quietly wrong, and
    /// the text scan above cannot see that.
    func testASwatchKeepsItsFiveDialledValuesWhenOnlyTheSampleIsReplaced() {
        var swatch = PointColor(sample: [0.42, 0.22, 0.16], range: 72, variance: -30,
                                shift: HSLShift(h: 30, s: -12, l: 6))
        swatch.sample = [0.51, 0.33, 0.29]      // the resolver's line, pinned above

        XCTAssertEqual(swatch.sample, [0.51, 0.33, 0.29])
        XCTAssertEqual(swatch.range, 72)
        XCTAssertEqual(swatch.variance, -30)
        XCTAssertEqual(swatch.shift, HSLShift(h: 30, s: -12, l: 6))

        // And what the route the photographer was left with costs him, stated as a fact:
        // a swatch born from a fresh pick carries the defaults, not his edit.
        let reborn = PointColor(sample: [0.51, 0.33, 0.29])
        XCTAssertEqual(reborn.range, 50)
        XCTAssertEqual(reborn.variance, 0)
        XCTAssertEqual(reborn.shift, HSLShift())
        XCTAssertNotEqual(reborn.shift, swatch.shift,
                          "− then eyedrop again is not a re-pick; it is a new swatch")
    }

    /// The chip that arms is the chip the ring is on, and the ring's position is a clamp.
    /// If the two disagreed, a click would arm a re-pick of a swatch other than the one
    /// the sliders are editing — a worse defect than the one being fixed.
    func testTheChipThatArmsIsTheChipTheRingIsOn() throws {
        let source = try Self.colorPanel()
        let tap = try Scan.between("private func tapSwatch(", "private var pickIsArmed",
                                   in: source)
        XCTAssertTrue(
            tap.contains("ColorPanel.removalTarget(selected: selectedSwatch, count: count) == i"),
            "arming has to ask the clamp, not the raw `selectedSwatch`: past the end of "
            + "the list they are different chips")
        XCTAssertTrue(tap.contains("selectedSwatch = i"),
                      "an unringed chip still just selects")
        XCTAssertTrue(tap.contains("state.cancelPick()"),
                      "pressing an armed affordance again cancels, the same contract as "
                      + "this panel's two other eyedroppers")
        XCTAssertTrue(tap.contains("state.beginPick(.pointColor(index: i))"))

        // The ring itself. `pointColorSection` spells the clamp out inline instead of
        // calling `removalTarget`, so there are two copies of one rule in this file. They
        // agree today — this is what says so out loud, and the honest fix is for the
        // section to call `removalTarget` the way `tapSwatch` and `removeSwatch` do.
        let section = try Scan.between("private var pointColorSection",
                                       "private func swatchChip(", in: source)
        XCTAssertTrue(section.contains("min(max(selectedSwatch, 0), swatches.count - 1)"),
                      "the ring's clamp")
        let removal = try Scan.between("static func removalTarget(",
                                       "static func selectionAfterRemoval", in: source)
        XCTAssertTrue(removal.contains("min(max(selected, 0), count - 1)"),
                      "and the arming clamp, which must stay the same rule")
    }

    // MARK: - slices

    /// Every producer in the app module. `PickTarget` is declared in `AppState.swift` and
    /// nothing outside `Sources/LumenApp` can name it, so this listing is complete —
    /// `Tests/` is deliberately not scanned, because a producer in a test does not make
    /// the swatch re-pickable for the photographer.
    private static func producersAcrossTheApp() throws -> [String] {
        let dir = Scan.appRoot
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertGreaterThan(names.count, 10, "the app module did not enumerate")
        var out: [String] = []
        for name in names {
            let text = try String(contentsOf: dir.appendingPathComponent(name),
                                  encoding: .utf8)
            out += Scan.pointColorProducers(in: text, file: name)
        }
        return out
    }

    private static func colorPanel() throws -> String {
        let raw = try Scan.appSource("ColorPanel.swift")
        return Scan.squeezed(Scan.stripped(raw))
    }

    /// The resolver's own branch, up to the next one.
    private static func resolverCase() throws -> String {
        let raw = try Scan.appSource("AppState.swift")
        let source = Scan.squeezed(Scan.stripped(raw))
        return try Scan.between("case .pointColor(let index):", "case .maskSample(",
                                in: source)
    }
}

// MARK: - reading LumenApp as text

/// Private to this file. The stripper is `DeliveryNameTests`' one, copied deliberately:
/// these test files are separately owned and a shared helper is a shared edit.
///
/// It does not understand string literals, so a `//` inside one would truncate a line.
/// Checked: no literal in `ColorPanel.swift` or in the scanned region of `AppState.swift`
/// contains one.
private enum Scan {

    static let appRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/LumenApp")

    static func appSource(_ name: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(name), encoding: .utf8)
    }

    static func stripped(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") { inBlock = false; index = source.index(index, offsetBy: 2) }
                else { index = source.index(after: index) }
                continue
            }
            if rest.hasPrefix("/*") { inBlock = true; index = source.index(index, offsetBy: 2); continue }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" { index = source.index(after: index) }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }

    /// The text between two markers, so an assertion can be scoped to one function or
    /// one branch instead of to the whole file — which is what makes an ORDERING
    /// assertion possible at all.
    static func between(_ a: String, _ b: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: a), "missing marker: \(a)").upperBound
        let tail = source[start...]
        let end = try XCTUnwrap(tail.range(of: b), "missing marker: \(b)").lowerBound
        return String(tail[..<end])
    }

    /// Every run of whitespace to one space, so an assertion about a wrapped expression
    /// is an assertion about the expression and not about where the author wrapped it.
    static func squeezed(_ source: String) -> String {
        var out = ""
        var space = false
        for ch in source {
            if ch.isWhitespace {
                if !space { out.append(" "); space = true }
            } else {
                out.append(ch); space = false
            }
        }
        return out
    }

    /// Sites that CONSTRUCT `PickTarget.pointColor(index:)`. See
    /// `testTheResolversOwnCaseIsNotCountedAsAProducer` for the two marks and why each
    /// one is here. Line-based, so it runs on stripped-but-unsqueezed source.
    static func pointColorProducers(in source: String, file: String) -> [String] {
        var out: [String] = []
        let lines = stripped(source).split(separator: "\n", omittingEmptySubsequences: false)
        for (n, raw) in lines.enumerated() {
            let line = String(raw)
            var from = line.startIndex
            while let hit = line.range(of: ".pointColor(", range: from..<line.endIndex) {
                from = hit.upperBound
                // MARK 1: a pattern position.
                let ahead = line[line.startIndex..<hit.lowerBound]
                if ahead.contains("case ") || ahead.hasSuffix("case") { continue }
                // MARK 2: a call passes a labelled argument; a pattern binds one.
                guard let close = line[hit.upperBound...].firstIndex(of: ")") else { continue }
                let args = line[hit.upperBound..<close]
                guard args.contains("index:"), !args.contains("let "),
                      !args.contains("var "), !args.contains("_") else { continue }
                out.append("\(file):\(n + 1) \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        return out
    }
}
