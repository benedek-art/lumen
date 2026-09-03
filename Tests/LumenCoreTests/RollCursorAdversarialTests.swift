// RollCursorAdversarialTests.swift
// An attempt to REFUTE the claim RollCursor makes about itself: that verifying a
// memoised answer against the roll it is handed — same length, same photograph
// standing at the remembered index — makes staleness impossible and an invalidation
// hook unnecessary.
//
// The existing suite checks the duplicate case only through a FRESH cursor, i.e. only
// through `rebuild`, which is the half that is correct. The fast path is untested
// against duplicates, and that is where the claim fails.

import XCTest
@testable import LumenCore

final class RollCursorAdversarialTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Volumes/Card/DCIM/100MSDCF/\(name).ARW")
    }

    private func roll(_ count: Int, prefix: String = "DSC") -> [URL] {
        (0..<count).map { url("\(prefix)\(String(format: "%05d", $0))") }
    }

    // MARK: The verification is not sufficient

    /// The length matches, the photograph IS standing at the remembered index, and the
    /// answer is still wrong: `firstIndex(of:)` says 0, the memo says 2.
    func testAVerifiedHitReturnsANonFirstIndexOnceTheRollCarriesTheFileTwice() {
        XCTExpectFailure("Recorded defect. This is a FINDING, recorded rather than silenced. The test runs and prints its real numbers on every lane; only the red is suppressed, so the day it is fixed this becomes an unexpected pass and asks for the expectation to be deleted.")
        let a = url("A"), b = url("B"), c = url("C")
        var ids = [a, b, c]
        var cursor = RollCursor()

        XCTAssertEqual(cursor.index(of: c, inRollOf: ids.count) { ids[$0] }, 2)
        XCTAssertEqual(cursor.rebuilds, 1)

        // Same length. C is still standing at index 2 — both halves of the stated
        // verification hold. A second copy of C has landed at index 0.
        ids = [c, b, c]
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[2], c)

        let answer = cursor.index(of: c, inRollOf: ids.count) { ids[$0] }
        XCTAssertEqual(cursor.rebuilds, 1, "the fast path was not taken, so this test "
                       + "is no longer exercising the fast path")
        XCTAssertEqual(answer, ids.firstIndex(of: c),
                       "the memo answered \(String(describing: answer)) where the "
                       + "search it replaces answers "
                       + "\(String(describing: ids.firstIndex(of: c)))")
    }

    /// The same failure reached the way an app would reach it: a roll of two, one file
    /// replaced by a copy of the other. Nothing about the length or the queried
    /// photograph's position changed.
    func testTheFastPathDisagreesWithFirstIndexAfterADuplicateAppearsBeforeIt() {
        XCTExpectFailure("Recorded defect. This is a FINDING, recorded rather than silenced. The test runs and prints its real numbers on every lane; only the red is suppressed, so the day it is fixed this becomes an unexpected pass and asks for the expectation to be deleted.")
        let x = url("X"), a = url("A")
        var ids = [x, a]
        var cursor = RollCursor()
        XCTAssertEqual(cursor.index(of: a, inRollOf: ids.count) { ids[$0] }, 1)

        ids = [a, a]
        let answer = cursor.index(of: a, inRollOf: ids.count) { ids[$0] }
        XCTAssertEqual(answer, ids.firstIndex(of: a),
                       "answered \(String(describing: answer)) for a roll whose first "
                       + "index is 0")
    }

    /// A fresh cursor on the very same roll gives the other answer, so the type is not
    /// merely opinionated about duplicates — it is inconsistent with itself. The same
    /// roll answered twice by two cursors in the same state of the world differs.
    func testTwoCursorsDisagreeAboutTheSameRoll() {
        XCTExpectFailure("The fast path proves an occurrence sits at the remembered index, not that it is the FIRST, so a duplicated URL makes the answer depend on the cursor's history. Latent: no path today puts a duplicate in the roll. This is a FINDING, recorded rather than silenced. The test runs and prints its real numbers on every lane; only the red is suppressed, so the day it is fixed this becomes an unexpected pass and asks for the expectation to be deleted.")
        let a = url("A"), b = url("B")
        var warmed = RollCursor()
        var ids = [b, a]
        _ = warmed.index(of: a, inRollOf: ids.count) { ids[$0] }
        ids = [a, a]

        var fresh = RollCursor()
        let freshAnswer = fresh.index(of: a, inRollOf: ids.count) { ids[$0] }
        let warmedAnswer = warmed.index(of: a, inRollOf: ids.count) { ids[$0] }
        XCTAssertEqual(freshAnswer, 0, "the rebuild path is the correct half")
        XCTAssertEqual(warmedAnswer, freshAnswer,
                       "the answer depends on the cursor's history, not on the roll")
    }

    // MARK: The attacks that FAILED — recorded so the boundary is documented

    /// The prompt's shape: length unchanged, queried photograph still at its remembered
    /// index, memo wrong about a DIFFERENT photograph. With distinct identities the
    /// per-identity verification does catch it, because the other photograph's own
    /// check reads its own remembered slot.
    func testAMemoWrongAboutAnotherPhotographIsCaughtWhenIdentitiesAreDistinct() {
        let a = url("A"), b = url("B"), c = url("C"), d = url("D")
        var ids = [a, b, c, d]
        var cursor = RollCursor()
        for (i, id) in ids.enumerated() {
            XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count) { ids[$0] }, i)
        }
        // A stays at 0 and D stays at 3; B and C trade places under the memo.
        ids = [a, c, b, d]
        XCTAssertEqual(cursor.index(of: a, inRollOf: ids.count) { ids[$0] }, 0)
        XCTAssertEqual(cursor.rebuilds, 1, "A's hit did not rebuild, as intended")
        XCTAssertEqual(cursor.index(of: b, inRollOf: ids.count) { ids[$0] }, 2)
        XCTAssertEqual(cursor.index(of: c, inRollOf: ids.count) { ids[$0] }, 1)
        XCTAssertEqual(cursor.index(of: d, inRollOf: ids.count) { ids[$0] }, 3)
    }

    /// Shrink and regrow to the same length between two lookups.
    func testARollThatShrinksAndRegrowsToTheSameLengthIsAnsweredCorrectly() {
        var ids = roll(12)
        var cursor = RollCursor()
        for (i, id) in ids.enumerated() {
            XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count) { ids[$0] }, i)
        }
        let survivors = Array(ids.prefix(9))
        ids = survivors + roll(3, prefix: "IMG")
        XCTAssertEqual(ids.count, 12)
        for id in ids + [url("ABSENT")] {
            XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count) { ids[$0] },
                           ids.firstIndex(of: id), id.lastPathComponent)
        }
    }

    /// A whole session of same-length mutations against a distinct-identity roll,
    /// every answer compared with the search this replaces.
    func testEverySameLengthMutationAgreesWithFirstIndexWhenIdentitiesAreDistinct() {
        var generator = SystemRandomNumberGenerator()
        var pool = roll(60)
        pool += roll(60, prefix: "IMG")
        var ids = Array(pool.prefix(30))
        var cursor = RollCursor()
        for round in 0..<200 {
            ids.shuffle(using: &generator)
            if round % 3 == 0 {
                // Swap one member out for one that was not in the roll: same length,
                // different contents.
                let incoming = pool[(round * 7) % pool.count]
                if !ids.contains(incoming) { ids[(round * 5) % ids.count] = incoming }
            }
            for id in pool {
                XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count) { ids[$0] },
                               ids.firstIndex(of: id),
                               "round \(round), \(id.lastPathComponent)")
            }
        }
    }

    // MARK: What the memo costs when it misses

    /// "A miss always rebuilds" is documented, but the cost is per CALL, and the cull
    /// path makes several calls per keystroke. Sitting on a photograph the filtered
    /// roll no longer contains turns each of them into a full pass — a hash-map build,
    /// which is strictly more expensive than the linear compare it replaced.
    func testSittingOnAnAbsentPhotographRebuildsOncePerCallNotOncePerRoll() {
        let ids = roll(2000)
        let rejected = url("REJECTED")
        var cursor = RollCursor()
        let callsPerKeystroke = 3
        let keystrokes = 30
        for _ in 0..<(keystrokes * callsPerKeystroke) {
            XCTAssertNil(cursor.index(of: rejected, inRollOf: ids.count) { ids[$0] })
        }
        XCTAssertEqual(cursor.rebuilds, keystrokes * callsPerKeystroke,
                       "a miss costs one full rebuild per call")
    }

    /// The roll emptying and refilling — closing a folder and opening it again — is not
    /// counted as a rebuild on the way down, but it does discard the map, so the first
    /// question after it pays a full pass.
    func testAnEmptyRollDiscardsTheMapAndTheNextQuestionPaysForIt() {
        let ids = roll(50)
        var cursor = RollCursor()
        _ = cursor.index(of: ids[10], inRollOf: ids.count) { ids[$0] }
        XCTAssertEqual(cursor.rebuilds, 1)
        XCTAssertNil(cursor.index(of: ids[10], inRollOf: 0) { _ in
            XCTFail("read an identity out of an empty roll")
            return URL(fileURLWithPath: "/never")
        })
        XCTAssertEqual(cursor.rebuilds, 1, "the empty path is not counted as a rebuild")
        _ = cursor.index(of: ids[10], inRollOf: ids.count) { ids[$0] }
        XCTAssertEqual(cursor.rebuilds, 2)
    }
}
