#if os(macOS)
import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class VignetteGeometryContractTests: XCTestCase {
    private let context = CIContext(options: [.workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(), .workingFormat: CIFormat.RGBAf])

    private func rendered(_ geometry: Geometry, origin: CGPoint = .zero,
                          ev: Double = -2, feather: Double = 75) throws -> (ImageBuffer, CGRect) {
        let extent = CGRect(origin: origin, size: CGSize(width: 640, height: 480))
        let input = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18,
                                          alpha: 1)).cropped(to: extent)
        let vignette = RenderGraph().applyVignette(input, ev: ev, feather: feather,
            geometry: geometry, dithered: false)
        var recipe = Recipe()
        recipe.develop.geometry = geometry
        let delivered = PipelineRenderer.applyGeometry(vignette, recipe: recipe)
        return (try XCTUnwrap(PipelineRenderer.buffer(from: delivered, context: context)),
                delivered.extent)
    }

    /// Expected burn is evaluated in DELIVERED coordinates, independently of the
    /// renderer's orientation matrix. Resampling affects only the smooth burn; the
    /// original scene is constant. Exclude two outer pixels from edge interpolation.
    private func check(_ geometry: Geometry, origin: CGPoint = .zero,
                       ev: Double = -2, feather: Double = 75,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let (pixels, extent) = try rendered(geometry, origin: origin, ev: ev, feather: feather)
        // buffer(from:) reads the integral extent. Rotation can leave an origin a
        // fraction below zero; that adds a leading pixel, not an image-space shift.
        let readBounds = extent.integral
        var worst = 0.0
        for y in stride(from: 2, to: pixels.height - 2, by: 3) {
            for x in stride(from: 2, to: pixels.width - 2, by: 3) {
                let u = 2 * (Double(x) + 0.5 + readBounds.minX - extent.minX) / extent.width - 1
                let v = 2 * (Double(y) + 0.5 + readBounds.minY - extent.minY) / extent.height - 1
                let radius = sqrt((u * u + v * v) / 2)
                let falloff = DetailEngine.vignetteFalloff(radius: radius,
                    inner: DetailEngine.vignetteInnerRadius(feather: feather))
                let expected = RGB(gray: 0.18 * pow(2, ev * falloff))
                worst = max(worst, pixels[x, y].maxAbsDifference(expected))
            }
        }
        XCTAssertLessThan(worst, 0.002, "geometry=\(geometry), origin=\(origin)",
                          file: file, line: line)
        print("VIGNETTE-GEO angle=\(geometry.angle) flip=\(geometry.flipH) EV=\(ev) extent=\(extent) read=\(readBounds) max=\(worst)")
        XCTAssertEqual(pixels[pixels.width / 2, pixels.height / 2].r, 0.18,
                       accuracy: 0.0001, file: file, line: line)
    }

    func testAsymmetricCropAndReflectedCropRetainACentredVignette() throws {
        let crop = Crop(x: 0.1, y: 0.1, w: 0.35, h: 0.7)
        try check(Geometry(crop: crop))
        try check(Geometry(crop: Crop(x: 1 - crop.x - crop.w, y: crop.y,
                                     w: crop.w, h: crop.h), flipH: true))
    }

    func testStraightenAndFlipUseDeliveredEllipseAxes() throws {
        for angle in [-90.0, -13, 13, 90] {
            for flip in [false, true] {
                try check(Geometry(crop: Crop(x: 0.08, y: 0.21, w: 0.64, h: 0.33),
                                   angle: angle, flipH: flip))
            }
        }
    }

    func testTranslatedSourceAndAmountSignDoNotChangeGeometry() throws {
        let geometry = Geometry(crop: Crop(x: 0.1, y: 0.2, w: 0.6, h: 0.55),
                                angle: -7, flipH: true)
        for ev in [-4.0, 0, 2] {
            try check(geometry, origin: CGPoint(x: 37, y: -19), ev: ev, feather: 50)
        }
    }
}
#endif
