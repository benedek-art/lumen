#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

/// Exercise the renderer, not a mirror of its dependency predicate: source preparation
/// and retained alpha keys must agree with the selection the reference actually lends.
final class MaskReferencePipelineTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
                                              .outputColorSpace: NSNull(),
                                              .workingFormat: CIFormat.RGBAf])

    private final class MaskReferenceFixtureSource: ImageSource {
        let url = URL(fileURLWithPath: "/tmp/lumen-mask-reference-regression.tif")
        let nativeLongEdge: Double
        let nativePixelSize: (width: Int, height: Int)
        let asShotTemperature = 5500.0
        let asShotTint = 0.0
        let captureMetadata: CaptureMetadata
        let statisticsProvenance = RawTruth.provenance(isRenderedFile: true)
        private let image: CIImage

        init(longEdge: Int, pixelGenerator: ((Double, Double) -> RGB)? = nil) {
            nativeLongEdge = Double(longEdge)
            nativePixelSize = (longEdge, longEdge / 2)
            captureMetadata = CaptureMetadata(asShotTemperature: 5500, asShotTint: 0,
                                               decoderVersion: nil,
                                               pixelSize: nativePixelSize)
            let pixels = ImageBuffer(width: longEdge, height: longEdge / 2) { u, v in
                pixelGenerator?(u, v) ?? RGB(gray: pow(2, -8 + u * 10))
            }
            image = pixels.pixels.withUnsafeBytes {
                CIImage(bitmapData: Data($0), bytesPerRow: longEdge * 16,
                        size: CGSize(width: longEdge, height: longEdge / 2),
                        format: .RGBAf, colorSpace: nil)
            }
        }

        func decode(recipe: Recipe, draft: Bool, scaleFactor: Double) -> CIImage? {
            image.transformed(by: CGAffineTransform(scaleX: scaleFactor, y: scaleFactor))
        }
    }

    private func reference(_ id: String, invert: Bool = false) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .maskRef, invert: invert)
        c.maskRef = id
        return c
    }

    private func band() -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .lumaRange)
        c.lo = 0.4; c.hi = 0.75; c.smooth = 0
        return c
    }

    private func polygon(left: Bool) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .polygon)
        let x = left ? 0.05 : 0.55
        c.path = [[x, 0.05], [x + 0.4, 0.05], [x + 0.4, 0.95], [x, 0.95]]
        return c
    }

    private func recipe(donor: MaskComponent, transitive: Bool = false,
                        inverted: Bool = false) -> Recipe {
        var leaf = Mask(id: "donor", enabled: false, components: [donor])
        leaf.invert = inverted
        let middle = Mask(id: "middle", enabled: false,
                          components: [reference("donor", invert: transitive)])
        var borrower = Mask(id: "borrower", components: [
            reference(transitive ? "middle" : "donor", invert: transitive)
        ])
        borrower.adjust.exposure = 1
        var r = Recipe()
        r.develop.denoise.mode = .off
        r.masks = transitive ? [leaf, middle, borrower] : [leaf, borrower]
        return r
    }

    private func pixels(_ renderer: PipelineRenderer, _ source: MaskReferenceFixtureSource,
                        _ recipe: Recipe,
                        strokes: [String: BrushStrokeSet] = [:]) throws -> ImageBuffer {
        let image = try renderer.exportedImage(source: source, recipe: recipe,
                                               using: ExportRecipe(name: "Mask test"),
                                               strokeSets: strokes)
        let out = try XCTUnwrap(PipelineRenderer.buffer(from: image, context: context))
        XCTAssertGreaterThan(out.pixels.max() ?? 0, 0.1,
                             "the graphics context must actually evaluate the image")
        return out
    }

    private func worst(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        guard a.width == b.width, a.height == b.height else { return .infinity }
        return zip(a.pixels, b.pixels).map { abs(Double($0) - Double($1)) }.max() ?? 0
    }

    func testDisabledImageDependentDonorKeepsItsSelectionThroughInvertedReferences() throws {
        let source = MaskReferenceFixtureSource(longEdge: 256)
        for transitive in [false, true] {
            for inverted in [false, true] {
                let disabled = recipe(donor: band(), transitive: transitive,
                                      inverted: inverted)
                var enabled = disabled
                enabled.masks[0].enabled = true
                let actual = try XCTUnwrap(PipelineRenderer().renderMaskAlpha(
                    source: source, recipe: disabled, maskID: "borrower"))
                let expected = try XCTUnwrap(PipelineRenderer().renderMaskAlpha(
                    source: source, recipe: enabled, maskID: "borrower"))
                XCTAssertGreaterThan(expected.values.max() ?? 0, 0.9)
                XCTAssertLessThan(expected.values.min() ?? 1, 0.1)
                let delta = zip(actual.values, expected.values).map { abs($0 - $1) }.max()!
                XCTAssertEqual(delta, 0, accuracy: 1e-6,
                               "disabled donor changed borrowed alpha; transitive=\(transitive), inverted=\(inverted)")
            }
        }
    }

    func testOverlayOfDisabledImageDependentMaskStillBuildsItsSource() throws {
        let source = MaskReferenceFixtureSource(longEdge: 256)
        var r = Recipe()
        r.masks = [Mask(id: "donor", enabled: false, components: [band()])]
        let disabled = try XCTUnwrap(PipelineRenderer().renderMaskAlpha(
            source: source, recipe: r, maskID: "donor", longEdge: 96))
        r.masks[0].enabled = true
        let enabled = try XCTUnwrap(PipelineRenderer().renderMaskAlpha(
            source: source, recipe: r, maskID: "donor", longEdge: 96))
        XCTAssertGreaterThan(enabled.values.max() ?? 0, 0.9)
        XCTAssertTrue(disabled.values == enabled.values,
                      "a disabled row's thumbnail must still show its exact selection")
    }

    func testDisabledDonorSourceIsPreparedForSmallAndFullResolutionExports() throws {
        for longEdge in [256, 1152] {
            let source = MaskReferenceFixtureSource(longEdge: longEdge)
            let disabled = recipe(donor: band(), transitive: true, inverted: true)
            var enabled = disabled
            enabled.masks[0].enabled = true
            let actual = try pixels(PipelineRenderer(), source, disabled)
            let expected = try pixels(PipelineRenderer(), source, enabled)
            XCTAssertEqual(actual.width, longEdge)
            XCTAssertLessThan(worst(actual, expected), 1e-6,
                              "disabled donor changed native \(longEdge)-pixel export")
        }
    }

    func testDonorGeometryEditInvalidatesBorrowerInRepeatedSmallNativeExport() throws {
        let source = MaskReferenceFixtureSource(longEdge: 256)
        for transitive in [false, true] {
            var r = recipe(donor: polygon(left: true), transitive: transitive)
            let held = PipelineRenderer()
            let before = try pixels(held, source, r)
            r.masks[0].components = [polygon(left: false)]
            let after = try pixels(held, source, r)
            let fresh = try pixels(PipelineRenderer(), source, r)
            XCTAssertGreaterThan(worst(before, fresh), 0.05,
                                 "the donor edit must visibly change this fixture")
            XCTAssertLessThan(worst(after, fresh), 1e-6,
                              "same-renderer final export kept old referenced geometry; transitive=\(transitive)")
        }
    }

    func testReferencedBrushArrivalInvalidatesBorrowerWithoutChangingItsRecipe() throws {
        let source = MaskReferenceFixtureSource(longEdge: 128)
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:donor"
        let r = recipe(donor: brush, transitive: true)
        let held = PipelineRenderer()
        let before = try pixels(held, source, r)
        let strokes = ["blob:donor": BrushStrokeSet(strokes: [
            BrushStroke(points: [BrushPoint(x: 0.3, y: 0.5)], size: 0.3,
                        feather: 0, flow: 100, density: 100)
        ])]
        let after = try pixels(held, source, r, strokes: strokes)
        let fresh = try pixels(PipelineRenderer(), source, r, strokes: strokes)
        XCTAssertGreaterThan(worst(before, fresh), 0.01)
        XCTAssertLessThan(worst(after, fresh), 1e-6,
                          "arriving strokes behind a reference reused its empty alpha")
    }

    func testReplacingSameKindMatteInvalidatesBorrower() throws {
        let source = MaskReferenceFixtureSource(longEdge: 128)
        let r = recipe(donor: MaskComponent(op: .add, kind: .aiSubject), transitive: true)
        let held = PipelineRenderer()
        let left = Plane(width: 128, height: 64) { u, _ in u < 0.5 ? 1 : 0 }
        let right = left.map { 1 - $0 }
        held.storeMattes(["aiSubject": left], requested: ["aiSubject"], for: source.url)
        let before = try pixels(held, source, r)
        held.storeMattes(["aiSubject": right], requested: ["aiSubject"], for: source.url)
        let after = try pixels(held, source, r)
        let freshRenderer = PipelineRenderer()
        freshRenderer.storeMattes(["aiSubject": right], requested: ["aiSubject"], for: source.url)
        let fresh = try pixels(freshRenderer, source, r)
        XCTAssertGreaterThan(worst(before, fresh), 0.05)
        XCTAssertLessThan(worst(after, fresh), 1e-6,
                          "replacement matte pixels must invalidate an exact alpha hit")
    }

    func testCycleWithAnImageDependentSelectionIsFiniteAndPreservesThatSelection() throws {
        let source = MaskReferenceFixtureSource(longEdge: 128)
        var r = recipe(donor: band(), transitive: true, inverted: true)
        let acyclic = r
        r.masks[0].components.append(reference("borrower", invert: true))
        let actual = try XCTUnwrap(PipelineRenderer().renderMaskAlpha(
            source: source, recipe: r, maskID: "borrower"))
        let expected = try XCTUnwrap(PipelineRenderer().renderMaskAlpha(
            source: source, recipe: acyclic, maskID: "borrower"))
        XCTAssertGreaterThan(expected.values.max() ?? 0, 0.9)
        XCTAssertLessThan(expected.values.min() ?? 1, 0.1)
        XCTAssertTrue(actual.values == expected.values)
        let closure = MaskDependency.closure(of: r.masks.last!, in: r.masks)
        XCTAssertEqual(closure.count, 3)
        XCTAssertNotNil(PipelineRenderer.maskSelectionFingerprint(closure))
    }

    func testSwitchedOffGroupStillSuppliesReferencedImageSelection() throws {
        let source = MaskReferenceFixtureSource(longEdge: 128)
        var r = recipe(donor: band(), transitive: true)
        r.masks[0].enabled = true
        r.masks[0].group = "sources"
        r.maskGroups = [MaskGroup(id: "sources", name: "Sources", enabled: false)]
        let disabled = try pixels(PipelineRenderer(), source, r)
        r.maskGroups[0].enabled = true
        let enabled = try pixels(PipelineRenderer(), source, r)
        XCTAssertLessThan(worst(disabled, enabled), 1e-6)
    }

    func testSourcePredicateIncludesEveryImageReaderAutomaskAndRefineThroughReferences() {
        let kinds: [MaskKind] = [.lumaRange, .colorRange, .similarity, .similarityLine, .luminosity]
        for kind in kinds {
            let r = recipe(donor: MaskComponent(op: .add, kind: kind), transitive: true)
            XCTAssertTrue(PipelineRenderer.maskReadsPicture(r.masks.last!, in: r.masks,
                strokeSets: [:], longEdge: 256), "referenced \(kind) needs source pixels")
        }
        var r = recipe(donor: polygon(left: true), transitive: true)
        XCTAssertFalse(PipelineRenderer.maskReadsPicture(r.masks.last!, in: r.masks,
            strokeSets: [:], longEdge: 256))
        r.masks[0].refine.feather = 100
        XCTAssertTrue(PipelineRenderer.maskReadsPicture(r.masks.last!, in: r.masks,
            strokeSets: [:], longEdge: 256))

        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:automask"
        r = recipe(donor: brush, transitive: true)
        let strokes = ["blob:automask": BrushStrokeSet(strokes: [
            BrushStroke(points: [BrushPoint(x: 0.3, y: 0.5)], automask: true)
        ])]
        XCTAssertTrue(PipelineRenderer.maskReadsPicture(r.masks.last!, in: r.masks,
            strokeSets: strokes, longEdge: 256))
        XCTAssertFalse(PipelineRenderer.maskReadsPicture(r.masks.last!, in: r.masks,
            strokeSets: [:], longEdge: 256))
    }

    func testSelectionKeyIgnoresAdjustmentAndCosmeticEditsButTracksDonorSelection() throws {
        var r = recipe(donor: polygon(left: true), transitive: true)
        func key(_ recipe: Recipe) throws -> String {
            try XCTUnwrap(PipelineRenderer.maskSelectionFingerprint(
                MaskDependency.closure(of: recipe.masks.last!, in: recipe.masks)))
        }
        let original = try key(r)
        for i in r.masks.indices {
            r.masks[i].name = "Renamed"
            r.masks[i].amount = 25
            r.masks[i].enabled.toggle()
            r.masks[i].adjust.exposure = 2
            r.masks[i].blend = .color
            r.masks[i].group = "folder"
        }
        XCTAssertEqual(try key(r), original)
        r.masks.insert(Mask(id: "unrelated", components: [band()]), at: 0)
        XCTAssertEqual(try key(r), original)
        for change in 0..<3 {
            var edited = r
            switch change {
            case 0: edited.masks[1].components = [polygon(left: false)]
            case 1: edited.masks[1].invert.toggle()
            default: edited.masks[1].refine.blur = 50
            }
            XCTAssertNotEqual(try key(edited), original)
        }
    }

    func testOrdinaryMaskReusesItsAlphaWhenOnlyItsAdjustmentChanges() throws {
        let source = MaskReferenceFixtureSource(longEdge: 128)
        var r = Recipe()
        r.develop.denoise.mode = .off
        var ordinary = Mask(id: "ordinary", components: [polygon(left: true)])
        ordinary.adjust.exposure = 1
        r.masks = [ordinary]
        let held = PipelineRenderer()
        let before = try pixels(held, source, r)
        let bakes = MaskRasterCache.currentStats.bakes
        let repeated = try pixels(held, source, r)
        XCTAssertEqual(worst(before, repeated), 0)
        XCTAssertEqual(MaskRasterCache.currentStats.bakes, bakes)
        r.masks[0].adjust.exposure = 2
        let changed = try pixels(held, source, r)
        XCTAssertGreaterThan(worst(before, changed), 0.01)
        XCTAssertEqual(MaskRasterCache.currentStats.bakes, bakes,
                       "adjusting a mask does not change its selection")
    }

    func testForgettingAnotherSourceKeepsGeometryBrushPlanes() throws {
        // Browsing to a neighbour, or prefetching one, used to run forgetMattes for
        // THAT file, and forgetMattes cleared every photo's brush planes. A brush
        // without Automask is geometry: the next render must resume the held plane,
        // not repaint the whole set.
        let source = MaskReferenceFixtureSource(longEdge: 128)
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:geometry-brush-survives"
        var mask = Mask(id: "painted-geometry", components: [brush])
        mask.adjust.exposure = 1
        var r = Recipe()
        r.develop.denoise.mode = .off
        r.masks = [mask]
        let strokes = ["blob:geometry-brush-survives": BrushStrokeSet(strokes: (0..<6).map { i in
            BrushStroke(points: [BrushPoint(x: 0.2 + 0.1 * Double(i), y: 0.5)], size: 0.1,
                        feather: 50, flow: 100, density: 100, automask: false)
        })]
        let held = PipelineRenderer()
        let before = try pixels(held, source, r, strokes: strokes)
        let stats = BrushPlaneCache.currentStats
        held.forgetMattes(for: URL(fileURLWithPath: "/tmp/lumen-some-other-photograph.tif"))
        let after = try pixels(held, source, r, strokes: strokes)
        let now = BrushPlaneCache.currentStats
        XCTAssertEqual(now.repainted, stats.repainted,
                       "another file's source change repainted an untouched geometry brush")
        XCTAssertEqual(now.strokesPainted, stats.strokesPainted)
        XCTAssertGreaterThan(now.resumed, stats.resumed,
                             "the raster rebake must have asked the brush cache, or this proves nothing")
        XCTAssertEqual(worst(before, after), 0)
    }

    func testForgettingSameURLSourceAlsoForgetsAutomaskedBrushPixels() throws {
        let original = MaskReferenceFixtureSource(longEdge: 128) { _, _ in RGB(gray: 0.18) }
        let replacement = MaskReferenceFixtureSource(longEdge: 128) { u, _ in RGB(gray: u < 0.5 ? 0.18 : 1.2) }
        XCTAssertEqual(original.url, replacement.url)
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:replacement-automask"
        var mask = Mask(id: "painted", components: [brush])
        mask.adjust.exposure = 1
        var r = Recipe()
        r.develop.denoise.mode = .off
        r.masks = [mask]
        let strokes = ["blob:replacement-automask": BrushStrokeSet(strokes: [
            BrushStroke(points: [BrushPoint(x: 0.4, y: 0.5)], size: 0.8,
                        feather: 0, flow: 100, density: 100, automask: true)
        ])]
        let held = PipelineRenderer()
        _ = try pixels(held, original, r, strokes: strokes)
        // The coordinator calls this when bytes change under the same path. Merely
        // clearing the finished alpha is insufficient if its brush prefix survives.
        held.forgetMattes(for: replacement.url)
        let actual = try pixels(held, replacement, r, strokes: strokes)
        let expected = try pixels(PipelineRenderer(), replacement, r, strokes: strokes)
        XCTAssertLessThan(worst(actual, expected), 1e-6,
                          "Automask retained a selection sampled from the old file")
        var ungated = strokes
        ungated["blob:replacement-automask"]!.strokes[0].automask = false
        let withoutGate = try pixels(PipelineRenderer(), replacement, r, strokes: ungated)
        XCTAssertGreaterThan(worst(expected, withoutGate), 0.05,
                             "the replacement fixture must exercise the Automask gate")
    }

    /// Astra M04 / S-10, the renderer's half. A mask holding a stroke thinner than
    /// `MaskRaster.brushFineRadiusPx` folds on a finer grid, and `rasterize` only uses a
    /// held brush plane of exactly that grid's size. Painted at the raster size, every
    /// plane this renderer held was refused and the whole set repainted inside the fold
    /// on every frame — correct pixels, and the ~140 ms settle back to seconds.
    func testAThinBrushIsHeldAtTheFoldSizeAndResumesThere() throws {
        let source = MaskReferenceFixtureSource(longEdge: 128)
        var brush = MaskComponent(op: .add, kind: .brush)
        brush.strokesRef = "blob:thin-brush-fold-size"
        var mask = Mask(id: "thin", components: [brush])
        mask.adjust.exposure = 1
        var r = Recipe()
        r.develop.denoise.mode = .off
        r.masks = [mask]
        func strokes(_ n: Int) -> [String: BrushStrokeSet] {
            ["blob:thin-brush-fold-size": BrushStrokeSet(strokes: (0..<n).map { i in
                BrushStroke(points: [BrushPoint(x: 0.1, y: 0.3 + 0.1 * Double(i)),
                                     BrushPoint(x: 0.9, y: 0.32 + 0.1 * Double(i))],
                            size: 0.004, feather: 50, flow: 40, density: 100)
            })]
        }
        let held = PipelineRenderer()
        _ = try pixels(held, source, r, strokes: strokes(3))
        let sizes = held.brushPlanes.heldPlaneSizes()
        XCTAssertFalse(sizes.isEmpty, "the render must have painted through the cache")
        let factor = MaskRaster.brushSupersampleLimit
        for size in sizes {
            XCTAssertEqual(Swift.max(size.width, size.height) % factor, 0)
            XCTAssertGreaterThanOrEqual(Swift.max(size.width, size.height), factor * 100,
                                        "held at the raster size, not the fold size: "
                                        + "the fold refuses it and repaints every stroke")
        }
        let stats = BrushPlaneCache.currentStats
        let appended = try pixels(held, source, r, strokes: strokes(4))
        let now = BrushPlaneCache.currentStats
        XCTAssertEqual(now.strokesPainted - stats.strokesPainted, 1)
        let cold = try pixels(PipelineRenderer(), source, r, strokes: strokes(4))
        XCTAssertEqual(worst(appended, cold), 0, accuracy: 1e-6)
    }
}
#endif
