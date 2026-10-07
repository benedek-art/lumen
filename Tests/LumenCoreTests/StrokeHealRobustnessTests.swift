import XCTest
@testable import LumenCore

final class StrokeHealRobustnessTests: XCTestCase {
    private func stroke(_ points: [BrushPoint], dx: Double = 0) -> BrushStroke {
        BrushStroke(points: points, size: 0.1,
                    retouch: StrokeRetouch(mode: .clone, dx: dx, dy: 0))
    }

    func testMalformedCoordinatesAndOffsetsAreRefusedWithoutRendering() {
        let image = ImageBuffer(width: 12, height: 8) { _, _ in RGB(gray: 0.4) }
        for value in [Double.nan, .infinity, -.infinity, 1e300, -1e300,
                      .greatestFiniteMagnitude] {
            let malformed = stroke([BrushPoint(x: value, y: 0.5)])
            XCTAssertNil(StrokeHeal.resolve(malformed, width: 12, height: 8))
            XCTAssertEqual(StrokeHeal.apply(image, strokes: [malformed]).pixels, image.pixels)
            let offset = stroke([BrushPoint(x: 0.5, y: 0.5)], dx: value)
            XCTAssertNil(StrokeHeal.resolve(offset, width: 12, height: 8))
            let window = StrokeSourceSearch.window(for: malformed,
                                                   sourceWidth: 12, sourceHeight: 8)
            XCTAssertEqual(window.x, 0)
            XCTAssertEqual(window.y, 0)
            XCTAssertEqual(window.width, 1)
            XCTAssertEqual(window.height, 1)
            XCTAssertNil(StrokeSourceSearch.autoOffset(for: malformed, in: image))
        }
    }

    func testEmptyNonfiniteAndOverflowingResamplingIsRefused() {
        XCTAssertTrue(StrokeHeal.resample([], spacing: 1).isEmpty)
        XCTAssertTrue(StrokeHeal.resample([.init(.nan, 0)], spacing: 1).isEmpty)
        XCTAssertTrue(StrokeHeal.resample([.init(-1e300, 0), .init(1e300, 0)],
                                         spacing: 1).isEmpty)
        XCTAssertTrue(StrokeHeal.resample([.init(0, 0)], spacing: .nan).isEmpty)
        XCTAssertTrue(StrokeHeal.resample([.init(0, 0)], spacing: 0).isEmpty)
        XCTAssertEqual(StrokeHeal.distance(.init(0, 0), to: []), .infinity)
        XCTAssertTrue(StrokeHeal.rimSamples([], radius: 1).0.isEmpty)
    }

    func testHugeButArithmeticallySafeStrokeIsCappedBeforeIntegerConversion() {
        let points = [StrokeHeal.Point(-1e20, 0), .init(1e20, 0)]
        let vertices = StrokeHeal.resample(points, spacing: 0.5)
        XCTAssertEqual(vertices.count, StrokeHeal.maxVertices)
        XCTAssertEqual(vertices.first, points.first)
        XCTAssertEqual(vertices.last, points.last)
        XCTAssertTrue(vertices.allSatisfy(StrokeHeal.usable))
    }

    func testOffCanvasStrokeRetainsItsPathAndPaintsOnlyTheImageIntersection() throws {
        let crossing = stroke([BrushPoint(x: -0.25, y: 0.5),
                               BrushPoint(x: 1.25, y: 0.5)])
        let g = try XCTUnwrap(StrokeHeal.resolve(crossing, width: 40, height: 20))
        XCTAssertEqual(g.vertices.first?.x, -10)
        XCTAssertEqual(g.vertices.last?.x, 50)
        XCTAssertEqual(g.minX, 0)
        XCTAssertEqual(g.maxX, 40)
        let alpha = StrokeHeal.alphaPlane(g)
        XCTAssertEqual(alpha.count, g.width * g.height)
        XCTAssertTrue(alpha.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        XCTAssertGreaterThan(alpha.max() ?? 0, 0.5)
        XCTAssertNil(StrokeHeal.resolve(stroke([BrushPoint(x: 1e20, y: 0.5)]),
                                       width: 40, height: 20))
    }

    func testLargeFiniteSourceOffsetsUseTheSameClampedImageEdge() {
        let image = ImageBuffer(width: 20, height: 12) { x, y in RGB(x, y, 0.2) }
        for direction in [-1.0, 1.0] {
            let near = stroke([BrushPoint(x: 0.5, y: 0.5)], dx: direction * 2)
            let far = stroke([BrushPoint(x: 0.5, y: 0.5)], dx: direction * 1e20)
            XCTAssertEqual(StrokeHeal.apply(image, strokes: [near]).pixels,
                           StrokeHeal.apply(image, strokes: [far]).pixels)
        }
    }

    func testSearchBoundsStayInsideImageForOffCanvasAndInvalidDimensions() {
        for x in [-1e20, -0.1, 1.1, 1e20] {
            let w = StrokeSourceSearch.window(for: stroke([BrushPoint(x: x, y: 0.5)]),
                                              sourceWidth: 40, sourceHeight: 20)
            XCTAssertGreaterThanOrEqual(w.x, 0)
            XCTAssertLessThanOrEqual(w.x + w.width, 40)
            XCTAssertGreaterThanOrEqual(w.y, 0)
            XCTAssertLessThanOrEqual(w.y + w.height, 20)
        }
        let s = stroke([BrushPoint(x: 0.5, y: 0.5)])
        XCTAssertNil(StrokeHeal.resolve(s, width: 0, height: 20))
        let invalid = StrokeSourceSearch.window(for: s, sourceWidth: -1, sourceHeight: 0)
        XCTAssertEqual(invalid.width, 1)
        XCTAssertEqual(invalid.height, 1)
        let image = ImageBuffer(width: 4, height: 4)
        XCTAssertNil(StrokeSourceSearch.autoOffset(for: s, in: image, window: invalid,
                                                  sourceWidth: 0, sourceHeight: -1))
        XCTAssertNil(StrokeSourceSearch.bestOffset(in: image,
                      points: [.init(-1e300, 0), .init(1e300, 0)], radius: 1, mode: .heal))
    }
}
