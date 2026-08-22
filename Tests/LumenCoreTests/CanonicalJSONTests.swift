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

        // The black-and-white mix on, and then switched off with the mix kept. The
        // second case is the one that matters: it must serialize the eight bands so
        // they are still there tomorrow, and it must fingerprint as the default recipe
        // so a mix nothing renders costs no cached render.
        var bwOn = Recipe()
        bwOn.look.bw = BlackAndWhite(bands: [0, 0, 0, 0, -40, -65, 0, 0])
        var bwOff = bwOn
        bwOff.look.bw?.enabled = false

        return ["default": Recipe(),
                "developEdit": developEdit,
                "maskAndLook": maskAndLookRecipe(),
                "beyondSixFigures": beyond,
                "beyondSixFiguresNeighbour": neighbour,
                "blackAndWhiteOn": bwOn,
                "blackAndWhiteKeptButOff": bwOff]
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

    // MARK: - The black-and-white treatment toggle (COLOR-20)

    /// The mix of a whole selection, toggled off and back on in one gesture.
    ///
    /// This is the defect, stated as a test. The rule used to live in `ColorPanel` over
    /// a `@State` stash carrying eight numbers and no photo identity, and
    /// `AppState.updateRecipe` runs its closure once per edit target — so toggling off
    /// on one frame and on again anywhere else wrote the FIRST frame's mix into every
    /// recipe in the selection. Three photos with three different mixes are the
    /// smallest arrangement in which a stash gives back the wrong one.
    func testTogglingTheTreatmentAcrossASelectionKeepsEachPhotosOwnMix() {
        let mixes: [[Double]] = [[0, 0, 0, 0, -40, -65, 0, 0],
                                 [30, 0, 0, 0, 0, 0, 0, 12],
                                 [0, 0, 100, 0, 0, 0, -25, 0]]
        var recipes = mixes.map { mix -> Recipe in
            var r = Recipe()
            r.look.bw = BlackAndWhite(bands: mix)
            return r
        }

        for i in recipes.indices {
            recipes[i].look.bw = BlackAndWhite.toggled(recipes[i].look.bw, on: false)
        }
        for i in recipes.indices {
            XCTAssertFalse(recipes[i].look.blackAndWhiteIsOn,
                           "photo \(i) is still rendering black and white")
        }

        for i in recipes.indices {
            recipes[i].look.bw = BlackAndWhite.toggled(recipes[i].look.bw, on: true)
        }
        for (i, mix) in mixes.enumerated() {
            XCTAssertTrue(recipes[i].look.blackAndWhiteIsOn, "photo \(i) came back off")
            XCTAssertEqual(recipes[i].look.bw?.bands, mix,
                           "photo \(i) came back with somebody else's mix")
        }
    }

    /// The state rule in full: both directions, with and without a stored mix.
    func testTheTreatmentToggleInBothDirections() {
        let mix: [Double] = [0, 0, 0, 0, -40, -65, 0, 0]

        // Nothing stored. On starts flat — NOT from whatever was last seen elsewhere.
        let freshOn = BlackAndWhite.toggled(nil, on: true)
        XCTAssertEqual(freshOn?.bands, Array(repeating: 0, count: 8))
        XCTAssertEqual(freshOn?.enabled, true)

        // Nothing stored, switched off: nothing is created. A photo that has never been
        // near this section must stay byte-identical to a default recipe.
        XCTAssertNil(BlackAndWhite.toggled(nil, on: false))

        // A real mix survives off and comes back unchanged.
        let stored = BlackAndWhite(bands: mix)
        let off = BlackAndWhite.toggled(stored, on: false)
        XCTAssertEqual(off?.bands, mix, "the mix was thrown away on the way off")
        XCTAssertEqual(off?.enabled, false)
        XCTAssertEqual(BlackAndWhite.toggled(off, on: true), stored)

        // A flat mix is not a mix: switching it off leaves the slot empty rather than
        // eight zeroes that would make the photo read as edited forever.
        XCTAssertNil(BlackAndWhite.toggled(BlackAndWhite(), on: false))

        // And the toggle is idempotent in both directions.
        XCTAssertEqual(BlackAndWhite.toggled(stored, on: true), stored)
        XCTAssertEqual(BlackAndWhite.toggled(off, on: false), off)
    }

    /// The other half of the finding: the stash died with the session. A mix switched
    /// off has to be in the file.
    func testASwitchedOffMixSurvivesSavingAndReloading() throws {
        var recipe = Recipe()
        recipe.look.bw = BlackAndWhite(bands: [0, 0, 0, 0, -40, -65, 0, 0],
                                       enabled: false)
        let json = try CanonicalJSON.canonicalRecipeJSON(recipe)
        XCTAssertTrue(json.contains("\"enabled\":false"),
                      "the switched-off treatment did not reach the wire: \(json)")

        let reloaded = try CanonicalJSON.decodeRecipe(from: Data(json.utf8))
        XCTAssertEqual(reloaded, recipe, "the mix did not survive the round trip")
        XCTAssertEqual(BlackAndWhite.toggled(reloaded.look.bw, on: true)?.bands,
                       [0, 0, 0, 0, -40, -65, 0, 0],
                       "the reloaded mix did not come back on")
    }

    /// Decode tolerance for pipeline version 1, where the slot's PRESENCE was the
    /// treatment being on. Reading the absent key as `false` would turn every
    /// black-and-white photo in an existing catalog back to colour on first open.
    func testARecipeWrittenBeforeTheEnabledFlagStillReadsAsBlackAndWhite() throws {
        let v1 = """
        {"pipelineVersion":1,"look":{"bw":{"bands":[0,0,0,0,-40,-65,0,0]}}}
        """
        let decoded = try CanonicalJSON.decodeRecipe(from: Data(v1.utf8))
        XCTAssertTrue(decoded.look.blackAndWhiteIsOn,
                      "a version-1 black-and-white photo reopened in colour")
        XCTAssertEqual(decoded.look.bw?.bands, [0, 0, 0, 0, -40, -65, 0, 0])
        XCTAssertEqual(decoded.pipelineVersion, 1,
                       "the recipe's own version was rewritten behind the user")
    }

    /// A mix nothing renders must cost nothing. `recipe_fp` keys every preview and
    /// artifact in the cache and answers "is this photo edited", so a stash that
    /// reached the fingerprint would re-render an unchanged frame and put an edited
    /// badge on a photo that renders exactly as it was shot.
    func testAStoredButSwitchedOffMixCostsNoRenderAndNoBadge() throws {
        var kept = Recipe()
        kept.look.bw = BlackAndWhite(bands: [0, 0, 0, 0, -40, -65, 0, 0],
                                     enabled: false)
        XCTAssertTrue(kept.rendersSameAs(Recipe()),
                      "a switched-off mix changed what the photo renders as")
        XCTAssertEqual(try RecipeFingerprint.fingerprint(kept),
                       try RecipeFingerprint.fingerprint(Recipe()),
                       "a switched-off mix invalidated the cache")

        // ...and switching it on is a different picture, or the flag reaches nothing.
        var on = kept
        on.look.bw?.enabled = true
        XCTAssertFalse(on.rendersSameAs(Recipe()))
        XCTAssertNotEqual(try RecipeFingerprint.fingerprint(on),
                          try RecipeFingerprint.fingerprint(kept),
                          "turning the treatment on did not change the fingerprint")
    }
}
