// ResetSemanticsTests.swift
// What Reset promises: this photograph, exactly as it was imported — not "close to it",
// and not a bare default recipe.
//
// The distinction is the whole subject. A `Recipe()` is what the FORMAT starts as; it is
// not what a PHOTOGRAPH starts as, and the two differ for most of the files anybody
// actually opens. A JPEG has been tone-mapped once already and starts on the "Linear"
// display transform so Lumen does not map it a second time; a camera raw starts on the
// Tier-1 denoise its capture ISO calls for. Land Reset on `Recipe()` and it does not
// restore the photograph, it edits it — crushing an already-mapped picture in the first
// case and un-denoising a high-ISO frame in the second, both of them persisted, both of
// them reported as "unedited" by every dot in the app.
//
// So the assertion here is EQUALITY against a freshly imported recipe for the same file,
// field for field and version for version, rather than a tolerance. There is no
// arithmetic in a reset for a tolerance to absorb: two recipes that are the same
// document must be the same value, or `recipe_fp` — which keys every preview and
// artifact in the catalog — hands a reset frame a different cache entry from an
// identical imported one and re-renders 45 megapixels to produce identical bytes.
//
// The metadata half runs against a real SQLite catalog rather than a mock, because
// "rating, flag, label and keywords survive a Reset" is a claim about two tables and
// only the database can be asked whether it is true.

import XCTest
@testable import LumenCore

final class ResetSemanticsTests: XCTestCase {

    // MARK: - The three kinds of file

    /// A camera raw whose EXIF recorded a high capture ISO.
    private let highISORaw = Recipe.SourceFile(isRendered: false, iso: 6400)
    /// A camera raw with no ISO recorded — a file that must be handed the flat wire
    /// defaults rather than an invented noise profile.
    private let unknownISORaw = Recipe.SourceFile(isRendered: false, iso: nil)
    /// A JPEG, HEIC or TIFF: already tone-mapped, and carrying an ISO that means
    /// something different because the camera has already denoised it.
    private let renderedFile = Recipe.SourceFile(isRendered: true, iso: 12800)

    /// A photograph somebody has genuinely worked on: every layer of the recipe moved,
    /// two masks in a folder, a crop, a straighten and a heal reference.
    ///
    /// Deliberately not a token one-slider edit. A reset that clears `develop` and
    /// forgets `look`, or clears both and forgets the masks, passes a small fixture and
    /// leaves a photographer's local work standing under a button that said it had put
    /// everything back.
    private func heavilyEdited() -> Recipe {
        var recipe = Recipe()

        recipe.develop.raw.temp = 7200
        recipe.develop.raw.tint = -14
        recipe.develop.tone = Tone(exposure: 1.25, contrast: 40, contrastPivot: -0.5,
                                   highlights: -60, shadows: 35, whites: 12, blacks: -8)
        recipe.develop.zones.mid.ev = 0.4
        recipe.develop.zones.bright.sat = -20
        recipe.develop.curve.point = [[0, 0], [0.5, 0.62], [1, 1]]
        recipe.develop.curve.preserveLuminance = false
        recipe.develop.color = ColorAdjust(vibrance: -10, saturation: 22,
                                           density: 80, protectSkin: 10)
        recipe.develop.mixer.uniformity = 30
        recipe.develop.mixer.bands[3].hue = 12
        recipe.develop.pointColors = [PointColor(sample: [0.4, 0.5, 0.6],
                                                 shift: HSLShift(h: 5, s: -20, l: 3))]
        recipe.develop.detail.texture = 30
        recipe.develop.detail.clarity = 15
        recipe.develop.detail.dehaze = 8
        recipe.develop.detail.capture = CaptureSharpen(auto: false, radius: 1.4,
                                                       amount: 60)
        recipe.develop.detail.sharpen = ManualSharpen(amount: 60, radius: 1.8,
                                                      detail: 40, masking: 25,
                                                      haloSuppression: 30)
        recipe.develop.denoise = Denoise(mode: .ai, amount: 80)
        recipe.develop.geometry.crop = Crop(x: 0.1, y: 0.08, w: 0.7, h: 0.6)
        recipe.develop.geometry.angle = 3.5
        recipe.develop.geometry.flipH = true
        recipe.develop.geometry.upright = Upright(vertical: 20, horizontal: -5)
        recipe.develop.geometry.lens = LensCorrections(profile: false, removeCA: false)
        recipe.develop.heal = Heal(strokesRef: "blob:xxh64:0123456789abcdef", count: 3)

        recipe.look.printerLights = PrinterLights(master: 2, r: -1, g: 0, b: 3)
        recipe.look.vignette = -1.5
        recipe.look.vignetteFeather = 20
        recipe.look.grain = CreativeGrain(amount: 40, size: 60, roughness: 70)
        recipe.look.render = RenderParams(preset: "Punchy", contrast: 1.4)

        let folder = MaskGroup(id: "group-sky", name: "Sky", amount: 80)
        recipe.maskGroups = [folder]
        recipe.masks = [
            Mask(id: "mask-1", name: "Sky", amount: 140, group: folder.id),
            Mask(id: "mask-2", name: "Face", amount: 60),
        ]
        return recipe
    }

    // MARK: - The core assertion

    /// Reset lands on a freshly imported recipe. Equal, not close — and for each of the
    /// three kinds of file, because they have three different starting points and a
    /// reset that knew about only one of them would pass a single-fixture test.
    func testResetLandsExactlyOnAFreshlyImportedRecipe() {
        for (name, file) in [("a high-ISO raw", highISORaw),
                             ("a raw with no ISO", unknownISORaw),
                             ("a rendered file", renderedFile)] {
            var recipe = heavilyEdited()
            recipe.resetToImported(from: file)
            XCTAssertEqual(recipe, Recipe.asImported(from: file),
                           "reset did not land on the imported recipe for \(name)")
        }
    }

    /// The same, taken from the other end: whatever was there before cannot leak
    /// through. Two photographs edited into completely different pictures reset to one
    /// value, because "as imported" is a property of the FILE and not of the edit.
    func testWhatWasThereBeforeCannotSurviveTheReset() {
        var worked = heavilyEdited()
        var barelyTouched = Recipe.asImported(from: highISORaw)
        barelyTouched.develop.tone.exposure = 0.1

        worked.resetToImported(from: highISORaw)
        barelyTouched.resetToImported(from: highISORaw)
        XCTAssertEqual(worked, barelyTouched,
                       "the previous edit leaked through the reset")
    }

    func testResetIsIdempotent() {
        var once = heavilyEdited()
        once.resetToImported(from: highISORaw)
        var twice = once
        twice.resetToImported(from: highISORaw)
        XCTAssertEqual(once, twice, "resetting twice is not resetting once")
    }

    // MARK: - The two things "as imported" is not a bare recipe about

    /// A rendered file comes back on the Linear transform, not on the type's "Neutral".
    ///
    /// This is the failure that has already been shipped once in this app, and it is
    /// visible rather than subtle: Lumen's display transform is the only one a raw ever
    /// gets, so applying it on top of the camera's own crushes the blacks and hardens
    /// the highlights of a picture that was fine when it was opened.
    func testResettingARenderedFileLeavesItOnTheLinearTransform() {
        var recipe = heavilyEdited()
        recipe.resetToImported(from: renderedFile)
        XCTAssertEqual(recipe.look.render.preset, LookSubset.linearPresetName,
                       "reset put a second tone map on an already-mapped file")
        XCTAssertNotEqual(recipe.look.render.preset, RenderParams().preset,
                          "the type's default preset is not what a rendered file "
                          + "starts on")
    }

    /// A raw comes back on the denoise its own capture ISO calls for, not on the flat
    /// wire default — which for a high-ISO frame is effectively un-denoising it.
    func testResettingARawKeepsTheDenoiseItsOwnISOCallsFor() {
        var recipe = heavilyEdited()
        recipe.resetToImported(from: highISORaw)
        XCTAssertEqual(recipe.develop.denoise,
                       ISODefaults.startingDenoise(forISO: 6400),
                       "reset did not restore the frame's own ISO denoise profile")
        XCTAssertNotEqual(recipe.develop.denoise, Denoise(),
                          "at ISO 6400 the ISO-adaptive profile must differ from the "
                          + "flat default, or this test proves nothing")
    }

    /// And a rendered file's ISO is NOT a noise profile. A JPEG shot at 12800 has been
    /// denoised by the camera already; its pixels follow no sensor noise model this
    /// table knows, so smoothing it again on the strength of its EXIF would be the
    /// second half of the same mistake.
    func testARenderedFilesISOIsNotTreatedAsANoiseProfile() {
        var recipe = heavilyEdited()
        recipe.resetToImported(from: renderedFile)
        XCTAssertEqual(recipe.develop.denoise, Denoise(),
                       "a rendered file was handed a raw sensor's noise profile")
    }

    /// A raw that recorded no ISO keeps the flat defaults rather than a guess.
    func testARawWithNoISORecordedKeepsTheFlatDefaults() {
        XCTAssertEqual(Recipe.asImported(from: unknownISORaw), Recipe(),
                       "a file with no ISO was handed an invented profile")
    }

    // MARK: - What Reset clears, stated so a change to it has to be deliberate

    func testResetClearsEveryMaskAndEveryMaskFolder() {
        var recipe = heavilyEdited()
        XCTAssertFalse(recipe.masks.isEmpty)
        XCTAssertFalse(recipe.maskGroups.isEmpty)
        recipe.resetToImported(from: highISORaw)
        XCTAssertTrue(recipe.masks.isEmpty, "local adjustments survived a whole-photo "
                      + "reset")
        XCTAssertTrue(recipe.maskGroups.isEmpty, "mask folders survived a whole-photo "
                      + "reset")
    }

    /// THE CROP GOES, and this test is here to say that is the house's answer rather
    /// than an oversight.
    ///
    /// Lumen has no as-shot crop to preserve: `Crop()` is the whole frame and nothing
    /// reads a crop out of raw metadata, so `develop.geometry.crop` is an edit like any
    /// other. `WorkspaceSection.frame`'s own Reset clears it, and a whole-photo Reset
    /// that spared it would be the one control in the app that resets everything except
    /// the thing you can see. A photographer who wants the framing kept and the grade
    /// thrown away has the per-section Resets one row up.
    func testResetClearsTheCropAndTheStraightenBecauseThoseAreEdits() {
        var recipe = heavilyEdited()
        recipe.resetToImported(from: highISORaw)
        XCTAssertEqual(recipe.develop.geometry, Geometry(),
                       "the frame's geometry is a develop setting and Reset must clear "
                       + "it")
    }

    // MARK: - The catalog's view of a reset frame

    /// A reset frame and a freshly imported one are ONE cache entry, not two.
    ///
    /// `recipe_fp` keys every preview and artifact in the catalog, so two recipes that
    /// are the same document must hash the same. The way this goes wrong is the
    /// pipeline version: a recipe decoded from an older catalog row carries that older
    /// version, and carrying it across a reset would leave a photograph whose whole
    /// document was rewritten by today's writer still claiming yesterday's vocabulary —
    /// a different fingerprint for identical bytes, a discarded 45-megapixel render, and
    /// a frame that can never share a cached artifact with an identical sibling.
    func testAResetFrameAndAFreshlyImportedOneShareOneFingerprint() throws {
        var older = heavilyEdited()
        older.pipelineVersion = 1
        older.resetToImported(from: highISORaw)

        let fresh = Recipe.asImported(from: highISORaw)
        XCTAssertEqual(older.pipelineVersion, fresh.pipelineVersion,
                       "the reset document kept a version its writer does not speak")
        XCTAssertEqual(try RecipeFingerprint.fingerprint(older),
                       try RecipeFingerprint.fingerprint(fresh),
                       "a reset frame cannot share a cached render with an identical "
                       + "imported one")
    }

    /// An imported rendered file does NOT render like a bare `Recipe()`, and that is
    /// worth pinning on its own because two readers depend on the difference in opposite
    /// directions. It is why `Recipe.asImported` has to exist at all — and it is also
    /// why `CatalogStore.saveRecipe` cannot decide "edited" by comparing against the
    /// type's default, which is a question this file raises rather than answers.
    func testAnImportedRenderedFileDoesNotRenderLikeABareDefaultRecipe() {
        XCTAssertFalse(Recipe.asImported(from: renderedFile).rendersSameAs(Recipe()),
                       "a rendered file's baseline is supposed to differ from the "
                       + "format's default — if it does not, nothing above is being "
                       + "tested")
    }

    // MARK: - Agreement with the per-section dots

    /// After a whole-photo Reset, no workspace section reports itself modified.
    ///
    /// This is the property that keeps the two Resets in the app honest with each other.
    /// The footer's Reset writes the baseline; the accordion's header dot decides
    /// whether a section's own Reset is offered at all, and it decides it against
    /// `denoiseDefault` and `renderDefault` handed in by the caller. If those two ever
    /// stop being the same baseline this factory produces, a photographer presses Reset
    /// and is left looking at a column of lit dots on a photograph the app has just
    /// declared untouched.
    func testNoWorkspaceSectionReportsModifiedAfterAReset() {
        for (name, file) in [("a high-ISO raw", highISORaw),
                             ("a raw with no ISO", unknownISORaw),
                             ("a rendered file", renderedFile)] {
            var recipe = heavilyEdited()
            recipe.resetToImported(from: file)
            let baseline = Recipe.asImported(from: file)
            let lit = WorkspaceSection.nonDefault(in: recipe,
                                                  softProofEnabled: false,
                                                  denoiseDefault: baseline.develop.denoise,
                                                  renderDefault: baseline.look.render)
            XCTAssertEqual(lit, [], "sections still report modified after a reset of "
                           + "\(name): \(lit.map(\.rawValue).sorted())")
        }
    }

    // MARK: - "Is this still as imported"

    /// The predicate the Reset affordance offers itself on answers about VALUES, and a
    /// pipeline bump is not a value. Two different questions, and conflating them would
    /// mark every photograph in the library as edited on the morning a version ships.
    func testIsAsImportedIgnoresThePipelineVersionThatTheResetItselfStamps() {
        var older = Recipe.asImported(from: highISORaw)
        older.pipelineVersion = 1
        XCTAssertTrue(older.isAsImported(from: highISORaw),
                      "an untouched photograph from an older catalog was called edited")

        var edited = Recipe.asImported(from: highISORaw)
        edited.develop.tone.exposure = 0.01
        XCTAssertFalse(edited.isAsImported(from: highISORaw),
                       "a moved slider was not noticed")
    }

    /// And it is baseline-aware in both directions: an untouched JPEG is not edited, and
    /// the same recipe read as a raw is.
    func testTheSameRecipeIsUntouchedForOneFileAndEditedForAnother() {
        let jpeg = Recipe.asImported(from: renderedFile)
        XCTAssertTrue(jpeg.isAsImported(from: renderedFile))
        XCTAssertFalse(jpeg.isAsImported(from: unknownISORaw),
                       "the Linear transform is an edit on a raw and a baseline on a "
                       + "JPEG, and the predicate has to tell them apart")
    }
}

// MARK: - The metadata half, against a real catalog

#if canImport(SQLite3)

/// Rating, flag, colour label and keywords survive a Reset — asked of the database
/// rather than asserted from the shape of the code.
///
/// They survive by CONSTRUCTION, which is the interesting part: none of them is in a
/// `Recipe` at all. The culling decisions live on the `photo` row and the recipe lives
/// on an `edit` row, so a reset writes one table and cannot reach the other. This suite
/// exists to keep that separation from being quietly given up — the day somebody folds a
/// rating into the recipe "so it travels with the sidecar", a whole-photo Reset starts
/// throwing away a cull.
final class ResetPreservesCatalogMetadataTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeStore() throws -> CatalogStore {
        try CatalogStore(path: directory.appendingPathComponent("lumen.db").path,
                         cachePath: directory.appendingPathComponent("cache.db").path)
    }

    func testCullingAndKeywordsSurviveAWholePhotoReset() throws {
        let store = try makeStore()
        let folderID = try store.registerFolder(path: "/Volumes/Shoots/2026-08-20")
        let file = ScannedFile(filename: "DSC0001.ARW", fileSize: 42_000_000,
                               fileMTime: 1_700_000_000, ext: "arw")
        _ = try store.scan(folderID: folderID, files: [file], at: CatalogStore.now())
        guard let row = try store.photo(folderID: folderID, filename: file.filename)
        else { return XCTFail("the scan did not register the photo") }

        // A photograph that has been culled, keyworded and worked on.
        try store.setRating(4, photoID: row.id)
        try store.setFlag(.pick, photoID: row.id)
        try store.setLabel(.green, photoID: row.id)
        _ = try store.addKeyword("Iceland", photoIDs: [row.id])
        _ = try store.addKeyword("Client", photoIDs: [row.id])
        var edited = Recipe()
        edited.develop.tone.exposure = 1.5
        edited.develop.geometry.crop = Crop(x: 0.1, y: 0.1, w: 0.7, h: 0.7)
        edited.masks = [Mask(id: "mask-1", name: "Sky")]
        try store.saveRecipe(edited, photoID: row.id, isCurrent: true)

        // The reset, written the way the app writes it.
        let source = Recipe.SourceFile(isRendered: false, iso: 6400)
        var reset = edited
        reset.resetToImported(from: source)
        try store.saveRecipe(reset, photoID: row.id, isCurrent: true)

        guard let after = try store.photo(id: row.id) else {
            return XCTFail("the photo row vanished")
        }
        XCTAssertEqual(after.rating, 4, "Reset threw away the rating")
        XCTAssertEqual(after.flag, .pick, "Reset threw away the flag")
        XCTAssertEqual(after.label, "green", "Reset threw away the colour label")
        XCTAssertEqual(try store.keywords(photoID: row.id).sorted(),
                       ["Client", "Iceland"], "Reset threw away the keywords")

        guard let stored = try store.currentRecipe(photoID: row.id) else {
            return XCTFail("the reset recipe did not come back")
        }
        XCTAssertEqual(stored, Recipe.asImported(from: source),
                       "the recipe that came back out of the catalog is not the one a "
                       + "fresh import would have produced")
        store.close()
    }
}

#endif
