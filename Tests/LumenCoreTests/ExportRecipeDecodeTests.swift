// ExportRecipeDecodeTests.swift
// A preset written by another build still decodes (K-016).
//
// `ExportRecipe` is Codable with the synthesised decoder, which requires all seventeen
// stored properties; `AppState.loadExportRecipes` reads the list with `try?` and falls
// back to `ExportRecipe.defaults`. So a payload missing one key does not produce an
// error, a warning, or a partial list — it silently replaces every delivery preset the
// photographer built with the stock four.
//
// The missing key arrives by ordinary means: this build adds a field, the stored payload
// predates it, and the presets are gone on first launch. `ExportRecipe`'s own `bitDepth`
// comment is the previous author noticing the trap and routing around it by refusing to
// add a field — the design being dictated by a decoder.

import XCTest
@testable import LumenCore

final class ExportRecipeDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> ExportRecipe {
        try JSONDecoder().decode(ExportRecipe.self, from: Data(json.utf8))
    }

    // MARK: - The defect

    /// The shape of every future field addition: a payload this build has never seen,
    /// missing a key this build has added.
    func testAPresetMissingANewFieldStillDecodes() throws {
        let recipe = try decode("""
        {"id":"web","name":"Web q90","enabled":true,"format":"jpeg","quality":90,
         "colorSpace":"srgb","resizeMode":"longEdge","resizeValue":2048,
         "allowUpscale":false,"resolutionPPI":300,"filenameTemplate":"{name}"}
        """)
        XCTAssertEqual(recipe.name, "Web q90", "the photographer's own preset survived")
        XCTAssertEqual(recipe.quality, 90, "and kept the setting it was built for")
        // The absent fields take the memberwise initializer's defaults.
        XCTAssertEqual(recipe.bitDepth, ExportRecipe(name: "").bitDepth)
        XCTAssertNil(recipe.watermark)
        XCTAssertNil(recipe.hdr)
    }

    /// A LIST of them, which is what is actually stored, and the failure mode that
    /// matters: one bad entry must not take the other three with it.
    func testAListSurvivesEvenWhenOneEntryIsSparse() throws {
        let json = """
        [{"name":"Full"},
         {"id":"a","name":"Print","enabled":false,"format":"tiff","quality":100,
          "bitDepth":16,"colorSpace":"adobeRGB","resizeMode":"none","resizeValue":2048,
          "allowUpscale":false,"resolutionPPI":300,"filenameTemplate":"{name}"}]
        """
        let list = try JSONDecoder().decode([ExportRecipe].self, from: Data(json.utf8))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map(\.name), ["Full", "Print"])
        XCTAssertEqual(list[1].bitDepth, 16)
        XCTAssertFalse(list[1].enabled)
    }

    /// An entry with no id or name is recoverable, not a reason to discard the list:
    /// a blank id collides in `Identifiable` and a blank name renders an empty row, so
    /// both get generated fallbacks.
    func testAnEntryWithNoIdOrNameIsRecoveredRatherThanRefused() throws {
        let a = try decode("{}")
        let b = try decode("{}")
        XCTAssertFalse(a.id.isEmpty)
        XCTAssertNotEqual(a.id, b.id, "two id-less entries must not collide")
        XCTAssertFalse(a.name.isEmpty)
    }

    // MARK: - What must NOT change

    /// A round trip is exact. The tolerant decode must not quietly drop a field the
    /// encoder wrote — that would be the same data loss with a different cause.
    func testEveryFieldSurvivesARoundTrip() throws {
        var recipe = ExportRecipe(name: "Delivery", enabled: false, format: .tiff,
                                  quality: 77, bitDepth: 16, colorSpace: .displayP3,
                                  resizeMode: .longEdge, resizeValue: 3000,
                                  allowUpscale: true, resolutionPPI: 240,
                                  filenameTemplate: "{name}-{date}", subfolder: "out")
        recipe.watermark = Watermark(text: "©", opacity: 40)
        let data = try JSONEncoder().encode(recipe)
        XCTAssertEqual(try JSONDecoder().decode(ExportRecipe.self, from: data), recipe,
                       "a field the encoder wrote came back different or missing")
    }

    /// And the stock presets round-trip, since they are what a fresh install stores.
    ///
    /// Captured once: `ExportRecipe.defaults` mints a fresh `UUID` per entry on every
    /// access, so two evaluations of it are never equal and comparing against a second
    /// one would test the UUID generator.
    func testTheStockPresetsRoundTrip() throws {
        let stock = ExportRecipe.defaults
        let data = try JSONEncoder().encode(stock)
        XCTAssertEqual(try JSONDecoder().decode([ExportRecipe].self, from: data), stock)
    }
}
