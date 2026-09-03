// RollCursorTests.swift
// The memo that replaced the per-keystroke linear search, and the verification that
// keeps it from ever answering about a roll it was not built from.
//
// Two properties, and they pull in opposite directions, which is the reason this file
// exists rather than a comment claiming both:
//
//   · it must be a MEMO — walking the roll on every keystroke is the cost being
//     removed, so a build count is asserted, not just the answers. Every test here that
//     only checked answers would pass unchanged against the linear search.
//   · it must never be STALE — a position map that survives a change to the roll points
//     at the wrong photograph, and a cull surface then prefetches, advances or rates
//     around a frame nobody is looking at.

import XCTest
@testable import LumenCore

final class RollCursorTests: XCTestCase {

    private func roll(_ count: Int, prefix: String = "DSC") -> [URL] {
        (0..<count).map {
            URL(fileURLWithPath: "/Volumes/Card/DCIM/100MSDCF/\(prefix)0\(String(format: "%05d", $0)).ARW")
        }
    }

    // MARK: It is a memo

    func testWalkingTheWholeRollBuildsTheIndexExactlyOnce() {
        // The shape of a cull: 2,000 frames, an arrow key held down, one question per
        // keystroke. The linear search this replaces answers all 2,000 correctly and
        // pays 2,000 passes to do it.
        let ids = roll(2000)
        var cursor = RollCursor()
        for (expected, id) in ids.enumerated() {
            XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count) { ids[$0] }, expected)
        }
        XCTAssertEqual(cursor.rebuilds, 1,
                       "2,000 keystrokes over an unchanged roll rebuilt the index "
                           + "\(cursor.rebuilds) times — the memo is not memoising")
    }

    func testAnUnchangedRollIsNeverWalkedTwiceEvenWhenTheCursorJumps() {
        // Filmstrip clicks, ⌘-clicks and filter jumps arrive out of order. Order is not
        // what makes the memo valid; the roll being the roll it was built from is.
        let ids = roll(500)
        var cursor = RollCursor()
        for step in stride(from: 0, to: 500, by: 7) {
            _ = cursor.index(of: ids[step], inRollOf: ids.count) { ids[$0] }
        }
        for step in stride(from: 499, through: 0, by: -13) {
            _ = cursor.index(of: ids[step], inRollOf: ids.count) { ids[$0] }
        }
        XCTAssertEqual(cursor.rebuilds, 1)
    }

    // MARK: It is never stale

    func testAReorderedRollIsAnsweredFromTheRollAndNotFromTheMemo() {
        // The failure this verification exists to make impossible. Sorting by rating
        // reorders the roll without changing its length, so a memo keyed on length
        // alone would keep answering with the old positions — and the ring would warm,
        // the cursor would advance, and a range selection would extend around a
        // photograph that is no longer there.
        var ids = roll(6)
        var cursor = RollCursor()
        XCTAssertEqual(cursor.index(of: ids[4], inRollOf: ids.count) { ids[$0] }, 4)

        ids.reverse()
        XCTAssertEqual(cursor.index(of: ids[4], inRollOf: ids.count) { ids[$0] }, 4,
                       "the memo answered about the roll it was built from, not the "
                           + "roll it was handed")
        for (expected, id) in ids.enumerated() {
            XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count) { ids[$0] }, expected)
        }
    }

    func testEveryAnswerMatchesFirstIndexAcrossAWholeCullSession() {
        // The property, stated against the search it replaces: filter, sort, reject,
        // re-filter — after each, every photograph in the roll and one that is not.
        var ids = roll(40)
        var cursor = RollCursor()
        let outsider = URL(fileURLWithPath: "/Volumes/Card/DCIM/100MSDCF/NOTHERE.ARW")

        func check(_ note: String) {
            for id in ids + [outsider] {
                XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count) { ids[$0] },
                               ids.firstIndex(of: id),
                               "\(note): \(id.lastPathComponent)")
            }
        }
        check("as scanned")
        ids.removeSubrange(10..<20)          // a filter narrowing
        check("filtered")
        ids.sort { $0.lastPathComponent > $1.lastPathComponent }   // sort reversed
        check("re-sorted")
        ids.append(contentsOf: roll(5, prefix: "IMG"))             // an ingest landing
        check("extended")
        ids.removeAll()                                            // folder closed
        check("emptied")
    }

    func testAPhotographTheRollDoesNotContainAnswersNil() {
        let ids = roll(10)
        var cursor = RollCursor()
        XCTAssertNil(cursor.index(of: URL(fileURLWithPath: "/elsewhere/x.arw"),
                                  inRollOf: ids.count) { ids[$0] })
    }

    func testAnEmptyRollAnswersNilWithoutReadingAnIdentity() {
        let ids: [URL] = []
        var cursor = RollCursor()
        XCTAssertNil(cursor.index(of: URL(fileURLWithPath: "/a.arw"),
                                  inRollOf: 0) { _ in
            XCTFail("read an identity out of an empty roll")
            return URL(fileURLWithPath: "/never")
        })
    }

    func testADuplicatedFileAnswersWithItsFirstPosition() {
        // A roll should not carry the same file twice, but `firstIndex(of:)` had an
        // answer if it ever did, and the replacement has to have the same one.
        let a = URL(fileURLWithPath: "/roll/a.arw")
        let b = URL(fileURLWithPath: "/roll/b.arw")
        let ids = [a, b, a, b]
        var cursor = RollCursor()
        XCTAssertEqual(cursor.index(of: a, inRollOf: ids.count) { ids[$0] }, 0)
        XCTAssertEqual(cursor.index(of: b, inRollOf: ids.count) { ids[$0] }, 1)
    }

    func testAShorteningRollNeverAnswersPastItsOwnEnd() {
        // The out-of-bounds shape: the memo remembers index 39 and the roll is now 5
        // long. The verification reads `idAt(memo)`, so an unchecked memo would not
        // merely be wrong here — it would index off the end of the caller's array.
        var ids = roll(40)
        var cursor = RollCursor()
        let last = ids[39]
        XCTAssertEqual(cursor.index(of: last, inRollOf: ids.count) { ids[$0] }, 39)
        ids = Array(ids.prefix(5))
        XCTAssertNil(cursor.index(of: last, inRollOf: ids.count) { ids[$0] })
        for i in ids.indices {
            XCTAssertEqual(cursor.index(of: ids[i], inRollOf: ids.count) { ids[$0] }, i)
        }
    }
}
