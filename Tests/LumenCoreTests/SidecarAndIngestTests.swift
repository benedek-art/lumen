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
