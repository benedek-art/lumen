// RollCursorAdversarialTests.swift
// An attempt to REFUTE the claim RollCursor makes about itself: that verifying a
// memoised answer against the roll it is handed — same length, same photograph
// standing at the remembered index — makes staleness impossible and an invalidation
// hook unnecessary.
//
// The existing suite checks the duplicate case only through a FRESH cursor, i.e. only
// through `rebuild`, which is the half that is correct. The fast path was untested
// against duplicates, and that is where the claim failed (S-08). The repair keys the
// memo on a revision the roll's owner bumps; the distinct-identity cases below still
// pass a constant revision, so they keep proving the slot verification on its own.

import XCTest
@testable import LumenCore

final class RollCursorAdversarialTests: XCTestCase {

    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Volumes/Card/DCIM/100MSDCF/\(name).ARW")
    }

    private func roll(_ count: Int, prefix: String = "DSC") -> [URL] {
        (0..<count).map { url("\(prefix)\(String(format: "%05d", $0))") }
    }

    // MARK: Duplicates (S-08) — the verification was not sufficient, the revision is

    // These three were recorded behind `XCTExpectFailure`: the fast path proved an
    // occurrence stood at the remembered index, not that it was the FIRST, so a roll
    // that gained a second copy of a file at the same length was answered from the
    // cursor's history. No O(1) check over `count` and `idAt` can see that — the slot
    // that changed is one it has no reason to read — so the owner now hands over a
    // revision that changes with the roll's contents, and each case below bumps it at
    // exactly the point the roll changes, as `AppState` does when it rebuilds `photos`.
    // Substitute the old fast-path condition (no revision check) and all three go red.

    /// The length matches and the photograph IS standing at the remembered index; the
    /// answer must still be `firstIndex(of:)`'s.
    func testAVerifiedHitReturnsANonFirstIndexOnceTheRollCarriesTheFileTwice() {
        let a = url("A"), b = url("B"), c = url("C")
        var ids = [a, b, c]
        var revision: UInt64 = 1
        var cursor = RollCursor()

        XCTAssertEqual(cursor.index(of: c, inRollOf: ids.count, revision: revision) { ids[$0] }, 2)
        XCTAssertEqual(cursor.rebuilds, 1)

        // Same length. C is still standing at index 2 — both halves of the old
        // verification hold. A second copy of C has landed at index 0.
        ids = [c, b, c]
        revision += 1
        XCTAssertEqual(ids.count, 3)
        XCTAssertEqual(ids[2], c)

        let answer = cursor.index(of: c, inRollOf: ids.count, revision: revision) { ids[$0] }
        XCTAssertEqual(answer, ids.firstIndex(of: c),
                       "the memo answered \(String(describing: answer)) where the "
                       + "search it replaces answers "
                       + "\(String(describing: ids.firstIndex(of: c)))")
        // And the fast path is still a fast path once the new roll is indexed.
        let built = cursor.rebuilds
        for _ in 0..<10 {
            XCTAssertEqual(cursor.index(of: c, inRollOf: ids.count, revision: revision) { ids[$0] }, 0)
            XCTAssertEqual(cursor.index(of: b, inRollOf: ids.count, revision: revision) { ids[$0] }, 1)
        }
        XCTAssertEqual(cursor.rebuilds, built, "an unchanged revision rebuilt the map")
    }

    /// The same failure reached the way an app would reach it: a roll of two, one file
    /// replaced by a copy of the other.
    func testTheFastPathDisagreesWithFirstIndexAfterADuplicateAppearsBeforeIt() {
        let x = url("X"), a = url("A")
        var ids = [x, a]
        var cursor = RollCursor()
        XCTAssertEqual(cursor.index(of: a, inRollOf: ids.count, revision: 7) { ids[$0] }, 1)

        ids = [a, a]
        let answer = cursor.index(of: a, inRollOf: ids.count, revision: 8) { ids[$0] }
        XCTAssertEqual(answer, ids.firstIndex(of: a),
                       "answered \(String(describing: answer)) for a roll whose first "
                       + "index is 0")
    }

    /// Two cursors in different states of history, asked about the same roll at the
    /// same revision, must give the same answer.
    func testTwoCursorsDisagreeAboutTheSameRoll() {
        let a = url("A"), b = url("B")
        var warmed = RollCursor()
        var ids = [b, a]
        _ = warmed.index(of: a, inRollOf: ids.count, revision: 1) { ids[$0] }
        ids = [a, a]

        var fresh = RollCursor()
        let freshAnswer = fresh.index(of: a, inRollOf: ids.count, revision: 2) { ids[$0] }
        let warmedAnswer = warmed.index(of: a, inRollOf: ids.count, revision: 2) { ids[$0] }
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
            XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count, revision: 0) { ids[$0] }, i)
        }
        // A stays at 0 and D stays at 3; B and C trade places under the memo.
        ids = [a, c, b, d]
        XCTAssertEqual(cursor.index(of: a, inRollOf: ids.count, revision: 0) { ids[$0] }, 0)
        XCTAssertEqual(cursor.rebuilds, 1, "A's hit did not rebuild, as intended")
        XCTAssertEqual(cursor.index(of: b, inRollOf: ids.count, revision: 0) { ids[$0] }, 2)
        XCTAssertEqual(cursor.index(of: c, inRollOf: ids.count, revision: 0) { ids[$0] }, 1)
        XCTAssertEqual(cursor.index(of: d, inRollOf: ids.count, revision: 0) { ids[$0] }, 3)
    }

    /// Shrink and regrow to the same length between two lookups.
    func testARollThatShrinksAndRegrowsToTheSameLengthIsAnsweredCorrectly() {
        var ids = roll(12)
        var cursor = RollCursor()
        for (i, id) in ids.enumerated() {
            XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count, revision: 0) { ids[$0] }, i)
        }
        let survivors = Array(ids.prefix(9))
        ids = survivors + roll(3, prefix: "IMG")
        XCTAssertEqual(ids.count, 12)
        for id in ids + [url("ABSENT")] {
            XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count, revision: 0) { ids[$0] },
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
                XCTAssertEqual(cursor.index(of: id, inRollOf: ids.count, revision: 0) { ids[$0] },
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
            XCTAssertNil(cursor.index(of: rejected, inRollOf: ids.count, revision: 0) { ids[$0] })
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
        _ = cursor.index(of: ids[10], inRollOf: ids.count, revision: 0) { ids[$0] }
        XCTAssertEqual(cursor.rebuilds, 1)
        XCTAssertNil(cursor.index(of: ids[10], inRollOf: 0, revision: 0) { _ in
            XCTFail("read an identity out of an empty roll")
            return URL(fileURLWithPath: "/never")
        })
        XCTAssertEqual(cursor.rebuilds, 1, "the empty path is not counted as a rebuild")
        _ = cursor.index(of: ids[10], inRollOf: ids.count, revision: 0) { ids[$0] }
        XCTAssertEqual(cursor.rebuilds, 2)
    }

    // MARK: The owner keeps its half of the contract

    private static func appSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/\(name).swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The revision is only as good as the owner that bumps it. `AppState.photos` is the
    /// one place the roll is rebuilt, so the bump has to sit beside the rebuild, and
    /// every cursor over that roll has to be handed the owner's revision rather than a
    /// constant. A source contract because `AppState` is macOS-only; it runs on Linux.
    func testTheRollOwnerBumpsTheRevisionWhereItRebuildsAndEveryCursorReadsIt() throws {
        let state = try Self.appSource("AppState")
        XCTAssertTrue(state.contains("photoCache = built\n        rollRevision &+= 1"),
                      "AppState rebuilds `photos` without bumping `rollRevision`")
        XCTAssertTrue(state.contains("revision: rollRevision) { list[$0].id }"),
                      "rollIndex does not key its cursor on the roll's revision")
        let loader = try Self.appSource("ThumbnailLoader")
        XCTAssertTrue(loader.contains("roll.index(of: anchor, inRollOf: count, revision: revision,"),
                      "the prefetch cursor ignores the revision it is handed")
        for view in ["GridView", "FilmstripView", "LoupeView"] {
            let text = try Self.appSource(view)
            XCTAssertFalse(text.contains("revision: 0"),
                           "\(view) hands the prefetch cursor a constant revision")
            XCTAssertTrue(text.contains("revision: rollRevision")
                          || text.contains("revision: state.rollRevision"),
                          "\(view) does not pass the roll's revision to the prefetch")
        }
    }
}
