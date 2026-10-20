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
        // After the double-click branch, whose put-back has a latch of its own.
        let press = try XCTUnwrap(body.range(of: "firstClickOrigin = value")).upperBound
        let latch = try XCTUnwrap(body[press...].range(of: "sliderGestureChanged(true)")).lowerBound
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

    /// Finding: the first click of a double-click jumped the value and the second reset
    /// through `onReset` under another key, so one ⌘Z landed on the click-point value.
    /// The second click puts the jump back (under the row's key) before resetting.
    func testADoubleClickPutsBackTheFirstClicksJumpBeforeResetting() throws {
        let body = try Self.trackChanged()
        let branch = try XCTUnwrap(ShellSource.body(after: "clickCount ?? 1) >= 2", in: body))
        let putBack = try XCTUnwrap(branch.range(of: "value = origin")).lowerBound
        let reset = try XCTUnwrap(branch.range(of: "reset(latched: true)")).lowerBound
        XCTAssertLessThan(putBack, reset)
        // One latch around both, so `onReset`'s write under another key folds in.
        let open = try XCTUnwrap(branch.range(of: "sliderGestureChanged(true)")).lowerBound
        let close = try XCTUnwrap(branch.range(of: "sliderGestureChanged(false)")).lowerBound
        XCTAssertLessThan(open, putBack)
        XCTAssertLessThan(reset, close)
        XCTAssertTrue(branch.contains("NSEvent.doubleClickInterval"),
                      "an origin from some earlier press must not be put back")
        let afterBranch = try XCTUnwrap(body.range(of: branch)).upperBound
        let remembered = try XCTUnwrap(body[afterBranch...].range(of: "firstClickOrigin = value"))
        let jump = try XCTUnwrap(body.range(of: "value = dragStartValue"))
        XCTAssertLessThan(remembered.lowerBound, jump.lowerBound,
                          "the origin must be taken before the press jumps the value")
    }

    /// Finding: the wheel's silence closer lived in the row, so it could unlatch another
    /// row's drag and share its epoch with it. The row now only reports the tick.
    func testTheWheelNudgeHandsItsLatchToTheState() throws {
        let s = try Self.slider()
        let body = try XCTUnwrap(ShellSource.body(after: "private func wheelNudge(", in: s))
        XCTAssertTrue(body.contains("sliderWheelTick(wheelOwner)"))
        XCTAssertFalse(body.contains("sliderGestureChanged"),
                       "the row must not open or close the shared latch for a wheel tick")
        XCTAssertFalse(body.contains("Task"), "the silence closer belongs to AppState")

        let state = try ShellSource.code("Sources/LumenApp/AppState.swift")
        let open = try XCTUnwrap(ShellSource.body(after: "func sliderGesture(active: Bool)",
                                                  in: state))
        XCTAssertTrue(ShellSource.squashed(open).contains(
            "if wheelGestureOwner != nil { closeSliderGesture() }"),
            "a gesture starting must end a wheel burst")
    }

    /// Finding: the colour wheel's release ignored the drag value, so a drag let go
    /// while the main actor lagged stopped short. Its release is a sample, as here.
    func testTheWheelTakesItsReleaseAsASample() throws {
        let code = try ShellSource.code("Sources/LumenApp/LumenControls.swift")
        let wheel = try XCTUnwrap(ShellSource.body(after: "struct LumenColorWheel: View", in: code))
        let ended = try XCTUnwrap(ShellSource.body(after: ".onEnded", in: wheel))
        XCTAssertTrue(ended.contains("if dragMoved { follow(drag) }"))
    }
}
