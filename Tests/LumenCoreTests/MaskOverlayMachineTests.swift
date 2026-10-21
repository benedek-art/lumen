// MaskOverlayMachineTests.swift
// The owner's scenarios, driven through the one state machine that decides the overlay.
//
// Each test is a row of the state table in docs/quality/lanes/WS-42/SPEC.md (T1-T18).
// They replace MaskOverlayRuleTests, whose three guards (the pin must be clearable, a
// drag blocks ambient overlays, a just-made mask survives a hover exit) are all
// restated here as scenarios against the machine that replaced the guard struct.
//
// Events are sent the way AppState sends them: the slider latch sends gestureBegan and
// gestureEnded, `updateRecipe` sends `.edited(classify(old, new))`, the panel sends
// created / selected / hover / toggle.

import XCTest
@testable import LumenCore

final class MaskOverlayMachineTests: XCTestCase {

    /// One Exposure drag on a mask's own Light section, exactly as AppState sees it.
    private let exposureDrag: [MaskOverlayMachine.Event] = [
        .gestureBegan, .edited(.adjustment), .edited(.adjustment), .gestureEnded,
    ]

    private func run(_ m: inout MaskOverlayMachine, _ events: [MaskOverlayMachine.Event]) {
        for e in events { m.send(e) }
    }

    // MARK: - The owner's report

    /// "It shows me the red item that is highlighted and it never goes away, even if
    /// I'm exposing it." Create a mask, overlay on, drag Exposure, overlay OFF, and it
    /// stays off after release.
    func testT1toT3_createThenDragExposureTakesTheOverlayDownAndKeepsItDown() {
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        XCTAssertEqual(m.visibleID, "m1", "T1: a new mask shows what it selects")

        m.send(.gestureBegan)
        XCTAssertEqual(m.visibleID, "m1",
                       "pressing a slider without moving it changes nothing yet")
        m.send(.edited(.adjustment))
        XCTAssertNil(m.visibleID, "T2: the first Exposure movement takes the red down")
        m.send(.edited(.adjustment))
        XCTAssertNil(m.visibleID)

        m.send(.gestureEnded)
        XCTAssertNil(m.visibleID,
                     "T3: it does not come back on release; only O, hover or a click does")
        m.send(.hoverEnded)
        XCTAssertNil(m.visibleID, "and a stray hover exit does not resurrect it")
    }

    func testT4_hoverBringsItBackWhileThePointerIsThere() {
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        run(&m, exposureDrag)
        m.send(.hoverBegan("m1"))
        XCTAssertEqual(m.visibleID, "m1")
        m.send(.hoverEnded)
        XCTAssertNil(m.visibleID)
    }

    func testT5_clickingTheMaskShowsItAgain() {
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        run(&m, exposureDrag)
        m.send(.selected("m1"))
        XCTAssertEqual(m.visibleID, "m1")
        run(&m, exposureDrag)
        XCTAssertNil(m.visibleID, "and the next drag takes it down again")
    }

    // MARK: - Show Overlay (the pin) and O

    func testT6T7_aPinnedOverlayHidesDuringTheDragAndReturnsOnRelease() {
        var m = MaskOverlayMachine()
        m.send(.selected("m1"))
        m.send(.pin("m1"))
        XCTAssertEqual(m.visibleID, "m1")
        m.send(.gestureBegan)
        m.send(.edited(.adjustment))
        XCTAssertNil(m.visibleID, "T6: even a pinned overlay is out of the way mid-drag")
        m.send(.gestureEnded)
        XCTAssertEqual(m.visibleID, "m1", "T7: Show Overlay brings it back on release")
        XCTAssertTrue(m.pinned)
    }

    func testT8_OOffMeansOffEvenForAJustMadeMask() {
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        m.send(.toggle(selected: "m1"))
        XCTAssertNil(m.visibleID)
        m.send(.hoverBegan("m2"))
        m.send(.hoverEnded)
        XCTAssertNil(m.visibleID, "the hover exit must not put the just-made mask back")
        XCTAssertFalse(m.pinned)
    }

    func testT9_OTogglesAPinOnTheSelectedMask() {
        var m = MaskOverlayMachine()
        m.send(.toggle(selected: "m1"))
        XCTAssertEqual(m.visibleID, "m1")
        XCTAssertTrue(m.pinned)
        m.send(.toggle(selected: "m1"))
        XCTAssertNil(m.visibleID)
        XCTAssertFalse(m.pinned)
        m.send(.toggle(selected: nil))
        XCTAssertNil(m.visibleID, "no mask, nothing to show, and no pin on nothing")
        XCTAssertFalse(m.pinned)
    }

    /// The old trap: hiding a pinned overlay left the pin set and every ambient path
    /// dead. Unpinning must return to a state where hover and selection work.
    func testUnpinReturnsToAWorkingAmbientState() {
        var m = MaskOverlayMachine()
        m.send(.pin("m1"))
        m.send(.unpin)
        XCTAssertNil(m.visibleID)
        m.send(.hoverBegan("m2"))
        XCTAssertEqual(m.visibleID, "m2")
        m.send(.hoverEnded)
        m.send(.selected("m3"))
        XCTAssertEqual(m.visibleID, "m3")
    }

    // MARK: - Selection work keeps it up

    func testT10_paintingOrDraggingAGradientKeepsTheOverlay() {
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        // A radial's Feather slider: a gesture, but it moves the SELECTION.
        run(&m, [.gestureBegan, .edited(.selection("m1")), .edited(.selection("m1"))])
        XCTAssertEqual(m.visibleID, "m1")
        m.send(.gestureEnded)
        XCTAssertEqual(m.visibleID, "m1")
        // A brush stroke lands outside any slider gesture.
        run(&m, exposureDrag)
        m.send(.edited(.selection("m1")))
        XCTAssertEqual(m.visibleID, "m1",
                       "painting after an adjustment shows the mask being painted")
    }

    func testT11_edgeRefineDragShowsTheMaskFromThePress() {
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        run(&m, exposureDrag)
        XCTAssertNil(m.visibleID)
        m.send(.gestureBegan)
        m.send(.selectionWork("m1"))
        XCTAssertEqual(m.visibleID, "m1", "the Edge press shows it before any value moves")
        m.send(.edited(.selection("m1")))
        m.send(.gestureEnded)
        XCTAssertEqual(m.visibleID, "m1", "and it stays to be judged after release")
    }

    func testT12_aPinFollowsTheSelectedMask() {
        var m = MaskOverlayMachine()
        m.send(.selected("m1"))
        // O flips what is on screen: the selected mask is showing, so the first press
        // hides it and the second turns Show Overlay on.
        m.send(.toggle(selected: "m1"))
        XCTAssertNil(m.visibleID)
        m.send(.toggle(selected: "m1"))
        XCTAssertTrue(m.pinned)
        m.send(.selected("m2"))
        XCTAssertEqual(m.visibleID, "m2")
        run(&m, exposureDrag)
        XCTAssertEqual(m.visibleID, "m2", "the pin returns on m2, not m1")
    }

    // MARK: - Never stuck

    func testT13_deletingThePinnedMaskClearsThePinAndHoverStillWorks() {
        var m = MaskOverlayMachine()
        m.send(.pin("m1"))
        m.send(.masksPresent(["m2"]))
        XCTAssertNil(m.visibleID)
        XCTAssertFalse(m.pinned)
        m.send(.hoverBegan("m2"))
        XCTAssertEqual(m.visibleID, "m2")
    }

    func testDeletingTheJustMadeOrHoveredMaskForgetsIt() {
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        m.send(.hoverBegan("m2"))
        m.send(.masksPresent([]))
        XCTAssertNil(m.visibleID)
        XCTAssertNil(m.litID)
        XCTAssertNil(m.hoverID)
    }

    func testT14_aPhotoChangeClearsEverything() {
        var m = MaskOverlayMachine()
        m.send(.pin("m1"))
        m.send(.created("m2"))
        m.send(.gestureBegan)
        m.send(.reset)
        XCTAssertEqual(m, MaskOverlayMachine())
        XCTAssertNil(m.visibleID)
    }

    func testT15_hoverDuringAnAdjustmentDragIsIgnored() {
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        m.send(.gestureBegan)
        m.send(.edited(.adjustment))
        m.send(.hoverBegan("m2"))
        XCTAssertNil(m.visibleID, "no red over the pixels being judged")
        m.send(.gestureEnded)
        XCTAssertNil(m.visibleID, "and the ignored hover does not fire on release")
    }

    func testT16_aTypedValueOrResetOutsideAGestureAlsoEndsTheLitPhase() {
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        m.send(.edited(.adjustment))
        XCTAssertNil(m.visibleID)
        XCTAssertFalse(m.suppressed, "no gesture, so nothing to wait for")
        m.send(.hoverBegan("m1"))
        XCTAssertEqual(m.visibleID, "m1")
    }

    func testT17_anyAdjustmentSliderCountsNotOnlyTheMasksOwn() {
        // Classified from real recipes below; here, the global Basic Exposure is the
        // same `.adjustment` event as the mask's own.
        let base = Recipe(masks: [Mask(id: "m1", components: [MaskComponent(op: .add, kind: .radial)])])
        var global = base
        global.develop.tone.exposure = 0.5
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        m.send(.gestureBegan)
        if let kind = MaskOverlayEdit.classify(old: base, new: global) { m.send(.edited(kind)) }
        XCTAssertNil(m.visibleID)
    }

    func testT18_cosmeticEditsLeaveItAlone() {
        let base = Recipe(masks: [Mask(id: "m1", name: "Sky",
                                       components: [MaskComponent(op: .add, kind: .radial)]),
                                  Mask(id: "m2", components: [MaskComponent(op: .add, kind: .linear)])])
        var renamed = base
        renamed.masks[0].name = "Sun"
        var reordered = base
        reordered.masks.swapAt(0, 1)
        var disabled = base
        disabled.masks[0].enabled = false
        for edit in [renamed, reordered, disabled] {
            XCTAssertNil(MaskOverlayEdit.classify(old: base, new: edit))
        }
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        XCTAssertEqual(m.visibleID, "m1")
    }

    /// Verifier round 1: O (or ⌥O / ⇧O, which call it when nothing shows) pressed
    /// mid-drag put the pin up over the pixels being judged.
    func testOPressedDuringAnAdjustmentDragWaitsForRelease() {
        var m = MaskOverlayMachine()
        m.send(.selected("m1"))
        run(&m, [.gestureBegan, .edited(.adjustment), .toggle(selected: "m1")])
        XCTAssertNil(m.visibleID, "the drag rule outranks the key")
        XCTAssertTrue(m.pinned, "but the key was heard")
        m.send(.gestureEnded)
        XCTAssertEqual(m.visibleID, "m1")
    }

    /// Verifier round 1: a selection edit arriving after an adjustment in the same
    /// gesture lifted the suppression.
    func testASelectionEditDoesNotLiftAnAdjustmentsSuppression() {
        var m = MaskOverlayMachine()
        m.send(.pin("m1"))
        run(&m, [.gestureBegan, .edited(.adjustment), .edited(.selection("m2"))])
        XCTAssertNil(m.visibleID)
        m.send(.gestureEnded)
        XCTAssertEqual(m.visibleID, "m2", "the pin follows the mask being worked on")
    }

    /// T18 through the machine, not just the classifier: a cosmetic edit sends no
    /// event, so the lit mask survives.
    func testT18_cosmeticEditsLeaveTheLitMaskUp() {
        let base = Recipe(masks: [Mask(id: "m1", name: "Sky",
                                       components: [MaskComponent(op: .add, kind: .radial)])])
        var renamed = base
        renamed.masks[0].name = "Sun"
        var m = MaskOverlayMachine()
        m.send(.created("m1"))
        if let kind = MaskOverlayEdit.classify(old: base, new: renamed) { m.send(.edited(kind)) }
        XCTAssertEqual(m.visibleID, "m1")
    }

    // MARK: - Precedence, stated once

    func testHoverOutranksThePinAndTheLitMask() {
        var m = MaskOverlayMachine()
        m.send(.pin("m1"))
        m.send(.hoverBegan("m2"))
        XCTAssertEqual(m.visibleID, "m2")
        m.send(.hoverEnded)
        XCTAssertEqual(m.visibleID, "m1")

        var n = MaskOverlayMachine()
        n.send(.created("m1"))
        n.send(.hoverBegan("m2"))
        XCTAssertEqual(n.visibleID, "m2")
        n.send(.hoverEnded)
        XCTAssertEqual(n.visibleID, "m1",
                       "leaving another row falls back to the mask still being made")
    }

    func testTheDefaultShowsNothing() {
        let m = MaskOverlayMachine()
        XCTAssertNil(m.visibleID)
        XCTAssertFalse(m.pinned)
        XCTAssertFalse(m.inGesture)
    }

    /// Every reachable state, by brute force: after any gesture that moved an
    /// adjustment, nothing is visible until release; after release, only the pin can
    /// be visible. This is "never stuck" as an invariant rather than an example.
    func testExhaustiveNoOverlayDuringAnAdjustmentDrag() {
        let ids = ["a", "b"]
        let alphabet: [MaskOverlayMachine.Event] = ids.flatMap { id in
            [.created(id), .selected(id), .hoverBegan(id), .pin(id), .selectionWork(id),
             .edited(.selection(id))]
        } + [.hoverEnded, .unpin, .toggle(selected: "a"), .edited(.adjustment),
             .masksPresent(["a"])]
        var states: [MaskOverlayMachine] = [MaskOverlayMachine()]
        for _ in 0..<3 {
            states = states.flatMap { s in alphabet.map { s.sending($0) } }
        }
        for s in states {
            let mid = s.sending(.gestureBegan, .edited(.adjustment))
            XCTAssertNil(mid.visibleID)
            let hovered = mid.sending(.hoverBegan("b"))
            XCTAssertNil(hovered.visibleID)
            let released = mid.sending(.gestureEnded)
            XCTAssertEqual(released.visibleID, s.pinned ? s.pinnedID : nil)
        }
    }
}

final class MaskOverlayEditTests: XCTestCase {

    private func recipe() -> Recipe {
        Recipe(masks: [Mask(id: "m1", components: [MaskComponent(op: .add, kind: .radial)]),
                       Mask(id: "m2", components: [MaskComponent(op: .add, kind: .brush)])],
               maskGroups: [MaskGroup(id: "g1", name: "Sky")])
    }

    func testMaskAdjustmentIsAnAdjustment() {
        let a = recipe()
        var b = a
        b.masks[0].adjust.exposure = 0.3
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: b), .adjustment)
    }

    func testStrengthAndBlendAreAdjustments() {
        let a = recipe()
        var b = a
        b.masks[1].amount = 150
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: b), .adjustment)
        var c = a
        c.masks[1].blend = .luminosity
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: c), .adjustment)
    }

    func testGlobalDevelopAndLookAreAdjustments() {
        let a = recipe()
        var b = a
        b.develop.tone.exposure = -1
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: b), .adjustment)
        var c = a
        c.look.vignette = -0.5
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: c), .adjustment)
    }

    func testGroupStrengthIsAnAdjustmentButItsNameIsNot() {
        let a = recipe()
        var b = a
        b.maskGroups[0].amount = 50
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: b), .adjustment)
        var c = a
        c.maskGroups[0].name = "Clouds"
        XCTAssertNil(MaskOverlayEdit.classify(old: a, new: c))
        var d = a
        d.maskGroups.append(MaskGroup(id: "g2"))
        XCTAssertNil(MaskOverlayEdit.classify(old: a, new: d),
                     "making a group moves no pixels")
    }

    func testComponentInvertAndEdgeAreSelectionWork() {
        let a = recipe()
        var b = a
        b.masks[0].components[0].feather = 40
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: b), .selection("m1"))
        var c = a
        c.masks[1].invert = true
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: c), .selection("m2"))
        var d = a
        d.masks[0].refine.feather = 20
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: d), .selection("m1"))
        var e = a
        e.masks[1].components[0].strokesRef = "blob"
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: e), .selection("m2"),
                       "a brush stroke landing is selection work")
    }

    func testAdjustmentWinsWhenOneWriteDoesBoth() {
        let a = recipe()
        var b = a
        b.masks[0].refine.feather = 20
        b.masks[0].adjust.exposure = 1
        XCTAssertEqual(MaskOverlayEdit.classify(old: a, new: b), .adjustment)
    }

    func testAddingOrDeletingAMaskIsNeither() {
        let a = recipe()
        var b = a
        b.masks.append(Mask(id: "m3"))
        XCTAssertNil(MaskOverlayEdit.classify(old: a, new: b))
        var c = a
        c.masks.removeFirst()
        XCTAssertNil(MaskOverlayEdit.classify(old: a, new: c))
    }

    func testNoChangeIsNeither() {
        XCTAssertNil(MaskOverlayEdit.classify(old: recipe(), new: recipe()))
    }
}
