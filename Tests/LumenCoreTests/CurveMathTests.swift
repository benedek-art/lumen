// The tone curve editor's editing rules, and the mixer's group move — the two pieces of
// panel arithmetic that used to live inside `#if os(macOS)` SwiftUI views, where nothing
// could reach them.
//
// Why the source scans at the bottom exist. Half of what goes wrong on a direct-
// manipulation surface is not the arithmetic being wrong, it is the VIEW no longer
// calling it: a rule extracted into LumenCore and then bypassed at the call site is a
// green lane over a broken editor. So the arithmetic is pinned here as arithmetic AND
// the call sites are pinned as text, with comments stripped first — this project has
// twice shipped a scan that a doc comment naming the symbol was enough to satisfy, and
// `CurveEditorView`'s header names most of these symbols on purpose.

import XCTest
@testable import LumenCore

final class CurveMathTests: XCTestCase {

    // MARK: - Sanitizing

    func testAMalformedWireCurveBecomesTheIdentity() {
        XCTAssertEqual(CurveEditing.sanitized(nil), CurveEditing.identity)
        XCTAssertEqual(CurveEditing.sanitized([]), CurveEditing.identity)
        // One usable row is not a curve; a short row and a NaN are not rows at all.
        XCTAssertEqual(CurveEditing.sanitized([[0.5]]), CurveEditing.identity)
        XCTAssertEqual(CurveEditing.sanitized([[0.2, 0.3], [0.5, Double.nan]]),
                       CurveEditing.identity)
    }

    func testSanitizingSortsAndClampsWithoutDroppingPoints() {
        let out = CurveEditing.sanitized([[1.4, -0.2], [0.5, 0.5], [0, 0]])
        XCTAssertEqual(out, [[0, 0], [0.5, 0.5], [1, 0]])
    }

    func testTheIdentityIsRecognisedSoItStoresAsNil() {
        XCTAssertTrue(CurveEditing.isIdentity([[0, 0], [1, 1]]))
        XCTAssertFalse(CurveEditing.isIdentity([[0, 0], [0.5, 0.6], [1, 1]]))
        XCTAssertFalse(CurveEditing.isIdentity([[0, 0.02], [1, 1]]))
    }

    // MARK: - Moving a point

    // The property that matters: whatever a drag asks for, the array comes back sorted
    // with strictly increasing x, so `MonotoneCubic` keeps every point it was given and
    // the index the gesture holds keeps naming the same point.
    func testAPointCanNeverBeDraggedPastItsNeighbours() {
        let points: [[Double]] = [[0, 0], [0.3, 0.3], [0.6, 0.6], [1, 1]]
        for target in stride(from: -0.5, through: 1.5, by: 0.01) {
            let moved = CurveEditing.moved(points, index: 1, toX: target, toY: 0.4)
            XCTAssertEqual(moved.count, points.count)
            for i in 1..<moved.count {
                XCTAssertGreaterThan(moved[i][0], moved[i - 1][0],
                                     "x must stay strictly increasing at target \(target)"
                                     + " — MonotoneCubic DROPS a point whose x is not "
                                     + "greater than the one before it, so a crossing "
                                     + "silently deletes a point mid-drag")
            }
            XCTAssertLessThanOrEqual(moved[1][0],
                                     points[2][0] - CurveEditing.minimumPointGap + 1e-12)
        }
    }

    func testTheAnchorsStillTravelTheirOwnEdges() {
        let points: [[Double]] = [[0, 0], [0.5, 0.5], [1, 1]]
        // The black point may be lifted and pushed right, up to its neighbour's window.
        let black = CurveEditing.moved(points, index: 0, toX: 0.9, toY: 0.25)
        XCTAssertEqual(black[0][0], 0.5 - CurveEditing.minimumPointGap, accuracy: 1e-12)
        XCTAssertEqual(black[0][1], 0.25, accuracy: 1e-12)
        // The white point the same, downward and leftward.
        let white = CurveEditing.moved(points, index: 2, toX: 0.1, toY: 0.8)
        XCTAssertEqual(white[2][0], 0.5 + CurveEditing.minimumPointGap, accuracy: 1e-12)
        XCTAssertEqual(white[2][1], 0.8, accuracy: 1e-12)
    }

    func testACollapsedWindowRefusesToReorderRatherThanGuessing() {
        // Only a decoded recipe can produce neighbours this close. The x must not move;
        // the y still must, so the point is not frozen.
        let points: [[Double]] = [[0.5, 0.1], [0.5005, 0.2], [0.501, 0.3]]
        let moved = CurveEditing.moved(points, index: 1, toX: 0.9, toY: 0.7)
        XCTAssertEqual(moved[1][0], 0.5005, accuracy: 1e-12)
        XCTAssertEqual(moved[1][1], 0.7, accuracy: 1e-12)
    }

    // MARK: - Deleting a point

    func testTheBlackAndWhiteAnchorsCannotBeDeleted() {
        let points: [[Double]] = [[0, 0], [0.4, 0.5], [0.7, 0.6], [1, 1]]
        XCTAssertNil(CurveEditing.deleting(points, at: 0),
                     "deleting the first point leaves MonotoneCubic extending flat below "
                     + "the new first x — every shadow under it renders one identical "
                     + "value, and only Flatten undoes it")
        XCTAssertNil(CurveEditing.deleting(points, at: points.count - 1))
        XCTAssertEqual(CurveEditing.deleting(points, at: 1),
                       [[0, 0], [0.7, 0.6], [1, 1]])
    }

    func testATwoPointCurveHasNothingToDelete() {
        for i in -1...2 {
            XCTAssertFalse(CurveEditing.isDeletable(index: i, count: 2))
        }
    }

    // MARK: - Hit testing

    func testTheHitTargetIsLargerThanTheDrawnPoint() {
        // The plot is 292 pt wide in the develop column at its 320 pt minimum; the dot
        // is drawn at radius 3 and the tolerance is 8. A press 6 pt away — clean off the
        // ink — must still take the point, and one 10 pt away must not.
        let plot = 292.0
        let tolerance = 8.0 / plot
        let points: [[Double]] = [[0, 0], [0.5, 0.5], [1, 1]]
        XCTAssertEqual(CurveEditing.hitIndex(points, x: 0.5 + 6 / plot, y: 0.5,
                                             toleranceX: tolerance,
                                             toleranceY: tolerance), 1)
        XCTAssertNil(CurveEditing.hitIndex(points, x: 0.5 + 10 / plot, y: 0.5,
                                           toleranceX: tolerance, toleranceY: tolerance))
    }

    func testAPressOnEmptyGraphGrabsNothing() {
        let points: [[Double]] = [[0, 0], [1, 1]]
        XCTAssertNil(CurveEditing.hitIndex(points, x: 0.5, y: 0.5,
                                           toleranceX: 0.03, toleranceY: 0.03))
        XCTAssertNil(CurveEditing.hitIndex(points, x: Double.nan, y: 0.5,
                                           toleranceX: 0.03, toleranceY: 0.03))
    }

    func testDragOutOnlyEscapesPastTheMargin() {
        XCTAssertFalse(CurveEditing.escapes(x: -0.01, y: 0.5,
                                            marginX: 0.03, marginY: 0.03))
        XCTAssertTrue(CurveEditing.escapes(x: -0.05, y: 0.5,
                                           marginX: 0.03, marginY: 0.03))
        XCTAssertTrue(CurveEditing.escapes(x: 0.5, y: 1.06,
                                          marginX: 0.03, marginY: 0.03))
    }

    // MARK: - Splits

    func testSplitsComeBackAscendingInsideTheirOwnBounds() {
        let hostile: [[Double]] = [[0.99, 0.995, 0.999], [0, 0, 0], [0.5, 0.4, 0.3],
                                   [Double.nan, 0.5, 0.75], [1, 1, 1]]
        for raw in hostile {
            let out = CurveEditing.sanitizedSplits(raw)
            XCTAssertEqual(out.count, 3)
            for v in out {
                XCTAssertGreaterThanOrEqual(v, CurveEditing.splitFloor)
                XCTAssertLessThanOrEqual(v, CurveEditing.splitCeiling,
                                         "the repair may not breach the bound it just "
                                         + "applied — \(raw) produced \(out)")
            }
            for i in 1..<out.count {
                XCTAssertGreaterThan(out[i], out[i - 1],
                                     "\(raw) produced \(out), which ZoneWeights would "
                                     + "divide by a zero gap")
            }
        }
    }

    func testAWrongLengthSplitArrayFallsBackToTheDefaults() {
        XCTAssertEqual(CurveEditing.sanitizedSplits([0.4]), CurveEditing.defaultSplits)
        XCTAssertEqual(CurveEditing.sanitizedSplits([]), CurveEditing.defaultSplits)
        XCTAssertEqual(CurveEditing.sanitizedSplits([0.1, 0.2, 0.3, 0.4]),
                       CurveEditing.defaultSplits)
    }

    // MARK: - Undo identity

    // K-038 / A2-05: two points of one channel used to share a key, and
    // `HistoryCoalescing` folds two edits that share a key, a photo set and the window
    // into ONE step. This is the assertion that the two decisions are now two.
    func testTwoPointsOfOneCurveAreTwoUndoSteps() {
        let photo = Set([URL(fileURLWithPath: "/tmp/a.arw")])
        let first = CurveEditing.pointCoalescingKey(prefix: "curve.",
                                                    channel: "point", index: 1)
        let second = CurveEditing.pointCoalescingKey(prefix: "curve.",
                                                     channel: "point", index: 2)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(
            HistoryCoalescing.shouldCoalesce(openKey: first, openURLs: photo,
                                             key: second, urls: photo,
                                             sinceLastEdit: 0.2, window: 1.2),
            "moving point 1 and then point 2 half a second later must be two undo "
            + "steps — one ⌘Z took both away")
    }

    func testOneDragOfOnePointIsStillOneUndoStep() {
        let photo = Set([URL(fileURLWithPath: "/tmp/a.arw")])
        let key = CurveEditing.pointCoalescingKey(prefix: "curve.",
                                                  channel: "point", index: 1)
        XCTAssertTrue(
            HistoryCoalescing.shouldCoalesce(openKey: key, openURLs: photo,
                                             key: key, urls: photo,
                                             sinceLastEdit: 0.016, window: 1.2))
    }

    func testAMaskCurveCannotCoalesceWithTheGlobalOne() {
        XCTAssertNotEqual(
            CurveEditing.pointCoalescingKey(prefix: "curve.", channel: "r", index: 0),
            CurveEditing.pointCoalescingKey(prefix: "mask.curve.ABC.", channel: "r",
                                            index: 0))
    }

    // MARK: - Readout

    // The slot the readout sits in is flexible, but the string it can produce must be
    // bounded or "flexible" only means the row grows until something else is squeezed.
    func testTheReadoutIsBoundedAndNeverSigned() {
        let worst = CurveEditing.readout(input: 100, output: 100)
        XCTAssertEqual(worst, "in 100.0%   out 100.0%")
        XCTAssertEqual(worst.count, 22)
        for input in stride(from: -50.0, through: 150.0, by: 0.5) {
            let text = CurveEditing.readout(input: input, output: 100 - input)
            XCTAssertFalse(text.contains("-"),
                           "the encoded axis has no negative half, so a minus sign in "
                           + "the readout is a clamp that did not happen: \(text)")
            XCTAssertLessThanOrEqual(text.count, worst.count)
        }
    }

    func testANonFiniteReadoutSaysSoInOneGlyph() {
        XCTAssertEqual(CurveEditing.percent(Double.nan), "—")
        XCTAssertEqual(CurveEditing.percent(Double.infinity), "—")
    }

    func testTheSplitReadoutIsBounded() {
        XCTAssertEqual(CurveEditing.splitReadout(index: 2, position: 0.9),
                       "split 3   90.0%")
        XCTAssertLessThanOrEqual(
            CurveEditing.splitReadout(index: 2, position: 1.0).count, 16)
    }

    // MARK: - The mixer's group move (B3-01)

    func testAGroupMoveAtTheRailKeepsEverySpread() {
        let bands: [Double] = [50, -50, 0, 0, 0, 0, 0, 0]
        let up = GroupMove.moved(bands, by: 100, lower: -100, upper: 100)
        // The set stopped at the first rail: band 0 reached +100 and everything moved
        // with it by the same 50.
        XCTAssertEqual(up, [100, 0, 50, 50, 50, 50, 50, 50])
        for i in bands.indices {
            XCTAssertEqual(up[i] - up[0], bands[i] - bands[0], accuracy: 1e-12,
                           "a group move is a rigid translation; band \(i)'s difference "
                           + "from band 0 may not change")
        }
        // And it comes back. The per-band clamp this replaces returned
        // [6.25, -43.75, 6.25 …] here, with the 100-unit spread squeezed down to 50.
        let back = GroupMove.moved(up, by: -50, lower: -100, upper: 100)
        XCTAssertEqual(back, bands)
    }

    func testAGroupMoveInsideTheRailsIsExact() {
        let bands: [Double] = [10, -20, 5, 0, 0, 0, 0, 0]
        XCTAssertEqual(GroupMove.moved(bands, by: 12, lower: -100, upper: 100),
                       [22, -8, 17, 12, 12, 12, 12, 12])
        XCTAssertEqual(GroupMove.allowed(bands, requested: 12,
                                         lower: -100, upper: 100), 12)
    }

    func testAGroupAlreadyOnTheRailWillNotMoveFurtherOut() {
        let bands: [Double] = [100, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(GroupMove.allowed(bands, requested: 30,
                                         lower: -100, upper: 100), 0)
        XCTAssertEqual(GroupMove.moved(bands, by: 30, lower: -100, upper: 100), bands)
        // Down is still free, all the way to the other rail.
        XCTAssertEqual(GroupMove.allowed(bands, requested: -30,
                                         lower: -100, upper: 100), -30)
    }

    func testAnOutOfRangeBandFromASidecarCanStillBeDraggedBack() {
        let bands: [Double] = [420, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(GroupMove.allowed(bands, requested: 10,
                                         lower: -100, upper: 100), 0)
        XCTAssertEqual(GroupMove.moved(bands, by: -10, lower: -100, upper: 100),
                       [100, -10, -10, -10, -10, -10, -10, -10],
                       "the elementwise clamp is what pulls a hostile value back into "
                       + "range once the row is touched")
    }

    func testTheMeanIsTheRowsRestingValue() {
        XCTAssertEqual(GroupMove.mean([50, -50, 0, 0, 0, 0, 0, 0]), 0, accuracy: 1e-12)
        XCTAssertEqual(GroupMove.mean([]), 0)
        XCTAssertEqual(GroupMove.mean([Double.nan, 4]), 2, accuracy: 1e-12)
    }

    // MARK: - The call sites

    // Comments stripped first. `CurveEditorView`'s header and `ColorPanel`'s prose name
    // several of these symbols, so an unstripped scan would be satisfied by the
    // explanation of the fix rather than by the fix.

    func testTheCurveEditorRoutesEveryEditingRuleThroughLumenCore() throws {
        let source = try Self.appSource("CurveEditorView.swift")
        for symbol in ["CurveEditing.moved(", "CurveEditing.deleting(",
                       "CurveEditing.hitIndex(", "CurveEditing.sanitized(",
                       "CurveEditing.sanitizedSplits(", "CurveEditing.escapes(",
                       "CurveEditing.pointCoalescingKey(", "CurveEditing.readout(",
                       "CurveEditing.isIdentity(", "CurveEditing.clampedSplit(",
                       "CurveEditing.nearestIndexByX(", "CurveEditing.splitReadout("] {
            XCTAssertTrue(source.contains(symbol),
                          "CurveEditorView no longer calls \(symbol) — the rule is in "
                          + "LumenCore where it is tested, and a view that stopped "
                          + "calling it is a green lane over a broken editor")
        }
    }

    func testTheCurveEditorDoesNotKeyEveryPointOfAChannelTogether() throws {
        let source = try Self.appSource("CurveEditorView.swift")
        XCTAssertFalse(source.contains("keyPrefix + channel.rawValue)"),
                       "K-038: `curve.<channel>` as the key for every point of a channel "
                       + "folds two different points' drags into one undo step")
    }

    func testTheMixerGroupRowMovesTheWholeSetTogether() throws {
        let source = try Self.appSource("ColorPanel.swift")
        XCTAssertTrue(source.contains("GroupMove.moved("),
                      "B3-01: the All-bands row must translate the set through "
                      + "GroupMove, not clamp each band on its own")
        XCTAssertTrue(source.contains("GroupMove.mean("))
    }

    /// THE ANCHOR GUARD IS THE RULE, NOT AN ARITHMETIC ACCIDENT.
    ///
    /// The editor's own deletion guard was `points.count > 2` — "a curve needs two
    /// points" — which lets the FIRST and LAST go the moment a third exists, by ⌥-click,
    /// by the context menu, and by dragging one out of the graph. `CurveEditing.deleting`
    /// refuses both anchors; this is the assertion that the old count test is not still
    /// standing beside it, letting one of the three routes through.
    func testTheCurveEditorHasNoDeletionRuleOfItsOwnLeft() throws {
        let source = try Self.appSource("CurveEditorView.swift")
        XCTAssertFalse(source.contains("points.count > 2"),
                       "the count-alone guard deletes a black or white anchor as soon as "
                       + "a third point exists — MonotoneCubic then extends flat below "
                       + "the new first x and every shadow under it renders one value")
    }

    /// A WAY BACK THAT IS NOT A RIGHT-CLICK.
    ///
    /// Flatten and Reset Splits lived only in the plot's context menu — on a graph whose
    /// LEFT click adds a point, so the one gesture that undoes an unwanted curve was the
    /// one gesture nothing announces. `resetButton` is on the readout row; this asserts
    /// it is declared AND placed, because a private view that nothing renders compiles.
    func testTheCurveEditorCarriesItsOwnResetOnTheSurface() throws {
        let source = try Self.appSource("CurveEditorView.swift")
        XCTAssertTrue(source.contains("private var resetButton: some View"))
        XCTAssertEqual(source.components(separatedBy: "resetButton").count - 1, 2,
                       "resetButton must be declared once and placed once — a reset "
                       + "affordance that is never added to a row is a way back that "
                       + "does not exist")
        XCTAssertTrue(source.contains("func resetCurrentCurve()"))
    }

    /// The ink and the target, pinned where the arithmetic test above assumes them.
    ///
    /// `testTheHitTargetIsLargerThanTheDrawnPoint` proves 8 catches a press 6 pt off a
    /// dot of radius 3. That proof is about the editor only while the editor still draws
    /// at 3 and presses at 8, and neither number is reachable from LumenCore.
    func testTheDrawnPointStaysSmallerThanThePressItAnswersTo() throws {
        let source = try Self.appSource("CurveEditorView.swift")
        XCTAssertTrue(source.contains("hitRadius: CGFloat = 8"),
                      "the press radius moved; re-derive testTheHitTargetIsLarger…")
        XCTAssertTrue(source.contains("width: 6, height: 6"),
                      "the control dot is drawn from a 6 pt box (radius 3) — a dot that "
                      + "grew past the tolerance would make the target smaller than the "
                      + "ink, which is the defect the two numbers are stated apart for")
    }

    // MARK: - The Zones register's quantum

    /// A CONTROL WHOSE READOUT ADVERTISES VALUES NO GESTURE CAN LAND ON IS LYING.
    ///
    /// The zone rows sat at `step: 0.01` over ±3 stops — 600 addressable values — inside
    /// a `DevelopDisclosure`, which is the narrowest host in the develop column. At the
    /// 320 pt minimum the track is 126 pt, so one step was 0.21 pt of travel: a
    /// one-pixel tremor moved the value five steps, and about five in six of the values
    /// the two decimals promise could not be reached by dragging at all.
    ///
    /// The floor is `LumenControls.swift`'s own sentence — "~1.0, under which a
    /// one-pixel tremor costs a whole unit" — and the numerator and denominator are both
    /// READ from the app rather than typed here, so the day the label column or the step
    /// moves this recomputes instead of reassuring.
    func testTheZoneRowsStepIsCoarseEnoughForTheNarrowestTrackItGets() throws {
        let zones = try Self.appSource("ZonesPanel.swift")
        let controls = try Self.appSource("LumenControls.swift")

        let step = try XCTUnwrap(Self.literal("stopStep: Double = ", in: zones))
        let column = try XCTUnwrap(Self.literal("minimumPanelWidth: CGFloat = ", in: controls))
        let label = try XCTUnwrap(Self.literal("labelWidth: CGFloat = ", in: controls))
        let readout = try XCTUnwrap(Self.literal("valueWidth: CGFloat = ", in: controls))

        // Both rows are the same geometry, and both must be on the constant.
        XCTAssertEqual(zones.components(separatedBy: "step: Self.stopStep").count - 1, 2,
                       "the five zone rows and the Global trim share one quantum; a "
                       + "literal left behind at one of them is a row the census cannot "
                       + "see")
        XCTAssertEqual(zones.components(separatedBy: "range: -3...3").count - 1, 2)

        // The develop column's fold chain: 2×4 scroll inset + 2×10 card gutter + 2×8
        // disclosure inset, each one literal in one file and pinned in
        // Tests/LumenAppTests/LayoutMetricSupport.swift.
        let foldChain: Double = 44
        // What a LumenSlider row spends before the groove: the label frame, its two
        // 6 pt gaps and the readout frame.
        let chrome = label + 6 + 6 + readout
        let track = column - foldChain - chrome
        let steps = ((-3.0).distance(to: 3.0) / step).rounded()
        let perStep = track / steps

        XCTAssertEqual(track, 126, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(
            perStep, 1.0,
            "a zone row has \(track) pt of track over \(Int(steps)) steps of \(step) "
            + "stops — \(perStep) pt per step, under the ~1.0 at which a one-pixel "
            + "tremor stops costing a whole step. Coarsen the step; the panel's width is "
            + "not this row's to spend")
    }

    /// The first number after `needle`, as the source writes it. Comments are already
    /// stripped by `appSource`, so a doc comment quoting the old value cannot answer.
    private static func literal(_ needle: String, in source: String) -> Double? {
        guard let range = source.range(of: needle) else { return nil }
        let digits = source[range.upperBound...]
            .prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(digits)
    }

    private static func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenCoreTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
            .appendingPathComponent("Sources/LumenApp")
        let text = try String(contentsOf: root.appendingPathComponent(name),
                              encoding: .utf8)
        return Self.strippingComments(text)
    }

    /// Line and block comments out, so no assertion above can be satisfied by prose
    /// about the thing it is looking for. The same walk `SurroundPaintTests` uses.
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                if rest.hasPrefix("*/") {
                    inBlock = false
                    index = source.index(index, offsetBy: 2)
                } else {
                    index = source.index(after: index)
                }
                continue
            }
            if rest.hasPrefix("/*") {
                inBlock = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("//") {
                while index < source.endIndex, source[index] != "\n" {
                    index = source.index(after: index)
                }
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }
}
