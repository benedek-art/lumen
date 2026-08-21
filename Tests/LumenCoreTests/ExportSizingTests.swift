import XCTest
@testable import LumenCore

/// What the exported file actually measures. The resize modes had no test, and the
/// composition `export()` performs — crop, then a long-edge scale derived from
/// `targetSize` — had never been checked against the size the sheet promises.
final class ExportSizingTests: XCTestCase {

    private func recipe(_ mode: ResizeMode, _ value: Double,
                        upscale: Bool = false) -> ExportRecipe {
        var r = ExportRecipe(name: "t", format: .jpeg)
        r.resizeMode = mode
        r.resizeValue = value
        r.allowUpscale = upscale
        return r
    }

    // MARK: Each mode means what it says

    func testEachModeHitsItsOwnAxis() {
        let landscape = (w: 6000, h: 4000)
        let portrait = (w: 4000, h: 6000)

        for (w, h) in [landscape, portrait] {
            let long = recipe(.longEdge, 2048).targetSize(sourceWidth: w, sourceHeight: h)
            XCTAssertEqual(Swift.max(long.width, long.height), 2048, "long edge on \(w)x\(h)")

            let short = recipe(.shortEdge, 1200).targetSize(sourceWidth: w, sourceHeight: h)
            XCTAssertEqual(Swift.min(short.width, short.height), 1200, "short edge on \(w)x\(h)")

            let width = recipe(.width, 1600).targetSize(sourceWidth: w, sourceHeight: h)
            XCTAssertEqual(width.width, 1600, "width on \(w)x\(h)")

            let height = recipe(.height, 1600).targetSize(sourceWidth: w, sourceHeight: h)
            XCTAssertEqual(height.height, 1600, "height on \(w)x\(h)")
        }
    }

    func testMegapixelsLandsOnTheRequestedCount() {
        for (w, h) in [(6000, 4000), (4000, 6000), (5000, 5000), (7728, 5152)] {
            for target in [1.0, 4.0, 12.0] {
                let size = recipe(.megapixels, target).targetSize(sourceWidth: w,
                                                                  sourceHeight: h)
                let actual = Double(size.width * size.height) / 1_000_000
                XCTAssertEqual(actual, target, accuracy: target * 0.01,
                               "\(w)x\(h) at \(target) MP produced \(actual) MP")
            }
        }
    }

    func testResizingHoldsTheAspectRatio() {
        for mode in ResizeMode.allCases where mode != .none {
            for (w, h) in [(6000, 4000), (4000, 6000), (7728, 5152)] {
                let size = recipe(mode, mode == .megapixels ? 6 : 1500)
                    .targetSize(sourceWidth: w, sourceHeight: h)
                let before = Double(w) / Double(h)
                let after = Double(size.width) / Double(size.height)
                // A pixel of rounding on the short edge of a small output is worth more
                // than 0.1%, so the bar is one pixel rather than a ratio.
                let implied = (Double(size.width) / before).rounded()
                XCTAssertLessThanOrEqual(abs(implied - Double(size.height)), 1,
                                         "\(mode) on \(w)x\(h): \(size) is not \(before)")
                XCTAssertEqual(after, before, accuracy: before * 0.01)
            }
        }
    }

    func testUpscaleIsRefusedUnlessAskedFor() {
        let refused = recipe(.longEdge, 12000).targetSize(sourceWidth: 6000, sourceHeight: 4000)
        XCTAssertEqual(refused.width, 6000)
        XCTAssertEqual(refused.height, 4000)

        let allowed = recipe(.longEdge, 12000, upscale: true)
            .targetSize(sourceWidth: 6000, sourceHeight: 4000)
        XCTAssertEqual(allowed.width, 12000)
        XCTAssertEqual(allowed.height, 8000)
    }

    func testDegenerateInputsDoNotProduceAZeroPixelFile() {
        for mode in ResizeMode.allCases {
            for value in [0.0, -5.0, Double.nan, 1e12] {
                let size = recipe(mode, value).targetSize(sourceWidth: 6000, sourceHeight: 4000)
                XCTAssertGreaterThanOrEqual(size.width, 1, "\(mode) at \(value)")
                XCTAssertGreaterThanOrEqual(size.height, 1, "\(mode) at \(value)")
            }
            let zero = recipe(mode, 2048).targetSize(sourceWidth: 0, sourceHeight: 0)
            XCTAssertGreaterThanOrEqual(zero.width, 0)
        }
    }

    // MARK: The composition `export()` actually performs

    /// `export()` does not resize to `targetSize` directly. It crops, asks `targetSize`
    /// for the pixel dimensions, and then hands `applyGeometry` the LONG EDGE of that
    /// answer as a scale target. Those are only the same thing if the long edge recovers
    /// the scale — which it does, but nothing checked it, and the crop and the straighten
    /// angle both feed the extent it is computed from.
    func testTheLongEdgeHandoffReproducesThePromisedSize() {
        for (sw, sh) in [(6000.0, 4000.0), (4000.0, 6000.0), (7728.0, 5152.0)] {
            for angle in [0.0, 4.5, -11.0] {
                for crop in [Crop(), Crop(x: 0.1, y: 0.2, w: 0.6, h: 0.5),
                             Crop(x: 0, y: 0, w: 0.3, h: 0.9)] {
                    for mode in ResizeMode.allCases {
                        var geometry = Geometry()
                        geometry.angle = angle
                        geometry.crop = crop
                        let croppedOnly = CropGeometry.resolve(sourceWidth: sw,
                                                               sourceHeight: sh,
                                                               geometry: geometry)
                        let export = recipe(mode, mode == .megapixels ? 6 : 1500)
                        let promised = export.targetSize(
                            sourceWidth: Int(croppedOnly.width),
                            sourceHeight: Int(croppedOnly.height))

                        // What `export()` then asks the renderer for.
                        let handoff = Swift.max(promised.width, promised.height)
                        let resolved = CropGeometry.resolve(
                            sourceWidth: sw, sourceHeight: sh, geometry: geometry,
                            targetLongEdge: mode == .none ? nil : handoff,
                            allowUpscale: export.allowUpscale)

                        let label = "\(sw)x\(sh) at \(angle)° \(mode) crop \(crop)"
                        XCTAssertLessThanOrEqual(
                            abs(resolved.outputWidth - promised.width), 1,
                            "\(label): promised \(promised.width) wide, renders "
                                + "\(resolved.outputWidth)")
                        XCTAssertLessThanOrEqual(
                            abs(resolved.outputHeight - promised.height), 1,
                            "\(label): promised \(promised.height) high, renders "
                                + "\(resolved.outputHeight)")
                    }
                }
            }
        }
    }

    /// A full-resolution export of an uncropped, unstraightened frame is the source's
    /// own pixel count. The whole point of "save the full megapixel file".
    func testAFullResolutionExportIsTheWholeSensor() {
        for (w, h) in [(6000.0, 4000.0), (8256.0, 5504.0), (11648.0, 8736.0)] {
            let resolved = CropGeometry.resolve(sourceWidth: w, sourceHeight: h,
                                                geometry: Geometry())
            XCTAssertEqual(resolved.outputWidth, Int(w))
            XCTAssertEqual(resolved.outputHeight, Int(h))
            let size = recipe(.none, 0).targetSize(sourceWidth: Int(w), sourceHeight: Int(h))
            XCTAssertEqual(size.width, Int(w))
            XCTAssertEqual(size.height, Int(h))
        }
    }
}
