// MaskOverlayRuleTests.swift
// The overlay's whole state machine: Lightroom's Automatically Toggle Overlay, plus an
// explicit Show/Hide that outranks it.

import XCTest
@testable import LumenCore

final class MaskOverlayRuleTests: XCTestCase {

    private typealias Rule = MaskOverlayRule

    private func rule(_ events: Rule.Event...) -> Rule {
        var r = Rule(masking: true)
        for e in events { r.reduce(e) }
        return r
    }

    private func shown(_ r: Rule) -> String? { r.shownID }

    // MARK: - Defaults

    func testNothingIsShownByDefault() {
        XCTAssertNil(Rule().shownID)
        XCTAssertNil(Rule(masking: true).shownID)
        XCTAssertEqual(Rule().choice, .automatic)
    }

    func testSelectingAMaskAloneShowsNothing() {
        XCTAssertNil(shown(rule(.selected("a"))))
    }

    // MARK: - Creation phase

    func testCreatingAMaskShowsItUntilTheFirstAdjustment() {
        var r = rule(.created("a"))
        XCTAssertEqual(r.resolution, .init(id: "a", reason: .creating))
        XCTAssertEqual(r.selectedID, "a")
        r.reduce(.adjusted("a", held: true))
        XCTAssertNil(r.shownID, "the first adjustment takes the red down")
        r.reduce(.gesturesEnded)
        XCTAssertNil(r.shownID, "and releasing the slider does not bring it back")
    }

    /// The owner's report, as a sequence: create, adjust, then hover in and out. The red
    /// must be gone after the adjustment and after every hover exit.
    func testAfterAdjustingTheOverlayAppearsOnlyWhileHovered() {
        var r = rule(.created("a"), .adjusted("a", held: false))
        XCTAssertNil(r.shownID)
        r.reduce(.panelHover("a"))
        XCTAssertEqual(r.resolution, .init(id: "a", reason: .panelHover))
        r.reduce(.panelHover(nil))
        XCTAssertNil(r.shownID)
        r.reduce(.canvasHover("a"))
        XCTAssertEqual(r.resolution, .init(id: "a", reason: .canvasHover))
        r.reduce(.canvasHover(nil))
        XCTAssertNil(r.shownID)
    }

    func testAnAdjustmentWithNoSliderHeldStillEndsCreation() {
        // A typed value, a reset button, a preset: no gesture, same rule.
        XCTAssertNil(shown(rule(.created("a"), .adjusted("a", held: false))))
    }

    func testAddingAComponentIsSelectionWorkAndShowsUntilAdjusted() {
        var r = rule(.created("a"), .adjusted("a", held: false), .componentAdded("a"))
        XCTAssertEqual(r.resolution, .init(id: "a", reason: .creating))
        r.reduce(.adjusted("a", held: false))
        XCTAssertNil(r.shownID)
    }

    func testHoveringAnotherMaskDuringCreationFallsBackToTheNewMask() {
        var r = rule(.created("a"), .panelHover("b"))
        XCTAssertEqual(r.shownID, "b")
        r.reduce(.panelHover(nil))
        XCTAssertEqual(r.shownID, "a")
    }

    func testCreatingASecondMaskMovesTheCreationPhase() {
        var r = rule(.created("a"))
        r.reduce(.selected("b"))
        r.reduce(.created("b"))
        XCTAssertEqual(r.shownID, "b")
        XCTAssertEqual(r.creatingID, "b")
    }

    // MARK: - Selection gestures

    func testASelectionGestureShowsOnlyWhileItIsHeld() {
        var r = rule(.created("a"), .adjusted("a", held: false))
        r.reduce(.selectionGesture("a"))
        XCTAssertEqual(r.resolution, .init(id: "a", reason: .selectionWork))
        r.reduce(.selectionGesture(nil))
        XCTAssertNil(r.shownID, "an adjusted mask does not stay red after a brush stroke")
    }

    func testAGestureOnAMaskStillBeingCreatedLeavesItShown() {
        var r = rule(.created("a"), .selectionGesture("a"), .gesturesEnded)
        XCTAssertEqual(r.resolution, .init(id: "a", reason: .creating))
    }

    func testADroppedGestureReleaseIsClosedByGesturesEnded() {
        var r = rule(.created("a"), .adjusted("a", held: false), .selectionGesture("a"))
        r.reduce(.gesturesEnded)
        XCTAssertNil(r.shownID, "the app's latch closing must end a selection gesture")
    }

    func testTheSelectionGestureOutranksHoverAndAdjusting() {
        let r = rule(.panelHover("b"), .selectionGesture("a"))
        XCTAssertEqual(r.shownID, "a")
    }

    // MARK: - Adjusting

    func testHoverIsSuppressedWhileAnAdjustmentIsHeld() {
        var r = rule(.adjusted("a", held: true), .panelHover("a"))
        XCTAssertNil(r.shownID)
        r.reduce(.gesturesEnded)
        XCTAssertEqual(r.shownID, "a")
    }

    // MARK: - The explicit choice

    func testOShowsWhenNothingIsShownAndHidesWhenSomethingIs() {
        var r = rule(.selected("a"))
        r.reduce(.toggle)
        XCTAssertEqual(r.choice, .show)
        XCTAssertEqual(r.resolution, .init(id: "a", reason: .chosen))
        r.reduce(.toggle)
        XCTAssertEqual(r.choice, .hide)
        XCTAssertNil(r.shownID)
        r.reduce(.toggle)
        XCTAssertEqual(r.choice, .show)
    }

    func testOHidesAMaskBeingCreated() {
        var r = rule(.created("a"))
        r.reduce(.toggle)
        XCTAssertEqual(r.choice, .hide)
        XCTAssertNil(r.shownID)
    }

    func testShowOutranksAdjusting() {
        var r = rule(.selected("a"), .choose(.show))
        r.reduce(.adjusted("a", held: true))
        XCTAssertEqual(r.shownID, "a", "an explicit Show is not an ambient overlay")
        r.reduce(.gesturesEnded)
        XCTAssertEqual(r.shownID, "a")
    }

    func testShowPreviewsTheHoveredMaskThenReturnsToTheSelection() {
        var r = rule(.selected("a"), .choose(.show), .panelHover("b"))
        XCTAssertEqual(r.shownID, "b")
        r.reduce(.panelHover(nil))
        XCTAssertEqual(r.shownID, "a")
    }

    func testShowFollowsTheSelection() {
        var r = rule(.selected("a"), .choose(.show))
        r.reduce(.selected("b"))
        XCTAssertEqual(r.shownID, "b")
    }

    func testHideOutranksEveryAmbientInput() {
        let r = rule(.created("a"), .choose(.hide), .panelHover("a"),
                     .canvasHover("a"), .selectionGesture("a"))
        XCTAssertNil(r.shownID)
    }

    func testReturningToAutomaticRestoresAmbientBehaviour() {
        var r = rule(.created("a"), .choose(.hide))
        XCTAssertNil(r.shownID)
        r.reduce(.choose(.automatic))
        XCTAssertEqual(r.shownID, "a", "creation was not ended by hiding")
        r.reduce(.choose(.show))
        r.reduce(.adjusted("a", held: false))
        r.reduce(.choose(.automatic))
        XCTAssertNil(r.shownID, "back in Automatic after an adjustment: nothing")
    }

    func testTheControlCyclesThroughAllThreeChoices() {
        XCTAssertEqual(Rule.nextChoice(after: .automatic), .show)
        XCTAssertEqual(Rule.nextChoice(after: .show), .hide)
        XCTAssertEqual(Rule.nextChoice(after: .hide), .automatic)
    }

    // MARK: - Selection, photo, masking

    func testSelectingAnotherMaskEndsCreation() {
        var r = rule(.created("a"))
        r.reduce(.selected("b"))
        XCTAssertNil(r.shownID)
        r.reduce(.selected("a"))
        XCTAssertNil(r.shownID, "creation does not come back by reselecting")
    }

    func testSelectingAnotherMaskEndsAGestureOnTheOldOne() {
        XCTAssertNil(shown(rule(.selected("a"), .selectionGesture("a"), .selected("b"))))
    }

    func testReselectingTheSameMaskIsANoOp() {
        XCTAssertEqual(shown(rule(.created("a"), .selected("a"))), "a")
    }

    func testChangingPhotoResetsEverythingIncludingTheChoice() {
        var r = rule(.created("a"), .choose(.show), .panelHover("a"))
        r.reduce(.photoChanged)
        XCTAssertNil(r.shownID)
        XCTAssertEqual(r.choice, .automatic)
        XCTAssertNil(r.selectedID)
        XCTAssertNil(r.panelHoverID)
        XCTAssertTrue(r.masking, "the editor stays open across photographs")
    }

    func testLeavingMaskingShowsNothingAndForgetsTheChoice() {
        var r = rule(.created("a"), .choose(.show), .selectionGesture("a"))
        r.reduce(.masking(false))
        XCTAssertNil(r.shownID)
        XCTAssertEqual(r.choice, .automatic)
        r.reduce(.masking(true))
        XCTAssertNil(r.shownID, "re-entering does not bring back a stale overlay")
    }

    func testNothingShowsOutsideMaskingWhateverTheInputs() {
        var r = Rule(masking: false)
        r.reduce(.selected("a"))
        r.reduce(.choose(.show))
        r.reduce(.panelHover("a"))
        XCTAssertNil(r.shownID)
    }

    func testOFromOutsideMaskingShowsOnceTheEditorOpens() {
        var r = Rule(masking: false)
        r.reduce(.toggle)
        r.reduce(.masking(true))
        r.reduce(.selected("a"))
        XCTAssertEqual(r.resolution, .init(id: "a", reason: .chosen))
    }

    // MARK: - Undo, redo, delete

    func testUndoingACreationLeavesNothingShown() {
        var r = rule(.created("a"))
        r.reduce(.gesturesEnded)
        r.reduce(.masksChanged([]))
        XCTAssertNil(r.shownID)
        XCTAssertNil(r.creatingID)
        XCTAssertNil(r.selectedID)
    }

    func testRedoingACreationDoesNotRestartTheCreationPhase() {
        var r = rule(.created("a"), .masksChanged([]))
        r.reduce(.masksChanged(["a"]))
        r.reduce(.selected("a"))
        XCTAssertNil(r.shownID)
    }

    func testDeletingAHoveredMaskDropsTheHover() {
        let r = rule(.created("a"), .adjusted("a", held: false), .panelHover("b"),
                     .canvasHover("b"), .masksChanged(["a"]))
        XCTAssertNil(r.shownID)
    }

    func testDeletingTheShownMaskUnderShowMovesToTheNewSelection() {
        var r = rule(.selected("a"), .choose(.show), .masksChanged(["b"]))
        XCTAssertNil(r.shownID)
        r.reduce(.selected("b"))
        XCTAssertEqual(r.shownID, "b")
    }

    func testUndoOfAnAdjustmentDoesNotBringTheRedBack() {
        let r = rule(.created("a"), .adjusted("a", held: false), .gesturesEnded,
                     .masksChanged(["a"]))
        XCTAssertNil(r.shownID)
    }

    // MARK: - The full sequence

    func testCreateAdjustHoverPinUnpinSelectOtherUndo() {
        var r = Rule(masking: false)
        r.reduce(.masking(true))
        r.reduce(.selected("a")); r.reduce(.created("a"))
        XCTAssertEqual(r.shownID, "a", "create")
        r.reduce(.selectionGesture("a"))
        XCTAssertEqual(r.shownID, "a", "draw")
        r.reduce(.gesturesEnded)
        XCTAssertEqual(r.shownID, "a", "still being made")
        r.reduce(.adjusted("a", held: true))
        XCTAssertNil(r.shownID, "adjust")
        r.reduce(.gesturesEnded)
        XCTAssertNil(r.shownID, "release")
        r.reduce(.panelHover("a"))
        XCTAssertEqual(r.shownID, "a", "hover in")
        r.reduce(.panelHover(nil))
        XCTAssertNil(r.shownID, "hover out")
        r.reduce(.toggle)
        XCTAssertEqual(r.resolution, .init(id: "a", reason: .chosen), "pin")
        r.reduce(.adjusted("a", held: false))
        XCTAssertEqual(r.shownID, "a", "pinned survives an adjustment")
        r.reduce(.toggle)
        XCTAssertNil(r.shownID, "unpin hides")
        r.reduce(.choose(.automatic))
        XCTAssertNil(r.shownID, "automatic, adjusted: nothing")
        r.reduce(.selected("b"))
        XCTAssertNil(r.shownID, "select other")
        r.reduce(.masksChanged(["b"]))
        XCTAssertNil(r.shownID, "undo")
        r.reduce(.masking(false))
        XCTAssertNil(r.shownID)
    }

    /// Exhaustive: from any reachable state, leaving masking or changing photo shows
    /// nothing, and after any adjustment with no pointer on a row or pin and no gesture,
    /// Automatic shows nothing. No sequence can leave the red stuck in Automatic.
    func testNoSequenceLeavesTheRedStuckInAutomatic() {
        let events: [Rule.Event] = [
            .created("a"), .created("b"), .selected("a"), .selected("b"), .selected(nil),
            .componentAdded("a"), .selectionGesture("a"), .selectionGesture(nil),
            .adjusted("a", held: true), .adjusted("b", held: false), .gesturesEnded,
            .panelHover("a"), .panelHover("b"), .panelHover(nil),
            .canvasHover("a"), .canvasHover(nil), .toggle, .choose(.show), .choose(.hide),
            .masksChanged(["a"]), .masksChanged(["a", "b"]),
        ]
        var frontier: [Rule] = [Rule(masking: true)]
        var seen: Set<String> = []
        func key(_ r: Rule) -> String { String(describing: r) }
        for _ in 0..<4 {
            var next: [Rule] = []
            for r in frontier {
                for e in events {
                    var s = r
                    s.reduce(e)
                    guard seen.insert(key(s)).inserted else { continue }
                    next.append(s)

                    var out = s; out.reduce(.masking(false))
                    XCTAssertNil(out.shownID)
                    var moved = s; moved.reduce(.photoChanged)
                    XCTAssertNil(moved.shownID)

                    var settled = s
                    for e in [Rule.Event.choose(.automatic), .adjusted("x", held: false),
                              .gesturesEnded, .panelHover(nil), .canvasHover(nil)] {
                        settled.reduce(e)
                    }
                    XCTAssertNil(settled.shownID, "stuck after \(key(s))")
                }
            }
            frontier = next
        }
        XCTAssertGreaterThan(seen.count, 100)
    }

    func testTheStateRoundTripsThroughJSONForTheDriverDump() throws {
        let r = rule(.created("a"), .panelHover("b"))
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(Rule.self, from: data), r)
    }
}
