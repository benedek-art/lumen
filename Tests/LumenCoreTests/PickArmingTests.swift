import XCTest
@testable import LumenCore

/// An armed pick is bound to the photo and the targets it was armed on
/// (docs/quality/lanes/WS-02/SPEC.md C1, H1, H2).
final class PickArmingTests: XCTestCase {

    private let photoA = URL(fileURLWithPath: "/shoot/A.arw")
    private let photoB = URL(fileURLWithPath: "/shoot/B.arw")

    /// Two swatches, and one mask carrying a Colour Range component with two samples,
    /// a radial, and one mask swatch.
    private func recipe() -> Recipe {
        var recipe = Recipe()
        recipe.develop.pointColors = [PointColor(sample: [0.8, 0.5, 0.4]),
                                      PointColor(sample: [0.3, 0.5, 0.7])]
        var range = MaskComponent(op: .add, kind: .colorRange)
        range.samples = [[0.6, 0.4, 0.3], [0.5, 0.4, 0.3]]
        let radial = MaskComponent(op: .add, kind: .radial)
        var mask = Mask(id: "m1", name: "Sky", components: [range, radial])
        mask.adjust.pointColors = [PointColor(sample: [0.2, 0.3, 0.6])]
        recipe.masks = [mask]
        return recipe
    }

    private var everyTarget: [PickArming.Target] {
        [.neutral, .newPointColor, .mixerBand, .pointColor(index: 1),
         .maskSample(maskID: "m1", component: 0), .maskPointColor(maskID: "m1")]
    }

    private func rejection(_ verdict: PickArming.Verdict) -> String? {
        if case .reject(let message) = verdict { return message }
        return nil
    }

    func testAcceptsOnTheArmedPhotoWithNothingChanged() {
        for target in everyTarget {
            let arming = PickArming(photo: photoA, target: target, recipe: recipe())
            XCTAssertEqual(arming.accepts(photo: photoA, recipe: recipe()), .accept, "\(target)")
        }
    }

    func testRejectsAnotherPhoto() {
        for target in everyTarget {
            let arming = PickArming(photo: photoA, target: target, recipe: recipe())
            XCTAssertEqual(arming.accepts(photo: photoB, recipe: recipe()),
                           .reject(PickArming.Rejection.anotherPhoto.message), "\(target)")
        }
    }

    func testRejectsAResampleAfterASwatchWasRemoved() {
        let arming = PickArming(photo: photoA, target: .pointColor(index: 1), recipe: recipe())
        var removedFirst = recipe()
        removedFirst.develop.pointColors.remove(at: 0)     // swatch 1 slid into slot 0
        XCTAssertEqual(arming.accepts(photo: photoA, recipe: removedFirst),
                       .reject(PickArming.Rejection.swatchesChanged.message))
        var removedBoth = recipe()
        removedBoth.develop.pointColors = []
        XCTAssertEqual(arming.accepts(photo: photoA, recipe: removedBoth),
                       .reject(PickArming.Rejection.swatchesChanged.message))
        // Not over-eager: a re-sample of slot 0 armed on an unchanged one-swatch list
        // stays valid.
        var one = recipe()
        one.develop.pointColors = [PointColor(sample: [0.1, 0.2, 0.3])]
        let slot0 = PickArming(photo: photoA, target: .pointColor(index: 0), recipe: one)
        XCTAssertEqual(slot0.accepts(photo: photoA, recipe: one), .accept)
    }

    func testRejectsAMaskSampleAfterItsComponentWasRemovedOrItsKindChanged() {
        let arming = PickArming(photo: photoA, target: .maskSample(maskID: "m1", component: 0),
                                recipe: recipe())
        // The Colour Range removed: the radial slid into slot 0.
        var removed = recipe()
        removed.masks[0].components.remove(at: 0)
        XCTAssertEqual(arming.accepts(photo: photoA, recipe: removed),
                       .reject(PickArming.Rejection.componentChanged.message))
        // Same count, different kind in the slot.
        var swapped = recipe()
        swapped.masks[0].components.swapAt(0, 1)
        XCTAssertEqual(arming.accepts(photo: photoA, recipe: swapped),
                       .reject(PickArming.Rejection.componentChanged.message))
        // A component appended after arming also moves what the snapshot meant.
        var added = recipe()
        added.masks[0].components.append(MaskComponent(op: .add, kind: .linear))
        XCTAssertEqual(arming.accepts(photo: photoA, recipe: added),
                       .reject(PickArming.Rejection.componentChanged.message))
    }

    func testRejectsAMaskThatNoLongerExists() {
        for target: PickArming.Target in [.maskSample(maskID: "m1", component: 0),
                                          .maskPointColor(maskID: "m1")] {
            let arming = PickArming(photo: photoA, target: target, recipe: recipe())
            var gone = recipe()
            gone.masks = []
            XCTAssertEqual(arming.accepts(photo: photoA, recipe: gone),
                           .reject(PickArming.Rejection.maskGone.message), "\(target)")
        }
        // Armed on a mask id this photo never had (another photo's mask).
        let foreign = PickArming(photo: photoA, target: .maskPointColor(maskID: "elsewhere"),
                                 recipe: recipe())
        XCTAssertEqual(foreign.accepts(photo: photoA, recipe: recipe()),
                       .reject(PickArming.Rejection.maskGone.message))
    }

    /// Audit §1.7: the cap used to be enforced silently inside the write.
    func testRejectsAtTheEightLimitWithAMessageThatSaysSo() {
        var full = recipe()
        full.develop.pointColors = Array(repeating: PointColor(sample: [0.5, 0.4, 0.3]),
                                         count: 8)
        full.masks[0].components[0].samples = Array(repeating: [0.5, 0.4, 0.3], count: 8)
        full.masks[0].adjust.pointColors = Array(repeating: PointColor(sample: [0.5, 0.4, 0.3]),
                                                 count: 8)
        let targets: [PickArming.Target] = [.newPointColor,
                                            .maskSample(maskID: "m1", component: 0),
                                            .maskPointColor(maskID: "m1")]
        var messages: [String] = []
        for target in targets {
            let arming = PickArming(photo: photoA, target: target, recipe: full)
            guard let message = rejection(arming.accepts(photo: photoA, recipe: full)) else {
                XCTFail("\(target) accepted a ninth"); continue
            }
            XCTAssertTrue(message.contains("8"), message)
            XCTAssertTrue(message.contains("limit"), message)
            messages.append(message)
        }
        XCTAssertEqual(Set(messages).count, 3)
        // Re-sampling an existing swatch at the cap writes nothing new: accepted.
        let resample = PickArming(photo: photoA, target: .pointColor(index: 7), recipe: full)
        XCTAssertEqual(resample.accepts(photo: photoA, recipe: full), .accept)
        // A component holding only its placeholder grey is not at any cap.
        var placeholder = recipe()
        placeholder.masks[0].components[0].samples = [PickArming.placeholderSample]
        let first = PickArming(photo: photoA, target: .maskSample(maskID: "m1", component: 0),
                               recipe: placeholder)
        XCTAssertEqual(first.accepts(photo: photoA, recipe: placeholder), .accept)
    }

    func testEveryRejectionHasADistinctNonEmptyMessage() {
        let messages = PickArming.Rejection.allCases.map(\.message)
        XCTAssertTrue(messages.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertEqual(Set(messages).count, messages.count, "\(messages)")
    }

    func testEveryPromptNamesEsc() {
        for target in everyTarget + [.pointColor(index: 0)] {
            XCTAssertTrue(target.prompt.contains("Esc"), target.prompt)
            XCTAssertFalse(target.prompt.isEmpty)
        }
    }

    func testEveryTargetHasASuccessMessage() {
        // The four that write the recipe: read off the recipe after the write.
        var after = recipe()
        after.develop.pointColors.append(PointColor(sample: [0.1, 0.2, 0.3]))
        after.masks[0].components[0].samples?.append([0.2, 0.2, 0.2])
        after.masks[0].adjust.pointColors.append(PointColor(sample: [0.1, 0.1, 0.1]))
        let expected: [(PickArming.Target, String)] = [
            (.newPointColor, "Swatch 3 added."),
            (.pointColor(index: 0), "Swatch 1 re-sampled."),
            (.maskSample(maskID: "m1", component: 0), "Sample 3 of 8 added."),
            (.maskPointColor(maskID: "m1"), "Mask swatch 2 added."),
        ]
        var messages: [String] = []
        for (target, want) in expected {
            let arming = PickArming(photo: photoA, target: target, recipe: recipe())
            XCTAssertEqual(arming.successMessage(after: after), want, "\(target)")
            messages.append(want)
        }
        // The two whose message is about something other than the recipe.
        let neutral = PickArming.neutralMessage(kelvin: 5120, tint: 4)
        XCTAssertEqual(neutral, "Neutral picked — 5120 K, tint 4")
        let band = PickArming.bandMessage(bandName: "Red")
        XCTAssertEqual(band, "Red selected.")
        messages += [neutral, band]
        XCTAssertTrue(messages.allSatisfy { !$0.isEmpty })
        XCTAssertEqual(Set(messages).count, messages.count)
    }
}
