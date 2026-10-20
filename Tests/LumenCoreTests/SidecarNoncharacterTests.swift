// SidecarNoncharacterTests.swift
//
// U+FFFE and U+FFFF are outside XML 1.0's Char production. Written verbatim, they
// made the sidecar fail to parse past that point, and the flush interlock then
// refused every later write to it.

import XCTest
@testable import LumenCore

final class SidecarNoncharacterTests: XCTestCase {

    func testANoncharacterInALabelDoesNotBreakTheSidecar() throws {
        let content = SidecarContent(rating: 3, label: "a\u{FFFF}b\u{FFFE}", recipeJSON: "{}")
        let document = XMPSidecar.serialize(content)
        XCTAssertFalse(document.unicodeScalars.contains("\u{FFFF}"))
        XCTAssertFalse(document.unicodeScalars.contains("\u{FFFE}"))
        let parsed = try XCTUnwrap(XMPSidecar.parse(document))
        XCTAssertTrue(parsed.parsedCleanly)
        XCTAssertEqual(parsed.label, "ab")
        XCTAssertEqual(parsed.recipeJSON, "{}")
    }
}
