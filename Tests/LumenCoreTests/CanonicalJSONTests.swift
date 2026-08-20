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

    // MARK: - The fixture cases

    /// Every case in `canonical.json`, keyed by the name the reference implementation
    /// gave it.
    ///
    /// A table rather than one test per case, because the two shapes fail differently
    /// when the reference adds a case: `first { $0.name == "…" }!` simply never looks at
    /// it. That is not hypothetical — `beyondSixFigures` and `beyondSixFiguresNeighbour`
    /// were generated, committed, and sat in the fixture as inert data while the Swift
    /// tests replayed three cases by name. They are the two cases that exist to catch a
    /// lossy `canonicalNumber`, so the whole `%.6g` truncation was invisible on this
    /// side of the mirror. `testEveryFixtureCaseIsReplayed` now makes that impossible.
    private func fixtureRecipes() -> [String: Recipe] {
        var developEdit = Recipe()
        developEdit.develop.raw.temp = 5200
        developEdit.develop.raw.tint = 8
        developEdit.develop.tone.exposure = 0.35
        developEdit.develop.tone.shadows = 25

        // Numbers no six-significant-digit format can represent. `exposure` and its
        // neighbour differ only in the 14th digit; `vignette` is a value real float
        // arithmetic produces (0.1 + 0.2 - 0.5 lands here).
        var beyond = Recipe()
        beyond.develop.tone.exposure = 1.2345678901234
        beyond.develop.raw.temp = 5123.456789
        beyond.look.vignette = -0.30000000000000004
        var neighbour = beyond
        neighbour.develop.tone.exposure = 1.2345678901235

        return ["default": Recipe(),
                "developEdit": developEdit,
                "maskAndLook": maskAndLookRecipe(),
                "beyondSixFigures": beyond,
                "beyondSixFiguresNeighbour": neighbour]
    }

    func testEveryFixtureCaseIsReplayed() throws {
        let fixture = try Fixtures.load("canonical", as: CanonicalFixture.self)
        let recipes = fixtureRecipes()
        for c in fixture.cases {
            guard let recipe = recipes[c.name] else {
                XCTFail("canonical.json case '\(c.name)' is replayed by no Swift "
                            + "recipe — add it to fixtureRecipes()")
                continue
            }
            XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(recipe), c.canonical,
                           "case \(c.name) serialization drifted")
            XCTAssertEqual(try RecipeFingerprint.fingerprint(recipe), c.fingerprint,
                           "case \(c.name) fingerprint drifted")
        }
        XCTAssertEqual(Set(fixture.cases.map(\.name)), Set(recipes.keys),
                       "the fixture and the replay table describe different case sets")
    }

    /// The property those two cases exist for, asserted directly rather than only
    /// through the fixture: a difference past the sixth significant figure must survive
    /// serialization AND must reach the fingerprint. A lossy `canonicalNumber` aliases
    /// two recipes that render differently onto one cache key, which serves the wrong
    /// picture from cache — the quietest possible failure.
    func testADifferencePastTheSixthFigureIsNotAliasedAway() throws {
        var a = Recipe()
        a.develop.tone.exposure = 1.2345678901234
        var b = a
        b.develop.tone.exposure = 1.2345678901235

        XCTAssertNotEqual(try CanonicalJSON.canonicalRecipeJSON(a),
                          try CanonicalJSON.canonicalRecipeJSON(b),
                          "two recipes differing past the sixth figure serialized "
                              + "identically — the number format is lossy")
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(a),
                          try RecipeFingerprint.fingerprint(b),
                          "two recipes that render differently share a fingerprint")

        // And what was written parses back to what went in, which is the same property
        // stated on the save path instead of the cache path.
        let decoded = try CanonicalJSON.decodeRecipe(
            from: Data(try CanonicalJSON.canonicalRecipeJSON(a).utf8))
        XCTAssertEqual(decoded.develop.tone.exposure, a.develop.tone.exposure,
                       "saving and reloading moved the exposure slider")
    }

    private func maskAndLookRecipe() -> Recipe {
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
        return recipe
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
        // Integers print without a fraction, and −0 normalizes to 0 so two recipes that
        // differ only in a sign bit nobody can see share a fingerprint.
        XCTAssertEqual(CanonicalJSON.canonicalNumber(0), "0")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(-0.0), "0")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(1), "1")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(-100), "-100")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(0.35), "0.35")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(5200), "5200")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(0.0625), "0.0625")

        // Every value above round-trips at six significant digits, so the whole set
        // passed while the format was `%.6g` — the truncation that made saving lossy
        // and let two different edits share a cache key. These do not.
        XCTAssertEqual(CanonicalJSON.canonicalNumber(1.2345678901234), "1.2345678901234")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(-0.30000000000000004),
                       "-0.30000000000000004")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(0.1), "0.1")
        XCTAssertEqual(CanonicalJSON.canonicalNumber(5123.456789), "5123.456789")
    }

    /// The rule the format rests on, as a property rather than a list: whatever
    /// `canonicalNumber` writes must parse back to the identical Double. Anything less
    /// means a saved edit reloads as a different edit.
    func testCanonicalNumberIsLossless() {
        var values: [Double] = [0.1, 1.0 / 3, 1e-7, 2.5e20, 1234567.5, 1e15 - 0.5,
                                -0.30000000000000004, 1.2345678901234, 5123.456789,
                                .leastNormalMagnitude, .greatestFiniteMagnitude]
        // A fixed seed, so a failure is reproducible rather than a story about a run
        // that happened once on someone else's machine.
        var state: UInt64 = 0x9E3779B97F4A7C15
        for _ in 0..<2000 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Double(state >> 11) * (1.0 / 9007199254740992.0)
            values.append((unit - 0.5) * 2000)
        }
        for v in values {
            let text = CanonicalJSON.canonicalNumber(v)
            guard let parsed = Double(text) else {
                XCTFail("canonicalNumber wrote \(text) for \(v), which is not a number")
                continue
            }
            XCTAssertEqual(parsed, v, "canonicalNumber lost \(v) — wrote \(text)")
        }
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
