// StrokeSourceRepickTests.swift
// WS-57: a painted heal stroke's source can be dragged and re-picked like a spot's —
// `StrokeHandles.hitSource/draggedSource`, `StrokeSourceSearch.rankedOffsets/nextOffset`.

import XCTest
@testable import LumenCore

final class StrokeSourceRepickTests: XCTestCase {

    private func textured(_ w: Int = 200, _ h: Int = 140) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            let t = 0.2 + 0.06 * sin(u * 37) * cos(v * 23)
            return RGB(t, t * 0.9, t * 0.8)
        }
    }

    private let points = [StrokeHeal.Point(60, 70), StrokeHeal.Point(100, 74),
                          StrokeHeal.Point(140, 70)]

    func testTheFirstRankedOffsetIsTheBestOffset() throws {
        let image = textured()
        for mode in [HealMode.heal, .clone] {
            let best = try XCTUnwrap(StrokeSourceSearch.bestOffset(in: image, points: points,
                                                                   radius: 6, mode: mode))
            let ranked = StrokeSourceSearch.rankedOffsets(in: image, points: points,
                                                          radius: 6, mode: mode)
            XCTAssertGreaterThan(ranked.count, 1, "nothing to cycle through")
            XCTAssertEqual(ranked[0].dx, best.dx, accuracy: 1e-12)
            XCTAssertEqual(ranked[0].dy, best.dy, accuracy: 1e-12)
            for i in ranked.indices {
                for j in ranked.indices where j > i {
                    XCTAssertGreaterThanOrEqual(
                        hypot(ranked[i].dx - ranked[j].dx, ranked[i].dy - ranked[j].dy), 6 - 1e-9,
                        "two alternatives that are the same texture")
                }
                // None may borrow from the tube itself.
                for v in points {
                    XCTAssertGreaterThanOrEqual(
                        StrokeHeal.distance(StrokeHeal.Point(v.x + ranked[i].dx, v.y + ranked[i].dy),
                                            to: points), 12 - 1e-6)
                }
            }
        }
    }

    func testSlashCyclesEveryAlternativeAndComesBack() {
        let w = 200, h = 140
        let candidates: [(dx: Double, dy: Double)] = [(0.0, 0.1), (0.1, 0.0), (-0.1, 0.0)]
        var stroke = BrushStroke(points: [BrushPoint(x: 0.3, y: 0.5), BrushPoint(x: 0.7, y: 0.5)],
                                 size: 0.06, feather: 0,
                                 retouch: StrokeRetouch(dx: 0.0, dy: 0.1))
        var seen: [Int] = []
        for _ in 0..<4 {
            guard let next = StrokeSourceSearch.nextOffset(for: stroke, candidates: candidates,
                                                           sourceWidth: w, sourceHeight: h)
            else { return XCTFail("no next offset") }
            seen.append(candidates.firstIndex { $0.dx == next.dx && $0.dy == next.dy } ?? -1)
            stroke.retouch?.dx = next.dx
            stroke.retouch?.dy = next.dy
        }
        XCTAssertEqual(seen, [1, 2, 0, 1])
        // An offset the photographer dragged somewhere else goes to the best.
        stroke.retouch?.dx = 0.4
        XCTAssertEqual(StrokeSourceSearch.nextOffset(for: stroke, candidates: candidates,
                                                     sourceWidth: w, sourceHeight: h)?.dx, 0.0)
        // A stroke without retouch, or no candidates: nothing.
        XCTAssertNil(StrokeSourceSearch.nextOffset(for: stroke, candidates: [],
                                                   sourceWidth: w, sourceHeight: h))
        stroke.retouch = nil
        XCTAssertNil(StrokeSourceSearch.nextOffset(for: stroke, candidates: candidates,
                                                   sourceWidth: w, sourceHeight: h))
    }

    func testTheSourceLineIsAHandleAndDraggingItMovesOnlyTheOffset() {
        let stroke = BrushStroke(points: [BrushPoint(x: 0.2, y: 0.5), BrushPoint(x: 0.6, y: 0.5)],
                                 size: 0.05, feather: 50,
                                 retouch: StrokeRetouch(mode: .clone, dx: 0, dy: 0.2))
        // On the dashed source line (y = 0.7), and off it.
        XCTAssertTrue(StrokeHandles.hitSource(x: 0.4, y: 0.7, stroke: stroke,
                                              sourceWidth: 400, sourceHeight: 200))
        XCTAssertFalse(StrokeHandles.hitSource(x: 0.4, y: 0.5, stroke: stroke,
                                               sourceWidth: 400, sourceHeight: 200),
                       "the painted stroke is not its source")
        XCTAssertFalse(StrokeHandles.hitSource(x: 0.9, y: 0.7, stroke: stroke,
                                               sourceWidth: 400, sourceHeight: 200))
        // A hair-thin stroke is still a target at the minimum grab.
        XCTAssertTrue(StrokeHandles.hitSource(x: 0.4, y: 0.72, stroke: stroke,
                                              sourceWidth: 400, sourceHeight: 200,
                                              minimumGrab: 6))
        let moved = StrokeHandles.draggedSource(stroke, dx: 0.05, dy: -0.1)
        XCTAssertEqual(moved.points, stroke.points)
        XCTAssertEqual(moved.retouch?.dx ?? .nan, 0.05, accuracy: 1e-12)
        XCTAssertEqual(moved.retouch?.dy ?? .nan, 0.1, accuracy: 1e-12)
        XCTAssertEqual(moved.retouch?.mode, .clone)
        XCTAssertEqual(StrokeHandles.draggedSource(stroke, dx: .nan, dy: 0), stroke)
    }

    /// The window round trip: ranked offsets searched in a window come back in the
    /// stroke's own units and agree with the whole-frame answer.
    func testRankedOffsetsForAStrokeMatchTheAutoOffset() throws {
        let image = textured(240, 160)
        var stroke = BrushStroke(points: [BrushPoint(x: 0.3, y: 0.5), BrushPoint(x: 0.6, y: 0.52)],
                                 size: 0.05, feather: 50,
                                 retouch: StrokeRetouch(dx: 0, dy: 0))
        let window = SpotSourceSearch.Window(x: 0, y: 0, width: 240, height: 160, scale: 1)
        let auto = try XCTUnwrap(StrokeSourceSearch.autoOffset(for: stroke, in: image))
        let ranked = StrokeSourceSearch.rankedOffsets(for: stroke, in: image, window: window,
                                                      sourceWidth: 240, sourceHeight: 160)
        XCTAssertEqual(ranked.first?.dx ?? .nan, auto.dx, accuracy: 1e-12)
        XCTAssertEqual(ranked.first?.dy ?? .nan, auto.dy, accuracy: 1e-12)
        stroke.retouch?.dx = auto.dx
        stroke.retouch?.dy = auto.dy
        let next = StrokeSourceSearch.nextOffset(for: stroke, candidates: ranked,
                                                 sourceWidth: 240, sourceHeight: 160)
        XCTAssertEqual(next?.dx, ranked.count > 1 ? ranked[1].dx : ranked[0].dx)
    }
}
