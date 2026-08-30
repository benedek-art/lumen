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

    // MARK: The target is rounded from the un-truncated crop extent (docs/32 G3)

    /// Any cropped or straightened photograph has a FRACTIONAL crop extent, and the
    /// export path used to truncate it to `Int` before asking for the target — moving
    /// the derived scale by up to a part in two thousand, which near a rounding
    /// boundary promises a short edge one pixel off what the resampler (whose scale
    /// comes from the true extent) then delivers. Both pinned cases flip under
    /// truncation, one in each direction; both were verified red against the
    /// truncating arithmetic before the fix.
    func testTheTargetIsRoundedFromTheUnTruncatedCropExtent() {
        // 1333.5 × (1600 / 2000.5) = 1066.53… → 1067. Truncated first:
        // 1333 × (1600 / 2000) = 1066.4 → 1066, one short of the delivery.
        let up = recipe(.longEdge, 1600).targetSize(sourceWidth: 2000.5,
                                                    sourceHeight: 1333.5)
        XCTAssertEqual(up.width, 1600)
        XCTAssertEqual(up.height, 1067,
                       "the short edge was computed from a truncated extent")

        // And the other direction: 1334.2 × (1600 / 2001.7) = 1066.45… → 1066,
        // where the truncated extent promises 1067 — one MORE than delivered.
        let down = recipe(.longEdge, 1600).targetSize(sourceWidth: 2001.7,
                                                      sourceHeight: 1334.2)
        XCTAssertEqual(down.width, 1600)
        XCTAssertEqual(down.height, 1066,
                       "the short edge was computed from a truncated extent")

        // The general property, on the axis each mode drives and on the derived one:
        // the promise is round(true extent × the mode's own scale), never a rounded
        // copy's arithmetic.
        for (w, h) in [(2000.5, 1333.5), (5999.4, 3999.6), (1365.4, 2048.3)] {
            for mode in [ResizeMode.longEdge, .shortEdge, .width, .height] {
                let value = 1500.0
                let size = recipe(mode, value).targetSize(sourceWidth: w,
                                                          sourceHeight: h)
                let axis: Double
                switch mode {
                case .longEdge: axis = Swift.max(w, h)
                case .shortEdge: axis = Swift.min(w, h)
                case .width: axis = w
                default: axis = h
                }
                let scale = Swift.min(value / axis, 1.0)
                XCTAssertEqual(size.width, Int((w * scale).rounded()),
                               "\(mode) on \(w)×\(h)")
                XCTAssertEqual(size.height, Int((h * scale).rounded()),
                               "\(mode) on \(w)×\(h)")
            }
        }

        // The Int overload is the same arithmetic through a conversion, not a second
        // implementation that can drift.
        let viaInt = recipe(.longEdge, 2048).targetSize(sourceWidth: 6000,
                                                        sourceHeight: 4000)
        let viaDouble = recipe(.longEdge, 2048).targetSize(sourceWidth: 6000.0,
                                                           sourceHeight: 4000.0)
        XCTAssertEqual(viaInt.width, viaDouble.width)
        XCTAssertEqual(viaInt.height, viaDouble.height)

        // Degenerate doubles stay degenerate, not fatal: the old Int overload echoed
        // a zero source back, and a non-finite axis must fold rather than trap.
        let zero = recipe(.longEdge, 2048).targetSize(sourceWidth: 0.0,
                                                      sourceHeight: 0.0)
        XCTAssertEqual(zero.width, 0)
        let nan = recipe(.longEdge, 2048).targetSize(sourceWidth: Double.nan,
                                                     sourceHeight: 4000.0)
        XCTAssertEqual(nan.width, 0)
        XCTAssertEqual(nan.height, 4000)
    }
}

/// The recipe's other promises — the ones the sheet's captions repeat (docs/32
/// Stream G items 1 and 2). Same file as the sizing suite because they are all
/// claims about what the exported file measures.
final class ExportRecipeHonestyTests: XCTestCase {

    /// Quality defaults to 100 everywhere a recipe is born: a delivery should not
    /// pay compression's price unasked.
    func testQualityDefaultsToOneHundred() {
        XCTAssertEqual(ExportRecipe(name: "fresh").quality, 100,
                       "a new recipe must not quietly compress")
        XCTAssertEqual(ExportRecipe.hdrHEIC.quality, 100)
        XCTAssertEqual(ExportRecipe.archiveOriginalSize.quality, 100)
    }

    /// The one stock recipe below 100 is the web preset, deliberately — and its NAME
    /// carries the number, so the trade is visible in the recipe list without opening
    /// the editor. If somebody retunes the preset, the name must move with it or this
    /// stays red.
    func testTheWebPresetSaysItsOwnQualityOut() {
        let web = ExportRecipe.webJPEG
        XCTAssertEqual(web.quality, 90, "the web preset trades quality for size on purpose")
        XCTAssertTrue(web.name.contains("q90"),
                      "a preset kept below the 100 default must say so in its name; "
                          + "it is called \"\(web.name)\"")
    }

    /// `effectiveBitDepth` is the depth the encoder will use, whatever the stored
    /// number says: JPEG folds everything to 8, HEIC folds any deeper request to its
    /// Main-10 ceiling, TIFF/PNG honour 16 — and a stored depth the format cannot
    /// write (a 10-bit HEIC recipe switched to TIFF) folds instead of leaking into
    /// the summary line or the dither's amplitude.
    func testEffectiveBitDepthFoldsToWhatTheFormatCanWrite() {
        func depth(_ format: ExportFormat, _ stored: Int) -> Int {
            ExportRecipe(name: "d", format: format, bitDepth: stored).effectiveBitDepth
        }
        XCTAssertEqual(depth(.jpeg, 8), 8)
        XCTAssertEqual(depth(.jpeg, 16), 8, "JPEG is 8-bit by format")
        XCTAssertEqual(depth(.heif, 8), 8)
        XCTAssertEqual(depth(.heif, 10), 10)
        XCTAssertEqual(depth(.heif, 16), 10, "HEVC Main 10 is HEIC's ceiling")
        XCTAssertEqual(depth(.tiff, 16), 16)
        XCTAssertEqual(depth(.png, 16), 16)
        XCTAssertEqual(depth(.tiff, 10), 8,
                       "TIFF has no 10-bit rung here — a HEIC depth must not leak")
        XCTAssertTrue(ExportFormat.heif.supportsTenBit)
        for other in ExportFormat.allCases where other != .heif {
            XCTAssertFalse(other.supportsTenBit, "\(other)")
        }
    }
}
