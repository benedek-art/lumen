// SavedLookTests.swift
// The three things a saved look has to get right, all of them pure or SQLite-backed
// and all of them therefore assertable here:
//
//   1. WHAT TRAVELS. A look carries the Look layer and refuses everything else. The
//      failure this pins is not a crash — it is a look that quietly brings one
//      photograph's crop, exposure or white balance to another, which is worse than
//      having no looks at all because it is only discovered frames later.
//   2. THE ROUND TRIP. Save, quit, relaunch, apply — against a real SQLite file, the
//      way CatalogTests tests the photo and album paths. docs/19's whole point is
//      "stored in the catalog, applied to any photo in any folder", and the in-memory
//      Copy Look that existed before this died at quit.
//   3. APPLY TO MANY. One look across a selection leaves every frame its own
//      normalization. That is the gesture the Develop/Look split exists for.

import XCTest
@testable import LumenCore

final class SavedLookTests: XCTestCase {

    // MARK: - Fixtures

    /// A Look with every one of its fields moved off its default.
    ///
    /// "Every field" is not a claim in a comment here — `testTheLookFixtureMovesEvery
    /// FieldOfTheLookLayer` asserts it against the encoder, so a field added to `Look`
    /// makes this fixture insufficient and says so, instead of leaving a new control
    /// silently untested by every assertion below that depends on the fixture being
    /// total.
    static func loadedLook() -> Look {
        Look(
            wheels: GradingWheels(
                global: Wheel(hue: 210, sat: 0.12, lum: 0.03),
                shadows: Wheel(hue: 18, sat: 0.06, lum: -0.04),
                mid: Wheel(hue: 90, sat: 0.02, lum: 0.01),
                high: Wheel(hue: 45, sat: 0.09, lum: -0.02),
                blending: 62, balance: -14, pivots: [0.29, 0.71],
                colorBalance: ColorBalanceParams(
                    hueShift: -8, vibrance: 22,
                    chroma: ColorBalanceAxis(global: 5, shadows: -3, mid: 2, high: 7),
                    saturation: ColorBalanceAxis(global: -6, shadows: 1, mid: 4, high: -2),
                    brilliance: ColorBalanceAxis(global: 3, shadows: 8, mid: -5, high: 6))),
            printerLights: PrinterLights(master: 3, r: -1, g: 2, b: 4),
            filmLab: FilmLab(stock: "lumen/portra400", amount: 84, exposure: 0.4,
                             pushPull: 1, halation: 35,
                             grain: FilmGrain(size: 1.3, amount: 41),
                             printSize: "8x10"),
            primaries: Primaries(rHue: 4, rPurity: -6, gHue: -3, gPurity: 8,
                                 bHue: 7, bPurity: -2, tintHue: 120, tintPurity: 5),
            bw: BlackAndWhite(bands: [10, -20, 30, -40, 5, 15, -25, 35], enabled: false),
            vignette: -0.8,
            vignetteFeather: 72,
            // The creative grain, set to something no default could be mistaken for.
            // It travels for the same reason the vignette does: it is an expression of
            // intent about a set of frames, and a saved look that dropped it would apply
            // a different picture than it saved.
            grain: CreativeGrain(amount: 38, size: 64, roughness: 22),
            render: RenderParams(preset: "Punchy", contrast: 1.4, skew: -0.2,
                                 huePreservation: 65, blackTarget: 2.5, whiteTarget: 90),
            lut: LUTReference(ref: "blob:xxh64:9f2adc41", name: "Kodachrome 64",
                              tap: .log, amount: 72))
    }

    /// A Develop layer with every one of its eleven top-level slots moved — the whole
    /// per-image half of the recipe, so "the look left develop alone" is asserted over
    /// all of it rather than over the two fields somebody happened to think of.
    static func loadedDevelop() -> Develop {
        Develop(
            raw: RawParams(decoder: "lumen", decoderVersion: 8, temp: 5600, tint: -12),
            tone: Tone(exposure: 1.25, contrast: 22, contrastPivot: 0.2,
                       highlights: -60, shadows: 35, whites: 12, blacks: -18),
            zones: Zones(pivots: [0.1, 0.3, 0.55, 0.8, 0.95],
                         dark: ZoneAdjust(ev: -0.3, wheel: [0.01, -0.02],
                                          sat: 8, falloff: 0.4)),
            curve: CurveSet(parametric: ParametricCurve(highlights: -15, lights: 8,
                                                        darks: -6, shadows: 20),
                            point: [[0, 0], [0.5, 0.56], [1, 1]],
                            preserveLuminance: false),
            color: ColorAdjust(vibrance: 24, saturation: 18, density: 62, protectSkin: 40),
            mixer: Mixer(bands: Array(repeating: MixerBand(hue: 5, sat: -8, lum: 3),
                                      count: 8),
                         uniformity: 30),
            pointColors: [PointColor(sample: [0.42, 0.31, 0.27], range: 62,
                                     variance: -10)],
            detail: Detail(texture: 28, clarity: 14, dehaze: 9),
            denoise: Denoise(mode: .ai, amount: 70, model: "nafnet/2.1"),
            geometry: Geometry(crop: Crop(x: 0.1, y: 0.05, w: 0.8, h: 0.75),
                               angle: -1.4, flipH: true),
            heal: Heal(strokesRef: "blob:xxh3:c41b0092", count: 14))
    }

    /// A mask that is unmistakably about ONE photograph: a brush blob recorded over it
    /// and a radial centred in its frame.
    static func perFrameMask() -> Mask {
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:xxh3:9f2ade01"
        var radial = MaskComponent(op: .intersect, kind: .radial)
        radial.center = [0.31, 0.62]
        radial.radii = [0.2, 0.15]
        return Mask(id: "mask-of-one-frame", name: "Sky", components: [brush, radial])
    }

    private static func objectKeys<T: Encodable>(of value: T) throws -> Set<String> {
        guard case .object(let obj) = try CanonicalJSON.tree(of: value) else {
            throw XCTSkip("expected an object at the top level")
        }
        return Set(obj.keys)
    }

    // MARK: - 1. What travels

    /// The partition is total: every top-level recipe key is on one side of it or the
    /// other. A key added to `Recipe` fails here until somebody decides whether a look
    /// carries it — which is the decision this whole feature turns on and the one most
    /// likely to be made by accident.
    func testTheLookPartitionNamesEveryTopLevelRecipeKey() throws {
        let keys = try SavedLookTests.objectKeys(of: Recipe())
        let named = LookSubset.carriedRecipeKeys.union(LookSubset.uncarriedRecipeKeys)
        XCTAssertEqual(keys, named,
                       "a top-level recipe key is on neither side of the look "
                       + "partition: decide whether a saved look carries it, then say "
                       + "so in LookSubset.carriedRecipeKeys / uncarriedRecipeKeys")
        XCTAssertTrue(LookSubset.carriedRecipeKeys
                        .isDisjoint(with: LookSubset.uncarriedRecipeKeys),
                      "a key cannot both travel and stay")
    }

    /// The fixture above really does move every field of the Look layer, so every
    /// assertion resting on it is resting on the whole layer.
    func testTheLookFixtureMovesEveryFieldOfTheLookLayer() throws {
        let loaded = SavedLookTests.loadedLook()
        let full = try CanonicalJSON.tree(of: loaded)
        let sparse = CanonicalJSON.sparse(full, defaults: try CanonicalJSON.tree(of: Look()))
        guard case .object(let fullObj) = full, case .object(let sparseObj) = sparse else {
            return XCTFail("Look does not encode as an object")
        }
        XCTAssertEqual(Set(sparseObj.keys), Set(fullObj.keys),
                       "these Look fields are still at their defaults in the fixture, "
                       + "so nothing below actually tests them: "
                       + Set(fullObj.keys).subtracting(sparseObj.keys).sorted()
                        .joined(separator: ", "))
    }

    func testTheDevelopFixtureMovesEverySlotOfTheDevelopLayer() throws {
        let loaded = SavedLookTests.loadedDevelop()
        let full = try CanonicalJSON.tree(of: loaded)
        let sparse = CanonicalJSON.sparse(full,
                                          defaults: try CanonicalJSON.tree(of: Develop()))
        guard case .object(let fullObj) = full, case .object(let sparseObj) = sparse else {
            return XCTFail("Develop does not encode as an object")
        }
        XCTAssertEqual(Set(sparseObj.keys), Set(fullObj.keys),
                       "these Develop slots are still at their defaults in the fixture: "
                       + Set(fullObj.keys).subtracting(sparseObj.keys).sorted()
                        .joined(separator: ", "))
    }

    /// The central claim, over the whole recipe at once: the target ends up wearing the
    /// source's Look and keeping every last field of its own Develop and its own masks.
    func testALookCarriesTheLookLayerWholeAndCarriesNothingElse() {
        let source = Recipe(develop: SavedLookTests.loadedDevelop(),
                            look: SavedLookTests.loadedLook(),
                            masks: [SavedLookTests.perFrameMask()])
        var target = Recipe()
        target.develop.tone.exposure = -0.75
        target.develop.raw.temp = 3200
        target.develop.geometry.crop = Crop(x: 0, y: 0.2, w: 1, h: 0.6)
        let targetDevelop = target.develop
        let targetMasks = target.masks

        let result = LookSubset.extracted(from: source).applied(to: target)

        XCTAssertEqual(result.look, source.look,
                       "the Look layer did not travel whole")
        XCTAssertEqual(result.develop, targetDevelop,
                       "the look brought some of the source photograph's per-image "
                       + "normalization with it")
        XCTAssertEqual(result.masks, targetMasks,
                       "the look brought the source photograph's masks with it")
    }

    /// Named separately from the test above even though it is implied by it, because
    /// this is the specific failure that makes a look worse than no look: the crop is
    /// the one thing a photographer notices instantly and forgives never.
    func testALookDoesNotCarryACrop() {
        var source = Recipe()
        source.develop.geometry.crop = Crop(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        source.develop.geometry.angle = -3.2
        source.look.vignette = -0.6

        var target = Recipe()
        target.develop.geometry.crop = Crop(x: 0, y: 0, w: 1, h: 0.8)

        let result = LookSubset.extracted(from: source).applied(to: target)

        XCTAssertEqual(result.develop.geometry.crop, Crop(x: 0, y: 0, w: 1, h: 0.8))
        XCTAssertEqual(result.develop.geometry.angle, 0)
        XCTAssertEqual(result.look.vignette, -0.6, "the look itself did not arrive")
    }

    /// The other half of docs/00 §4's sentence — "a film look never smuggles in
    /// someone's white balance".
    func testALookDoesNotCarryWhiteBalanceOrExposure() {
        var source = Recipe()
        source.develop.raw.temp = 7800
        source.develop.raw.tint = 42
        source.develop.tone.exposure = 2.0
        source.look.printerLights = PrinterLights(master: 5)

        let result = LookSubset.extracted(from: source).applied(to: Recipe())

        XCTAssertNil(result.develop.raw.temp, "as-shot neutral was overwritten")
        XCTAssertNil(result.develop.raw.tint, "as-shot neutral was overwritten")
        XCTAssertEqual(result.develop.tone.exposure, 0, "this frame's exposure moved")
        XCTAssertEqual(result.look.printerLights, PrinterLights(master: 5))
    }

    /// Masks stay with the photograph they were drawn on, and the reason they stay is
    /// that there is no such thing as a look-tagged mask yet.
    ///
    /// The second half is a tripwire on the wire format: the day `Mask` gains a
    /// register, this fails and points at the one function that has to decide what to
    /// do about it. It checks names rather than a whole key set on purpose — a new
    /// refinement control is not a portability decision and should not fail a test —
    /// and it is therefore only as good as the vocabulary listed, which is stated here
    /// rather than implied.
    func testNoMaskTravelsBecauseNoMaskDeclaresARegister() throws {
        let keys = try SavedLookTests.objectKeys(of: SavedLookTests.perFrameMask())
        let registerNames: Set<String> = ["register", "stage", "layer", "tag", "isLook"]
        XCTAssertTrue(keys.isDisjoint(with: registerNames),
                      "Mask has gained a register, so look-tagged masks now exist "
                      + "(audit FILM-17). LookSubset.applied(to:) must decide whether "
                      + "to carry them, and this test must be rewritten to say which.")

        let source = Recipe(look: SavedLookTests.loadedLook(),
                            masks: [SavedLookTests.perFrameMask()])
        var target = Recipe()
        target.masks = [Mask(id: "target-own-mask", name: "Face")]

        let result = LookSubset.extracted(from: source).applied(to: target)
        XCTAssertEqual(result.masks.map(\.id), ["target-own-mask"])
    }

    /// A look is a value, so applying it twice is applying it once.
    func testApplyingALookTwiceChangesNothingTheSecondTime() {
        let look = LookSubset.extracted(
            from: Recipe(look: SavedLookTests.loadedLook()))
        let target = Recipe(develop: SavedLookTests.loadedDevelop())
        let once = look.applied(to: target)
        XCTAssertEqual(look.applied(to: once), once)
    }

    // MARK: - The version rule

    func testApplyingALookWrittenInANewerVocabularyRaisesTheRecipeVersion() {
        let look = LookSubset(pipelineVersion: 2,
                              look: Look(bw: BlackAndWhite(bands: Array(repeating: 3,
                                                                        count: 8),
                                                           enabled: false)))
        let target = Recipe(pipelineVersion: 1)
        let result = look.applied(to: target)
        XCTAssertEqual(result.pipelineVersion, 2,
                       "the recipe now holds an expression only a version-2 reader "
                       + "understands and must say so")
    }

    func testApplyingAnOlderLookDoesNotDowngradeTheRecipe() {
        let look = LookSubset(pipelineVersion: 1, look: Look(vignette: -0.5))
        let target = Recipe(pipelineVersion: 2,
                            develop: SavedLookTests.loadedDevelop())
        let result = look.applied(to: target)
        XCTAssertEqual(result.pipelineVersion, 2,
                       "a slice that speaks for the Look layer restamped the whole "
                       + "document, including a develop layer it never touched")
        XCTAssertEqual(result.look.vignette, -0.5)
    }

    // MARK: - 3. Apply to many

    /// One look across a selection: every frame ends up expressing the same look and
    /// keeping its own normalization. Asserted over the SET, because the property is
    /// about the set — it is what "one look across 800 frames is a selection gesture"
    /// means.
    func testOneLookAcrossASelectionLeavesEveryFrameItsOwnDevelop() {
        let look = LookSubset.extracted(
            from: Recipe(develop: SavedLookTests.loadedDevelop(),
                         look: SavedLookTests.loadedLook()))

        let frames: [Recipe] = (0..<8).map { index in
            var recipe = Recipe()
            recipe.develop.tone.exposure = Double(index) * 0.25 - 1.0
            recipe.develop.raw.temp = 4000 + Double(index) * 250
            recipe.develop.geometry.crop = Crop(x: 0, y: 0, w: 1,
                                                h: 1 - Double(index) * 0.05)
            recipe.masks = [Mask(id: "mask-\(index)")]
            return recipe
        }

        let graded = look.applied(toAll: frames)

        XCTAssertEqual(graded.count, frames.count)
        for (before, after) in zip(frames, graded) {
            XCTAssertEqual(after.look, look.look, "a frame did not get the look")
            XCTAssertEqual(after.develop, before.develop,
                           "a frame lost its own normalization")
            XCTAssertEqual(after.masks, before.masks, "a frame lost its own masks")
        }
        XCTAssertEqual(Set(graded.map { $0.develop.tone.exposure }).count, 8,
                       "the eight frames were flattened onto one exposure")
    }

    // MARK: - Names

    func testALookNameIsTrimmedAndCollapsed() {
        XCTAssertEqual(LookSubset.normalizedName("  Portra   warm \n"), "Portra warm")
        XCTAssertEqual(LookSubset.normalizedName("Portra warm"), "Portra warm")
    }

    func testANameThatIsOnlyWhitespaceIsNotAName() {
        XCTAssertNil(LookSubset.normalizedName(""))
        XCTAssertNil(LookSubset.normalizedName("   \t\n "))
    }

    func testALookNameIsLengthCapped() {
        let long = String(repeating: "x", count: LookSubset.maximumNameLength + 40)
        XCTAssertEqual(LookSubset.normalizedName(long)?.count,
                       LookSubset.maximumNameLength)
    }

    // MARK: - 2. The round trip, in JSON

    func testALookSurvivesItsCanonicalJSONWithEveryFieldIntact() throws {
        let subset = LookSubset(pipelineVersion: currentPipelineVersion,
                                look: SavedLookTests.loadedLook())
        let json = try CanonicalJSON.canonicalLookJSON(subset)
        let restored = try CanonicalJSON.decodeLookSubset(from: Data(json.utf8))
        XCTAssertEqual(restored, subset)
    }

    func testADefaultLookStillStoresItsVersion() throws {
        let json = try CanonicalJSON.canonicalLookJSON(LookSubset(pipelineVersion: 2))
        XCTAssertTrue(json.contains("\"pipelineVersion\":2"),
                      "a look with nothing moved stored no version at all: \(json)")
        XCTAssertEqual(try CanonicalJSON.decodeLookSubset(from: Data(json.utf8)),
                       LookSubset(pipelineVersion: 2))
    }

    func testALookWrittenByALaterBuildOpensRatherThanFailing() throws {
        let json = """
        {"pipelineVersion":3,"look":{"vignette":-0.5,"somethingNewer":{"a":1}}}
        """
        let restored = try CanonicalJSON.decodeLookSubset(from: Data(json.utf8))
        XCTAssertEqual(restored.look.vignette, -0.5)
        XCTAssertEqual(restored.pipelineVersion, 3)
    }
}
