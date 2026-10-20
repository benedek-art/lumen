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

    /// The encoded recipe flattened to dotted leaf paths.
    private func leaves(of recipe: ExportRecipe) throws -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        func walk(_ value: JSONValue, _ path: String) {
            if case .object(let o) = value {
                for (k, v) in o { walk(v, path.isEmpty ? k : path + "." + k) }
            } else {
                out[path] = value
            }
        }
        walk(try CanonicalJSON.tree(of: recipe), "")
        return out
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
        recipe.watermark = Watermark(text: "©", position: .topLeft, opacity: 40,
                                     sizePercent: 5, insetPercent: 4)
        recipe.sharpen = OutputSharpen(medium: .matte, amount: .high)
        recipe.metadata = MetadataPolicy(includeEXIF: false, includeCameraSerial: true,
                                         includeGPS: true, includeKeywords: false,
                                         copyright: "© X", contact: "x@y.z")
        recipe.sequenceStart = 250
        recipe.collision = .skip
        recipe.hdr = HDRSettings(headroomEV: 1.5, mapScale: 0.5, deliberateSDRBase: false)

        // Every encoded leaf must differ from the default, or a decoder that ignores the
        // key passes (the decoder falls back to exactly that default). The optionals the
        // reference fills by hand (watermark, subfolder, hdr, metadata's copyright and
        // contact) are compared against their type's default, so a nil left in one of
        // those fails too. A NEW optional left nil is encoded by neither tree, so it is
        // not caught here: add it to the reference. `id` and `name` have generated
        // fallbacks, not defaults.
        let reference = ExportRecipe(name: "", watermark: Watermark(),
                                     subfolder: "", hdr: HDRSettings())
        var referenceTree = try leaves(of: reference)
        referenceTree["metadata.copyright"] = .string("")
        referenceTree["metadata.contact"] = .string("")
        let sampleTree = try leaves(of: recipe)
        XCTAssertEqual(Set(sampleTree.keys), Set(referenceTree.keys).union(["id", "name"]),
                       "the sample leaves a field unset")
        for (path, value) in referenceTree where path != "id" && path != "name" {
            XCTAssertNotEqual(sampleTree[path], value, "\(path) is sampled at its default")
        }

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
