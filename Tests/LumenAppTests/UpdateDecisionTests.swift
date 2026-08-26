// The self-update decision's contract: same commit is current, a newer release
// updates, an older release NEVER silently downgrades, and anything unstamped or
// malformed does nothing at all — an updater's failure mode must be inaction.
#if os(macOS)

import XCTest
@testable import LumenApp

final class UpdateDecisionTests: XCTestCase {

    private let older = Date(timeIntervalSince1970: 1_000_000)
    private let newer = Date(timeIntervalSince1970: 2_000_000)

    func testTheSameCommitIsUpToDateHoweverItIsAbbreviated() {
        XCTAssertEqual(UpdateDecision.decide(
            ownCommit: "abcdef1234567890", ownBuildDate: older,
            remoteCommit: "abcdef1234567890", remotePublishedAt: newer), .upToDate)
        // CI stamps the full SHA; a future stamp might abbreviate. Prefix equality
        // in either direction is the same build.
        XCTAssertEqual(UpdateDecision.decide(
            ownCommit: "abcdef123456", ownBuildDate: older,
            remoteCommit: "abcdef1234567890abcdef1234567890abcdef12",
            remotePublishedAt: newer), .upToDate)
    }

    func testADifferentNewerReleaseUpdates() {
        XCTAssertEqual(UpdateDecision.decide(
            ownCommit: "abcdef1234567890", ownBuildDate: older,
            remoteCommit: "1234567890abcdef", remotePublishedAt: newer), .update)
        // No dates at all still updates: a different commit with nothing saying
        // it is older is the common CI case.
        XCTAssertEqual(UpdateDecision.decide(
            ownCommit: "abcdef1234567890", ownBuildDate: nil,
            remoteCommit: "1234567890abcdef", remotePublishedAt: nil), .update)
    }

    func testAnOlderReleaseNeverSilentlyDowngrades() {
        XCTAssertEqual(UpdateDecision.decide(
            ownCommit: "abcdef1234567890", ownBuildDate: newer,
            remoteCommit: "1234567890abcdef", remotePublishedAt: older), .ownIsNewer)
    }

    func testAnUnstampedBuildOrMalformedReleaseDoesNothing() {
        XCTAssertEqual(UpdateDecision.decide(
            ownCommit: nil, ownBuildDate: nil,
            remoteCommit: "1234567890abcdef", remotePublishedAt: newer), .unknown)
        XCTAssertEqual(UpdateDecision.decide(
            ownCommit: "abcdef1234567890", ownBuildDate: older,
            remoteCommit: nil, remotePublishedAt: newer), .unknown)
        // A truncated stamp is not an identity.
        XCTAssertEqual(UpdateDecision.decide(
            ownCommit: "abc", ownBuildDate: older,
            remoteCommit: "abcdef1234567890", remotePublishedAt: newer), .unknown)
    }

    func testTheReleaseBodyContractParsesAndRejects() {
        XCTAssertEqual(UpdateDecision.commit(inReleaseBody:
            "commit: abcdef1234567890\nRolling development build."),
            "abcdef1234567890")
        XCTAssertEqual(UpdateDecision.commit(inReleaseBody:
            "Rolling development build.\n  COMMIT: ABCDEF12  \n"), "ABCDEF12")
        XCTAssertNil(UpdateDecision.commit(inReleaseBody: "no such line here"))
        XCTAssertNil(UpdateDecision.commit(inReleaseBody:
            "commit: not-a-hex-value"),
            "prose after the key must not be mistaken for an identity")
    }
}

#endif
