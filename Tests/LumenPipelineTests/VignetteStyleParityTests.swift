#if os(macOS)
// VignetteStyleParityTests.swift
// WS-41 SPEC line 24: the vignette kernel against `DetailEngine.vignette`, for every
// style, on a crop with straighten and flip, at non-default Midpoint, Roundness, Feather
// and Highlights, at a burn and a lift — and the hard edge of Feather 0.
//
// Bars are the existing ones: 0.005·max(1, ref) dithered (the golden bar the clamp and
// feather goldens use) and 0.002·max(1, ref) undithered (the geometry contract's bar on
// mid-grey, scaled for a source that runs to 2.0 so a lift does not hold a 5.6 value to
// an absolute 0.002).

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class VignetteStyleParityTests: XCTestCase {

    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) as Any,
        .workingFormat: CIFormat.RGBAf,
    ])

    private func ciImage(from buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data,
                       bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf,
                       colorSpace: nil)
    }

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
        guard pixels.contains(where: { $0 != 0 }) else {
            XCTFail("the render produced an all-zero frame")
            return nil
        }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }

    /// 64×32, luminance 0.02…2 along x (log-spaced) and saturated hues along y — so the
    /// highlight knee, the paint anchors and Color Priority's chroma all see real range.
    private let source: ImageBuffer = {
        ImageBuffer(width: 64, height: 32) { u, v in
            let y = 0.02 * pow(100.0, u)
            let hue = v * 2 * Double.pi
            let tint = RGB(1 + 0.8 * cos(hue), 1 + 0.8 * cos(hue - 2.094),
                           1 + 0.8 * cos(hue + 2.094))
            return tint * (y / RGBColorSpace.rec2020.luminance(tint))
        }
    }()

    private let geometry = Geometry(crop: Crop(x: 0.1, y: 0.2, w: 0.6, h: 0.55),
                                    angle: -7, flipH: true)

    private func worst(_ settings: VignetteSettings, dithered: Bool,
                       file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let gpuImage = RenderGraph().applyVignette(ciImage(from: source), settings,
                                                   geometry: geometry, dithered: dithered)
        let gpu = try XCTUnwrap(readBack(gpuImage, width: source.width,
                                         height: source.height), file: file, line: line)
        let reference = DetailEngine.vignette(source, settings, geometry: geometry)
        var worst = 0.0
        for y in 0..<source.height {
            for x in 0..<source.width {
                let ref = reference[x, y]
                let scale = Swift.max(1, Swift.max(ref.r, Swift.max(ref.g, ref.b)))
                worst = Swift.max(worst, ref.maxAbsDifference(gpu[x, y]) / scale)
            }
        }
        return worst
    }

    func testEveryStyleAgreesBetweenTheRenderers() throws {
        try XCTSkipUnless(KernelLibrary.vignette != nil, "kernel unavailable")
        let shapes: [(midpoint: Double, roundness: Double, feather: Double, highlights: Double)] = [
            (30, -60, 20, 70), (80, 80, 90, 0),
        ]
        for style in VignetteStyle.allCases {
            for shape in shapes {
                for amount in [-3.0, 1.5] {
                    let s = VignetteSettings(amount: amount, feather: shape.feather,
                                             midpoint: shape.midpoint,
                                             roundness: shape.roundness,
                                             highlights: shape.highlights, style: style)
                    let undithered = try worst(s, dithered: false)
                    let dithered = try worst(s, dithered: true)
                    print(String(format: "VIGNETTE-PARITY %@ m%.0f r%.0f f%.0f h%.0f a%+.1f "
                                 + "undithered %.6f dithered %.6f", style.rawValue,
                                 shape.midpoint, shape.roundness, shape.feather,
                                 shape.highlights, amount, undithered, dithered))
                    XCTAssertLessThanOrEqual(undithered, 0.002, "\(s)")
                    XCTAssertLessThanOrEqual(dithered, 0.005, "\(s)")
                }
            }
        }
    }

    /// Feather 0's anti-aliased hard edge, edge pixels included.
    func testTheHardEdgeAgreesBetweenTheRenderers() throws {
        try XCTSkipUnless(KernelLibrary.vignette != nil, "kernel unavailable")
        for style in VignetteStyle.allCases {
            for amount in [-3.0, 1.5] {
                let s = VignetteSettings(amount: amount, feather: 0, midpoint: 40,
                                         style: style)
                XCTAssertLessThanOrEqual(try worst(s, dithered: false), 0.002, "\(s)")
                XCTAssertLessThanOrEqual(try worst(s, dithered: true), 0.005, "\(s)")
            }
        }
    }

    /// The shared field is the delivered frame `applyGeometry` crops to: its orientation
    /// is `geometryRects`' and its rectangle is `geometryRects(...).target.integral`.
    func testTheSharedFieldIsGeometryRects() {
        let size = CGSize(width: 640, height: 480)
        for angle in [-90.0, -13, -7, 0, 13, 90] {
            for flip in [false, true] {
                let geo = Geometry(crop: Crop(x: 0.08, y: 0.21, w: 0.64, h: 0.33),
                                   angle: angle, flipH: flip)
                let rects = PipelineRenderer.geometryRects(geo, sourceSize: size)
                let field = VignetteField(geometry: geo, sourceWidth: 640, sourceHeight: 480)
                let t = rects.orientation
                for (a, b) in [(Double(t.a), field.a), (Double(t.b), field.b),
                               (Double(t.c), field.c), (Double(t.d), field.d),
                               (Double(t.tx), field.tx), (Double(t.ty), field.ty)] {
                    XCTAssertEqual(a, b, accuracy: 1e-9, "angle \(angle) flip \(flip)")
                }
                let e = rects.target.integral
                XCTAssertEqual(Double(e.midX), field.centreX, accuracy: 1e-9)
                XCTAssertEqual(Double(e.midY), field.centreY, accuracy: 1e-9)
                XCTAssertEqual(Double(e.width) / 2, field.halfWidth, accuracy: 1e-9)
                XCTAssertEqual(Double(e.height) / 2, field.halfHeight, accuracy: 1e-9)
            }
        }
    }
}
#endif
