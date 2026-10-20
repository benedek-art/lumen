// ResponsivenessRenderTests.swift
// The render path's pure rules that a drag and its settle depend on.
//
// A settle can land before the brush blobs its recipe names have loaded — they arrive
// asynchronously beside the recipe — and such a frame draws every painted component as
// nothing while carrying the final recipe's fingerprint. It must never be filed as the
// photo's developed preview, the same way a settle without its mattes is not.

#if os(macOS)
import XCTest
import LumenCore
@testable import LumenApp

final class ResponsivenessRenderTests: XCTestCase {

    private func brush(_ ref: String) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .brush)
        c.strokesRef = ref
        return c
    }

    func testARecipeWithNoStrokesIsNeverPending() {
        XCTAssertFalse(RenderCoordinator.strokesPending(recipe: Recipe(), strokeSets: [:]))
    }

    func testABrushBlobNotYetLoadedIsPending() {
        var recipe = Recipe()
        recipe.masks = [Mask(id: "a", name: "Painted", components: [brush("blob:a")])]
        XCTAssertTrue(RenderCoordinator.strokesPending(recipe: recipe, strokeSets: [:]))
        XCTAssertFalse(RenderCoordinator.strokesPending(
            recipe: recipe, strokeSets: ["blob:a": BrushStrokeSet()]))
    }

    func testThePaintedHealBlobCountsToo() {
        var recipe = Recipe()
        recipe.develop.heal.strokesRef = "blob:heal"
        XCTAssertTrue(RenderCoordinator.strokesPending(recipe: recipe, strokeSets: [:]))
        XCTAssertFalse(RenderCoordinator.strokesPending(
            recipe: recipe, strokeSets: ["blob:heal": BrushStrokeSet()]))
    }

    func testASettleMissingItsStrokesIsNotADevelopedPreview() {
        XCTAssertTrue(RenderCoordinator.mayBecomeDevelopedPreview(
            draft: false, region: nil, showingUncropped: false, softProofing: false,
            note: nil, mattesPending: false, strokesPending: false))
        XCTAssertFalse(RenderCoordinator.mayBecomeDevelopedPreview(
            draft: false, region: nil, showingUncropped: false, softProofing: false,
            note: nil, mattesPending: false, strokesPending: true))
    }
}
#endif
