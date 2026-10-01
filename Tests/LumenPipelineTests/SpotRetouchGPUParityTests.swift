// SpotRetouchGPUParityTests.swift
// S5 RETOUCH on the GPU against `SpotRetouch`, the f64 reference.
//
// Heal and Clone, hard and feathered, at fractional source offsets, near the frame edge
// (where the clamped sampler and `ImageBuffer.bilinear`'s clamped edge must agree), with
// overlapping spots whose ORDER matters, at three sizes — one square, one odd and wide,
// one tall — because the two sides agree trivially on a square and disagree, if they are
// going to, on the long-edge radius and the y flip.
//
// THE TOLERANCE. 1e-3 absolute on a frame whose values span about 0.6. Not the 1e-4 the
// parametric masks hold, and the reason is the sampler, not the arithmetic: the masks are
// closed forms of `destCoord()` and never sample, while a spot borrows pixels through
// Core Image's bilinear sampler, whose interpolation weights are hardware-filtered at
// reduced sub-texel precision. On these smooth fixtures (neighbouring pixels differ by
// a few hundredths) that is a few 1e-4; 1e-3 bounds it with margin and is still forty
// times smaller than the smallest change a spot here makes.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class SpotRetouchGPUParityTests: XCTestCase {

    private let sizes: [(w: Int, h: Int)] = [(256, 256), (331, 197), (128, 320)]
    private let tolerance = 1e-3

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        .workingFormat: CIFormat.RGBAf,
    ])

    // MARK: - Fixtures

    /// Smooth texture with a blemish at (0.4, 0.5) — enough structure that a wrong
    /// offset, a mirrored y or a wrong radius is a large error, smooth enough that the
    /// sampler's weight precision is not.
    private func scene(_ w: Int, _ h: Int) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            let aspect = Double(h) / Double(Swift.max(w, h))
            let width = Double(w) / Double(Swift.max(w, h))
            // Two blemishes, so the spot near the corner has something to remove too.
            let first = hypot((u - 0.4) * width, (v - 0.5) * aspect) < 0.03
            let second = hypot((u - 0.12) * width, (v - 0.15) * aspect) < 0.025
            let blemish = first || second ? 0.3 : 0
            return RGB(0.25 + 0.15 * sin(9 * u) * cos(7 * v) + blemish,
                       0.3 + 0.1 * u - 0.05 * v + blemish * 0.5,
                       0.2 + 0.08 * cos(11 * v + 3 * u))
        }
    }

    private func cases() -> [(name: String, spots: [HealSpot])] {
        [
            ("heal, feathered, fractional offset",
             [HealSpot(id: "a", mode: .heal, x: 0.4, y: 0.5, sourceX: 0.613, sourceY: 0.437,
                       radius: 0.06, feather: 50, opacity: 100)]),
            ("clone, hard edge",
             [HealSpot(id: "b", mode: .clone, x: 0.4, y: 0.5, sourceX: 0.2, sourceY: 0.71,
                       radius: 0.05, feather: 0, opacity: 100)]),
            ("heal at half opacity, full feather",
             [HealSpot(id: "c", mode: .heal, x: 0.4, y: 0.5, sourceX: 0.55, sourceY: 0.62,
                       radius: 0.08, feather: 100, opacity: 50)]),
            // The source disc hangs off the frame: the clamped edge on both sides.
            ("heal sourced off the edge",
             [HealSpot(id: "d", mode: .heal, x: 0.12, y: 0.15, sourceX: 0.03, sourceY: 0.04,
                       radius: 0.05, feather: 40, opacity: 100)]),
            // Overlapping, so the second reads the first's output — order is checked.
            ("two overlapping spots",
             [HealSpot(id: "e", mode: .clone, x: 0.4, y: 0.5, sourceX: 0.7, sourceY: 0.5,
                       radius: 0.06, feather: 30, opacity: 100),
              HealSpot(id: "f", mode: .heal, x: 0.44, y: 0.52, sourceX: 0.3, sourceY: 0.3,
                       radius: 0.05, feather: 60, opacity: 90)]),
        ]
    }

    // MARK: - The parity

    func testTheRetouchKernelsCompile() {
        // Not a skip: a kernel that fails to compile is the defect this lane exists to
        // catch, and `applySpots` would otherwise return its input and pass everything.
        XCTAssertTrue(KernelLibrary.retouchAvailable,
                      "spot kernels failed: \(KernelLibrary.unavailableKernels)")
    }

    func testEverySpotMatchesTheReferenceAtEverySize() throws {
        try XCTSkipUnless(KernelLibrary.retouchAvailable, "covered by the compile test")
        for size in sizes {
            let input = scene(size.w, size.h)
            for (name, spots) in cases() {
                let reference = SpotRetouch.apply(input, spots: spots)
                let gpu = try XCTUnwrap(readBack(RenderGraph.applySpots(ciImage(input),
                                                                       spots: spots),
                                                 width: size.w, height: size.h))
                var worst = 0.0, moved = 0.0
                for y in 0..<size.h {
                    for x in 0..<size.w {
                        worst = Swift.max(worst, gpu[x, y].maxAbsDifference(reference[x, y]))
                        moved = Swift.max(moved,
                                          reference[x, y].maxAbsDifference(input[x, y]))
                    }
                }
                XCTAssertGreaterThan(moved, 0.04,
                                     "\(name) @\(size.w)x\(size.h): the spot changed "
                                         + "nothing, so the comparison proves nothing")
                XCTAssertLessThan(worst, tolerance,
                                  "\(name) @\(size.w)x\(size.h): GPU is \(worst) from "
                                      + "the reference")
            }
        }
    }

    /// Outside a spot's box the GPU hands back the input's own bytes — the property a
    /// recipe's untouched regions, and a recipe without spots, are owed.
    func testPixelsOutsideTheSpotAreTheInputsOwn() throws {
        try XCTSkipUnless(KernelLibrary.retouchAvailable, "covered by the compile test")
        let input = scene(331, 197)
        let spots = cases()[0].spots
        let gpu = try XCTUnwrap(readBack(RenderGraph.applySpots(ciImage(input), spots: spots),
                                         width: 331, height: 197))
        guard let box = SpotRetouch.resolve(spots[0], width: 331, height: 197) else {
            return XCTFail("did not resolve")
        }
        for y in 0..<197 {
            for x in 0..<331 where !(box.minX..<box.maxX).contains(x)
                || !(box.minY..<box.maxY).contains(y) {
                XCTAssertEqual(gpu[x, y], input[x, y], "(\(x), \(y)) outside the box moved")
            }
        }
        XCTAssertEqual(try XCTUnwrap(readBack(RenderGraph.applySpots(ciImage(input), spots: []),
                                              width: 331, height: 197)).pixels,
                       input.pixels)
    }

    /// S5 sits before S6 in the graph, as in the reference: the colour-stage input of a
    /// recipe with a spot is the colour-stage input, without the spot, of the retouched
    /// picture. (`maskSource` so S3 does not run, which would put a stage between them on
    /// one side only.)
    func testTheGraphRetouchesBeforeTheLinearStage() throws {
        try XCTSkipUnless(KernelLibrary.retouchAvailable, "covered by the compile test")
        let input = scene(256, 256)
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1.1
        let spots = cases()[0].spots
        var withSpots = recipe
        withSpots.develop.heal.spots = spots
        let options = RenderGraph.Options(longEdge: 256, maskSource: true)
        let a = RenderGraph().colorStageInput(ciImage(input),
                                              plan: RenderPlan(recipe: withSpots),
                                              options: options)
        let b = RenderGraph().colorStageInput(
            RenderGraph.applySpots(ciImage(input), spots: spots),
            plan: RenderPlan(recipe: recipe), options: options)
        let ra = try XCTUnwrap(readBack(a, width: 256, height: 256))
        let rb = try XCTUnwrap(readBack(b, width: 256, height: 256))
        XCTAssertLessThan(ra.maxAbsDifference(rb), 1e-5)
        let plain = try XCTUnwrap(readBack(
            RenderGraph().colorStageInput(ciImage(input), plan: RenderPlan(recipe: recipe),
                                          options: options), width: 256, height: 256))
        XCTAssertGreaterThan(ra.maxAbsDifference(plain), 0.04, "the spot did nothing")
    }

    // MARK: - Bridges

    private func ciImage(_ buffer: ImageBuffer) -> CIImage {
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: buffer.width * 16,
                       size: CGSize(width: buffer.width, height: buffer.height),
                       format: .RGBAf, colorSpace: nil)
    }

    private func readBack(_ image: CIImage, width: Int, height: Int) -> ImageBuffer? {
        XCTAssertEqual(image.extent.width, CGFloat(width), accuracy: 0.5)
        XCTAssertEqual(image.extent.height, CGFloat(height), accuracy: 0.5)
        var pixels = [Float](repeating: -1, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(image, toBitmap: base, rowBytes: width * 16,
                           bounds: CGRect(x: image.extent.minX, y: image.extent.minY,
                                          width: CGFloat(width), height: CGFloat(height)),
                           format: .RGBAf, colorSpace: nil)
        }
        // A render that wrote nothing leaves the -1 sentinel, which no fixture holds.
        guard !pixels.contains(-1) else { return nil }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

#endif
