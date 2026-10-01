// The default recipe's tree is built once, not once per canonical form.
//
// `canonicalRecipeJSON` and `decodeRecipe` both sparse against `tree(of: Recipe())`, and
// both used to build it on every call — a full encoder round trip of a constant, 38% of
// a canonical form measured in a release build, paid by every recipe save, every
// `RecipeFingerprint.fingerprint` (the settle frame's developed-preview identity) and
// every sidecar merge. Counted with `CanonicalJSON.treeBuilds`, so the property is an
// integer and the shared runner's timing noise cannot reach it.
import XCTest
@testable import LumenCore

final class CanonicalDefaultsBaselineTests: XCTestCase {

    private func edited() -> Recipe {
        var r = Recipe()
        r.develop.tone.exposure = 0.7
        r.develop.color.vibrance = -15
        r.look.vignette = -0.4
        return r
    }

    private func encodes(_ body: () throws -> Void) rethrows -> Int {
        let before = CanonicalJSON.treeBuilds.value
        try body()
        return CanonicalJSON.treeBuilds.value - before
    }

    func testACanonicalFormEncodesOnlyTheRecipeItWasHanded() throws {
        let recipe = edited()
        _ = try CanonicalJSON.canonicalRecipeJSON(recipe)   // the baseline, once
        let calls = 5
        let count = try encodes {
            for _ in 0..<calls { _ = try CanonicalJSON.canonicalRecipeJSON(recipe) }
        }
        XCTAssertEqual(count, calls,
                       "one round trip per call — the recipe's own — and none for the "
                           + "constant default it is sparsed against")
        let fingerprints = try encodes { _ = try RecipeFingerprint.fingerprint(recipe) }
        XCTAssertEqual(fingerprints, 1)
    }

    /// The memo is invisible: the canonical text, the fingerprint and a decode are what
    /// a freshly built baseline gives.
    func testTheRememberedBaselineIsTheDefaultRecipesTree() throws {
        XCTAssertEqual(try CanonicalJSON.recipeDefaults(), try CanonicalJSON.tree(of: Recipe()))
        XCTAssertEqual(try CanonicalJSON.lookDefaults(),
                       try CanonicalJSON.tree(of: LookSubset()))
        let recipe = edited()
        var expected = CanonicalJSON.sparse(try CanonicalJSON.tree(of: recipe),
                                            defaults: try CanonicalJSON.tree(of: Recipe()))
        if case .object(var obj) = expected {
            obj["pipelineVersion"] = .number(Double(recipe.pipelineVersion))
            expected = .object(obj)
        }
        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        XCTAssertEqual(json, CanonicalJSON.serialize(expected))
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(json.utf8)), recipe)
        XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(Recipe()),
                       "{\"pipelineVersion\":\(currentPipelineVersion)}")
    }
}
