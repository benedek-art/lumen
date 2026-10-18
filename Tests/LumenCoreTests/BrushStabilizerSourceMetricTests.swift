import XCTest
@testable import LumenCore

final class BrushStabilizerSourceMetricTests: XCTestCase {
    private func sample(width: Double, height: Double, dx: Double, dy: Double,
                        strength: Double = 100) -> (x: Double, y: Double)? {
        var helper = BrushStabilizer(strength: strength,
                                     sourceWidth: width, sourceHeight: height)
        _ = helper.next(x: 0.25, y: 0.25)
        guard let p = helper.next(x: 0.25 + dx / width, y: 0.25 + dy / height)
        else { return nil }
        return ((p.x - 0.25) * width, (p.y - 0.25) * height)
    }

    func testEqualPixelTravelHasOneLongEdgeRopeInLandscapeAndPortrait() throws {
        for (width, height) in [(1000.0, 500.0), (500.0, 1000.0), (1000.0, 1000.0)] {
            // At100 rope=20px. A30px move leaves10px of brush travel, on either axis.
            let h = try XCTUnwrap(sample(width: width, height: height, dx: 30, dy: 0))
            let v = try XCTUnwrap(sample(width: width, height: height, dx: 0, dy: 30))
            XCTAssertEqual(h.x, 10, accuracy: 1e-10)
            XCTAssertEqual(v.y, 10, accuracy: 1e-10)
            XCTAssertNil(sample(width: width, height: height, dx: 15, dy: 0))
            XCTAssertNil(sample(width: width, height: height, dx: 0, dy: 15))
        }
    }

    func testObliqueTravelAndReflectionUsePixelDistance() throws {
        // A3:4:5 direction travelling50px on a1000px long edge leaves30px travel.
        // Expected displacement is the physical unit direction times30, independent
        // of normalized aspect, reflection or a quarter-turn of pointer direction.
        for (dx, dy) in [(30.0, 40.0), (-30.0, 40.0), (40.0, -30.0)] {
            let p = try XCTUnwrap(sample(width: 1000, height: 500, dx: dx, dy: dy))
            XCTAssertEqual(p.x, dx * 0.6, accuracy: 1e-10)
            XCTAssertEqual(p.y, dy * 0.6, accuracy: 1e-10)
        }
    }

    func testFinalReleaseIsExactAndDisabledSamplesRemainExact() throws {
        var seed = BrushStabilizer(strength: 100, sourceWidth: 1000, sourceHeight: 333)
        let first = try XCTUnwrap(seed.next(x: 0.987654321, y: 0.123456789))
        XCTAssertEqual(first.x, 0.987654321)
        XCTAssertEqual(first.y, 0.123456789)
        var helper = BrushStabilizer(strength: 100, sourceWidth: 1000, sourceHeight: 500)
        _ = helper.next(x: 0.25, y: 0.25)
        _ = helper.next(x: 0.28, y: 0.31)
        let end = try XCTUnwrap(helper.finish(x: 0.28, y: 0.31))
        XCTAssertEqual(end.x, 0.28)
        XCTAssertEqual(end.y, 0.31)
        XCTAssertNil(helper.finish(x: 0.28, y: 0.31))
        var off = BrushStabilizer(strength: 0, sourceWidth: 1000, sourceHeight: 333)
        for (x, y) in [(0.123456789, 0.987654321), (-0.2, 1.1)] {
            let p = try XCTUnwrap(off.next(x: x, y: y))
            XCTAssertEqual(p.x, x)
            XCTAssertEqual(p.y, y)
        }
    }

    func testLegacyUnitMetricAndInvalidDimensionsRetainTheirContract() throws {
        var legacy = BrushStabilizer(strength: 100)
        var square = BrushStabilizer(strength: 100, sourceWidth: 500, sourceHeight: 500)
        var unknown = BrushStabilizer(strength: 100, sourceWidth: .nan, sourceHeight: 0)
        for (x, y) in [(0.2, 0.3), (0.3, 0.5), (0.7, 0.4)] {
            let a = try XCTUnwrap(legacy.next(x: x, y: y))
            let b = try XCTUnwrap(square.next(x: x, y: y))
            let c = try XCTUnwrap(unknown.next(x: x, y: y))
            XCTAssertEqual(a.x, b.x); XCTAssertEqual(a.y, b.y)
            XCTAssertEqual(a.x, c.x); XCTAssertEqual(a.y, c.y)
        }
        XCTAssertEqual(legacy.length, 0.02)
    }

    func testUnrepresentableMetricAndNonfiniteRopeRemainSafe() throws {
        for (width, height) in [(Double.infinity, 500.0), (0.0, 500.0),
                                (Double.leastNonzeroMagnitude, Double.greatestFiniteMagnitude)] {
            var helper = BrushStabilizer(strength: 100, sourceWidth: width, sourceHeight: height)
            _ = helper.next(x: 0.25, y: 0.25)
            let p = try XCTUnwrap(helper.next(x: 0.30, y: 0.25))
            XCTAssertEqual(p.x, 0.28, accuracy: 1e-12)
            XCTAssertTrue(p.y.isFinite)
        }
        for rope in [Double.nan, .infinity, -.infinity, -1] {
            let helper = BrushStabilizer(strength: 100, maxLength: rope,
                                         sourceWidth: 1000, sourceHeight: 500)
            XCTAssertEqual(helper.length, 0)
        }
    }
}
