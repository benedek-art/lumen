// MaskReorderTests.swift
// Moving a mask one place, once folders exist.
//
// Masks fold in list order — both renderers walk `plan.masks` front to back, so where two
// overlap the later one works on the earlier one's output — which means the reorder has
// to happen in the flat array however the list is drawn.
//
// A flat swap was right until this round and is wrong now. The neighbour in the array is
// very often in a different group, so "move down" inside a folder would either appear to
// do nothing (the two rows are not adjacent on screen) or shuffle two folders' contents
// past each other. Both read as the button being broken, and neither is something a test
// of the swap itself would have noticed — it is a question about which PAIR the arrow
// picks.

#if os(macOS)

import XCTest
@testable import LumenApp
@testable import LumenCore

final class MaskReorderTests: XCTestCase {

    /// a, b in "g"; c ungrouped; d in "g"; e ungrouped — deliberately interleaved,
    /// because a fixture where each folder's masks are already contiguous cannot fail
    /// the way the flat swap failed.
    private func interleaved() -> [Mask] {
        func mask(_ id: String, _ group: String?) -> Mask {
            var m = Mask(id: id, name: id)
            m.group = group
            return m
        }
        return [mask("a", "g"), mask("b", "g"), mask("c", nil),
                mask("d", "g"), mask("e", nil)]
    }

    func testTheFirstInAFolderCannotMoveUpEvenThoughItIsNotFirstInTheList() {
        let masks = interleaved()
        XCTAssertFalse(MaskPanel.reorderRoom(masks, 0).up, "a is first in its folder")
        XCTAssertTrue(MaskPanel.reorderRoom(masks, 0).down)
    }

    func testTheLastInAFolderCannotMoveDownEvenThoughItIsNotLastInTheList() {
        let masks = interleaved()
        // d is index 3 of 5, and the last of the three in "g".
        XCTAssertTrue(MaskPanel.reorderRoom(masks, 3).up)
        XCTAssertFalse(MaskPanel.reorderRoom(masks, 3).down,
                       "d is last in its folder, so the arrow must be off")
    }

    func testAnUngroupedMaskSeesOnlyOtherUngroupedMasks() {
        let masks = interleaved()
        // c is index 2, and the FIRST of the two ungrouped ones.
        XCTAssertFalse(MaskPanel.reorderRoom(masks, 2).up)
        XCTAssertTrue(MaskPanel.reorderRoom(masks, 2).down)
        // e is index 4, and the last.
        XCTAssertTrue(MaskPanel.reorderRoom(masks, 4).up)
        XCTAssertFalse(MaskPanel.reorderRoom(masks, 4).down)
    }

    func testAMaskAloneInItsFolderHasNowhereToGo() {
        var m = Mask(id: "only", name: "only")
        m.group = "g"
        let room = MaskPanel.reorderRoom([m, Mask(id: "other", name: "other")], 0)
        XCTAssertFalse(room.up)
        XCTAssertFalse(room.down)
    }

    func testAnIndexOffTheEndIsRefusedRatherThanCrashing() {
        let room = MaskPanel.reorderRoom(interleaved(), 99)
        XCTAssertFalse(room.up)
        XCTAssertFalse(room.down)
    }

    func testWithNoFoldersAtAllItIsTheOldRuleExactly() {
        // Every mask ungrouped: the siblings ARE the list, so the arrows are enabled
        // exactly where `index > 0` and `index < count - 1` said they were.
        let masks = (0..<4).map { Mask(id: "m\($0)", name: "m\($0)") }
        for index in masks.indices {
            let room = MaskPanel.reorderRoom(masks, index)
            XCTAssertEqual(room.up, index > 0)
            XCTAssertEqual(room.down, index < masks.count - 1)
        }
    }
}

#endif
