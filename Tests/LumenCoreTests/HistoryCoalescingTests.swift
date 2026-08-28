// HistoryCoalescingTests.swift
// The undo-step folding rule (docs/23 audit queue item 3). The conviction case is
// the photo switch: same control, inside the window, DIFFERENT photo — the old
// key+recency rule folded that into the open step, so undo reverted the photo no
// longer on screen and the new photo's pre-drag state was never recorded.

import XCTest
@testable import LumenCore

final class HistoryCoalescingTests: XCTestCase {

    private let a = Set([URL(fileURLWithPath: "/shoot/DSC0001.ARW")])
    private let b = Set([URL(fileURLWithPath: "/shoot/DSC0002.ARW")])

    func testTheSameDragOnTheSamePhotoCoalesces() {
        XCTAssertTrue(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: a,
            key: "tone.exposure", urls: a,
            sinceLastEdit: 0.05, window: 1.2))
    }

    func testAPhotoSwitchInsideTheWindowOpensANewStep() {
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: a,
            key: "tone.exposure", urls: b,
            sinceLastEdit: 0.4, window: 1.2),
            "the same control on a different photo is a different edit — folding it "
                + "makes undo revert the off-screen photo")
    }

    func testASelectionChangeInsideTheWindowOpensANewStep() {
        // More photos than the open step claims — equality, not subset, so the
        // step's `before` stays complete for every photo it can restore.
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: a,
            key: "tone.exposure", urls: a.union(b),
            sinceLastEdit: 0.1, window: 1.2))
    }

    func testADifferentControlOpensANewStep() {
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: a,
            key: "tone.contrast", urls: a,
            sinceLastEdit: 0.1, window: 1.2))
    }

    func testAPauseBeyondTheWindowOpensANewStep() {
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: a,
            key: "tone.exposure", urls: a,
            sinceLastEdit: 1.3, window: 1.2))
    }

    func testAKeylessEditNeverCoalesces() {
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: nil, openURLs: a, key: nil, urls: a,
            sinceLastEdit: 0.1, window: 1.2))
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: a, key: nil, urls: a,
            sinceLastEdit: 0.1, window: 1.2))
    }
}
