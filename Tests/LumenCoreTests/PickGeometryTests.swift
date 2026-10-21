import XCTest
@testable import LumenCore

/// The displayed ↔ source mapping every eyedropper click goes through
/// (docs/quality/lanes/WS-02/SPEC.md F1). The renderer's CoreGraphics pair is the
/// authority; `PickGeometryParityTests` (LumenPipelineTests, macOS) holds this twin to it.
final class PickGeometryTests: XCTestCase {

    static let angles: [Double] = [-45, -30, -7.3, 0, 0.5, 12, 30, 45]
    static let crops: [Crop] = [Crop(), Crop(x: 0.1, y: 0.2, w: 0.5, h: 0.6),
                                Crop(x: 0, y: 0, w: 0.05, h: 0.05),
                                Crop(x: 0.7, y: 0.65, w: 0.3, h: 0.35)]
    static let sources: [(Double, Double)] = [(6000, 4000), (4000, 6000), (3, 2)]
    static let grid: [Double] = (0...10).map { Double($0) / 10 }

    /// Every combination the spec names: angle × flip × crop × source.
    static func everyGeometry() -> [(Geometry, Double, Double)] {
        var out: [(Geometry, Double, Double)] = []
        for angle in angles {
            for flip in [false, true] {
                for crop in crops {
                    for (w, h) in sources {
                        out.append((Geometry(crop: crop, angle: angle, flipH: flip), w, h))
                    }
                }
            }
        }
        return out
    }

    func testRoundTripBothWays() {
        var worst = 0.0
        for (geo, w, h) in Self.everyGeometry() {
            for u in Self.grid {
                for v in Self.grid {
                    let s = PickGeometry.sourcePoint(displayedX: u, displayedY: v, geometry: geo,
                                                     sourceWidth: w, sourceHeight: h)
                    let d = PickGeometry.displayedPoint(sourceX: s.x, sourceY: s.y, geometry: geo,
                                                        sourceWidth: w, sourceHeight: h)
                    worst = Swift.max(worst, abs(d.x - u), abs(d.y - v))
                    // And from the source side, with the grid read as source points.
                    let d2 = PickGeometry.displayedPoint(sourceX: u, sourceY: v, geometry: geo,
                                                         sourceWidth: w, sourceHeight: h)
                    let s2 = PickGeometry.sourcePoint(displayedX: d2.x, displayedY: d2.y,
                                                      geometry: geo,
                                                      sourceWidth: w, sourceHeight: h)
                    worst = Swift.max(worst, abs(s2.x - u), abs(s2.y - v))
                }
            }
        }
        XCTAssertLessThan(worst, 1e-9, "worst round-trip error \(worst)")
    }

    func testIdentity() {
        for (w, h) in Self.sources {
            for u in Self.grid {
                for v in Self.grid {
                    let s = PickGeometry.sourcePoint(displayedX: u, displayedY: v,
                                                     geometry: Geometry(),
                                                     sourceWidth: w, sourceHeight: h)
                    XCTAssertEqual(s.x, u, accuracy: 1e-12)
                    XCTAssertEqual(s.y, v, accuracy: 1e-12)
                }
            }
        }
    }

    func testPureCrop() {
        for crop in Self.crops {
            let geo = Geometry(crop: crop)
            let c = CropGeometry.normalized(crop)
            for u in Self.grid {
                for v in Self.grid {
                    let s = PickGeometry.sourcePoint(displayedX: u, displayedY: v, geometry: geo,
                                                     sourceWidth: 6000, sourceHeight: 4000)
                    XCTAssertEqual(s.x, c.x + u * c.w, accuracy: 1e-12)
                    XCTAssertEqual(s.y, c.y + v * c.h, accuracy: 1e-12)
                }
            }
        }
    }

    func testFlipHMirrorsX() {
        for u in Self.grid {
            for v in Self.grid {
                let s = PickGeometry.sourcePoint(displayedX: u, displayedY: v,
                                                 geometry: Geometry(flipH: true),
                                                 sourceWidth: 6000, sourceHeight: 4000)
                XCTAssertEqual(s.x, 1 - u, accuracy: 1e-12)
                XCTAssertEqual(s.y, v, accuracy: 1e-12)
            }
        }
    }

    /// A centred crop's centre is the picture's centre whatever the rotation or mirror.
    func testCentreMapsToCentre() {
        for angle in Self.angles {
            for flip in [false, true] {
                for crop in [Crop(), Crop(x: 0.25, y: 0.25, w: 0.5, h: 0.5)] {
                    for (w, h) in Self.sources {
                        let geo = Geometry(crop: crop, angle: angle, flipH: flip)
                        let s = PickGeometry.sourcePoint(displayedX: 0.5, displayedY: 0.5,
                                                         geometry: geo,
                                                         sourceWidth: w, sourceHeight: h)
                        XCTAssertEqual(s.x, 0.5, accuracy: 1e-12, "\(geo) \(w)x\(h)")
                        XCTAssertEqual(s.y, 0.5, accuracy: 1e-12, "\(geo) \(w)x\(h)")
                    }
                }
            }
        }
    }

    /// The crop is inscribed, so no displayed corner can map outside the source.
    func testDisplayedCornersLandInsideTheSource() {
        for (geo, w, h) in Self.everyGeometry() {
            for (u, v) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
                let s = PickGeometry.sourcePoint(displayedX: u, displayedY: v, geometry: geo,
                                                 sourceWidth: w, sourceHeight: h)
                XCTAssertTrue(s.x >= -1e-9 && s.x <= 1 + 1e-9
                                  && s.y >= -1e-9 && s.y <= 1 + 1e-9,
                              "corner (\(u), \(v)) of \(geo) on \(w)x\(h) → \(s)")
            }
        }
    }

    /// The one case with a by-hand answer: a square at ±45° shows the inscribed diamond's
    /// square, whose top-left corner touches the source's left or top edge midpoint.
    func testFortyFiveDegreesOnASquare() {
        let plus = PickGeometry.sourcePoint(displayedX: 0, displayedY: 0,
                                            geometry: Geometry(angle: 45),
                                            sourceWidth: 1000, sourceHeight: 1000)
        XCTAssertEqual(plus.x, 0, accuracy: 1e-9)
        XCTAssertEqual(plus.y, 0.5, accuracy: 1e-9)
        let minus = PickGeometry.sourcePoint(displayedX: 0, displayedY: 0,
                                             geometry: Geometry(angle: -45),
                                             sourceWidth: 1000, sourceHeight: 1000)
        XCTAssertEqual(minus.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(minus.y, 0, accuracy: 1e-9)
    }
}
