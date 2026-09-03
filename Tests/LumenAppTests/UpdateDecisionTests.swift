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

    /// THE DIGEST IS THE ONLY IDENTITY CHECK THESE UPDATES HAVE (L-03).
    ///
    /// The bundles are ad-hoc signed — `scripts/build-app.sh` runs
    /// `codesign --force --sign -`, because an unsigned binary will not launch on Apple
    /// Silicon and there is no Developer ID to sign with. So the installer's
    /// `codesign --verify --deep --strict` answers "is this signature internally
    /// consistent with these contents", which an ad-hoc signature made by ANYBODY
    /// satisfies. The only other check on the payload was a byte count read from the
    /// same JSON that supplied the download URL.
    ///
    /// A 64-hex `sha256:` line in the release body, published by CI from the bytes it
    /// uploaded, is what closes that. These assertions are the parser half; the
    /// installer half is `install(asset:commit:digest:)`, which hashes the download
    /// before anything unpacks it.
    func testTheDigestLineIsParsedAndAMissingOneIsRefused() {
        let real = String(repeating: "ab", count: 32)          // 64 hex characters
        XCTAssertEqual(UpdateDecision.digest(inReleaseBody:
            "commit: abcdef1234567890\nsha256: \(real)\nRolling build."), real)
        XCTAssertEqual(UpdateDecision.digest(inReleaseBody:
            "  SHA256:  \(real.uppercased())  "), real,
            "the key is case-insensitive and the value is normalised, because a digest "
                + "that fails to match on case is a broken updater, not a caught attack")

        // FAILS CLOSED, every way it can be absent or malformed.
        XCTAssertNil(UpdateDecision.digest(inReleaseBody:
            "commit: abcdef1234567890\nRolling development build."),
            "a body with no digest must not install — an attacker shaping the feed "
                + "would otherwise just omit the line")
        XCTAssertNil(UpdateDecision.digest(inReleaseBody: "sha256: \(real)cd"),
                     "65 characters is not a digest")
        XCTAssertNil(UpdateDecision.digest(inReleaseBody: "sha256: abcdef"),
                     "a short value is a truncated line, not a weaker digest")
        XCTAssertNil(UpdateDecision.digest(inReleaseBody: "sha256: " + String(repeating: "z", count: 64)),
                     "64 non-hex characters is not a digest")

        // And the two keys do not read each other's lines.
        XCTAssertNil(UpdateDecision.digest(inReleaseBody: "commit: \(real)"))
        XCTAssertNil(UpdateDecision.commit(inReleaseBody: "sha256: \(real)"))
    }

    /// THE INSTALLED BUNDLE IS NEVER MOVED OUT OF THE WAY (L-04).
    ///
    /// The swap cannot be reached from a test — it replaces the running app — so the
    /// property is asserted where it can be: the installer must not move `current`
    /// anywhere, because the moment it does there is a window in which the photographer
    /// has no Lumen, and the failure handler's "The running build is untouched" becomes
    /// a claim rather than a fact.
    ///
    /// `replaceItemAt` leaves the original in place when it fails. That is the whole
    /// fix: the message is true by construction instead of by assertion, and there is
    /// no rollback to discard with a `try?`.
    func testTheInstallerNeverMovesTheRunningBundleAside() {
        let updater = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/LumenApp/AppUpdater.swift")
        guard let raw = try? String(contentsOf: updater, encoding: .utf8) else {
            return XCTFail("AppUpdater.swift not found — move this scan with it")
        }
        // Comments out: this file now explains at length what it used to do, and the
        // explanation contains the very call the check is looking for. `DesignSystemTests`
        // and `EditRevisionRuleTests` were each caught by exactly this.
        let code = raw.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[..<slashes.lowerBound]
            }
            .joined(separator: "\n")

        XCTAssertFalse(code.contains("moveItem(at: current"),
                       "the installer moves the running bundle aside again — that is "
                           + "the window in which the photographer has no Lumen, and "
                           + "the failure alert's \"running build is untouched\" stops "
                           + "being true")
        XCTAssertTrue(code.contains("replaceItemAt(current"),
                      "the atomic replacement is gone; whatever took its place has to "
                          + "leave the original in place on failure or the alert lies")
    }

    /// THE WORKFLOW PUBLISHES IT. A parser that fails closed against a body CI never
    /// writes is an updater that has quietly stopped updating, which is the failure
    /// this pair of assertions exists to make loud.
    func testTheReleaseWorkflowPublishesADigest() {
        let ci = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".github/workflows/ci.yml")
        guard let text = try? String(contentsOf: ci, encoding: .utf8) else {
            return XCTFail("ci.yml not found — if it moved, move this scan with it")
        }
        XCTAssertTrue(text.contains("shasum -a 256 Lumen.app.zip"),
                      "the release step no longer computes the asset's digest, so every "
                          + "published build now fails the installer's own check")
        XCTAssertTrue(text.contains("sha256: ${DIGEST}"),
                      "the digest is computed and not written into the release body")
    }
}

#endif
