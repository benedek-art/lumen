// MathTests.swift
// Curve, zone-weight, mask-algebra, and xxh64 goldens — every expected value was
// computed AND property-checked by the Python reference (scripts/gen-fixtures.py):
// curves proven monotone, zone weights proven a partition of unity, xxh64 checked
// against the reference C implementation. These tests prove the Swift ports match.

import XCTest
@testable import LumenCore

private struct CurvesFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let points: [[Double]]
        let samples: [Double]
        let values: [Double]
    }
    let cases: [Case]
}

private struct ZonesFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let pivots: [Double]
        let samples: [Double]
        let weights: [[Double]]
    }
    struct Exposure: Decodable {
        let pivots: [Double]
        let zoneEV: [Double]
        let globalEV: Double
        let samples: [Double]
        let stops: [Double]
    }
    let cases: [Case]
    let exposure: Exposure
}

private struct MaskFixture: Decodable {
    struct Component: Decodable {
        let op: String
        let alpha: Double
        let invert: Bool
        let amount: Double
    }
    struct Case: Decodable {
        let name: String
        let stack: [Component]
        let expected: Double
    }
    let cases: [Case]
}

private struct FingerprintFixture: Decodable {
    struct Vector: Decodable {
        let input: String
        let xxh64: String
    }
    let vectors: [Vector]
}

final class MathTests: XCTestCase {

    private let eps = 1e-9

    func testMonotoneCubicMatchesReference() throws {
        let fixture = try Fixtures.load("curves", as: CurvesFixture.self)
        for c in fixture.cases {
            let curve = MonotoneCubic(points: c.points)
            for (x, expected) in zip(c.samples, c.values) {
                XCTAssertEqual(curve.evaluate(x), expected, accuracy: eps,
                               "curve \(c.name) at x=\(x)")
            }
        }
    }

    func testMonotoneCubicStaysMonotone() {
        let curve = MonotoneCubic(points: [[0, 0], [0.1, 0.05], [0.2, 0.9], [1, 1]])
        var last = -Double.infinity
        for i in 0...500 {
            let y = curve.evaluate(Double(i) / 500)
            XCTAssertGreaterThanOrEqual(y, last - 1e-12, "overshoot at i=\(i)")
            last = y
        }
    }

    func testBakeLUTEndpoints() {
        let curve = MonotoneCubic(points: [[0, 0.1], [1, 0.9]])
        let lut = curve.bakeLUT(size: 256)
        XCTAssertEqual(lut.count, 256)
        XCTAssertEqual(lut.first!, 0.1, accuracy: eps)
        XCTAssertEqual(lut.last!, 0.9, accuracy: eps)
    }

    func testZoneWeightsMatchReference() throws {
        let fixture = try Fixtures.load("zones", as: ZonesFixture.self)
        for c in fixture.cases {
            for (x, expected) in zip(c.samples, c.weights) {
                let w = ZoneWeights.weights(x: x, pivots: c.pivots)
                XCTAssertEqual(w.count, expected.count)
                for (wi, ei) in zip(w, expected) {
                    XCTAssertEqual(wi, ei, accuracy: eps, "zones \(c.name) at x=\(x)")
                }
                XCTAssertEqual(w.reduce(0, +), 1, accuracy: eps,
                               "partition of unity at x=\(x)")
            }
        }
        let e = fixture.exposure
        for (x, expected) in zip(e.samples, e.stops) {
            XCTAssertEqual(
                ZoneWeights.exposureStops(x: x, pivots: e.pivots,
                                          zoneEV: e.zoneEV, globalEV: e.globalEV),
                expected, accuracy: eps)
        }
    }

    func testMaskAlgebraMatchesReference() throws {
        let fixture = try Fixtures.load("maskalgebra", as: MaskFixture.self)
        for c in fixture.cases {
            let stack = c.stack.map { comp in
                (op: MaskOp(rawValue: comp.op)!, invert: comp.invert,
                 amount: comp.amount, alpha: comp.alpha)
            }
            XCTAssertEqual(MaskAlgebra.combined(stack), c.expected, accuracy: eps,
                           "mask case \(c.name)")
        }
    }

    func testXXH64MatchesReferenceImplementation() throws {
        let fixture = try Fixtures.load("fingerprint", as: FingerprintFixture.self)
        for v in fixture.vectors {
            XCTAssertEqual(XXH64.hexDigest(v.input), v.xxh64,
                           "xxh64 mismatch for input of \(v.input.utf8.count) bytes")
        }
    }
}
