// Which sections a recipe has touched — the input to the header dot and, more
// importantly, to the Simple register's honesty clause.
import XCTest
@testable import LumenCore

final class WorkspaceModificationTests: XCTestCase {

    func testACleanRecipeTouchesNothing() {
        XCTAssertEqual(WorkspaceSection.nonDefault(in: Recipe()), [],
                       "a photograph nobody has edited must show no dots at all")
    }

    /// AS SHOT IS NOT AN EDIT, however far from neutral the camera put it. `temp` and
    /// `tint` are optional for exactly this reason and reading them as numbers would
    /// light White Balance on every photograph ever opened.
    func testAsShotWhiteBalanceIsNotAModification() {
        var recipe = Recipe()
        XCTAssertNil(recipe.develop.raw.temp)
        XCTAssertFalse(WorkspaceSection.nonDefault(in: recipe).contains(.whiteBalance))
        recipe.develop.raw.temp = 5200
        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe).contains(.whiteBalance))
    }

    /// PRESENCE AND DETAIL SHARE ONE STRUCT, and this is the test that keeps them from
    /// sharing one dot. Texture is Presence's; Sharpening is Detail's; both live in
    /// `develop.detail`, so a struct-level comparison would light both for either edit
    /// and the dot would stop meaning anything.
    func testPresenceAndDetailLightSeparatelyDespiteSharingAStruct() {
        var texture = Recipe()
        texture.develop.detail.texture = 30
        let afterTexture = WorkspaceSection.nonDefault(in: texture)
        XCTAssertTrue(afterTexture.contains(.presence))
        XCTAssertFalse(afterTexture.contains(.detail),
                       "sharpening was not touched, so Detail is clean")

        var sharpen = Recipe()
        sharpen.develop.detail.sharpen.amount = 40
        let afterSharpen = WorkspaceSection.nonDefault(in: sharpen)
        XCTAssertTrue(afterSharpen.contains(.detail))
        XCTAssertFalse(afterSharpen.contains(.presence),
                       "texture was not touched, so Presence is clean")
    }

    /// Zones folds inside Tone as a disclosure, so it must light Tone — otherwise a
    /// photographer who used the zone sliders sees a clean header above them.
    func testZonesLightTheSectionItIsFoldedInto() {
        var recipe = Recipe()
        recipe.develop.zones.dark.ev = 0.5
        let touched = WorkspaceSection.nonDefault(in: recipe)
        XCTAssertTrue(touched.contains(.tone))
    }

    /// Vibrance and Saturation are rendered under Presence — a decision this phase made
    /// deliberately, because §5.1 gives Develop no Colour section and Grade's Colour is
    /// the Mixer surface. The dot has to follow the rows or it points at the wrong
    /// header.
    func testSaturationLightsPresenceWhereItIsDrawn() {
        var recipe = Recipe()
        recipe.develop.color.saturation = 25
        let touched = WorkspaceSection.nonDefault(in: recipe)
        XCTAssertTrue(touched.contains(.presence))
        XCTAssertFalse(touched.contains(.color),
                       "Grade's Colour is the Mixer, Point Colour and B&W surface")
    }

    /// Soft proof is a viewing mode, not part of the photograph. It must never come out
    /// of the recipe — a recipe copied to another frame would carry it.
    func testSoftProofComesFromTheSessionAndNotTheRecipe() {
        let recipe = Recipe()
        XCTAssertFalse(WorkspaceSection.nonDefault(in: recipe).contains(.softProof))
        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe, softProofEnabled: true)
            .contains(.softProof))
    }

    /// Export recipes are catalog-wide, so a dot on this photograph would be answering a
    /// question about some other one.
    func testExportRecipesNeverLight() {
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1
        recipe.look.vignette = -1
        recipe.develop.geometry.angle = 3
        XCTAssertFalse(WorkspaceSection.nonDefault(in: recipe).contains(.exportRecipes))
    }

    /// The stored-but-unapplied LUT still counts: it is something the photographer set,
    /// and a dot that ignored it would be the panel disagreeing with the sidecar.
    func testAStoredLUTLightsLooksEvenThoughNothingAppliesIt() {
        var recipe = Recipe()
        recipe.look.lut = LUTReference(ref: "blob:xxh64:abc", name: "kodak")
        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe).contains(.looks))
    }

    /// Every section a workspace can draw must be REACHABLE by some edit, or its dot is
    /// decoration. The two exceptions are stated and asserted rather than assumed.
    func testEverySectionExceptTheTwoNonRecipeOnesCanBeLit() {
        var everything = Recipe()
        everything.develop.raw.temp = 5200
        everything.develop.tone.exposure = 1
        everything.develop.curve.point = [[0, 0], [0.4, 0.6], [1, 1]]
        everything.develop.zones.dark.ev = 0.5
        everything.develop.detail.texture = 10
        everything.develop.detail.sharpen.amount = 50
        everything.develop.geometry.angle = 2
        everything.develop.mixer.uniformity = 40
        everything.develop.heal.count = 1
        everything.look.vignette = -1
        everything.look.wheels.shadows.sat = 0.2
        everything.look.filmLab = FilmLab(stock: "lumen/portra400")
        everything.look.render.preset = "Punchy"

        let touched = WorkspaceSection.nonDefault(in: everything, softProofEnabled: true)
        let unreachable = Set(WorkspaceSection.allCases)
            .subtracting(touched)
            .subtracting([.exportRecipes])
        XCTAssertTrue(unreachable.isEmpty,
                      "no section may carry a dot nothing can light: \(unreachable)")
    }
}

extension WorkspaceModificationTests {

    /// A HIGH-ISO FRAME STARTS WITH DENOISE ALREADY ON, and that is not an edit.
    ///
    /// `ISODefaults.startingDenoise(forISO:)` gives the photograph its own starting
    /// point, so comparing against `Denoise()` would light Detail on every RAW file ever
    /// opened. A dot that is always on is a dot that says nothing — which is the same
    /// argument the "Default" badges were removed under.
    func testThePhotographsOwnDenoiseStartingPointIsNotAnEdit() {
        var recipe = Recipe()
        let start = ISODefaults.startingDenoise(forISO: 6400)
        recipe.develop.denoise = start
        XCTAssertNotEqual(start, Denoise(),
                          "the test is only meaningful if ISO 6400 starts off default")

        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe).contains(.detail),
                      "against the type's default it looks edited, which is the bug")
        XCTAssertFalse(WorkspaceSection.nonDefault(in: recipe, denoiseDefault: start)
            .contains(.detail),
                       "against the photograph's own default it is untouched")
    }

    /// And moving off that starting point IS an edit.
    func testMovingOffThePhotographsDenoiseStartingPointIsAnEdit() {
        var recipe = Recipe()
        let start = ISODefaults.startingDenoise(forISO: 6400)
        recipe.develop.denoise = start
        recipe.develop.denoise.amount += 10
        XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe, denoiseDefault: start)
            .contains(.detail))
    }
}

extension WorkspaceModificationTests {

    /// A recipe with every section moved off its default, built once and reused by the
    /// property tests below. Deliberately not a helper that touches "some" fields: the
    /// point of these is that they hold for every section at once, including the
    /// interactions between sections that share a struct.
    private func everythingEdited() -> Recipe {
        var r = Recipe()
        r.develop.raw.temp = 5200
        r.develop.raw.tint = -14
        r.develop.tone.exposure = 1.2
        r.develop.zones.dark.ev = 0.4
        r.develop.curve.point = [[0, 0], [0.4, 0.6], [1, 1]]
        r.develop.detail.texture = 20
        r.develop.detail.clarity = 15
        r.develop.detail.dehaze = 10
        r.develop.color.saturation = 25
        r.develop.detail.sharpen.amount = 60
        r.develop.denoise.amount = 40
        r.develop.geometry.angle = 2.5
        r.develop.mixer.uniformity = 30
        r.develop.pointColors = []
        r.develop.heal.count = 2
        r.look.vignette = -1.2
        r.look.wheels.shadows.sat = 0.3
        r.look.printerLights.r = 2
        r.look.primaries.rHue = 5
        r.look.filmLab = FilmLab(stock: "lumen/portra400")
        r.look.render.preset = "Punchy"
        return r
    }

    /// THE PROPERTY THAT KEEPS THE HEADER HONEST.
    ///
    /// Reset and the modified dot are two descriptions of the same fact — "this section
    /// is at its defaults" — written in two places. If they disagree, a photographer
    /// clicks Reset and the dot stays on, which reads as a button that does not work.
    /// Asserted for every section rather than for a chosen few, because the pairs that
    /// break are the ones nobody thought to pick: Presence and Detail share
    /// `develop.detail`, Tone owns Zones, Effects reaches into both `look` and
    /// `develop`.
    func testResettingASectionClearsItsOwnDot() {
        for section in WorkspaceSection.allCases where section.resetsTheRecipe {
            var recipe = everythingEdited()
            XCTAssertTrue(WorkspaceSection.nonDefault(in: recipe).contains(section),
                          "\(section) must start modified or this proves nothing")
            section.reset(&recipe)
            XCTAssertFalse(WorkspaceSection.nonDefault(in: recipe).contains(section),
                           "Reset on \(section) left its own dot lit")
        }
    }

    /// AND IT MUST NOT CLEAR ANYBODY ELSE'S.
    ///
    /// The sections that share a struct are exactly where this goes wrong: assigning
    /// `develop.detail = Detail()` to reset Sharpening would silently wipe Texture,
    /// Clarity and Dehaze out of Presence, and the photographer would have no idea which
    /// click did it.
    func testResettingASectionTouchesNoOtherSection() {
        for section in WorkspaceSection.allCases where section.resetsTheRecipe {
            var recipe = everythingEdited()
            let before = WorkspaceSection.nonDefault(in: recipe)
            section.reset(&recipe)
            let after = WorkspaceSection.nonDefault(in: recipe)
            XCTAssertEqual(before.subtracting(after), [section],
                           "Reset on \(section) also cleared "
                               + "\(before.subtracting(after).subtracting([section]))")
        }
    }

    /// Reset is idempotent, which is worth one line because a reset that drifts on a
    /// second click is a reset that is doing something other than assigning defaults.
    func testResetIsIdempotent() {
        for section in WorkspaceSection.allCases {
            var once = everythingEdited()
            section.reset(&once)
            var twice = once
            section.reset(&twice)
            XCTAssertEqual(once, twice, "\(section) reset twice is not reset once")
        }
    }

    /// The two sections with no Reset must genuinely have nothing to reset, or the
    /// header is hiding a button a photographer needs.
    func testTheTwoSectionsWithoutAResetChangeNothing() {
        for section in WorkspaceSection.allCases where !section.resetsTheRecipe {
            var recipe = everythingEdited()
            let before = recipe
            section.reset(&recipe)
            XCTAssertEqual(before, recipe,
                           "\(section) claims no reset but mutated the recipe")
        }
    }

    /// A clean recipe stays clean: no section's reset may INTRODUCE a difference, which
    /// is what a wrong default constant would do and what nothing else here would catch.
    func testResettingACleanRecipeIsANoOp() {
        for section in WorkspaceSection.allCases {
            var recipe = Recipe()
            section.reset(&recipe)
            XCTAssertEqual(recipe, Recipe(),
                           "\(section) reset wrote something into a default recipe")
        }
    }
}
