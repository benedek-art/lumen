import XCTest
@testable import LumenCore

/// The crop guides' geometry (lane C1, SPEC M7 and the O cycle).
final class CropGuidesTests: XCTestCase {

    private let aspects = [0.5, 1.0, 1.5, 3.0]

    func testOCycleVisitsEveryStyleOnceAndReturns() {
        var seen: [CropGuides.Style] = []
        var s = CropGuides.Style.thirds
        repeat {
            seen.append(s)
            s = s.next
        } while s != .thirds && seen.count < 20
        XCTAssertEqual(Set(seen), Set(CropGuides.Style.allCases))
        XCTAssertEqual(seen.count, CropGuides.Style.allCases.count)
        XCTAssertEqual(seen, [.thirds, .golden, .grid, .diagonals, .triangle, .spiral, .off])
    }

    func testEverySegmentStaysInsideTheRectangle() {
        for style in CropGuides.Style.allCases {
            for aspect in aspects {
                let w = 300 * aspect, h = 300.0
                for turn in 0..<4 {
                    let segments = CropGuides.segments(style, width: w, height: h,
                                                       orientation: turn)
                    if style == .off { XCTAssertTrue(segments.isEmpty) } else {
                        XCTAssertFalse(segments.isEmpty, "\(style)")
                    }
                    for s in segments {
                        for (x, y) in [(s.x0, s.y0), (s.x1, s.y1)] {
                            XCTAssertTrue(x >= -1e-9 && x <= w + 1e-9 && y >= -1e-9
                                          && y <= h + 1e-9, "\(style) \(aspect) \(turn)")
                        }
                    }
                }
            }
        }
        XCTAssertTrue(CropGuides.segments(.thirds, width: 0, height: 10).isEmpty)
    }

    func testGoldenRatioSitsAtPointSixOneEight() {
        let segments = CropGuides.segments(.golden, width: 1000, height: 1000)
        let xs = Set(segments.filter { $0.x0 == $0.x1 }.map { ($0.x0 * 1000).rounded() / 1000 })
        XCTAssertEqual(xs, [381.966, 618.034])
    }

    /// The perpendiculars meet the diagonal at a right angle in the rectangle's REAL
    /// units, and their feet lie on it.
    func testTriangleIsAGoldenTriangleInRealUnits() {
        for aspect in aspects {
            let w = 400 * aspect, h = 400.0
            for turn in 0..<2 {
                let s = CropGuides.segments(.triangle, width: w, height: h, orientation: turn)
                XCTAssertEqual(s.count, 3)
                let d = s[0]
                let dx = d.x1 - d.x0, dy = d.y1 - d.y0
                XCTAssertEqual(abs(dx), w, accuracy: 1e-9)
                XCTAssertEqual(abs(dy), h, accuracy: 1e-9)
                for p in s[1...] {
                    let px = p.x1 - p.x0, py = p.y1 - p.y0
                    XCTAssertEqual((px * dx + py * dy) / (w * h), 0, accuracy: 1e-9)
                    // The foot is on the diagonal.
                    let cross = (p.x1 - d.x0) * dy - (p.y1 - d.y0) * dx
                    XCTAssertEqual(cross / (w * h), 0, accuracy: 1e-9)
                }
            }
            let a = CropGuides.segments(.triangle, width: w, height: h, orientation: 0)[0]
            let b = CropGuides.segments(.triangle, width: w, height: h, orientation: 1)[0]
            XCTAssertNotEqual(a, b, "⇧O must give the mirrored triangle")
        }
    }

    /// The spiral is continuous, and each of the four orientations puts its eye in a
    /// different quadrant.
    func testSpiralIsContinuousAndEachTurnMovesTheEye() {
        for aspect in aspects {
            let w = 500 * aspect, h = 500.0
            var quadrants = Set<Int>()
            for turn in 0..<4 {
                let s = CropGuides.segments(.spiral, width: w, height: h, orientation: turn)
                for (a, b) in zip(s, s.dropFirst()) {
                    XCTAssertEqual(a.x1, b.x0, accuracy: 1e-9)
                    XCTAssertEqual(a.y1, b.y0, accuracy: 1e-9)
                }
                let eye = s.last!
                let q = (eye.x1 > w / 2 ? 1 : 0) + (eye.y1 > h / 2 ? 2 : 0)
                quadrants.insert(q)
                // Starts on the rectangle's boundary.
                let start = s.first!
                let onEdge = abs(start.x0) < 1e-6 || abs(start.x0 - w) < 1e-6
                    || abs(start.y0) < 1e-6 || abs(start.y0 - h) < 1e-6
                XCTAssertTrue(onEdge)
            }
            XCTAssertEqual(quadrants.count, 4, "aspect \(aspect)")
        }
    }

    func testRotationGridIsFinerThanTheGridGuide() {
        let fine = CropGuides.rotationGrid(width: 100, height: 100)
        let grid = CropGuides.segments(.grid, width: 100, height: 100)
        XCTAssertEqual(fine.count, 2 * (CropGuides.rotationGridDivisions - 1))
        XCTAssertGreaterThan(fine.count, grid.count)
    }
}
