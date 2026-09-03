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
                       "CurveEditing.pointCoalescingKey(", "CurveEditing.readout("] {
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
