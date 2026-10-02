// InspectionGainMemoTests.swift
// The memo behind the `[` / `]` inspection holds (W2/H1-06, the half of K-031 the row
// did not name).
//
// It was one entry deep, keyed on the plate's identity, and every surface that shows a
// hold shows more than one plate — so split and two-pane before/after and Compare's two
// panes alternated through the one slot at a 100% miss rate, a full-extent Core Image
// pass per plate per body pass on the main thread. And the nil-hold path returned before
// touching the memo, so key-up kept two full-resolution frames resident for the life of
// the process.
//
// Substitutions, each red: capacity 1 (the old memo) → the alternating test counts 6
// transforms, not 2; a nil hold that returns without clearing → `entries` is not empty
// after key-up.
#if os(macOS)

import XCTest
import LumenCore
@testable import LumenApp

final class InspectionGainMemoTests: XCTestCase {

    private final class Plate {}

    func testTwoPlatesDrawnAlternatelyEachTransformOnce() {
        var memo = InspectionGainMemo<Plate>()
        let before = Plate(), after = Plate()
        var transforms = 0
        let make: (Plate, InspectionHold) -> Plate? = { _, _ in transforms += 1; return Plate() }
        let hold = InspectionHold.allCases[0]
        var first: [ObjectIdentifier] = []
        for pass in 0..<3 {
            let b = memo.value(for: before, hold: hold, make: make)
            let a = memo.value(for: after, hold: hold, make: make)
            if pass == 0 { first = [ObjectIdentifier(b), ObjectIdentifier(a)] }
            XCTAssertEqual([ObjectIdentifier(b), ObjectIdentifier(a)], first,
                           "a hit must hand back the frame the first pass made")
        }
        XCTAssertEqual(transforms, 2,
                       "two plates over three body passes cost \(transforms) transforms")
    }

    func testKeyUpReleasesEveryHeldFrame() {
        var memo = InspectionGainMemo<Plate>()
        let plates = [Plate(), Plate(), Plate()]
        for plate in plates {
            _ = memo.value(for: plate, hold: InspectionHold.allCases[0]) { _, _ in Plate() }
        }
        XCTAssertEqual(memo.entries.count, 3)
        let shown = memo.value(for: plates[0], hold: nil) { _, _ in
            XCTFail("no transform without a hold"); return nil
        }
        XCTAssertTrue(shown === plates[0], "no hold draws the plate untouched")
        XCTAssertTrue(memo.entries.isEmpty, "key-up kept \(memo.entries.count) frames")
    }

    func testTheMemoIsBoundedAndADifferentHoldIsADifferentEntry() {
        var memo = InspectionGainMemo<Plate>()
        let plate = Plate()
        var transforms = 0
        for hold in InspectionHold.allCases {
            _ = memo.value(for: plate, hold: hold) { _, _ in transforms += 1; return Plate() }
        }
        XCTAssertEqual(transforms, InspectionHold.allCases.count,
                       "switching hold must not serve the other hold's frame")
        for _ in 0..<(InspectionGainMemo<Plate>.capacity * 2) {
            _ = memo.value(for: Plate(), hold: InspectionHold.allCases[0]) { _, _ in Plate() }
        }
        XCTAssertEqual(memo.entries.count, InspectionGainMemo<Plate>.capacity)
    }
}

#endif
