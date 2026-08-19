// CanonicalJSONTests.swift
// The recipe format contract: Swift's Recipe() defaults must match the committed
// default-recipe.json byte-for-meaning; canonical sparse serialization and
// fingerprints must match the Python reference exactly. A failure here means the
// wire format drifted — fix the divergence, never the fixture (unless the format
// change is intentional, in which case regenerate fixtures and say so in the commit).

import XCTest
@testable import LumenCore

private struct CanonicalFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let canonical: String
        let fingerprint: String
    }
    let cases: [Case]
}

final class CanonicalJSONTests: XCTestCase {

    func testDefaultRecipeMatchesCommittedFixture() throws {
        let fixtureTree = try JSONDecoder().decode(
            JSONValue.self, from: Fixtures.data("default-recipe"))
        let swiftTree = try CanonicalJSON.tree(of: Recipe())
        XCTAssertEqual(
            CanonicalJSON.serialize(swiftTree),
            CanonicalJSON.serialize(fixtureTree),
            "Recipe() defaults drifted from default-recipe.json — format change?")
    }

    func testCaseA_defaultRecipe() throws {
        let fixture = try Fixtures.load("canonical", as: CanonicalFixture.self)
        let caseA = fixture.cases.first { $0.name == "default" }!
        let canon = try CanonicalJSON.canonicalRecipeJSON(Recipe())
        XCTAssertEqual(canon, caseA.canonical)
        XCTAssertEqual(try RecipeFingerprint.fingerprint(Recipe()), caseA.fingerprint)
    }

    func testCaseB_developEdit() throws {
        let fixture = try Fixtures.load("canonical", as: CanonicalFixture.self)
        let caseB = fixture.cases.first { $0.name == "developEdit" }!

        var recipe = Recipe()
        recipe.develop.raw.temp = 5200
        recipe.develop.raw.tint = 8
        recipe.develop.tone.exposure = 0.35
        recipe.develop.tone.shadows = 25

        XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(recipe), caseB.canonical)
        XCTAssertEqual(try RecipeFingerprint.fingerprint(recipe), caseB.fingerprint)
    }

    func testCaseC_maskAndLook() throws {
        let fixture = try Fixtures.load("canonical", as: CanonicalFixture.self)
        let caseC = fixture.cases.first { $0.name == "maskAndLook" }!

        var recipe = Recipe()
        recipe.look.wheels.shadows = Wheel(hue: 18, sat: 0.06, lum: -0.04)
        recipe.look.printerLights.master = 3
        recipe.look.printerLights.r = -1
        recipe.look.filmLab = FilmLab(
            stock: "lumen/portra400", amount: 100, pushPull: 0, halation: 35,
            grain: FilmGrain(size: 1, amount: 40))

        var sky = MaskComponent(op: .add, kind: .aiSky)
        sky.model = "skyseg/1.3"
        var brush = MaskComponent(op: .subtract, kind: .brush, amount: 80)
        brush.strokesRef = "blob:xxh64:00c41b0000000000"
        var luma = MaskComponent(op: .intersect, kind: .lumaRange)
        luma.lo = 0.55
        luma.hi = 1
        luma.smooth = 0.5

        var adjust = LocalAdjust()
        adjust.exposure = -0.6
        adjust.temp = -300

        recipe.masks = [Mask(
            id: "6f000000-0000-0000-0000-00000000la01",
            name: "Sky", enabled: true, amount: 100,
            components: [sky, brush, luma],
            refine: MaskRefine(feather: 12, edge: -5, blur: 0),
            adjust: adjust)]

        XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(recipe), caseC.canonical)
        XCTAssertEqual(try RecipeFingerprint.fingerprint(recipe), caseC.fingerprint)
    }

    func testSparseDecodeRoundTrip() throws {
        // A sparse document (only edited keys) must decode into the full recipe.
        var expected = Recipe()
        expected.develop.raw.temp = 5200
        expected.develop.raw.tint = 8
        expected.develop.tone.exposure = 0.35
        expected.develop.tone.shadows = 25

        let sparse = try CanonicalJSON.canonicalRecipeJSON(expected)
        let decoded = try CanonicalJSON.decodeRecipe(from: Data(sparse.utf8))
        XCTAssertEqual(decoded, expected)
    }

    func testUnknownKeysAreForwardCompatible() throws {
        let futureDoc = """
        {"pipelineVersion":1,"develop":{"tone":{"exposure":1.5}},"someFutureFeature":{"x":1}}
        """
        let decoded = try CanonicalJSON.decodeRecipe(from: Data(futureDoc.utf8))
        XCTAssertEqual(decoded.develop.tone.exposure, 1.5)
    }

    func testCanonicalNumberRule() {
        XCTAssertEqual(CanonicalJSON.canonicalNumber(0), "0")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(-0.0), "0")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(1), "1")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(-100), "-100")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(0.35), "0.35")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(5200), "5200")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(0.0625), "0.0625")
    }

    func testDenoiseFingerprintIgnoresLook() throws {
        var a = Recipe()
        a.develop.raw.temp = 5600
        var b = a
        b.look.wheels.shadows.hue = 200  // look edits must NOT invalidate denoise cache
        XCTAssertEqual(
            RecipeFingerprint.denoiseInputFingerprint(a),
            RecipeFingerprint.denoiseInputFingerprint(b))
        var c = a
        c.develop.raw.temp = 3200        // WB changes MUST invalidate it (docs/07)
        XCTAssertNotEqual(
            RecipeFingerprint.denoiseInputFingerprint(a),
            RecipeFingerprint.denoiseInputFingerprint(c))
    }
}
