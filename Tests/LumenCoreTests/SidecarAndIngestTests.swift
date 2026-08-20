// SidecarAndIngestTests.swift
// XMP sidecar byte-exact serialization + parse round-trip, and rename-template
// goldens. The XMP fixture strings were validated with a real XML parser at
// generation time; here we prove the Swift writer produces the identical bytes
// and the Swift reader recovers the identical fields.

import XCTest
@testable import LumenCore

private struct XMPFixture: Decodable {
    struct Content: Decodable {
        let rating: Int
        /// Absent in the fixture for the cases that carry no flag, so it decodes as
        /// nil rather than requiring `"flag": "none"` in every case.
        let flag: String?
        let label: String?
        let pipelineVersion: Int
        let recipeFingerprint: String?
        let recipeJSON: String?
        let catalogUUID: String?
        let writeStamp: String?
    }
    struct Case: Decodable {
        let name: String
        let content: Content
        let xmp: String
    }
    let cases: [Case]
}

private struct RenameFixture: Decodable {
    struct Context: Decodable {
        let originalBasename: String
        let captureDate: [String: Int]
        let camera: String?
        let cameraSerial: String?
        let iso: Int?
        let job: String?
    }
    struct Case: Decodable {
        let template: String
        let seq: Int
        let context: Context
        let expected: String
    }
    let cases: [Case]
}

final class SidecarAndIngestTests: XCTestCase {

    private func expectedFlag(_ c: XMPFixture.Content) -> SidecarFlag {
        guard let raw = c.flag else { return .none }
        // Not `?? .none`: an unrecognized string in the fixture is a fixture bug, and
        // silently reading it as "no flag" would make the flag cases pass while
        // testing nothing — which is exactly how the missing field went unnoticed.
        guard let flag = SidecarFlag(rawValue: raw) else {
            XCTFail("xmp fixture carries an unknown flag: \(raw)")
            return .none
        }
        return flag
    }

    private func sidecarContent(_ c: XMPFixture.Content) -> SidecarContent {
        SidecarContent(rating: c.rating, flag: expectedFlag(c), label: c.label,
                       pipelineVersion: c.pipelineVersion,
                       recipeFingerprint: c.recipeFingerprint,
                       recipeJSON: c.recipeJSON,
                       catalogUUID: c.catalogUUID,
                       writeStamp: c.writeStamp)
    }

    func testXMPSerializationMatchesFixtureBytes() throws {
        let fixture = try Fixtures.load("xmp", as: XMPFixture.self)
        for c in fixture.cases {
            XCTAssertEqual(XMPSidecar.serialize(sidecarContent(c.content)), c.xmp,
                           "xmp case \(c.name) serialization drifted")
        }
    }

    func testXMPParseRecoversFields() throws {
        let fixture = try Fixtures.load("xmp", as: XMPFixture.self)
        for c in fixture.cases {
            guard let parsed = XMPSidecar.parse(c.xmp) else {
                XCTFail("xmp case \(c.name) failed to parse")
                continue
            }
            // The flag is asserted on its own line as well as through Equatable. It was
            // added to the writer, the reference implementation and the fixture without
            // being added to this file's decoder, so both XMP tests failed with
            // "serialization drifted" and a wall of near-identical XML — a message that
            // says nothing about which field went missing.
            XCTAssertEqual(parsed.flag, expectedFlag(c.content),
                           "xmp case \(c.name) lost its flag")
            XCTAssertEqual(parsed, sidecarContent(c.content), "xmp case \(c.name)")
        }
    }

    /// Flag and rating are separate axes, which is the entire reason `lumen:flag`
    /// exists instead of Lightroom's `xmp:Rating = -1` convention: a photo can be four
    /// stars AND rejected, and writing −1 into the rating would destroy one of them.
    func testFlagAndRatingSurviveEachOther() {
        for flag in [SidecarFlag.none, .pick, .reject] {
            for rating in 0...5 {
                let content = SidecarContent(rating: rating, flag: flag)
                guard let parsed = XMPSidecar.parse(XMPSidecar.serialize(content)) else {
                    return XCTFail("\(flag) at \(rating) stars did not parse back")
                }
                XCTAssertEqual(parsed.flag, flag,
                               "\(rating) stars destroyed the \(flag) flag")
                XCTAssertEqual(parsed.rating, rating,
                               "the \(flag) flag destroyed a \(rating)-star rating")
            }
        }
    }

    func testXMPRoundTripWithRealRecipe() throws {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.35
        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        let content = SidecarContent(rating: 4, label: "Green",
                                     recipeFingerprint: try RecipeFingerprint.fingerprint(recipe),
                                     recipeJSON: json)
        let parsed = XMPSidecar.parse(XMPSidecar.serialize(content))
        XCTAssertEqual(parsed, content)
        let decoded = try CanonicalJSON.decodeRecipe(from: Data(parsed!.recipeJSON!.utf8))
        XCTAssertEqual(decoded, recipe)
    }

    // MARK: - Catalog / sidecar reconciliation

    /// "Losing the catalog costs speed, never work."
    ///
    /// That promise had no test. `CatalogTests` proves a `SidecarContent` round-trips
    /// through `XMPSidecar`, and nothing proved that a pick which exists ONLY in the
    /// sidecar comes back into the catalog on rescan — which is the exact scenario the
    /// flag field was added for, and it lived in `LumenApp`, a target with no tests.
    /// The rule now lives in `SidecarMerge`, in LumenCore, and this is it.
    func testTheSidecarFillsInWhatTheCatalogDoesNotKnow() throws {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 0.75
        let sidecar = SidecarContent(rating: 4, flag: .reject, label: "Green",
                                     recipeJSON: try CanonicalJSON
                                        .canonicalRecipeJSON(recipe))

        // A catalog that knows nothing — restored from an older backup, or a photo
        // that just arrived from another machine. Everything comes back.
        let recovered = SidecarMerge.resolve(catalog: SidecarMerge.State(),
                                             sidecar: sidecar)
        XCTAssertEqual(recovered.rating, 4)
        XCTAssertEqual(recovered.flag, .reject)
        XCTAssertEqual(recovered.label, "Green")
        XCTAssertEqual(recovered.recipe, recipe)

        // Flag and rating are separate axes all the way through: four stars AND
        // rejected survives the merge, not just the round trip.
        XCTAssertEqual(recovered.rating, 4)
        XCTAssertEqual(recovered.flag, .reject)
    }

    func testTheCatalogWinsWhereverItHasSomethingToSay() throws {
        var catalogRecipe = Recipe()
        catalogRecipe.develop.tone.exposure = 1.5
        var sidecarRecipe = Recipe()
        sidecarRecipe.develop.tone.exposure = -1.5

        let catalog = SidecarMerge.State(rating: 2, flag: .pick, label: "Blue",
                                         recipe: catalogRecipe)
        let sidecar = SidecarContent(rating: 5, flag: .reject, label: "Red",
                                     recipeJSON: try CanonicalJSON
                                        .canonicalRecipeJSON(sidecarRecipe))
        let merged = SidecarMerge.resolve(catalog: catalog, sidecar: sidecar)

        // The catalog is what the running app just edited; the sidecar may be seconds
        // stale behind its debounce. Letting the sidecar win would undo the last edit.
        XCTAssertEqual(merged.rating, 2, "the sidecar overwrote a rating")
        XCTAssertEqual(merged.flag, .pick, "the sidecar overwrote a flag")
        XCTAssertEqual(merged.label, "Blue", "the sidecar overwrote a label")
        XCTAssertEqual(merged.recipe, catalogRecipe, "the sidecar overwrote an edit")
    }

    func testMergingIsAdditivePerField() throws {
        // Each field fills in independently: a catalog that knows the rating but not
        // the flag keeps its rating and gains the flag.
        let sidecar = SidecarContent(rating: 5, flag: .pick, label: "Red")
        let partial = SidecarMerge.resolve(
            catalog: SidecarMerge.State(rating: 3), sidecar: sidecar)
        XCTAssertEqual(partial.rating, 3)
        XCTAssertEqual(partial.flag, .pick)
        XCTAssertEqual(partial.label, "Red")

        // No sidecar at all is the identity.
        let alone = SidecarMerge.State(rating: 1, flag: .reject, label: "Yellow")
        XCTAssertEqual(SidecarMerge.resolve(catalog: alone, sidecar: nil), alone)

        // A sidecar with nothing in it cannot erase anything.
        XCTAssertEqual(SidecarMerge.resolve(catalog: alone, sidecar: SidecarContent()),
                       alone)

        // An empty label in either place is treated as absent rather than as a value,
        // so an empty string cannot shadow a real label.
        let blank = SidecarMerge.resolve(catalog: SidecarMerge.State(label: ""),
                                         sidecar: SidecarContent(label: "Purple"))
        XCTAssertEqual(blank.label, "Purple")
    }

    /// A sidecar whose recipe will not parse must leave the catalog's nil alone rather
    /// than becoming an empty recipe. "No edit recorded" and "edited back to default"
    /// are different states, and only one of them is a lie about the photographer's
    /// work.
    func testACorruptSidecarRecipeDoesNotBecomeAnEmptyEdit() {
        for json in ["{not json", "", "null", "[]", "{\"pipelineVersion\":"] {
            let merged = SidecarMerge.resolve(
                catalog: SidecarMerge.State(),
                sidecar: SidecarContent(rating: 3, recipeJSON: json))
            XCTAssertNil(merged.recipe,
                         "a recipe parsed out of \(json.debugDescription)")
            // The fields that DID parse still come through — partial salvage, same as
            // the sidecar parser's own policy.
            XCTAssertEqual(merged.rating, 3)
        }
    }

    func testXMPParseRejectsGarbage() {
        XCTAssertNil(XMPSidecar.parse("this is not xml"))
        XCTAssertNil(XMPSidecar.parse("<unrelated><xml/></unrelated>"))
    }

    func testRenameTemplatesMatchReference() throws {
        let fixture = try Fixtures.load("rename", as: RenameFixture.self)
        for c in fixture.cases {
            var date = DateComponents()
            date.year = c.context.captureDate["year"]
            date.month = c.context.captureDate["month"]
            date.day = c.context.captureDate["day"]
            date.hour = c.context.captureDate["hour"]
            date.minute = c.context.captureDate["minute"]
            date.second = c.context.captureDate["second"]
            let ctx = RenameContext(originalBasename: c.context.originalBasename,
                                    captureDate: date,
                                    camera: c.context.camera,
                                    cameraSerial: c.context.cameraSerial,
                                    iso: c.context.iso,
                                    job: c.context.job)
            XCTAssertEqual(RenameTemplate.render(c.template, context: ctx, seq: c.seq),
                           c.expected, "template \(c.template)")
        }
    }

    func testRenameTemplateValidation() {
        XCTAssertEqual(RenameTemplate.unknownTokens(in: "{date}_{seq}_{job}"), [])
        XCTAssertEqual(RenameTemplate.unknownTokens(in: "{seq:4}"), [])
        XCTAssertEqual(RenameTemplate.unknownTokens(in: "{bogus}_{seq:0}"),
                       ["bogus", "seq:0"])
    }

    func testMaskComponentValidation() {
        var brush = MaskComponent(op: .add, kind: .brush)
        XCTAssertNotNil(brush.validationError())
        brush.strokesRef = "blob:xxh64:0011223344556677"
        XCTAssertNil(brush.validationError())

        var luma = MaskComponent(op: .intersect, kind: .lumaRange)
        luma.lo = 0.8
        luma.hi = 0.2
        XCTAssertNotNil(luma.validationError()) // lo > hi

        XCTAssertNil(MaskComponent(op: .add, kind: .aiSubject).validationError())
    }
}
