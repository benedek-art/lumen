// SidecarLabelPolicyTests.swift
// A rating keystroke must not delete somebody else's colour label.

import XCTest
@testable import LumenCore

final class SidecarLabelPolicyTests: XCTestCase {

    /// The defect. Lightroom wrote "To Print"; this build has no word for it, so it
    /// holds `.none`; the photographer presses `2`. Nothing about the label changed, so
    /// the write must not mention it.
    func testARatingKeystrokeLeavesALabelThisBuildCannotNameAlone() {
        XCTAssertNil(SidecarLabelPolicy.write(appLabel: nil, labelChanged: false),
                     "a flag or rating keystroke asserted `.some(nil)` for the label, "
                     + "and XMPMerge owns `xmp:Label`, so pressing a rating deleted "
                     + "another tool's label from the file")
    }

    /// Clearing a label the photographer CAN see is a decision, and must persist.
    func testClearingALabelStillClearsIt() {
        let written = SidecarLabelPolicy.write(appLabel: nil, labelChanged: true)
        XCTAssertNotNil(written, "a cleared label must reach the file")
        XCTAssertEqual(written ?? "unset", String?.none,
                       "clearing writes `.some(nil)` — the element is removed")
    }

    /// Setting one is authoritative whether or not the edit "changed" it — a re-assert
    /// of the same label repairs a file somebody else stripped.
    func testSettingALabelAlwaysWritesIt() {
        XCTAssertEqual(SidecarLabelPolicy.write(appLabel: "red", labelChanged: true), "red")
        XCTAssertEqual(SidecarLabelPolicy.write(appLabel: "red", labelChanged: false), "red")
    }

    /// An empty string is not a label; it is the absence of one wearing a name.
    func testAnEmptyNameIsTreatedAsNoLabel() {
        XCTAssertNil(SidecarLabelPolicy.write(appLabel: "", labelChanged: false))
    }
}
