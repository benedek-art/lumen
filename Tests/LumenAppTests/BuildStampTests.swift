// The menu's build stamp: run number first when CI stamped one, the commit always,
// the date legible — and an unstamped dev build says so instead of imitating a
// release. Pinned so the string the owner reads to verify "am I current?" cannot
// drift silently.
#if os(macOS)

import XCTest
@testable import LumenApp

final class BuildStampTests: XCTestCase {

    /// 2026-08-28 09:52:53 UTC — the publish instant of the release this test
    /// generation shipped from.
    private let date = Date(timeIntervalSince1970: 1_787_910_773)
    private let utc = TimeZone(identifier: "UTC")!

    func testACIBuildShowsNumberCommitAndDate() {
        XCTAssertEqual(
            BuildStamp.label(number: 236,
                             commit: "d8612d2c8e301b1277c36ce5ab28043143238cc6",
                             date: date, timeZone: utc),
            "Build 236 · d8612d2 · Aug 28, 2026, 09:52")
    }

    func testALocalScriptBuildHasNoNumberButKeepsItsIdentity() {
        XCTAssertEqual(
            BuildStamp.label(number: nil, commit: "abcdef1234567890",
                             date: date, timeZone: utc),
            "Build abcdef1 · Aug 28, 2026, 09:52")
        XCTAssertEqual(
            BuildStamp.label(number: nil, commit: "abcdef1234567890", date: nil),
            "Build abcdef1")
    }

    func testAnUnstampedBuildSaysSoInsteadOfImitatingARelease() {
        XCTAssertEqual(BuildStamp.label(number: nil, commit: nil, date: nil),
                       "Development build — no update stamp")
        XCTAssertEqual(BuildStamp.label(number: 7, commit: "abc", date: date),
                       "Development build — no update stamp",
                       "a truncated stamp is not an identity")
    }
}

#endif
