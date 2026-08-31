// PasteMasksTests.swift
// docs/36 §4 item 27 — putting one photograph's masks on the rest of the shoot.
//
// Three commands where there was one. Paste Settings still means "make this photograph
// like that one"; Paste Settings WITHOUT MASKS is the one that makes it usable across a
// sequence, because masks are geometry in SOURCE coordinates and a radial over a face in
// one frame lands on a shoulder in the next — so pasting a whole recipe across forty
// frames destroys forty sets of local work to deliver one white balance. Lightroom asks
// with a checkbox dialog you answer identically nine times in ten.
//
// PASTE MASKS APPENDS, and that is the algorithm this file is about. The ids are the
// interesting part: a naive append can produce two masks sharing one id, which every
// `firstIndex(where:)` in the application silently resolves to the first — and a
// reference between two pasted masks has to keep pointing at its partner rather than at
// the copy that was already here.

import XCTest
@testable import LumenCore

final class PasteMasksTests: XCTestCase {

    private func mask(_ id: String, group: String? = nil,
                      refTo: String? = nil) -> Mask {
        var m = Mask(id: id, name: id)
        m.group = group
        if let refTo {
            var c = MaskComponent(op: .add, kind: .maskRef)
            c.maskRef = refTo
            m.components = [c]
        } else {
            var c = MaskComponent(op: .add, kind: .radial)
            c.center = [0.5, 0.5]
            c.radii = [0.3, 0.3]
            m.components = [c]
        }
        return m
    }

    // MARK: - It appends

    func testTheTargetsOwnMasksSurvive() {
        // The whole difference between this and Paste Settings. Replacing would delete
        // whatever local work each target already had, with no way back but undo.
        var target = Recipe()
        target.masks = [mask("mine")]
        var source = Recipe()
        source.masks = [mask("theirs")]

        let out = target.appendingMasks(from: source)
        XCTAssertEqual(out.masks.map(\.id), ["mine", "theirs"])
    }

    func testTheDevelopAndLookOfTheTargetAreUntouched() {
        var target = Recipe()
        target.develop.tone.exposure = 1.5
        target.look.vignette = -0.8
        var source = Recipe()
        source.develop.tone.exposure = -2
        source.look.vignette = 0.4
        source.masks = [mask("a")]

        let out = target.appendingMasks(from: source)
        XCTAssertEqual(out.develop.tone.exposure, 1.5, accuracy: 0)
        XCTAssertEqual(out.look.vignette, -0.8, accuracy: 0)
    }

    func testPastingNothingChangesNothing() {
        var target = Recipe()
        target.masks = [mask("mine")]
        XCTAssertEqual(target.appendingMasks(from: Recipe()), target)
    }

    // MARK: - The ids

    func testACollidingIdIsReissuedRatherThanDuplicated() {
        // Pasting the same mask twice. Two masks sharing one id is not a cosmetic
        // problem: every `firstIndex(where:)` in the application resolves it to the
        // first, so the second is unselectable, uneditable and undeletable.
        var target = Recipe()
        target.masks = [mask("sky")]
        var source = Recipe()
        source.masks = [mask("sky")]

        let out = target.appendingMasks(from: source)
        XCTAssertEqual(out.masks.count, 2)
        XCTAssertNotEqual(out.masks[0].id, out.masks[1].id)
        XCTAssertEqual(out.masks[0].id, "sky", "the one that was here keeps its id")
        XCTAssertEqual(Set(out.masks.map(\.id)).count, 2)
    }

    func testAnIdThatDoesNotCollideIsLeftAlone() {
        // Churning ids for no reason would break every reference on the source side
        // that this paste is not carrying.
        var target = Recipe()
        target.masks = [mask("mine")]
        var source = Recipe()
        source.masks = [mask("theirs")]
        XCTAssertEqual(target.appendingMasks(from: source).masks[1].id, "theirs")
    }

    func testAReferenceBetweenTwoPastedMasksFollowsThemBoth() {
        // The property that makes the batch a batch. Both ids collide and are re-issued;
        // the pointer must land on its partner's NEW id, not on the copy that was
        // already here — which would silently repoint a "Sky ∩ Person" at the wrong sky.
        var target = Recipe()
        target.masks = [mask("sky"), mask("both", refTo: "sky")]
        var source = Recipe()
        source.masks = [mask("sky"), mask("both", refTo: "sky")]

        let out = target.appendingMasks(from: source)
        XCTAssertEqual(out.masks.count, 4)
        let pastedSky = out.masks[2]
        let pastedRef = out.masks[3]
        XCTAssertNotEqual(pastedSky.id, "sky")
        XCTAssertEqual(pastedRef.components[0].maskRef, pastedSky.id,
                       "the pasted reference points at the pasted sky")
        XCTAssertEqual(out.masks[1].components[0].maskRef, "sky",
                       "and the one that was already here is untouched")
    }

    func testAReferenceToSomethingOutsideTheBatchIsLeftAlone() {
        // It names a mask on the SOURCE photograph. Inventing a target for it here
        // would be a selection nobody asked for; leaving it dangling is what
        // `testAReferenceToNothingSelectsNothingRatherThanEverything` already covers.
        var target = Recipe()
        target.masks = [mask("mine")]
        var source = Recipe()
        source.masks = [mask("ref", refTo: "somewhere-else")]
        let out = target.appendingMasks(from: source)
        XCTAssertEqual(out.masks[1].components[0].maskRef, "somewhere-else")
    }

    // MARK: - The folders come too

    func testGroupsArrivedWithTheirMasksStillInThem() {
        var source = Recipe()
        source.maskGroups = [MaskGroup(id: "g", name: "retouch", amount: 60)]
        source.masks = [mask("a", group: "g"), mask("b", group: "g")]

        let out = Recipe().appendingMasks(from: source)
        XCTAssertEqual(out.maskGroups.count, 1)
        XCTAssertEqual(out.maskGroups[0].name, "retouch")
        XCTAssertEqual(out.maskGroups[0].amount, 60)
        XCTAssertEqual(out.masks.map(\.group), ["g", "g"])
        XCTAssertEqual(out.effective(out.masks[0]).amount, 60, accuracy: 1e-12,
                       "and the folder still does what it did")
    }

    func testACollidingGroupIsReissuedAndItsMembersFollowIt() {
        // Pasting the same folder twice must not merge the two batches into one folder —
        // turning the second group off would then turn the first one off too.
        var target = Recipe()
        target.maskGroups = [MaskGroup(id: "g", name: "first")]
        target.masks = [mask("a", group: "g")]
        var source = Recipe()
        source.maskGroups = [MaskGroup(id: "g", name: "second")]
        source.masks = [mask("b", group: "g")]

        let out = target.appendingMasks(from: source)
        XCTAssertEqual(out.maskGroups.count, 2)
        XCTAssertNotEqual(out.maskGroups[0].id, out.maskGroups[1].id)
        XCTAssertEqual(out.masks[0].group, "g", "the one already here keeps its folder")
        XCTAssertEqual(out.masks[1].group, out.maskGroups[1].id,
                       "and the pasted mask follows the pasted folder")
    }

    func testAPastedMaskKeepsEverythingElseAboutItself() {
        var source = Recipe()
        var m = mask("a")
        m.amount = 45
        m.invert = true
        m.blend = .luminosity
        m.enabled = false
        m.adjust.exposure = 0.7
        m.adjust.kelvin = 4200
        m.refine.blur = 30
        source.masks = [m]

        let out = Recipe().appendingMasks(from: source).masks[0]
        XCTAssertEqual(out.amount, 45, accuracy: 0)
        XCTAssertTrue(out.invert)
        XCTAssertEqual(out.blend, .luminosity)
        XCTAssertFalse(out.enabled)
        XCTAssertEqual(out.adjust.exposure, 0.7, accuracy: 0)
        XCTAssertEqual(out.adjust.kelvin, 4200)
        XCTAssertEqual(out.refine.blur, 30, accuracy: 0)
    }

    func testPastingTheSameBatchThreeTimesGivesThreeIndependentCopies() {
        var source = Recipe()
        source.maskGroups = [MaskGroup(id: "g", name: "retouch")]
        source.masks = [mask("sky", group: "g"), mask("both", group: "g", refTo: "sky")]

        var out = Recipe()
        for _ in 0..<3 { out = out.appendingMasks(from: source) }

        XCTAssertEqual(out.masks.count, 6)
        XCTAssertEqual(Set(out.masks.map(\.id)).count, 6, "every mask is reachable")
        XCTAssertEqual(Set(out.maskGroups.map(\.id)).count, 3)
        // Each copy's reference points inside its own copy.
        for batch in 0..<3 {
            let sky = out.masks[batch * 2]
            let pointer = out.masks[batch * 2 + 1]
            XCTAssertEqual(pointer.components[0].maskRef, sky.id, "batch \(batch)")
            XCTAssertEqual(sky.group, pointer.group, "batch \(batch) shares a folder")
        }
        XCTAssertEqual(Set(out.masks.map(\.group)).count, 3,
                       "and the three folders are three folders")
    }
}
