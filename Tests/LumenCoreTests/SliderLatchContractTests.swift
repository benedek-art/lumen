// SliderLatchContractTests.swift
// Where `LumenSlider` opens, re-asserts and hands off the gesture latch.
//
// `LumenSlider` lives in `Sources/LumenApp`, which no Linux compiler sees, so these are
// text scans over the comment-stripped source (`ShellSource`). What the latch DOES is
// pinned against the real `AppState` in LumenAppTests (`GestureUndoStepTests`); these pin
// that the control actually calls it in the order that behaviour needs.

import Foundation
import XCTest

final class SliderLatchContractTests: XCTestCase {

    private static func slider() throws -> String {
        let code = try ShellSource.code("Sources/LumenApp/LumenControls.swift")
        return try XCTUnwrap(ShellSource.body(after: "struct LumenSlider: View", in: code))
    }

    /// The track's `onChanged` closure.
    private static func trackChanged() throws -> String {
        let s = try slider()
        let drag = try XCTUnwrap(s.range(of: "DragGesture(minimumDistance: 0)"))
        return try XCTUnwrap(ShellSource.body(after: ".onChanged",
                                              in: String(s[drag.upperBound...])))
    }

    /// The readout scrub's `onChanged` closure.
    private static func scrubChanged() throws -> String {
        let s = try slider()
        let drag = try XCTUnwrap(s.range(of: "DragGesture(minimumDistance: 3)"))
        return try XCTUnwrap(ShellSource.body(after: ".onChanged",
                                              in: String(s[drag.upperBound...])))
    }

    /// Finding: a track press wrote its jump before the latch opened — an immediate
    /// catalog write and an epoch-less undo step a pause could split.
    func testATrackPressOpensTheLatchBeforeItWritesTheJump() throws {
        let body = try Self.trackChanged()
        let latch = try XCTUnwrap(body.range(of: "sliderGestureChanged(true)")).lowerBound
        let jump = try XCTUnwrap(body.range(of: "value = dragStartValue")).lowerBound
        XCTAssertLessThan(latch, jump, "the press's jump is written before the latch opens")
    }

    /// Finding: the latch was asserted only on the first sample, so anything that closed
    /// it under a held button (watchdog, ⌘Z, a stale closer) left the drag unlatched.
    func testTheTrackReassertsTheLatchOnEverySample() throws {
        let body = try Self.trackChanged()
        let inert = try XCTUnwrap(body.range(of: "if pressWasReset { return }"))
        XCTAssertTrue(body[inert.upperBound...].contains("sliderGestureChanged(true)"),
                      "the track latches only inside its first-event branch")
    }

    func testTheScrubReassertsTheLatchOnEverySample() throws {
        let body = try Self.scrubChanged()
        let first = try XCTUnwrap(ShellSource.body(after: "if !isScrubbing", in: body))
        let firstEnd = try XCTUnwrap(body.range(of: first)).upperBound
        XCTAssertTrue(body[firstEnd...].contains("sliderGestureChanged(true)"),
                      "the scrub latches only inside its first-event branch")
    }
}
