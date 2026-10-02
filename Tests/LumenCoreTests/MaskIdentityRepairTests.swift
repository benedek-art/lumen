import XCTest
@testable import LumenCore

/// S-07: two rows carrying one mask id. Repaired on load where the rename changes no
/// picture, left alone and reported where it would.
final class MaskIdentityRepairTests: XCTestCase {

    private func radial(_ cx: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = [cx, 0.5]
        c.radii = [0.3, 0.45]
        c.feather = 0
        return c
    }

    private func reference(_ id: String) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .maskRef)
        c.maskRef = id
        return c
    }

    private func adjusted(_ mask: Mask, exposure: Double) -> Mask {
        var m = mask
        m.adjust.exposure = exposure
        return m
    }

    /// Through the decoder, which is where the repair lives: a sidecar is JSON.
    private func loaded(_ recipe: Recipe) throws -> Recipe {
        try JSONDecoder().decode(Recipe.self, from: JSONEncoder().encode(recipe))
    }

    private var input: ImageBuffer {
        ImageBuffer(width: 24, height: 16) { u, v in RGB(gray: 0.1 + 0.3 * u + 0.1 * v) }
    }

    private func pixels(_ recipe: Recipe) -> [Float] {
        ReferenceRenderer.render(input, plan: RenderPlan(recipe: recipe)).pixels
    }

    func testALaterDuplicateIsRenamedAndRendersExactlyAsBefore() throws {
        var recipe = Recipe()
        recipe.masks = [
            adjusted(Mask(id: "dup", name: "first", components: [radial(0.3)]), exposure: 1),
            adjusted(Mask(id: "dup", name: "second", components: [radial(0.7)]), exposure: -1),
            // A third mask naming the id means the FIRST row, before and after.
            adjusted(Mask(id: "user", components: [reference("dup")]), exposure: 0.5),
            // An id the fresh name must step over.
            adjusted(Mask(id: "dup-2", components: [radial(0.5)]), exposure: 0.25),
        ]
        let repaired = try loaded(recipe)
        XCTAssertEqual(repaired.masks.map(\.id), ["dup", "dup-3", "user", "dup-2"])
        XCTAssertEqual(repaired.masks.map(\.name), recipe.masks.map(\.name), "both rows kept")
        XCTAssertEqual(repaired.masks[2].components[0].maskRef, "dup",
                       "the reference already meant the first row and keeps meaning it")
        XCTAssertEqual(repaired.duplicateMaskIDs, [])
        XCTAssertEqual(try loaded(recipe).masks.map(\.id), repaired.masks.map(\.id),
                       "the fresh id must be deterministic")
        let before = pixels(recipe)
        XCTAssertNotEqual(before, pixels(Recipe()), "the fixture must move the picture")
        XCTAssertTrue(pixels(repaired) == before, "the repair must move no pixel")
        XCTAssertEqual(try RecipeFingerprint.fingerprint(repaired),
                       try RecipeFingerprint.fingerprint(recipe),
                       "a repaired recipe keeps its cache key")
    }

    func testARenameThatWouldChangeTheSelectionIsLeftAndReported() throws {
        // Rasterizing the second "x" puts "x" in the cycle guard, so its chain back to
        // "x" through "y" is refused. Renamed, the same chain would reach the FIRST "x"
        // and select its radial: a different picture. So it is not renamed.
        var recipe = Recipe()
        recipe.masks = [
            adjusted(Mask(id: "x", components: [radial(0.3)]), exposure: 1),
            adjusted(Mask(id: "x", components: [radial(0.8), reference("y")]), exposure: -1),
            adjusted(Mask(id: "y", components: [reference("x")]), exposure: 0.5),
        ]
        let repaired = try loaded(recipe)
        XCTAssertEqual(repaired.masks.map(\.id), ["x", "x", "y"])
        XCTAssertEqual(repaired.duplicateMaskIDs, ["x"], "the panel must be able to say so")
        XCTAssertTrue(pixels(repaired) == pixels(recipe), "declining the rename must move no pixel")

        // And the reason is real: the rename it declined does change the picture.
        var forced = recipe
        forced.masks[1].id = "x-2"
        XCTAssertNotEqual(pixels(forced), pixels(recipe),
                          "the guard must be protecting a picture, or this proves nothing")
    }

    func testAWellFormedRecipeIsUntouched() throws {
        var recipe = Recipe()
        recipe.masks = [Mask(id: "a", components: [radial(0.3)]),
                        Mask(id: "b", components: [reference("a")])]
        XCTAssertEqual(try loaded(recipe), recipe)
        let outcome = MaskIdentityRepair.repair(recipe.masks)
        XCTAssertEqual(outcome.masks, recipe.masks)
        XCTAssertEqual(outcome.renamed, [])
        XCTAssertEqual(outcome.unresolved, [])
    }
}
