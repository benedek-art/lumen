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

// MARK: - The gesture epoch (L-01)
//
// A grading wheel's puck writes hue and then sat inside one `onChanged`, through two
// bindings with two different coalescing keys. The open step's key alternated and never
// matched the incoming one, so the key rule failed on every mouse event: two undo steps
// per event, sixty events a second, against a 400-step ring — about three and a half
// seconds of moving a puck evicted everything older in the session.

extension HistoryCoalescingTests {

    private var oneURL: Set<URL> { [URL(fileURLWithPath: "/a.arw")] }

    /// The defect, in one assertion: two different keys, same gesture, one step.
    func testTwoFieldsWrittenByOneGestureCoalesceDespiteDifferentKeys() {
        XCTAssertTrue(HistoryCoalescing.shouldCoalesce(
            openKey: "wheel.Shadows.hue", openURLs: oneURL,
            key: "wheel.Shadows.sat", urls: oneURL,
            sinceLastEdit: 0.016, window: 1.2,
            openEpoch: 7, epoch: 7),
            "a wheel puck writes hue and sat under two keys in one mouse event; without "
            + "the epoch that was two undo steps per event")
    }

    /// A long, careful drag is still one decision — the window must not close it.
    /// The silence watchdog that already exists is what ends an abandoned gesture.
    func testALongGestureIsStillOneStep() {
        XCTAssertTrue(HistoryCoalescing.shouldCoalesce(
            openKey: "wheel.Shadows.hue", openURLs: oneURL,
            key: "wheel.Shadows.hue", urls: oneURL,
            sinceLastEdit: 9.0, window: 1.2,
            openEpoch: 3, epoch: 3))
    }

    /// THE EPOCH ONLY EVER ADDS A REASON TO COALESCE, never a reason to refuse.
    ///
    /// Two quick nudges of the same slider are two gestures with two epochs, and they
    /// still fold — because that is the rule this app already chose, and the file says
    /// so: the WINDOW is what separates decisions ("nudge, think, nudge again gives you
    /// two steps"), not the mouse button. An earlier version of this test asserted the
    /// opposite and was wrong about the app it was testing; making different epochs
    /// refuse would have quietly turned every double-nudge into two undo steps.
    func testDifferentGesturesStillFollowTheOlderKeyAndWindowRule() {
        XCTAssertTrue(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: oneURL,
            key: "tone.exposure", urls: oneURL,
            sinceLastEdit: 0.05, window: 1.2,
            openEpoch: 4, epoch: 5),
            "same control, 50 ms apart: the window rule folded these before the epoch "
            + "existed and must still fold them")
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: oneURL,
            key: "tone.exposure", urls: oneURL,
            sinceLastEdit: 3.0, window: 1.2,
            openEpoch: 4, epoch: 5),
            "and a pause between two gestures still starts a new step")
    }

    /// The photo set still governs: a drag that spans a photograph switch must not fold
    /// the second photograph's edit into the first's step.
    func testAGestureSpanningAPhotoSwitchDoesNotCoalesce() {
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: oneURL,
            key: "tone.exposure", urls: [URL(fileURLWithPath: "/b.arw")],
            sinceLastEdit: 0.016, window: 1.2,
            openEpoch: 7, epoch: 7),
            "the epoch must not override the photo-set guard — that guard exists so an "
            + "off-screen photograph's pre-drag state is never lost")
    }

    /// Outside a gesture the old rule is untouched.
    func testOutsideAGestureTheKeyAndWindowRuleStillDecides() {
        XCTAssertTrue(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: oneURL,
            key: "tone.exposure", urls: oneURL,
            sinceLastEdit: 0.5, window: 1.2, openEpoch: nil, epoch: nil))
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: oneURL,
            key: "tone.exposure", urls: oneURL,
            sinceLastEdit: 3.0, window: 1.2, openEpoch: nil, epoch: nil),
            "a pause still starts a new step")
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: "tone.exposure", openURLs: oneURL,
            key: "tone.contrast", urls: oneURL,
            sinceLastEdit: 0.1, window: 1.2, openEpoch: nil, epoch: nil),
            "two different controls outside a gesture are two steps")
    }

    /// The property the owner actually lost: a drag no longer eats the session.
    ///
    /// Counts steps the way `HistoryStack` would, over a 240-event drag — four seconds
    /// at 60 Hz, past the 3.4 s that used to fill the 400-step ring.
    func testAFourSecondWheelDragCostsOneStepRatherThanFiveHundred() {
        var steps = 0
        var openKey: String?
        var openEpoch: Int?
        for event in 0..<240 {
            for key in ["wheel.Shadows.hue", "wheel.Shadows.sat"] {
                let coalesces = steps > 0 && HistoryCoalescing.shouldCoalesce(
                    openKey: openKey, openURLs: oneURL,
                    key: key, urls: oneURL,
                    sinceLastEdit: 0.016, window: 1.2,
                    openEpoch: openEpoch, epoch: 9)
                if !coalesces {
                    steps += 1
                    openKey = key
                    openEpoch = 9
                }
                _ = event
            }
        }
        XCTAssertEqual(steps, 1,
                       "a four-second wheel drag produced \(steps) undo steps; at 480 "
                       + "steps it evicts a 400-step history and the session's earlier "
                       + "work cannot be undone back to")
    }
}
