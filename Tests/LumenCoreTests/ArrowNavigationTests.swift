// ArrowNavigationTests.swift
// Which list an arrow key walks, and — the point of the whole file — whether it is
// allowed to touch the selection while it walks.
//
// The defect this pins: in Compare and Survey, → ran the grid's "select the next
// photo", and that path resets the selection to one photo. Compare and Survey draw the
// selection, so the key documented as cycling the candidate destroyed the comparison
// it was moving inside.

import XCTest
@testable import LumenCore

final class ArrowNavigationTests: XCTestCase {

    // MARK: Browsing

    func testBrowsingWalksTheRollAndTheSelectionFollowsTheCursor() {
        XCTAssertEqual(ArrowNavigation.step(delta: 1, libraryCursor: 4, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 1,
                                            comparing: false),
                       .selectSingle(index: 5))
        XCTAssertEqual(ArrowNavigation.step(delta: -1, libraryCursor: 4, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 1,
                                            comparing: false),
                       .selectSingle(index: 3))
        // ↑ ↓ in the grid are the same press with a row's worth of delta.
        XCTAssertEqual(ArrowNavigation.step(delta: 6, libraryCursor: 4, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 1,
                                            comparing: false),
                       .selectSingle(index: 10))
    }

    func testBrowsingWithAMultiSelectionStillRebuildsIt() {
        // Outside a comparison, forty selected frames and one arrow press means "no,
        // this one" — the selection following the cursor is the correct behaviour there
        // and is not what was broken.
        XCTAssertEqual(ArrowNavigation.step(delta: 1, libraryCursor: 4, libraryCount: 40,
                                            selectionCursor: 2, selectionCount: 40,
                                            comparing: false),
                       .selectSingle(index: 5))
    }

    // MARK: Comparing

    func testComparingMovesInsideTheSelectionInsteadOfRebuildingIt() {
        // The fix, stated once: with six frames up in Survey, → moves to the next pane.
        // It does not select photo 21 of the roll and throw the other five away.
        XCTAssertEqual(ArrowNavigation.step(delta: 1, libraryCursor: 20, libraryCount: 40,
                                            selectionCursor: 2, selectionCount: 6,
                                            comparing: true),
                       .moveWithinSelection(index: 3))
        XCTAssertEqual(ArrowNavigation.step(delta: -1, libraryCursor: 20, libraryCount: 40,
                                            selectionCursor: 2, selectionCount: 6,
                                            comparing: true),
                       .moveWithinSelection(index: 1))
    }

    func testNoArrowPressInAComparisonCanEverRebuildTheSelection() {
        // The invariant, swept rather than sampled: whatever the delta, whatever the
        // cursor, a press inside a comparison of two or more either moves within the set
        // or does nothing. `selectSingle` is what collapsed the set, so it must not be
        // reachable from here at all.
        for count in 2...8 {
            for cursor in 0..<count {
                for delta in [-12, -6, -1, 0, 1, 6, 12] {
                    let step = ArrowNavigation.step(delta: delta,
                                                    libraryCursor: 20, libraryCount: 40,
                                                    selectionCursor: cursor,
                                                    selectionCount: count,
                                                    comparing: true)
                    switch step {
                    case .selectSingle:
                        XCTFail("comparing \(count) at \(cursor), delta \(delta), "
                                    + "rebuilt the selection")
                    case .moveWithinSelection(let index):
                        XCTAssertTrue((0..<count).contains(index))
                    case .stay:
                        break
                    }
                }
            }
        }
    }

    func testComparingASinglePhotoStillBrowsesTheRoll() {
        // "This one against the next one" is the cull gesture: the second frame is
        // implied by the cursor, so both frames advance together.
        for selected in [0, 1] {
            XCTAssertEqual(ArrowNavigation.step(delta: 1, libraryCursor: 4,
                                                libraryCount: 40,
                                                selectionCursor: selected == 1 ? 0 : nil,
                                                selectionCount: selected,
                                                comparing: true),
                           .selectSingle(index: 5))
        }
    }

    func testACursorOutsideTheComparedSetLandsBackInsideIt() {
        // A ⌘-click can leave the cursor on a photo that is not in the selection. The
        // recovery is to step back into the set, never to walk the roll — walking the
        // roll from here is what destroys the comparison.
        XCTAssertEqual(ArrowNavigation.step(delta: 1, libraryCursor: 20, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 4,
                                            comparing: true),
                       .moveWithinSelection(index: 0))
        XCTAssertEqual(ArrowNavigation.step(delta: -1, libraryCursor: 20, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 4,
                                            comparing: true),
                       .moveWithinSelection(index: 3))
    }

    // MARK: Ends and empties

    func testBothWalksStopAtTheirEndsRatherThanWrapping() {
        XCTAssertEqual(ArrowNavigation.step(delta: 1, libraryCursor: 39, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 1,
                                            comparing: false),
                       .stay)
        XCTAssertEqual(ArrowNavigation.step(delta: -1, libraryCursor: 0, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 1,
                                            comparing: false),
                       .stay)
        XCTAssertEqual(ArrowNavigation.step(delta: 1, libraryCursor: 20, libraryCount: 40,
                                            selectionCursor: 3, selectionCount: 4,
                                            comparing: true),
                       .stay)
        XCTAssertEqual(ArrowNavigation.step(delta: -1, libraryCursor: 20, libraryCount: 40,
                                            selectionCursor: 0, selectionCount: 4,
                                            comparing: true),
                       .stay)
        // A key held down past the end clamps rather than running off.
        XCTAssertEqual(ArrowNavigation.step(delta: 99, libraryCursor: 4, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 1,
                                            comparing: false),
                       .selectSingle(index: 39))
    }

    func testAnEmptyRollDoesNothingInEveryView() {
        for comparing in [true, false] {
            XCTAssertEqual(ArrowNavigation.step(delta: 1, libraryCursor: nil,
                                                libraryCount: 0, selectionCursor: nil,
                                                selectionCount: 0, comparing: comparing),
                           .stay)
        }
    }

    func testNoCursorAtAllLandsOnTheFirstPhoto() {
        XCTAssertEqual(ArrowNavigation.step(delta: 1, libraryCursor: nil, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 0,
                                            comparing: false),
                       .selectSingle(index: 0))
        XCTAssertEqual(ArrowNavigation.step(delta: -1, libraryCursor: nil, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 0,
                                            comparing: false),
                       .selectSingle(index: 0))
    }

    func testAZeroDeltaNeverMovesAnythingAndNeverRewritesTheSelection() {
        XCTAssertEqual(ArrowNavigation.step(delta: 0, libraryCursor: 4, libraryCount: 40,
                                            selectionCursor: nil, selectionCount: 1,
                                            comparing: false),
                       .stay)
        XCTAssertEqual(ArrowNavigation.step(delta: 0, libraryCursor: 20, libraryCount: 40,
                                            selectionCursor: 2, selectionCount: 6,
                                            comparing: true),
                       .stay)
    }

    func testEveryIndexReturnedIsAddressableInTheListItNames() {
        for comparing in [true, false] {
            for libraryCount in [1, 2, 40] {
                for selectionCount in [0, 1, 2, 5] {
                    for delta in [-40, -1, 1, 40] {
                        let step = ArrowNavigation.step(
                            delta: delta,
                            libraryCursor: libraryCount > 1 ? 1 : 0,
                            libraryCount: libraryCount,
                            selectionCursor: selectionCount > 0 ? 0 : nil,
                            selectionCount: selectionCount,
                            comparing: comparing)
                        switch step {
                        case .selectSingle(let index):
                            XCTAssertTrue((0..<libraryCount).contains(index))
                        case .moveWithinSelection(let index):
                            XCTAssertTrue((0..<selectionCount).contains(index))
                        case .stay:
                            break
                        }
                    }
                }
            }
        }
    }
}
