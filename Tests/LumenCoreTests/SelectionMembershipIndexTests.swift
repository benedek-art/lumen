import XCTest
@testable import LumenCore

final class SelectionMembershipIndexTests: XCTestCase {
    func testSparseSelectionsMatchSourceOrderIncludingUnknownIDs() {
        let ids = Array(0..<100)
        let index = SelectionMembershipIndex(ids)
        for offset in 0..<80 {
            let selection: Set<Int> = [offset, (offset + 17) % 100, 999]
            XCTAssertEqual(index.positions(for: selection), ids.indices.filter { selection.contains(ids[$0]) })
        }
        XCTAssertEqual(index.positions(for: []), [])
    }

    func testDenseAndDuplicateSelectionsRequestLosslessScan() {
        XCTAssertNil(SelectionMembershipIndex([0, 1, 2, 3]).positions(for: [0, 1, 2]))
        XCTAssertNil(SelectionMembershipIndex([0, 1, 0, 2]).positions(for: [0]))
        XCTAssertEqual(SelectionMembershipIndex([0, 1, 0]).positions(for: []), [])
    }

    func testRebuiltIndexUsesNewArrayPositions() {
        XCTAssertEqual(SelectionMembershipIndex([0, 1, 2, 3]).positions(for: [1]), [1])
        XCTAssertEqual(SelectionMembershipIndex([3, 2, 1, 0]).positions(for: [1]), [2])
        XCTAssertEqual(SelectionMembershipIndex([3, 2, 4, 0]).positions(for: [1]), [])
    }
}
