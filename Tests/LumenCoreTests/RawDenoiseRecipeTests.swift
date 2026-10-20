// RawDenoiseRecipeTests.swift
// `Denoise.raw` — the per-photo toggle and strength for the raw-domain AI denoiser —
// is a new recipe field on a format with years of sidecars behind it. These tests pin
// both halves of adding it safely: what did NOT change (every recipe written before
// the field, the default tree, every existing fingerprint, byte for byte) and what
// did (a recipe that turns it on is a different picture; one that only moves strength
// is the same cached pre-pass).

import XCTest
@testable import LumenCore

final class RawDenoiseRecipeTests: XCTestCase {

    // Captured from this branch BEFORE `Denoise.raw` existed. Literals rather than a
    // recomputation, because a recomputation would move with the change it polices.
    private static let defaultCanonical = #"{"pipelineVersion":2}"#
    private static let defaultFingerprint = "xxh64:fd50cceee634dfb4"
    private static let defaultDenoiseInput = "xxh64:d730b5c38ab52508"
    private static let defaultFullTreeDigest = "68b478a3b73cfdea"
    private static let editedCanonical =
        #"{"develop":{"denoise":{"amount":65,"mode":"ai","model":"nafnet/2.1"},"#
        + #""raw":{"temp":5600}},"pipelineVersion":2}"#
    private static let editedFingerprint = "xxh64:73a427829dcf55c1"
    private static let editedDenoiseInput = "xxh64:5cd1fb0a682472ef"

    private static func edited() -> Recipe {
        var r = Recipe()
        r.develop.denoise = Denoise(mode: .ai, amount: 65, model: "nafnet/2.1")
        r.develop.raw.temp = 5600
        return r
    }

    private static func withRaw(_ settings: RawDenoiseSettings?,
                                base: Recipe = Recipe()) -> Recipe {
        var r = base
        r.develop.denoise.raw = settings
        return r
    }

    // MARK: - Nothing written before the field changes

    func testFullDefaultTreeFixtureDecodesWithRawNil() throws {
        let recipe = try CanonicalJSON.decodeRecipe(from: Fixtures.data("default-recipe"))
        XCTAssertNil(recipe.develop.denoise.raw)
        XCTAssertEqual(recipe, Recipe())
    }

    func testEveryCanonicalFixtureCaseDecodesWithRawNilAndKeepsItsFingerprint() throws {
        let cases = try JSONDecoder().decode(CanonicalFixtureFile.self,
                                             from: Fixtures.data("canonical"))
        XCTAssertFalse(cases.cases.isEmpty)
        for c in cases.cases {
            let recipe = try CanonicalJSON.decodeRecipe(from: Data(c.canonical.utf8))
            XCTAssertNil(recipe.develop.denoise.raw, c.name)
            XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(recipe), c.canonical, c.name)
        }
    }

    func testDefaultRecipeCanonicalJSONAndFingerprintAreByteIdentical() throws {
        let r = Recipe()
        XCTAssertNil(r.develop.denoise.raw)
        XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(r), Self.defaultCanonical)
        XCTAssertEqual(try RecipeFingerprint.fingerprint(r), Self.defaultFingerprint)
        XCTAssertEqual(RecipeFingerprint.denoiseInputFingerprint(r), Self.defaultDenoiseInput)
        // The FULL tree, not just the sparse form: a defaulted non-optional would be
        // pruned from the canonical string yet still change `default-recipe.json`.
        let full = CanonicalJSON.serialize(try CanonicalJSON.tree(of: r))
        XCTAssertEqual(XXH64.hexDigest(full), Self.defaultFullTreeDigest)
        XCTAssertFalse(full.contains("\"raw\":{\"enabled\""))
    }

    func testAnEditedRecipeWithoutTheFieldKeepsItsFingerprints() throws {
        let r = Self.edited()
        XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(r), Self.editedCanonical)
        XCTAssertEqual(try RecipeFingerprint.fingerprint(r), Self.editedFingerprint)
        XCTAssertEqual(RecipeFingerprint.denoiseInputFingerprint(r), Self.editedDenoiseInput)
    }

    // MARK: - Round trip and tolerant decoding

    func testRoundTripWithRawSet() throws {
        let settings = RawDenoiseSettings(enabled: true, strength: 40,
                                          model: "lumen-denoise/b64")
        let r = Self.withRaw(settings, base: Self.edited())
        let json = try CanonicalJSON.canonicalRecipeJSON(r)
        XCTAssertTrue(json.contains(
            #""raw":{"enabled":true,"model":"lumen-denoise/b64","strength":40}"#), json)
        let back = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertEqual(back, r)
        XCTAssertEqual(back.develop.denoise.raw, settings)
        XCTAssertEqual(try CanonicalJSON.canonicalRecipeJSON(back), json)
    }

    func testAnOutOfRangeStrengthRoundTripsAsWritten() throws {
        // The clamp is in the accessor, not the decoder: a sidecar must round-trip.
        let r = Self.withRaw(RawDenoiseSettings(enabled: true, strength: 250))
        let back = try CanonicalJSON.decodeRecipe(
            from: Data(try CanonicalJSON.canonicalRecipeJSON(r).utf8))
        XCTAssertEqual(back.develop.denoise.raw?.strength, 250)
    }

    func testPartialRawObjectDecodesWithFullStrength() throws {
        let json = #"{"develop":{"denoise":{"raw":{"enabled":true}}},"pipelineVersion":2}"#
        let r = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertEqual(r.develop.denoise.raw,
                       RawDenoiseSettings(enabled: true, strength: 100, model: nil))
        // The neighbours are untouched by the new key's presence.
        XCTAssertEqual(r.develop.denoise.mode, .classic)
        XCTAssertEqual(r.develop.denoise.amount, 50)
    }

    func testEmptyRawObjectDecodesToTheOffDefault() throws {
        let s = try JSONDecoder().decode(RawDenoiseSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(s, RawDenoiseSettings())
        XCTAssertFalse(s.enabled)
        XCTAssertEqual(s.strength, 100)
        XCTAssertNil(s.model)
    }

    /// The same contract `RecipeCodecToleranceTests` enforces for every type it can
    /// reach, stated here directly so it holds even while that walk's sample leaves
    /// `raw` nil: drop any one key and only that field falls back.
    func testRawSettingsSurviveTheLossOfAnyOneKey() throws {
        let full = RawDenoiseSettings(enabled: true, strength: 30, model: "m/1")
        let tree = try CanonicalJSON.tree(of: full)
        guard case .object(let obj) = tree else { return XCTFail("not an object") }
        XCTAssertEqual(Set(obj.keys), ["enabled", "strength", "model"])
        for key in obj.keys {
            var reduced = obj
            reduced[key] = nil
            let data = Data(CanonicalJSON.serialize(.object(reduced)).utf8)
            let s = try JSONDecoder().decode(RawDenoiseSettings.self, from: data)
            XCTAssertEqual(s.enabled, key == "enabled" ? false : true, key)
            XCTAssertEqual(s.strength, key == "strength" ? 100 : 30, key)
            XCTAssertEqual(s.model, key == "model" ? nil : "m/1", key)
        }
    }

    // MARK: - Strength accessor

    func testStrengthFractionClampsAndRefusesNonFinite() {
        func f(_ v: Double) -> Double { RawDenoiseSettings(enabled: true, strength: v)
            .strengthFraction }
        XCTAssertEqual(f(100), 1)
        XCTAssertEqual(f(40), 0.4, accuracy: 1e-12)
        XCTAssertEqual(f(0), 0)
        XCTAssertEqual(f(250), 1)
        XCTAssertEqual(f(-20), 0)
        XCTAssertEqual(f(.nan), 1)
        XCTAssertEqual(f(.infinity), 1)
        XCTAssertEqual(f(-.infinity), 1)
    }

    func testIsActiveNeedsEnabledAndNonZeroStrength() {
        XCTAssertTrue(RawDenoiseSettings(enabled: true).isActive)
        XCTAssertFalse(RawDenoiseSettings(enabled: false).isActive)
        XCTAssertFalse(RawDenoiseSettings(enabled: true, strength: 0).isActive)
        XCTAssertFalse(RawDenoiseSettings(enabled: true, strength: -5).isActive)
    }

    // MARK: - Fingerprints

    func testTurningRawOnChangesBothFingerprints() throws {
        let off = Recipe()
        let on = Self.withRaw(RawDenoiseSettings(enabled: true))
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(on),
                          try RecipeFingerprint.fingerprint(off))
        XCTAssertNotEqual(RecipeFingerprint.denoiseInputFingerprint(on),
                          RecipeFingerprint.denoiseInputFingerprint(off))
    }

    func testChangingTheRawModelChangesTheDenoiseInput() {
        let a = Self.withRaw(RawDenoiseSettings(enabled: true, model: "a/1"))
        let b = Self.withRaw(RawDenoiseSettings(enabled: true, model: "b/1"))
        XCTAssertNotEqual(RecipeFingerprint.denoiseInputFingerprint(a),
                          RecipeFingerprint.denoiseInputFingerprint(b))
    }

    /// Strength is a post-blend over a full-strength cached pre-pass: it is a different
    /// picture (`recipe_fp` moves) but the same denoise input (the cache survives).
    func testChangingOnlyStrengthMovesTheRecipeButNotTheDenoiseInput() throws {
        let a = Self.withRaw(RawDenoiseSettings(enabled: true, strength: 100))
        let b = Self.withRaw(RawDenoiseSettings(enabled: true, strength: 35))
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(a),
                          try RecipeFingerprint.fingerprint(b))
        XCTAssertEqual(RecipeFingerprint.denoiseInputFingerprint(a),
                       RecipeFingerprint.denoiseInputFingerprint(b))
    }

    /// A switched-off block does not change what the decoder is fed, so the denoise
    /// input must equal a recipe that never had the field.
    func testADisabledRawBlockLeavesTheDenoiseInputAlone() {
        let off = Self.withRaw(RawDenoiseSettings(enabled: false, strength: 20,
                                                  model: "x/1"),
                               base: Self.edited())
        XCTAssertEqual(RecipeFingerprint.denoiseInputFingerprint(off),
                       Self.editedDenoiseInput)
    }
}

private struct CanonicalFixtureFile: Decodable {
    struct Case: Decodable {
        let name: String
        let canonical: String
    }
    let cases: [Case]
}
