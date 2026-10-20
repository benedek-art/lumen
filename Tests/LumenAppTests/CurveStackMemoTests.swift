// CurveStackMemoTests.swift
// The curve editor bakes its `CurveStack` once per curve set, not once per read.
//
// `stack` was a computed `CurveStack(curveSet)`, read three or four times per body, and
// the editor re-bodies on every `EditRevision` bump — so an Exposure drag in the same
// column re-baked an unchanged parametric curve several times per mouse event.
//
// Substitutions, each red: a memo that never hits → the repeat test counts 5 bakes, not
// 1; a memo that never misses → the changed-set test reads the stale Shadows value; a
// `stack` property that builds `CurveStack(curveSet)` directly → the source contract.
#if os(macOS)

import XCTest
import LumenCore
@testable import LumenApp

final class CurveStackMemoTests: XCTestCase {

    private func set(shadows: Double) -> CurveSet {
        CurveSet(parametric: ParametricCurve(shadows: shadows))
    }

    func testRepeatedReadsOfOneSetBakeOnce() {
        let memo = CurveStackMemo()
        let curve = set(shadows: 20)
        for _ in 0..<5 { _ = memo.stack(for: curve) }
        XCTAssertEqual(memo.bakes, 1, "five reads of an unchanged set baked \(memo.bakes) times")
    }

    func testAChangedSetIsRebakedAndServed() {
        let memo = CurveStackMemo()
        _ = memo.stack(for: set(shadows: 20))
        let moved = memo.stack(for: set(shadows: -40))
        XCTAssertEqual(memo.bakes, 2)
        XCTAssertEqual(moved.set.parametric.shadows, -40,
                       "the memo served a stack baked for the previous curve set")
        XCTAssertEqual(moved.master(0.2), CurveStack(set(shadows: -40)).master(0.2),
                       accuracy: 1e-12)
    }

    func testTheEditorReadsItsStackThroughTheMemo() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // LumenAppTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // <package>
        let raw = try String(contentsOf: root.appendingPathComponent(
            "Sources/LumenApp/CurveEditorView.swift"), encoding: .utf8)
        let source = blankingComments(in: raw)
        XCTAssertTrue(source.contains(
            "private var stack: CurveStack { stackMemo.stack(for: curveSet) }"),
                      "the editor's stack no longer goes through CurveStackMemo")
        XCTAssertEqual(source.components(separatedBy: "CurveStack(").count - 1, 1,
                       "only CurveStackMemo may construct a CurveStack in the editor")
    }
}

#endif
