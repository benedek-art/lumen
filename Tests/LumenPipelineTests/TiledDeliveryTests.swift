// TiledDeliveryTests.swift
// A delivery rendered tile by tile (`PipelineRenderer.renderedInTiles`) must be the
// frame rendered whole: a kernel whose region of interest is too small shows up here
// as a seam, long before a 33 MP export.

#if os(macOS)

import CoreImage
import XCTest
@testable import LumenCore
@testable import LumenPipeline

final class TiledDeliveryTests: XCTestCase {

    func testTilesMatchTheWholeFrame() throws {
        try XCTSkipUnless(KernelLibrary.coreAvailable, "core kernels unavailable")
        let w = 640, h = 427
        let buffer = ImageBuffer(width: w, height: h) { u, v in
            let ramp = 0.18 * pow(2.0, -6 + u * 10)
            let texture = 1.0 + 0.2 * sin(u * 97.0) * sin(v * 61.0)
            let edge: Double = v > 0.5 ? 1.6 : 0.6
            let y = ramp * texture * edge
            return RGB(y, y * 0.9, y * 1.1)
        }
        let data = buffer.pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let decoded = CIImage(bitmapData: data, bytesPerRow: w * 16,
                              size: CGSize(width: w, height: h), format: .RGBAf,
                              colorSpace: nil)
        var recipe = Recipe()
        recipe.develop.tone.contrast = 40
        recipe.develop.tone.shadows = 50
        recipe.develop.tone.highlights = -40
        recipe.develop.detail.clarity = 50
        recipe.develop.detail.texture = 40
        recipe.develop.detail.dehaze = 30
        recipe.develop.detail.sharpen.amount = 60
        let plan = RenderPlan(recipe: recipe, lutSize: LUT3D.exportSize)
        let graph = RenderGraph(healStrokesOf: recipe, strokeSets: [:])
        let image = graph.build(decoded, plan: plan,
                                options: RenderGraph.Options(longEdge: w,
                                                             lutSize: LUT3D.exportSize))
        let tiled = try PipelineRenderer.renderedInTiles(image, minimumPixels: 0, tile: 96)
        XCTAssertEqual(tiled.extent, image.extent)

        let context = PipelineRenderer.tileContext
        let whole = try XCTUnwrap(PipelineRenderer.buffer(from: image, context: context))
        let pieces = try XCTUnwrap(PipelineRenderer.buffer(from: tiled, context: context))
        XCTAssertEqual(whole.width, pieces.width)
        XCTAssertEqual(whole.height, pieces.height)
        var worst = 0.0
        for i in 0..<whole.pixels.count where i % 4 != 3 {
            let a = Double(whole.pixels[i]), b = Double(pieces.pixels[i])
            worst = max(worst, abs(a - b) / max(1, abs(a)))
        }
        // Half-float storage of the tiled buffer is the only expected difference.
        XCTAssertLessThan(worst, 2e-3, "a tile seam: some kernel under-reports its reach")
    }
}

#endif
