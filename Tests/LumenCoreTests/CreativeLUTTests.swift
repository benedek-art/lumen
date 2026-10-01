// The creative-LUT stage, end to end on the reference path: a `.cube` parsed, stored
// by content hash, resolved by a recipe, applied at the tap it declares, blended by its
// Amount, hashed into the render identity, and carried through every wire format a
// recipe travels in — with the newer-build guard (M-01) still holding.
//
// THE OTHER HALF IS THE ONE THAT MATTERS MOST: a recipe with no LUT renders the same
// bytes it rendered before the stage existed. Both renderers skip the stage outright
// when `CreativeLUTStage(reference:)` is nil, so the equality is structural; these tests
// pin each way of being nil, and the proof suite (`ControlProofTests`, 135 records,
// unchanged by this stage) pins the rest.
//
// GPU parity is `LumenPipelineTests/CreativeLUTParityTests.swift`, on macOS.

import Foundation
import XCTest
@testable import LumenCore

final class CreativeLUTTests: XCTestCase {

    // MARK: - Fixtures

    /// Inverts red, passes green and blue — far enough from the identity that a stage
    /// which did nothing fails every assertion below.
    static let redInvertingCube = """
        TITLE "red inverted"
        LUT_3D_SIZE 2
        1.0 0.0 0.0
        0.0 0.0 0.0
        1.0 1.0 0.0
        0.0 1.0 0.0
        1.0 0.0 1.0
        0.0 0.0 1.0
        1.0 1.0 1.0
        0.0 1.0 1.0
        """

    static var cube: LUT3D { LUT3D.fromCubeFile(redInvertingCube)! }

    /// A library holding the red-inverting cube under `ref`, and nothing else — so no
    /// test depends on the shared shelf or on another test's registrations.
    static func library(ref: String = "blob:xxh64:00000000000000aa") -> CreativeLUTLibrary {
        let library = CreativeLUTLibrary()
        library.register(cube, for: ref)
        return library
    }

    static let ref = "blob:xxh64:00000000000000aa"

    /// A small scene-linear frame with a ramp in each channel and some out-of-SDR values,
    /// so both taps see shadows, mid-tones and highlights.
    static let frame = ImageBuffer(width: 24, height: 16) { u, v in
        RGB(0.02 + 1.4 * u, 0.05 + 0.6 * v, 0.3 * (1 - u) + 0.01)
    }

    private func render(_ recipe: Recipe, library: CreativeLUTLibrary,
                        input: ImageBuffer = CreativeLUTTests.frame) -> ImageBuffer {
        ReferenceRenderer.render(input, plan: RenderPlan(recipe: recipe),
                                 inputs: ReferenceRenderer.Inputs(luts: library))
    }

    private func recipe(tap: LUTReference.Tap, amount: Double = 100,
                        ref: String = CreativeLUTTests.ref) -> Recipe {
        var recipe = Recipe()
        recipe.look.lut = LUTReference(ref: ref, name: "Probe", tap: tap, amount: amount)
        return recipe
    }

    private func maxDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        zip(a.pixels, b.pixels).map { abs(Double($0) - Double($1)) }.max() ?? 0
    }

    // MARK: - Parse and apply

    /// The display tap's declared space, measured: an sRGB value goes in, the cube's
    /// answer for that sRGB code comes out — through the working-space round trip.
    func testTheDisplayTapLooksUpTheSRGBCodeAndReturnsTheCubesAnswer() {
        let stage = CreativeLUTStage(tap: .display, amount: 100, cube: Self.cube)
        let srgbLinear = RGB(0.2, 0.5, 0.7)
        let working = CreativeLUTStage.displayToWorking.apply(srgbLinear)

        let out = CreativeLUTStage.workingToDisplay.apply(stage.apply(working))
        let expectedRed = TransferFunction.srgb.decode(1 - TransferFunction.srgb.encode(0.2))
        XCTAssertEqual(out.r, expectedRed, accuracy: 1e-9, "red was not inverted in sRGB code")
        XCTAssertEqual(out.g, 0.5, accuracy: 1e-9, "green moved through a cube that passes it")
        XCTAssertEqual(out.b, 0.7, accuracy: 1e-9, "blue moved through a cube that passes it")
    }

    /// The identity cube at the display tap is the identity on every in-gamut SDR value —
    /// which is what proves the two matrices and the two transfer curves are each
    /// other's inverse, rather than merely each plausible.
    func testAnIdentityCubeAtTheDisplayTapChangesNoSDRValue() {
        let stage = CreativeLUTStage(tap: .display, amount: 100, cube: .identity(size: 2))
        for c in [RGB(0.18, 0.18, 0.18), RGB(0.9, 0.1, 0.4), RGB(0.001, 0.6, 0.95)] {
            let working = CreativeLUTStage.displayToWorking.apply(c)
            XCTAssertLessThan(stage.apply(working).maxAbsDifference(working), 1e-9, "\(c)")
        }
    }

    /// The display tap is SDR-referred: above display white it has nothing to say, and
    /// clamps. Pinned so an HDR rendition's behaviour is a stated decision, not a surprise.
    func testTheDisplayTapClampsAboveDisplayWhite() {
        let stage = CreativeLUTStage(tap: .display, amount: 100, cube: .identity(size: 2))
        let out = stage.apply(RGB(gray: 3))
        XCTAssertLessThan(out.maxAbsDifference(RGB(gray: 1)), 1e-9)
    }

    /// The log tap's declared space: `LumenLog` in, `LumenLog` out.
    func testTheLogTapLooksUpTheLumenLogCode() {
        let stage = CreativeLUTStage(tap: .log, amount: 100, cube: Self.cube)
        let c = RGB(0.18, 0.4, 2.0)
        let out = stage.apply(c)
        XCTAssertEqual(out.r, LumenLog.decode(1 - LumenLog.encode(0.18)), accuracy: 1e-9)
        XCTAssertEqual(out.g, 0.4, accuracy: 1e-9)
        XCTAssertEqual(out.b, 2.0, accuracy: 1e-9)
    }

    /// Amount is a linear blend against the stage's input, 0…100, clamped.
    func testAmountBlendsAgainstTheInput() {
        let c = RGB(0.3, 0.2, 0.1)
        let full = CreativeLUTStage(tap: .log, amount: 100, cube: Self.cube).apply(c)
        let half = CreativeLUTStage(tap: .log, amount: 50, cube: Self.cube).apply(c)
        XCTAssertLessThan(half.maxAbsDifference(c + (full - c) * 0.5), 1e-12)
        XCTAssertEqual(CreativeLUTStage(tap: .log, amount: 250, cube: Self.cube).amount, 1)
        XCTAssertEqual(CreativeLUTStage(tap: .log, amount: .nan, cube: Self.cube).amount, 0)
    }

    // MARK: - Position in the pipeline

    /// THE DISPLAY TAP IS THE LAST COLOUR STAGE BEFORE GRAIN: rendering with it is the
    /// no-LUT render with the stage applied on top, value for value. A LUT placed
    /// anywhere upstream of the transform would fail this by the transform's whole
    /// curvature.
    func testTheDisplayTapRunsOnTheFormedPicture() {
        let library = Self.library()
        let without = render(Recipe(), library: library)
        let with = render(recipe(tap: .display), library: library)
        let stage = CreativeLUTStage(tap: .display, amount: 100, cube: Self.cube)
        XCTAssertGreaterThan(maxDifference(with, without), 0.05,
                             "the LUT changed nothing, so the position test proves nothing")
        XCTAssertEqual(maxDifference(with, without.map(stage.apply)), 0,
                       "the display tap is not on the formed picture")
    }

    /// AND BEFORE GRAIN, because the export lays grain down after its resize and this is
    /// the only order both paths can share. The grain stage is run by hand on the
    /// LUT'd picture and must match the render bit for bit; LUT-after-grain would not.
    func testTheDisplayTapRunsBeforeGrain() throws {
        let library = Self.library()
        var grained = recipe(tap: .display)
        grained.look.grain = CreativeGrain(amount: 70, size: 50, roughness: 50)
        let plan = RenderPlan(recipe: grained)
        let grain = try XCTUnwrap(plan.grain)

        let rendered = render(grained, library: library)
        let lutOnly = render(recipe(tap: .display), library: library)
        let longEdge = max(Self.frame.width, Self.frame.height)
        let expected = ReferenceRenderer.applyGrain(
            lutOnly, grain: grain, seed: FilmGrainProfile.defaultPlateSeed, longEdge: longEdge)
        XCTAssertEqual(maxDifference(rendered, expected), 0,
                       "the grain did not land on the LUT's output")
    }

    /// THE LOG TAP IS THE LAST STAGE BEFORE THE TRANSFORM: on a recipe whose
    /// scene-referred stages are all identity, rendering with it equals rendering the
    /// pre-mapped input without it.
    func testTheLogTapRunsBeforeTheTransform() {
        let plan = RenderPlan(recipe: Recipe())
        XCTAssertTrue(plan.linear.isIdentity && plan.toneIsIdentity
                          && plan.colorGradeIsIdentity && plan.vignetteEV == 0,
                      "the default recipe has a scene-referred stage now; this test's "
                          + "premise needs a recipe where the log tap is the first move")
        let library = Self.library()
        let stage = CreativeLUTStage(tap: .log, amount: 100, cube: Self.cube)
        let with = render(recipe(tap: .log), library: library)
        let premapped = render(Recipe(), library: library, input: Self.frame.map(stage.apply))
        XCTAssertGreaterThan(maxDifference(with, render(Recipe(), library: library)), 0.05)
        XCTAssertEqual(maxDifference(with, premapped), 0,
                       "the log tap is not the last scene-referred stage")
    }

    // MARK: - No LUT is no change

    /// Every way a recipe can carry no LUT that renders: absent, empty ref, Amount 0,
    /// negative Amount, and a ref whose bytes this machine does not hold. Each renders
    /// exactly the no-LUT picture.
    func testEveryInertLUTRendersExactlyTheNoLUTPicture() {
        let library = Self.library()
        let baseline = render(Recipe(), library: library)
        let inert: [(String, Recipe)] = [
            ("empty ref", recipe(tap: .display, ref: "")),
            ("Amount 0", recipe(tap: .display, amount: 0)),
            ("negative Amount", recipe(tap: .log, amount: -5)),
            ("missing blob", recipe(tap: .display, ref: "blob:xxh64:00000000000000bb")),
        ]
        for (what, recipe) in inert {
            XCTAssertNil(CreativeLUTStage(reference: recipe.look.lut, library: library), what)
            XCTAssertEqual(render(recipe, library: library).pixels, baseline.pixels, what)
        }
    }

    // MARK: - Render identity

    /// A LUT that renders is hashed — Amount, tap and cube all move `recipe_fp` — and
    /// its name, a label, does not.
    func testALUTThatRendersIsPartOfTheRenderIdentity() throws {
        let carried = recipe(tap: .display, amount: 62)
        let fp = { try RecipeFingerprint.fingerprint($0) }
        XCTAssertFalse(carried.rendersSameAs(Recipe()))
        XCTAssertNotEqual(try fp(carried), try fp(Recipe()))

        var moved = carried
        moved.look.lut?.amount = 63
        XCTAssertNotEqual(try fp(moved), try fp(carried), "Amount did not reach the hash")
        moved = carried
        moved.look.lut?.tap = .log
        XCTAssertNotEqual(try fp(moved), try fp(carried), "the tap did not reach the hash")
        moved = carried
        moved.look.lut?.ref = "blob:xxh64:00000000000000cc"
        XCTAssertNotEqual(try fp(moved), try fp(carried), "the cube did not reach the hash")

        var renamed = carried
        renamed.look.lut?.name = "Something else"
        XCTAssertEqual(try fp(renamed), try fp(carried), "renaming a LUT re-renders")
        XCTAssertTrue(renamed.rendersSameAs(carried))

        for inert in [recipe(tap: .display, amount: 0), recipe(tap: .display, ref: "")] {
            XCTAssertEqual(try fp(inert), try fp(Recipe()),
                           "a LUT that renders nothing was hashed as a different picture")
        }
    }

    // MARK: - Round trips

    func testALUTSurvivesTheRecipeTheSidecarAndASavedLook() throws {
        let carried = recipe(tap: .log, amount: 37)

        let wire = try CanonicalJSON.canonicalRecipeJSON(carried)
        XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(wire.utf8)).look.lut,
                       carried.look.lut, "recipe JSON")

        let sidecar = XMPSidecar.serialize(SidecarContent(
            recipeFingerprint: try RecipeFingerprint.fingerprint(carried), recipeJSON: wire))
        let parsed = try XCTUnwrap(XMPSidecar.parse(sidecar))
        let fromSidecar = try CanonicalJSON.decodeRecipe(
            from: Data(try XCTUnwrap(parsed.recipeJSON).utf8))
        XCTAssertEqual(fromSidecar.look.lut, carried.look.lut, "XMP sidecar")
        XCTAssertEqual(parsed.recipeFingerprint, try RecipeFingerprint.fingerprint(fromSidecar))

        let look = try CanonicalJSON.canonicalLookJSON(LookSubset.extracted(from: carried))
        let saved = try CanonicalJSON.decodeLookSubset(from: Data(look.utf8))
        XCTAssertEqual(saved.applied(to: Recipe()).look.lut, carried.look.lut, "saved look")
    }

    /// A saved look applied part of the way dials the LUT's Amount, the way the panel's
    /// Amount tooltip promises for every categorical choice in a look.
    func testASavedLookAtPartialAmountDialsTheLUT() {
        let lut = LUTReference(ref: Self.ref, name: "A", tap: .display, amount: 80)
        var carried = Look()
        carried.lut = lut
        XCTAssertEqual(LookSubset.blended(from: Look(), toward: carried, amount: 25).lut?.amount,
                       20)
        var own = Look()
        own.lut = LUTReference(ref: Self.ref, name: "A", tap: .display, amount: 40)
        XCTAssertEqual(LookSubset.blended(from: own, toward: carried, amount: 50).lut?.amount,
                       60)
        XCTAssertEqual(LookSubset.blended(from: own, toward: Look(), amount: 50).lut?.amount,
                       20)
        XCTAssertEqual(LookSubset.blended(from: own, toward: carried, amount: 100).lut, lut)
    }

    // MARK: - The newer-build guard (M-01)

    /// THE WIRE KEYS ARE FROZEN. Every `pipelineVersion` 2 build decodes exactly these
    /// four, so a LUT recipe survives an older build's sidecar flush whole. A fifth key
    /// would be dropped by every one of those builds on its next write — M-01 — and must
    /// arrive with a version bump; this is the test that makes that a decision.
    func testTheLUTWireKeysAreTheOnesEveryVersion2BuildDecodes() throws {
        let data = try JSONEncoder().encode(LUTReference(ref: Self.ref, name: "n",
                                                         tap: .log, amount: 12))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["ref", "name", "tap", "amount"])
        XCTAssertEqual(currentPipelineVersion, 2,
                       "the version moved — re-read M-01 before relaxing the key pin above")
    }

    /// And the guard itself still holds for a LUT recipe: this build writes one it can
    /// represent, and declines to restate one a newer build wrote.
    func testTheNewerBuildGuardStillHoldsForALUTRecipe() throws {
        let carried = recipe(tap: .display)
        XCTAssertEqual(carried.pipelineVersion, currentPipelineVersion)
        let all: SidecarStatedFields = [.rating, .recipe]
        XCTAssertTrue(XMPSidecar.writableFields(all, documentVersion: carried.pipelineVersion)
                        .contains(.recipe))
        XCTAssertFalse(XMPSidecar.writableFields(all, documentVersion: currentPipelineVersion + 1)
                         .contains(.recipe))
    }

    // MARK: - Import and storage

    func testImportStoresTheFileByItsOwnHashBesideTheBrushStrokes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-lut-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(directory: root.appendingPathComponent("blobs"))
        let library = CreativeLUTLibrary()
        let bytes = Data(Self.redInvertingCube.utf8)

        let reference = try CreativeLUTImport.importCube(bytes, named: "Red", into: blobs,
                                                         library: library)
        XCTAssertEqual(reference.ref, BrushStrokeSet.blobRef(for: bytes))
        XCTAssertEqual(reference.name, "Red")
        XCTAssertEqual(reference.tap, .display)
        XCTAssertEqual(reference.amount, 100)
        XCTAssertEqual(blobs.data(for: reference.ref), bytes, "stored verbatim")

        // The catalog backup copies it — the same shelf, the same backup.
        let backup = root.appendingPathComponent("backup.blobs")
        XCTAssertEqual(try blobs.backUp(to: backup), 1)

        // A fresh library reaches it through the store, as the app's attached one does.
        let fresh = CreativeLUTLibrary()
        XCTAssertNil(fresh.cube(for: reference.ref), "nothing attached, nothing found")
        fresh.attach { blobs.data(for: $0) }
        XCTAssertEqual(fresh.cube(for: reference.ref), Self.cube)
    }

    func testAFileThatIsNotACubeIsRefusedAndNeverStored() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-lut-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blobs = try BlobStore(directory: root)
        XCTAssertThrowsError(try CreativeLUTImport.importCube(
            Data("LUT_1D_SIZE 4\n0 0 0\n1 1 1\n".utf8), named: "1d", into: blobs,
            library: CreativeLUTLibrary())) { error in
            XCTAssertEqual(error as? CreativeLUTImport.Failure, .notACube)
        }
        let stored = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".blob") }
        XCTAssertTrue(stored.isEmpty, "a refused file was stored anyway: \(stored)")
    }
}
