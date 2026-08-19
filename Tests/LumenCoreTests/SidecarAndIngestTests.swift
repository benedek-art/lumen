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

    private func sidecarContent(_ c: XMPFixture.Content) -> SidecarContent {
        SidecarContent(rating: c.rating, label: c.label,
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
            XCTAssertEqual(parsed, sidecarContent(c.content), "xmp case \(c.name)")
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
