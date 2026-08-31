// MaskOverlayRuleTests.swift
// The three guards that produced three defects, with nothing testing any of them.
//
// The overlay state machine lived entirely inside `AppState` — `@MainActor`, and its
// initializer opens a catalog on disk, so it has never been unit testable. It shipped
// with five inputs, nine writers of one variable, and zero tests. An audit found three
// defects in it, and all three were guards rather than logic.
//
// `MaskOverlayRule` is those guards, in LumenCore, called by `AppState` rather than
// mirrored in it. These tests convict the shipping code.

import XCTest
@testable import LumenCore

final class MaskOverlayRuleTests: XCTestCase {

    // MARK: - The pin, and the trap it used to be

    /// The defect, in one assertion.
    ///
    /// The row menu's "Keep it showing" pinned. "Keep it hidden" cleared the overlay and
    /// left the pin SET. Flash, hover and the edge-drag overlay all open with
    /// `guard !pinned`, so from that moment nothing ambient could draw: no creation
    /// flash, no hover preview, no matte while dragging an edge — for the rest of the
    /// photograph, with nothing on screen saying so.
    ///
    /// What convicts the fix is not that a pin blocks ambient rules, which is correct
    /// and deliberate; it is that the pin must be CLEARABLE, and that the state reached
    /// by hiding a pinned overlay is one where ambient rules work again.
    func testHidingAPinnedOverlayReturnsToAWorkingAmbientState() {
        var rule = MaskOverlayRule(pinned: true)
        XCTAssertFalse(rule.ambientAllowed,
                       "a pinned overlay is a decision and ambient rules defer to it")

        // "Keep it hidden" — which must take the pin with it.
        rule.pinned = false
        XCTAssertTrue(rule.ambientAllowed,
                      "hiding a pinned overlay left the pin set, which silently "
                          + "disabled flash, hover and the edge overlay")
    }

    // MARK: - Suppression, which was written and never read

    /// `maskOverlaySuppressed` was set on every Effect press and read by nothing except
    /// its own dedup guard. So the flag whose entire job was "not now" was inert, and a
    /// flash arriving mid-drag — clicking another mask's pin, say — put the red straight
    /// back over the pixels being judged.
    func testAnEffectDragBlocksEveryAmbientRule() {
        let rule = MaskOverlayRule(suppressed: true)
        XCTAssertFalse(rule.ambientAllowed)
    }

    /// Hovering a row during an Exposure drag used to defeat the suppression outright:
    /// `hoverMaskOverlay` consulted the pin and not the suppression, so the overlay came
    /// back up over the pixels the drag was there to judge.
    func testHoveringARowDuringAnEffectDragDoesNotRaiseTheOverlay() {
        let rule = MaskOverlayRule(persistentID: "m1", suppressed: true)
        XCTAssertFalse(rule.ambientAllowed)
        XCTAssertNil(rule.afterHoverExit,
                     "nor may the pointer LEAVING a row raise it during a drag")
    }

    /// Both blocks are independent — neither one is doing the other's work.
    func testEitherBlockAloneIsEnough() {
        XCTAssertTrue(MaskOverlayRule().ambientAllowed)
        XCTAssertFalse(MaskOverlayRule(pinned: true).ambientAllowed)
        XCTAssertFalse(MaskOverlayRule(suppressed: true).ambientAllowed)
        XCTAssertFalse(MaskOverlayRule(pinned: true, suppressed: true).ambientAllowed)
    }

    // MARK: - The persistent phase

    /// The rule the panel had no way to express: a mask stays lit until it is adjusted.
    ///
    /// Every path was a countdown or a hover, so "show me what I just selected" was a
    /// flash you had to catch. Worse, for a brush, a gradient, a radial or an outline
    /// the flash rendered NOTHING — an undrawn mask's alpha is zero and a zero-alpha
    /// colour overlay composites to the photograph unchanged — and painting did not
    /// raise the overlay either. A brush mask could reach a finished adjustment without
    /// the red having been visible for one frame.
    func testAMaskStillBeingMadeSurvivesItsStandDownTimer() {
        let rule = MaskOverlayRule(persistentID: "m1")
        XCTAssertFalse(rule.mayStandDown("m1"),
                       "the 1400 ms flash timer must not take down a mask that has "
                           + "not been adjusted yet")
        XCTAssertTrue(rule.mayStandDown("m2"),
                      "another mask's flash is still a flash")
    }

    /// With no persistent mask the timer behaves exactly as it always did, so the fix
    /// cannot have made a flash permanent.
    func testWithNothingPersistentEveryFlashStandsDown() {
        let rule = MaskOverlayRule()
        XCTAssertTrue(rule.mayStandDown("m1"))
        XCTAssertTrue(rule.mayStandDown("anything"))
    }

    /// Hovering a second mask while a new one is lit used to end with the photograph
    /// dark: the exit cleared the overlay outright and nothing put the persistent one
    /// back. The pointer leaving a row is not a decision to stop showing the mask you
    /// are in the middle of making.
    func testLeavingARowFallsBackToTheMaskStillBeingMade() {
        XCTAssertEqual(MaskOverlayRule(persistentID: "m1").afterHoverExit, "m1")
    }

    /// And with nothing being made, leaving a row still takes the overlay down — the
    /// hover preview must not become sticky.
    func testLeavingARowWithNothingPendingTakesTheOverlayDown() {
        XCTAssertNil(MaskOverlayRule().afterHoverExit)
    }

    // MARK: - The phase ends on the first Effect touch, not the first change

    /// The distinction that makes the rule right rather than merely persistent.
    ///
    /// Refining an edge is still SELECTION work, and the overlay is the only place a
    /// selection is visible at all — so an Edge drag must not end the persistent phase.
    /// Only an Effect control, which moves the picture, does. `AppState` expresses this
    /// by clearing `persistentID` from `setMaskOverlaySuppressed` (the Effect zone's
    /// hook) and never from `setMaskEdgeGesture` (the Edge zone's), so what this asserts
    /// is the consequence: suppression and persistence can be true together exactly once
    /// — during the press that ends the phase — and the overlay is down for it.
    func testSuppressionWinsOverPersistenceSoTheFirstAdjustmentIsJudgedClean() {
        let midPress = MaskOverlayRule(persistentID: "m1", suppressed: true)
        XCTAssertFalse(midPress.ambientAllowed)
        XCTAssertNil(midPress.afterHoverExit,
                     "the overlay is out of the way for the very first adjustment, "
                         + "not from the second one onward")
    }

    // MARK: - Shape

    /// It is a value, so two rules with the same inputs are the same rule. This is what
    /// lets `AppState` build one on demand in a computed property instead of holding a
    /// fourth piece of state that could fall out of step with the three it summarises.
    func testItIsAValue() {
        XCTAssertEqual(MaskOverlayRule(pinned: true, persistentID: "m", suppressed: false),
                       MaskOverlayRule(pinned: true, persistentID: "m", suppressed: false))
        XCTAssertNotEqual(MaskOverlayRule(persistentID: "m1"),
                          MaskOverlayRule(persistentID: "m2"))
    }

    /// The default is the state a photograph opens in: nothing pinned, nothing being
    /// made, nothing suppressed, every ambient rule live.
    func testTheDefaultIsAnOrdinaryWorkingState() {
        let fresh = MaskOverlayRule()
        XCTAssertTrue(fresh.ambientAllowed)
        XCTAssertNil(fresh.persistentID)
        XCTAssertNil(fresh.afterHoverExit)
        XCTAssertTrue(fresh.mayStandDown("m1"))
    }
}
