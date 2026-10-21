// VignetteRecipeTests.swift
// WS-41 SPEC lines 5, 27 (state half) and 28: the four new vignette fields on the wire,
// in the plan, in looks, in copy/paste, in the Effects dot and Reset, and in search.

import XCTest
@testable import LumenCore

final class VignetteRecipeTests: XCTestCase {

    private func assertDefaults(_ look: Look, file: StaticString = #filePath,
                                line: UInt = #line) {
        XCTAssertEqual(look.vignetteMidpoint, 50, file: file, line: line)
        XCTAssertEqual(look.vignetteRoundness, 0, file: file, line: line)
        XCTAssertEqual(look.vignetteHighlights, 0, file: file, line: line)
        XCTAssertEqual(look.vignetteStyle, .highlightPriority, file: file, line: line)
    }

    // MARK: - Line 5

    /// (a) Old sidecars decode to the four defaults.
    func testOldSidecarsDecodeToTheDefaults() throws {
        let amountOnly = try CanonicalJSON.decodeRecipe(
            from: Data(#"{"look":{"vignette":-1.3}}"#.utf8))
        assertDefaults(amountOnly.look)
        XCTAssertEqual(amountOnly.look.vignette, -1.3)
        let featherOnly = try CanonicalJSON.decodeRecipe(
            from: Data(#"{"pipelineVersion":2,"look":{"vignette":-1.3,"vignetteFeather":30}}"#.utf8))
        assertDefaults(featherOnly.look)
        XCTAssertEqual(featherOnly.look.vignetteFeather, 30)
        // Through the struct's own decoder too, not only the canonical merge.
        let direct = try JSONDecoder().decode(Look.self, from: Data(#"{"vignette":-2}"#.utf8))
        assertDefaults(direct)
    }

    /// (b) and (c): the defaults are sparse-pruned, so the canonical form of an untouched
    /// recipe and the fingerprint of every existing recipe do not move.
    func testTheDefaultsArePrunedSoNoFingerprintMoves() throws {
        XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(Recipe()),
                       "{\"pipelineVersion\":\(currentPipelineVersion)}")
        var old = Recipe()
        old.look.vignette = -1.3
        old.look.vignetteFeather = 70
        let json = try CanonicalJSON.canonicalRecipeJSON(old)
        for key in ["vignetteMidpoint", "vignetteRoundness", "vignetteHighlights",
                    "vignetteStyle"] {
            XCTAssertFalse(json.contains(key), "\(key) serialized at its default")
        }
        var explicit = old
        explicit.look.vignetteMidpoint = 50
        explicit.look.vignetteRoundness = 0
        explicit.look.vignetteHighlights = 0
        explicit.look.vignetteStyle = .highlightPriority
        XCTAssertEqual(try RecipeFingerprint.fingerprint(explicit),
                       try RecipeFingerprint.fingerprint(old))
    }

    /// (e) An unknown style decodes to Highlight Priority rather than failing the recipe.
    func testAnUnknownStyleDecodesToHighlightPriority() throws {
        let r = try CanonicalJSON.decodeRecipe(
            from: Data(#"{"look":{"vignette":-1,"vignetteStyle":"tritone"}}"#.utf8))
        XCTAssertEqual(r.look.vignetteStyle, .highlightPriority)
        XCTAssertEqual(r.look.vignette, -1)
    }

    /// (f) Every non-default value round-trips, and the style is written as its word.
    func testEveryNonDefaultValueRoundTrips() throws {
        for style in VignetteStyle.allCases {
            var r = Recipe()
            r.look.vignette = -2
            r.look.vignetteMidpoint = 17
            r.look.vignetteRoundness = -63
            r.look.vignetteHighlights = 81
            r.look.vignetteStyle = style
            let json = try CanonicalJSON.canonicalRecipeJSON(r)
            if style != .highlightPriority {
                XCTAssertTrue(json.contains("\"vignetteStyle\":\"\(style.rawValue)\""), json)
            }
            let back = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
            XCTAssertEqual(back.look, r.look)
            XCTAssertNotEqual(try RecipeFingerprint.fingerprint(r),
                              try RecipeFingerprint.fingerprint(Recipe()))
        }
    }

    // MARK: - Line 28: wiring

    func testThePlanCarriesAllSixFields() {
        var r = Recipe()
        r.look.vignette = -1.5
        r.look.vignetteFeather = 20
        r.look.vignetteMidpoint = 30
        r.look.vignetteRoundness = 40
        r.look.vignetteHighlights = 60
        r.look.vignetteStyle = .paintOverlay
        let v = RenderPlan(recipe: r).vignette
        XCTAssertEqual(v, VignetteSettings(amount: -1.5, feather: 20, midpoint: 30,
                                           roundness: 40, highlights: 60,
                                           style: .paintOverlay))
    }

    /// A look blends the three numbers like Feather and lands the style whole at any
    /// Amount above zero, like a stock's name.
    func testALookBlendsTheNumbersAndLandsTheStyleWhole() {
        var carried = Look()
        carried.vignette = -2
        carried.vignetteMidpoint = 90
        carried.vignetteRoundness = -100
        carried.vignetteHighlights = 100
        carried.vignetteStyle = .colorPriority
        let own = Look()
        let half = LookSubset.blended(from: own, toward: carried, amount: 40)
        XCTAssertEqual(half.vignetteMidpoint, 50 + 40 * 0.4, accuracy: 1e-9)
        XCTAssertEqual(half.vignetteRoundness, -40, accuracy: 1e-9)
        XCTAssertEqual(half.vignetteHighlights, 40, accuracy: 1e-9)
        XCTAssertEqual(half.vignetteStyle, .colorPriority)
        XCTAssertEqual(LookSubset.blended(from: own, toward: carried, amount: 0).vignetteStyle,
                       .highlightPriority)
    }

    func testCopySettingsCarriesTheVignetteWhole() {
        var source = Recipe()
        source.look.vignette = -1
        source.look.vignetteMidpoint = 20
        source.look.vignetteRoundness = 70
        source.look.vignetteHighlights = 55
        source.look.vignetteStyle = .paintOverlay
        let got = Recipe().adoptingSettings(from: source, groups: [.effects])
        XCTAssertEqual(got.look.vignetteMidpoint, 20)
        XCTAssertEqual(got.look.vignetteRoundness, 70)
        XCTAssertEqual(got.look.vignetteHighlights, 55)
        XCTAssertEqual(got.look.vignetteStyle, .paintOverlay)
        let untouched = Recipe().adoptingSettings(from: source, groups: [.tone])
        assertDefaults(untouched.look)
    }

    func testSearchFindsTheVignetteByItsNewWords() {
        for word in ["midpoint", "roundness", "highlight priority", "color priority",
                     "paint overlay"] {
            XCTAssertEqual(ControlIndex.search(word).first?.id, "look.vignette",
                           "'\(word)' should find the vignette")
        }
    }

    // MARK: - Line 27: the Effects dot and Reset, one test per field

    private func assertDotAndReset(_ edit: (inout Recipe) -> Void, _ name: String) {
        var recipe = Recipe()
        edit(&recipe)
        XCTAssertEqual(recipe.look.vignette, 0, "the edit must be at Amount 0")
        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe).contains(.effects),
                      "a moved \(name) must light the Effects dot at Amount 0")
        WorkspaceSection.effects.reset(&recipe)
        XCTAssertFalse(WorkspaceSection.nonDefault(in: recipe).contains(.effects),
                       "Reset must clear the \(name)")
        assertDefaults(recipe.look)
        XCTAssertEqual(recipe.look.vignetteFeather, Look.vignetteFeatherDefault)
    }

    func testTheDotAndResetCoverTheAmount() {
        var recipe = Recipe()
        recipe.look.vignette = -1
        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe).contains(.effects))
        WorkspaceSection.effects.reset(&recipe)
        XCTAssertEqual(recipe.look.vignette, 0)
    }

    func testTheDotAndResetCoverTheFeather() {
        assertDotAndReset({ $0.look.vignetteFeather = 10 }, "feather")
    }

    func testTheDotAndResetCoverTheMidpoint() {
        assertDotAndReset({ $0.look.vignetteMidpoint = 80 }, "midpoint")
    }

    func testTheDotAndResetCoverTheRoundness() {
        assertDotAndReset({ $0.look.vignetteRoundness = -30 }, "roundness")
    }

    func testTheDotAndResetCoverTheHighlights() {
        assertDotAndReset({ $0.look.vignetteHighlights = 40 }, "highlights")
    }

    func testTheDotAndResetCoverTheStyle() {
        assertDotAndReset({ $0.look.vignetteStyle = .colorPriority }, "style")
    }
}
