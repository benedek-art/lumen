// MaskGroupTests.swift
// docs/36 §4 item 26 — folders, and the bug that finding a place for them uncovered.
//
// docs/36 §1.5 measured the problem plainly: nothing in the plan survived fifteen masks,
// and a portrait retouched properly has more than that. A flat list of twenty rows named
// "Radial Gradient 14" is not something anyone navigates.
//
// A group does three things and no more — collapse, turn off, scale — and the tests are
// organized that way. What it deliberately has NOT got is a mask or a blend mode of its
// own: both would mean folding the members' alphas into one composite and running the
// whole local stage again on that, which is a nested compositor and a different feature.
//
// The last section is the interesting one, and it is not about groups. Working out where
// a disabled GROUP should sit turned up a place where a disabled MASK was already wrong:
// `enabled` has never meant "stops selecting", and `MaskChannelAndReferenceTests` pins
// that — but it pins it by calling `MaskRaster.combine` directly, and the renderers were
// handing that function an already-filtered list. So the rule held in the unit test and
// in neither renderer.

import XCTest
@testable import LumenCore

final class MaskGroupTests: XCTestCase {

    private let space = RGBColorSpace.rec2020

    private func radial(_ cx: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [cx, 0.5]
        c.radii = [0.3, 0.4]
        c.feather = 0
        return c
    }

    private func lifted(_ id: String, group: String? = nil) -> Mask {
        var m = Mask(id: id, name: id, components: [radial(0.5)])
        m.adjust.exposure = 1
        m.group = group
        return m
    }

    // MARK: - It turns off

    func testADisabledGroupTakesItsMembersAdjustmentsOutOfThePicture() {
        var recipe = Recipe()
        recipe.maskGroups = [MaskGroup(id: "g", name: "retouch", enabled: false)]
        recipe.masks = [lifted("a", group: "g"), lifted("b", group: "g"),
                        lifted("c")]
        let plan = RenderPlan(recipe: recipe)
        XCTAssertEqual(plan.masks.map(\.id), ["c"],
                       "only the ungrouped mask reaches the picture")
    }

    func testAnEnabledGroupChangesNothingAboutItsMembers() {
        var recipe = Recipe()
        recipe.maskGroups = [MaskGroup(id: "g", name: "retouch")]
        recipe.masks = [lifted("a", group: "g")]
        let plan = RenderPlan(recipe: recipe)
        XCTAssertEqual(plan.masks.count, 1)
        XCTAssertEqual(plan.masks[0].amount, 100, accuracy: 0)
    }

    func testAMaskDisabledInsideAnEnabledGroupStaysDisabled() {
        // The two switches are AND, not override: a group cannot switch a mask back on.
        var recipe = Recipe()
        recipe.maskGroups = [MaskGroup(id: "g", name: "retouch")]
        var mask = lifted("a", group: "g")
        mask.enabled = false
        recipe.masks = [mask]
        XCTAssertTrue(RenderPlan(recipe: recipe).masks.isEmpty)
    }

    // MARK: - It scales

    func testAGroupAmountMultipliesItsMembers() {
        var recipe = Recipe()
        recipe.maskGroups = [MaskGroup(id: "g", name: "retouch", amount: 50)]
        var mask = lifted("a", group: "g")
        mask.amount = 200
        recipe.masks = [mask, lifted("b")]
        let plan = RenderPlan(recipe: recipe)
        let a = plan.masks.first { $0.id == "a" }
        let b = plan.masks.first { $0.id == "b" }
        XCTAssertEqual(a?.amount ?? 0, 100, accuracy: 1e-12,
                       "a group at 50 and a mask at 200 compose to 100")
        XCTAssertEqual(b?.amount ?? 0, 100, accuracy: 1e-12,
                       "and an ungrouped mask is untouched")
    }

    func testAGroupAmountReachesPixelsAndNotJustThePlan() {
        // The half a plan-level assertion cannot make: the number has to arrive at the
        // composite. Half the group is half the exposure lift, on the same fixture.
        let image = ImageBuffer(width: 4, height: 4) { _, _ in RGB(0.2, 0.2, 0.2) }
        let alpha = Plane(width: 4, height: 4, fill: 1)

        func rendered(_ groupAmount: Double) -> Double {
            var recipe = Recipe()
            recipe.maskGroups = [MaskGroup(id: "g", name: "g", amount: groupAmount)]
            recipe.masks = [lifted("a", group: "g")]
            let plan = RenderPlan(recipe: recipe)
            let out = ReferenceRenderer.applyMasks(image, plan: plan,
                                                   alphas: [(plan.masks[0], alpha)],
                                                   space: space)
            return Double(out[0, 0].g)
        }
        let full = rendered(100), half = rendered(50), none = rendered(0)
        // `ImageBuffer` stores Float32, so 0.2 does not survive as 0.2.
        XCTAssertEqual(none, 0.2, accuracy: 1e-6, "a group at 0 is a group turned off")
        XCTAssertGreaterThan(full, 0.38, "a full stop on 0.2")
        // Exposure is a gain, so half a stop is √2 rather than half the difference.
        XCTAssertEqual(half, 0.2 * pow(2, 0.5), accuracy: 1e-6)
    }

    func testAGroupAmountIsClampedRatherThanTrusted() {
        var recipe = Recipe()
        recipe.maskGroups = [MaskGroup(id: "g", name: "g", amount: 1e9)]
        recipe.masks = [lifted("a", group: "g")]
        XCTAssertEqual(RenderPlan(recipe: recipe).masks[0].amount, 200, accuracy: 0)
    }

    // MARK: - It collapses, and collapsing is free

    func testCollapsingOrRenamingAGroupDoesNotChangeTheRender() {
        var open = Recipe()
        open.maskGroups = [MaskGroup(id: "g", name: "retouch")]
        open.masks = [lifted("a", group: "g")]
        var shut = open
        shut.maskGroups = [MaskGroup(id: "g", name: "faces", collapsed: true)]
        XCTAssertTrue(open.rendersSameAs(shut),
                      "opening a folder must not re-render 45 megapixels")

        var off = open
        off.maskGroups = [MaskGroup(id: "g", name: "retouch", enabled: false)]
        XCTAssertFalse(open.rendersSameAs(off), "and turning one off must")
    }

    // MARK: - What a missing group means

    func testAMaskNamingAGroupThatIsGoneIsUngroupedRatherThanHidden() {
        // A folder hand-deleted out of a sidecar must not silently take its members'
        // edits with it — that is an hour of someone's work disappearing with no error.
        var recipe = Recipe()
        recipe.masks = [lifted("a", group: "vanished")]
        let plan = RenderPlan(recipe: recipe)
        XCTAssertEqual(plan.masks.count, 1)
        XCTAssertEqual(plan.masks[0].amount, 100, accuracy: 0)
    }

    // MARK: - Wire format

    func testGroupsRoundTripAndAnOldRecipeHasNone() throws {
        var recipe = Recipe()
        recipe.maskGroups = [MaskGroup(id: "g", name: "retouch", enabled: false,
                                       amount: 65, collapsed: true)]
        recipe.masks = [lifted("a", group: "g")]
        let back = try CanonicalJSON.decodeRecipe(
            from: Data(CanonicalJSON.canonicalRecipeJSON(recipe).utf8))
        XCTAssertEqual(back.maskGroups.count, 1)
        XCTAssertEqual(back.maskGroups[0].name, "retouch")
        XCTAssertFalse(back.maskGroups[0].enabled)
        XCTAssertEqual(back.maskGroups[0].amount, 65)
        XCTAssertTrue(back.maskGroups[0].collapsed)
        XCTAssertEqual(back.masks[0].group, "g")

        let old = """
        {"pipelineVersion":1,"masks":[{"id":"m","components":[]}]}
        """
        let decoded = try CanonicalJSON.decodeRecipe(from: Data(old.utf8))
        XCTAssertTrue(decoded.maskGroups.isEmpty)
        XCTAssertNil(decoded.masks[0].group)
    }

    // MARK: - The bug the groups uncovered

    func testTheRendererResolvesAReferenceAgainstEveryMaskAndNotJustTheEnabledOnes() {
        // `enabled` says whether a mask's ADJUSTMENTS reach the picture. It has never
        // meant the mask stops SELECTING, and turning the Sky mask off to look at
        // something must not silently empty every mask built on it.
        //
        // `MaskChannelAndReferenceTests` already asserted that — of `MaskRaster.combine`,
        // called directly with the whole list. The renderers were handing it
        // `plan.masks`, which is filtered to the enabled ones, so the rule held in the
        // unit test and in neither renderer. This asserts it of the PLAN, which is where
        // the two lists now part company.
        var source = Mask(id: "src", name: "sky", components: [radial(0.3)])
        source.enabled = false
        var pointer = Mask(id: "p", name: "follows")
        var ref = MaskComponent(op: .add, kind: .maskRef)
        ref.maskRef = "src"
        pointer.components = [ref]
        pointer.adjust.exposure = 1

        var recipe = Recipe()
        recipe.masks = [source, pointer]
        let plan = RenderPlan(recipe: recipe)

        XCTAssertEqual(plan.masks.map(\.id), ["p"],
                       "the disabled mask's own adjustments stay out")
        XCTAssertEqual(plan.allMasks.map(\.id), ["src", "p"],
                       "and it is still there to be pointed at")

        let alpha = MaskRaster.combine(mask: pointer, size: (width: 32, height: 24),
                                       masks: plan.allMasks)
        XCTAssertGreaterThan(alpha.values.max().map(Double.init) ?? 0, 0.9,
                             "the reference still selects what the disabled mask selects")

        let throughFilteredList = MaskRaster.combine(mask: pointer,
                                                     size: (width: 32, height: 24),
                                                     masks: plan.masks)
        XCTAssertEqual(throughFilteredList.values.max().map(Double.init) ?? 1, 0,
                       accuracy: 0,
                       "and through the filtered list it selects nothing — which is "
                           + "what both renderers were doing")
    }

    func testAMemberOfADisabledGroupStillLendsItsSelection() {
        // The same rule one level up. Hiding a folder to see past it must not empty
        // every mask built on something inside it.
        var recipe = Recipe()
        recipe.maskGroups = [MaskGroup(id: "g", name: "sources", enabled: false)]
        var source = Mask(id: "src", name: "sky", components: [radial(0.3)])
        source.group = "g"
        var ref = MaskComponent(op: .add, kind: .maskRef)
        ref.maskRef = "src"
        let pointer = Mask(id: "p", name: "follows", components: [ref])
        recipe.masks = [source, pointer]

        let plan = RenderPlan(recipe: recipe)
        XCTAssertEqual(plan.masks.map(\.id), ["p"])
        let alpha = MaskRaster.combine(mask: pointer, size: (width: 32, height: 24),
                                       masks: plan.allMasks)
        XCTAssertGreaterThan(alpha.values.max().map(Double.init) ?? 0, 0.9)
    }

    func testTheOverlayCanStillFindAMaskThatIsSwitchedOff() {
        // A mask you have selected in order to edit is one you need to SEE. Both
        // renderers looked the selected mask up in the filtered list, so switching a
        // mask off while editing it made its overlay vanish.
        var recipe = Recipe()
        var mask = lifted("a")
        mask.enabled = false
        recipe.masks = [mask]
        let plan = RenderPlan(recipe: recipe)
        XCTAssertNil(plan.masks.first { $0.id == "a" })
        XCTAssertNotNil(plan.allMasks.first { $0.id == "a" })
    }
}
