// StrokeHealGPUParityTests.swift
// S5 RETOUCH, the painted half, on the GPU against `StrokeHeal`, the reference.
//
// Heal and Clone, straight and bent (a bend drops the rim samples on its inside, which
// the two sides must drop identically), a single dab, a stroke whose source runs off the
// frame edge, and two crossing strokes whose ORDER matters — at the spot test's three
// sizes, for its reasons (long-edge radius and the y flip only disagree off the square).
//
// THE TOLERANCE is the spot test's 1e-3, for the spot test's reason: the borrowed and
// rim pixels go through Core Image's bilinear sampler. The tube's alpha is not a source
// of error here — it is the reference's own plane, uploaded — and the rim positions are
// split into a coarse and a fine part (`KernelLibrary.strokeApplySource`) so a
// half-float intermediate cannot move them by more than a hundredth of a pixel.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class StrokeHealGPUParityTests: XCTestCase {

    private let sizes: [(w: Int, h: Int)] = [(256, 256), (331, 197), (128, 320)]
    private let tolerance = 1e-3

    private let context = CIContext(options: [
        .workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
        .workingFormat: CIFormat.RGBAf,
    ])

    /// The spot test's smooth texture, with a dark scratch along y = 0.5 from x 0.2 to
    /// 0.7 for the strokes to remove.
    private func scene(_ w: Int, _ h: Int) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            let aspect = Double(h) / Double(Swift.max(w, h))
            let scratch = u > 0.2 && u < 0.7 && abs((v - 0.5) * aspect) < 0.01 ? -0.15 : 0
            return RGB(0.3 + 0.15 * sin(9 * u) * cos(7 * v) + scratch,
                       0.3 + 0.1 * u - 0.05 * v + scratch,
                       0.2 + 0.08 * cos(11 * v + 3 * u))
        }
    }

    private func stroke(_ points: [(Double, Double)], size: Double, mode: HealMode,
                        dx: Double, dy: Double, feather: Double = 50,
                        opacity: Double = 100) -> BrushStroke {
        BrushStroke(points: points.map { BrushPoint(x: $0.0, y: $0.1) }, size: size,
                    feather: feather, density: opacity,
                    retouch: StrokeRetouch(mode: mode, dx: dx, dy: dy))
    }

    private func cases() -> [(name: String, strokes: [BrushStroke])] {
        [
            ("heal, straight, fractional offset",
             [stroke([(0.2, 0.5), (0.45, 0.5), (0.7, 0.5)], size: 0.05, mode: .heal,
                     dx: 0.0137, dy: 0.0913)]),
            ("clone, bent, hard edge",
             [stroke([(0.3, 0.3), (0.5, 0.45), (0.6, 0.7), (0.4, 0.75)], size: 0.06,
                     mode: .clone, dx: 0.21, dy: -0.04, feather: 0)]),
            ("heal, a U-bend whose inner rim is dropped",
             [stroke([(0.35, 0.3), (0.35, 0.6), (0.45, 0.66), (0.55, 0.6), (0.55, 0.3)],
                     size: 0.08, mode: .heal, dx: -0.18, dy: 0.02, feather: 60)]),
            ("heal, one dab at half opacity",
             [stroke([(0.4, 0.5)], size: 0.07, mode: .heal, dx: 0.12, dy: 0.1,
                     opacity: 50)]),
            ("heal sourced off the edge",
             [stroke([(0.04, 0.5), (0.25, 0.5)], size: 0.05, mode: .heal, dx: -0.09,
                     dy: 0.08, feather: 40)]),
            ("two crossing strokes",
             [stroke([(0.2, 0.5), (0.7, 0.5)], size: 0.04, mode: .clone, dx: 0, dy: 0.12),
              stroke([(0.45, 0.3), (0.45, 0.7)], size: 0.05, mode: .heal, dx: 0.15,
                     dy: 0, feather: 70, opacity: 90)]),
        ]
    }

    func testTheStrokeKernelsCompile() {
        XCTAssertTrue(KernelLibrary.strokeRetouchAvailable,
                      "stroke kernels failed: \(KernelLibrary.unavailableKernels)")
    }

    func testEveryStrokeMatchesTheReferenceAtEverySize() throws {
        try XCTSkipUnless(KernelLibrary.strokeRetouchAvailable, "covered by the compile test")
        for size in sizes {
            let input = scene(size.w, size.h)
            for (name, strokes) in cases() {
                let reference = StrokeHeal.apply(input, strokes: strokes)
                let gpu = try XCTUnwrap(readBack(
                    RenderGraph.applyHealStrokes(ciImage(input), strokes: strokes),
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
                                     "\(name) @\(size.w)x\(size.h): the stroke changed "
                                         + "nothing, so the comparison proves nothing")
                XCTAssertLessThan(worst, tolerance,
                                  "\(name) @\(size.w)x\(size.h): GPU is \(worst) from "
                                      + "the reference")
            }
        }
    }

    /// Outside a stroke's box the GPU hands back the input's own bytes, and no strokes
    /// is the input itself.
    func testPixelsOutsideTheStrokeAreTheInputsOwn() throws {
        try XCTSkipUnless(KernelLibrary.strokeRetouchAvailable, "covered by the compile test")
        let input = scene(331, 197)
        let strokes = cases()[0].strokes
        let gpu = try XCTUnwrap(readBack(
            RenderGraph.applyHealStrokes(ciImage(input), strokes: strokes),
            width: 331, height: 197))
        guard let box = StrokeHeal.resolve(strokes[0], width: 331, height: 197) else {
            return XCTFail("did not resolve")
        }
        for y in 0..<197 {
            for x in 0..<331 where !(box.minX..<box.maxX).contains(x)
                || !(box.minY..<box.maxY).contains(y) {
                XCTAssertEqual(gpu[x, y], input[x, y], "(\(x), \(y)) outside the box moved")
            }
        }
        XCTAssertEqual(try XCTUnwrap(readBack(
            RenderGraph.applyHealStrokes(ciImage(input), strokes: []),
            width: 331, height: 197)).pixels, input.pixels)
    }

    /// The graph renders a recipe's strokes when it is built from the stroke sets, after
    /// the spots and before S6 — the reference's order.
    func testTheGraphHealsStrokesAfterSpotsAndBeforeTheLinearStage() throws {
        try XCTSkipUnless(KernelLibrary.strokeRetouchAvailable
                              && KernelLibrary.retouchAvailable, "covered by the compile tests")
        let input = scene(256, 256)
        let strokes = cases()[0].strokes
        let set = BrushStrokeSet(strokes: strokes)
        let ref = try set.blobRef()
        var recipe = Recipe()
        recipe.develop.tone.exposure = 1.1
        let spot = HealSpot(id: "s", mode: .clone, x: 0.45, y: 0.5, sourceX: 0.45,
                            sourceY: 0.8, radius: 0.04, feather: 20, opacity: 100)
        var retouched = recipe
        retouched.develop.heal.spots = [spot]
        retouched.develop.heal.strokesRef = ref
        retouched.develop.heal.count = 1
        let options = RenderGraph.Options(longEdge: 256, maskSource: true)
        let a = RenderGraph(healStrokesOf: retouched, strokeSets: [ref: set])
            .colorStageInput(ciImage(input), plan: RenderPlan(recipe: retouched),
                             options: options)
        let b = RenderGraph().colorStageInput(
            RenderGraph.applyHealStrokes(RenderGraph.applySpots(ciImage(input),
                                                                spots: [spot]),
                                         strokes: strokes),
            plan: RenderPlan(recipe: recipe), options: options)
        let ra = try XCTUnwrap(readBack(a, width: 256, height: 256))
        let rb = try XCTUnwrap(readBack(b, width: 256, height: 256))
        XCTAssertLessThan(ra.maxAbsDifference(rb), 1e-5)
        // And without the stroke set the graph renders the spot alone: a missing blob
        // heals nothing, rather than something else.
        let spotOnly = try XCTUnwrap(readBack(RenderGraph().colorStageInput(
            ciImage(input), plan: RenderPlan(recipe: retouched), options: options),
            width: 256, height: 256))
        XCTAssertGreaterThan(ra.maxAbsDifference(spotOnly), 0.04, "the stroke did nothing")
    }

    // MARK: - Bridges (the spot test's)

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
        guard !pixels.contains(-1) else { return nil }
        return ImageBuffer(width: width, height: height, pixels: pixels)
    }
}

#endif
