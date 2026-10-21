// GeometryGPUParityTests.swift
// S16 on the GPU (`PipelineRenderer.applyGeometry` → `GeometryKernels`) against its CPU
// definition (`GeometryResample`, LumenCore). WS-25 spec lines 10-11.
//
// Five geometries — a plain crop, a 1° straighten, 10° with a flip and a crop, a 0.3×
// output scale (two halvings, then the geometric pass), an Upright Vertical with a
// manual tilt — at three sizes, one square, one odd and wide, one tall, because the y
// flip between the CPU's top-left frame and Core Image's bottom-up one is exactly what
// a square hides.
//
// THE TOLERANCE. 2e-3 max, 2e-4 mean, on a frame spanning about 0.6. The two sides run
// the same taps with the same weights; what differs is float32 against the CPU's
// double accumulation, the GPU's `sin`, and the sampler's texel addressing at exact
// pixel centres. A wrong convention (a flipped y, a half-pixel shift, a missed
// halving) is an error of 0.05 or more on this texture.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class GeometryGPUParityTests: XCTestCase {

    private let sizes: [(w: Int, h: Int)] = [(256, 256), (331, 197), (160, 300)]

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        .workingFormat: CIFormat.RGBAf,
    ])

    private func scene(_ w: Int, _ h: Int) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            let checker = (Int(u * 23) + Int(v * 17)) % 2 == 0 ? 0.08 : 0.0
            return RGB(0.25 + 0.15 * sin(19 * u) * cos(13 * v) + checker,
                       0.3 + 0.2 * u - 0.1 * v,
                       0.2 + 0.1 * cos(29 * v + 5 * u) + checker * 0.5)
        }
    }

    private func cases() -> [(name: String, geometry: Geometry, longEdge: Int?)] {
        [
            ("crop", Geometry(crop: Crop(x: 0.13, y: 0.21, w: 0.61, h: 0.52)), nil),
            ("1° straighten", Geometry(angle: 1), nil),
            ("10° + flip + crop",
             Geometry(crop: Crop(x: 0.1, y: 0.05, w: 0.7, h: 0.8), angle: 10, flipH: true), nil),
            ("0.3× scale + 4°", Geometry(angle: -4), 0),
            ("upright vertical + tilt",
             Geometry(upright: Upright(vertical: 30, rotate: 2, aspect: 10)), nil),
        ]
    }

    func testTheGeometryKernelsCompile() {
        XCTAssertTrue(GeometryKernels.unavailable.isEmpty,
                      "S16 kernels failed: \(GeometryKernels.unavailable)")
    }

    func testGPUMatchesTheCPUDefinition() throws {
        try XCTSkipUnless(GeometryKernels.unavailable.isEmpty, "covered by the compile test")
        for size in sizes {
            let input = scene(size.w, size.h)
            for (name, geometry, longEdge) in cases() {
                let target = longEdge.map { _ in Int(Double(Swift.max(size.w, size.h)) * 0.3) }
                let map = GeometryMap(geometry: geometry, sourceWidth: size.w,
                                      sourceHeight: size.h, targetLongEdge: target)
                let cpu = GeometryResample.apply(input, map: map)
                var recipe = Recipe()
                recipe.develop.geometry = geometry
                let gpuImage = PipelineRenderer.applyGeometry(ciImage(input), recipe: recipe,
                                                              scaleTo: target)
                XCTAssertEqual(Int(gpuImage.extent.width), map.outputWidth, "\(name)")
                XCTAssertEqual(Int(gpuImage.extent.height), map.outputHeight, "\(name)")
                let gpu = try XCTUnwrap(readBack(gpuImage, width: map.outputWidth,
                                                 height: map.outputHeight))
                var worst = 0.0, sum = 0.0
                for y in 0..<cpu.height {
                    for x in 0..<cpu.width {
                        let d = gpu[x, y].maxAbsDifference(cpu[x, y])
                        worst = Swift.max(worst, d)
                        sum += d
                    }
                }
                let mean = sum / Double(cpu.count)
                print("GEOMETRY-PARITY \(name) @\(size.w)x\(size.h) → \(cpu.width)x\(cpu.height): "
                      + "max \(worst) mean \(mean)")
                XCTAssertLessThan(worst, 2e-3, "\(name) @\(size.w)x\(size.h)")
                XCTAssertLessThan(mean, 2e-4, "\(name) @\(size.w)x\(size.h)")
            }
        }
    }

    /// The map the mask tools invert is the one `geometryRects` encodes, whenever there
    /// is no Upright: the old inverse, rebuilt here from `geometryRects` itself.
    func testPointMappingsAgreeWithGeometryRects() {
        var worst = 0.0
        for size in [CGSize(width: 6000, height: 4000), CGSize(width: 333, height: 777)] {
            for angle in [-30.0, -3, 0, 7, 44] {
                for flip in [false, true] {
                    let geo = Geometry(crop: Crop(x: 0.12, y: 0.08, w: 0.55, h: 0.7),
                                       angle: angle, flipH: flip)
                    let (orientation, _, target) = PipelineRenderer.geometryRects(
                        geo, sourceSize: size)
                    for (u, v) in [(0.0, 0.0), (1, 1), (0.3, 0.8), (0.5, 0.5)] {
                        let point = CGPoint(x: target.minX + CGFloat(u) * target.width,
                                            y: target.maxY - CGFloat(v) * target.height)
                        let s = orientation.isIdentity ? point : point.applying(orientation.inverted())
                        let legacy = CGPoint(x: s.x / size.width, y: 1 - s.y / size.height)
                        let now = PipelineRenderer.sourceNormalized(
                            displayedX: u, displayedY: v, geometry: geo, sourceSize: size)
                        worst = Swift.max(worst, abs(legacy.x - now.x), abs(legacy.y - now.y))
                    }
                }
            }
        }
        print("GEOMETRY-POINTS worst normalized difference \(worst)")
        XCTAssertLessThan(worst, 1e-6)
    }

    // MARK: - Bridges

    private func ciImage(_ buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf, colorSpace: nil)
    }

    private func readBack(_ image: CIImage, width: Int, height: Int) -> ImageBuffer? {
        var pixels = [Float](repeating: -1, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16,
                           bounds: CGRect(x: image.extent.minX, y: image.extent.minY,
                                          width: CGFloat(width), height: CGFloat(height)),
                           format: .RGBAf, colorSpace: nil)
        }
        guard !pixels.contains(-1) else { return nil }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

#endif
