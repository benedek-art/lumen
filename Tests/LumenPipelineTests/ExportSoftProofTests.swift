// ExportSoftProofTests.swift
// The proof the photographer approves has to be the proof the file gets.
//
// `PipelineRenderer.exportedImage` built its `RenderPlan` with no `softProof:`
// argument. So ⇧S proofed the loupe to the destination — perceptual chroma compression
// into a print's gamut, the flat paper simulation, the flag over what will not fit —
// and the export rendered against the working space, handed that to an encoder, and
// let ColorSync clip each channel independently at conversion time. Per-channel
// clipping is the mapping the perceptual intent exists to replace: it rotates a
// saturated blue toward purple rather than desaturating it along its own hue. Two
// pictures, one approved and the other delivered, with nothing on any surface saying
// which was which.
//
// The lock this file puts on that is structural rather than anecdotal. `previewPlan`
// and `exportPlan` are two functions in one place, and the first test below builds BOTH
// from one settings value and compares the proof each carries. A future edit that drops
// the argument from one of them cannot pass — which is the property the old shape could
// not have, because the two plans were spelled inline in two functions four hundred
// lines apart and nothing could hold them next to each other.
//
// The semantics of what `deliveredProof` drops, and why, are measured in
// `SoftProofExportTests` over in LumenCore, where they run on every lane rather than
// only where Core Image exists.

#if os(macOS)

import CoreImage
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class ExportSoftProofTests: XCTestCase {

    private let context = CIContext(options: [.workingFormat: CIFormat.RGBAh,
                                              .cacheIntermediates: false])

    /// A source that hands back a known picture at any scale, so nothing the decode
    /// does can explain a difference an assertion finds.
    private final class StubSource: ImageSource {
        let url = URL(fileURLWithPath: "/dev/null/export-soft-proof")
        let asShotTemperature: Double = 5500
        let asShotTint: Double = 0
        // Numbers of unknown origin: this stub has no decoder behind it, and claiming
        // `.sceneLinearDecode` would put a decoder's label on them.
        let statisticsProvenance: RawStatistics.Provenance = .unspecified
        private let image: CIImage
        init(_ image: CIImage) { self.image = image }
        var nativePixelSize: (width: Int, height: Int) {
            (Int(image.extent.width), Int(image.extent.height))
        }
        var nativeLongEdge: Double { Double(max(image.extent.width, image.extent.height)) }
        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? { image }
        var captureMetadata: CaptureMetadata {
            CaptureMetadata(asShotTemperature: asShotTemperature, asShotTint: asShotTint,
                            decoderVersion: nil, pixelSize: nativePixelSize)
        }
    }

    /// The proof a photographer checking a print would actually have on: sRGB
    /// destination, perceptual intent, warning on, paper simulated.
    private let viewing = SoftProof(enabled: true, space: .srgb, intent: .perceptual,
                                    showGamutWarning: true, simulatePaperWhite: true)

    /// A default recipe denoises; that stage is not the subject of anything here and it
    /// costs real time at export size.
    private var quietRecipe: Recipe {
        var recipe = Recipe()
        recipe.develop.denoise.mode = .off
        return recipe
    }

    // MARK: - The two plans cannot drift apart

    /// ONE settings value, both plans, one comparison. This is the test the defect could
    /// not have survived.
    ///
    /// The three fields compared are the three that are a decision about DATA — is there
    /// a proof at all, which destination, and what happens to what does not fit. The two
    /// that deliberately differ are asserted below, in the tests named for them, so that
    /// a blanket equality here could not quietly bake an instrument into a file.
    func testTheExportPlanCarriesThePreviewsProof() throws {
        let renderer = PipelineRenderer()
        let source = StubSource(ciImage(from: ImageBuffer(width: 8, height: 8) { _, _ in
            RGB(gray: 0.18)
        }))
        let recipe = quietRecipe

        let preview = renderer.previewPlan(source: source, recipe: recipe, draft: false,
                                           softProof: viewing)
        let export = renderer.exportPlan(source: source, recipe: recipe,
                                         using: ExportRecipe(name: "web"),
                                         softProof: viewing)

        let shown = try XCTUnwrap(preview.softProof?.settings,
                                  "the preview plan carries no proof, so every "
                                      + "comparison below would be between two absences")
        XCTAssertNotNil(export.softProof,
                        "the export plan carries no proof at all: the loupe is proofing "
                            + "to \(viewing.space.displayName) and the file is not")
        let written = try XCTUnwrap(export.softProof?.settings)
        XCTAssertEqual(written.enabled, shown.enabled)
        XCTAssertEqual(written.space, shown.space,
                       "the file is being proofed to a different destination than the "
                           + "picture that was approved")
        XCTAssertEqual(written.intent, shown.intent,
                       "the intent decides what happens to the colours that do not fit; "
                           + "the two paths must not choose differently")

        // And off is off, on both sides: an export with no proof must build the plan it
        // built before this argument existed.
        XCTAssertNil(renderer.exportPlan(source: source, recipe: recipe,
                                         using: ExportRecipe(name: "web"),
                                         softProof: nil).softProof)
        XCTAssertNil(renderer.exportPlan(source: source, recipe: recipe,
                                         using: ExportRecipe(name: "web"),
                                         softProof: SoftProof(enabled: false)).softProof)
    }

    /// The gamut warning is a screen instrument and it must never be in a file. The two
    /// halves are the plan's state and the delivered pixels, because a stage can be
    /// correctly configured and still reach the picture by another route.
    func testTheGamutWarningIsNeverBakedIntoADeliveredFile() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let renderer = PipelineRenderer()
        let width = 16, height = 4
        // Left half a saturated Rec.2020 green sRGB cannot store, right half mid-grey.
        let frame = ImageBuffer(width: width, height: height) { u, _ in
            u < 0.5 ? RGB(0.02, 1.1, 0.02) : RGB(gray: 0.18)
        }
        let source = StubSource(ciImage(from: frame))
        let export = renderer.exportPlan(source: source, recipe: quietRecipe,
                                         using: ExportRecipe(name: "web"),
                                         softProof: viewing)
        XCTAssertEqual(export.softProof?.settings.showGamutWarning, false,
                       "the delivery is carrying the flag")
        XCTAssertNil(export.finishLUTBeforeProof,
                     "the second table exists only to draw the flag, and a delivery "
                         + "that keeps it can still be made to draw it")

        let delivered = try renderer.exportedImage(source: source, recipe: quietRecipe,
                                                   using: ExportRecipe(name: "web"),
                                                   softProof: viewing)
        let pixels = try XCTUnwrap(readBack(delivered, width: width, height: height))
        let flag = SoftProof.warningColor
        XCTAssertGreaterThan(pixels[2, 2].maxAbsDifference(flag), 0.05,
                             "the unstorable half of the delivered file is flat grey "
                                 + "where the photograph was: \(pixels[2, 2])")
    }

    /// The paper simulation is the other instrument, and the one that is easy to mistake
    /// for a conversion. It compresses the picture into the print's own range so the
    /// screen can show how flat the print will look; the paper then does that
    /// compression itself, physically, so a file that arrives with it applied is printed
    /// flat twice.
    func testThePaperSimulationIsNeverBakedIntoADeliveredFile() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let renderer = PipelineRenderer()
        let width = 8, height = 4
        // A bright neutral — two stops over mid-grey — because that is where the paper
        // simulation does its visible work: it maps [0, 1] onto
        // [`SoftProof.inkBlack`, `SoftProof.paperWhite`], so the gap it opens grows with
        // the value. Bright rather than blown, so the proof's own clamp at display white
        // cannot be mistaken for the simulation.
        let source = StubSource(ciImage(from: ImageBuffer(width: width, height: height) {
            _, _ in RGB(gray: 0.18 * 4)
        }))
        let export = renderer.exportPlan(source: source, recipe: quietRecipe,
                                         using: ExportRecipe(name: "print"),
                                         softProof: viewing)
        XCTAssertEqual(export.softProof?.settings.simulatePaperWhite, false)

        let recipeOut = ExportRecipe(name: "print")
        let proofed = try renderer.exportedImage(source: source, recipe: quietRecipe,
                                                 using: recipeOut, softProof: viewing)
        let plain = try renderer.exportedImage(source: source, recipe: quietRecipe,
                                               using: recipeOut, softProof: nil)
        let a = try XCTUnwrap(readBack(proofed, width: width, height: height))
        let b = try XCTUnwrap(readBack(plain, width: width, height: height))
        // A neutral is inside sRGB, so the gamut map has nothing to do to it and the
        // ONLY thing that could move it is the paper simulation. That is what makes this
        // frame the right instrument for this question.
        XCTAssertGreaterThan(b[4, 2].g, 0.4,
                             "the frame is too dark for the simulation to be visible in "
                                 + "it — brighten it rather than loosening the tolerance")
        let simulated = SoftProof.inkBlack
            + b[4, 2].g * (SoftProof.paperWhite - SoftProof.inkBlack)
        XCTAssertGreaterThan(abs(a[4, 2].g - simulated), 0.02,
                             "the delivered value \(a[4, 2].g) is the print's own range "
                                 + "(\(simulated)) rather than the file's")
        XCTAssertEqual(a[4, 2].g, b[4, 2].g, accuracy: 0.01,
                       "the delivered neutral moved: \(a[4, 2].g) against an unproofed "
                           + "\(b[4, 2].g)")
    }

    /// And the half that would pass for free if `deliveredProof` returned nil: the
    /// transform has to REACH the file. A colour sRGB cannot store must come out
    /// different, and a neutral must come out the same.
    func testTheProofsTransformReachesTheDeliveredPixels() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let renderer = PipelineRenderer()
        let width = 16, height = 4
        let source = StubSource(ciImage(from: ImageBuffer(width: width, height: height) {
            u, _ in u < 0.5 ? RGB(0.02, 1.1, 0.02) : RGB(gray: 0.18)
        }))
        let recipeOut = ExportRecipe(name: "web")
        // The warning off, so what is measured is the map and not the flag.
        var mapping = viewing
        mapping.showGamutWarning = false

        let proofed = try renderer.exportedImage(source: source, recipe: quietRecipe,
                                                 using: recipeOut, softProof: mapping)
        let plain = try renderer.exportedImage(source: source, recipe: quietRecipe,
                                               using: recipeOut, softProof: nil)
        let a = try XCTUnwrap(readBack(proofed, width: width, height: height))
        let b = try XCTUnwrap(readBack(plain, width: width, height: height))

        XCTAssertGreaterThan(a[2, 2].maxAbsDifference(b[2, 2]), 0.02,
                             "the delivered file rendered a colour sRGB cannot hold "
                                 + "exactly as the unproofed export did — the proof "
                                 + "reached the screen and not the file")
        XCTAssertLessThan(a[13, 2].maxAbsDifference(b[13, 2]), 0.01,
                          "the proof moved an in-gamut neutral in the delivery")
    }

    /// Nothing moves for anybody who is not proofing. Every existing export golden in
    /// this suite depends on it, and this states it once rather than leaving it to be
    /// inferred from their continuing to pass.
    func testAnUnproofedExportIsUnchanged() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let renderer = PipelineRenderer()
        let width = 16, height = 4
        let source = StubSource(ciImage(from: ImageBuffer(width: width, height: height) {
            u, v in RGB(0.18 * (0.2 + u), 0.18 * (0.2 + u) * 0.9, 0.18 * (0.2 + v))
        }))
        let recipeOut = ExportRecipe(name: "web")
        let withArgument = try renderer.exportedImage(source: source, recipe: quietRecipe,
                                                      using: recipeOut, softProof: nil)
        let withoutArgument = try renderer.exportedImage(source: source,
                                                         recipe: quietRecipe,
                                                         using: recipeOut)
        let a = try XCTUnwrap(readBack(withArgument, width: width, height: height))
        let b = try XCTUnwrap(readBack(withoutArgument, width: width, height: height))
        for x in 0..<width {
            XCTAssertEqual(a[x, 2].maxAbsDifference(b[x, 2]), 0, accuracy: 1e-6,
                           "column \(x) moved on a path with no proof on it")
        }
    }

    // MARK: - Nothing is left half-written

    /// The delivery lands under its own name and takes its scaffolding with it.
    ///
    /// An export folder holding a `.part` file after a clean run means the rename did
    /// not happen and the encoder wrote wherever it liked; one holding two files means
    /// the temp was copied rather than moved.
    func testTheDeliveryLandsUnderItsOwnNameAndLeavesNoTemp() throws {
        try XCTSkipUnless(KernelLibrary.isAvailable, "kernels unavailable")
        let renderer = PipelineRenderer()
        let source = StubSource(ciImage(from: ImageBuffer(width: 8, height: 8) { _, _ in
            RGB(gray: 0.18)
        }))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumen-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("frame.jpg")
        _ = try renderer.export(source: source, recipe: quietRecipe, to: destination,
                                using: ExportRecipe(name: "web"))

        let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(written, ["frame.jpg"],
                       "the export folder holds \(written) — a clean run leaves the "
                           + "delivery and nothing else")
        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size]
        XCTAssertGreaterThan((size as? Int) ?? 0, 0, "the delivery is empty")
    }

    /// Where the encoder writes, and the three properties that make the rename safe.
    ///
    /// A SIBLING, because a move across volumes is a copy and a copy is the
    /// half-written file again with an extra step. HIDDEN, because a photographer
    /// watching a folder fill should not see files appear under names they did not ask
    /// for. UNIQUE, because the whole point of the multi-recipe sheet is several
    /// recipes writing one photograph at once, and `ExportRecipe.disambiguated` keeps
    /// their deliveries apart but knows nothing about temps.
    func testTheTempFileIsAUniqueHiddenSibling() {
        let destination = URL(fileURLWithPath: "/Volumes/Deliveries/2026/frame.jpg")
        let a = PipelineRenderer.partialURL(for: destination)
        let b = PipelineRenderer.partialURL(for: destination)

        XCTAssertEqual(a.deletingLastPathComponent(),
                       destination.deletingLastPathComponent(),
                       "a temp outside the destination's directory makes the move a "
                           + "cross-volume copy")
        XCTAssertTrue(a.lastPathComponent.hasPrefix("."),
                      "the temp is visible in the export folder: \(a.lastPathComponent)")
        XCTAssertNotEqual(a.lastPathComponent, destination.lastPathComponent)
        XCTAssertNotEqual(a, b, "two recipes writing one photograph collide on the temp")
    }

    // MARK: - Frame helpers

    private func ciImage(from buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf, colorSpace: nil)
    }

    /// Read back in the WORKING space (`colorSpace: nil`), which is where the proof's
    /// domain and range both live — a read through sRGB would clip the very colours
    /// these tests are asking about.
    private func readBack(_ image: CIImage, width: Int, height: Int) -> ImageBuffer? {
        XCTAssertEqual(image.extent.width, CGFloat(width), accuracy: 0.5)
        XCTAssertEqual(image.extent.height, CGFloat(height), accuracy: 0.5)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let bounds = CGRect(x: image.extent.origin.x, y: image.extent.origin.y,
                            width: CGFloat(width), height: CGFloat(height))
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: nil)
        }
        // An all-zero buffer is what a render that wrote nothing leaves behind, and it
        // satisfies a surprising number of comparisons — "the neutral did not move"
        // reads 0 == 0 and passes at every pixel. Alpha is excluded from the test for
        // the reason `KernelGoldenTests.readBack` states: a dead read leaves alpha at 0
        // too, while a live one fills it.
        let wroteSomething = stride(from: 0, to: pixels.count, by: 4).contains {
            pixels[$0] != 0 || pixels[$0 + 1] != 0 || pixels[$0 + 2] != 0
        }
        guard wroteSomething else {
            XCTFail("the render produced an all-zero frame — comparing against it would "
                        + "pass by accident")
            return nil
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

#endif
