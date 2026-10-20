// MaskGuidePlaneTests.swift
// The refine guide's percentile normalization, selected instead of sorted.
//
// `guidePlane` used to sort the whole log-luminance plane to read two percentiles and
// the extremes; it now selects them. That is only a speed change if the selected values
// are the SAME Floats the sort gave, so every assertion here is exact equality against
// the old sort-based guide, kept below as the reference — not a tolerance, which would
// let a selection that is off by one rank pass on a smooth plane.

import XCTest
@testable import LumenCore

final class MaskGuidePlaneTests: XCTestCase {

    // MARK: - Reference

    /// The guide exactly as it was before selection: full sort, read by index.
    private func sortedReferenceGuide(_ src: ImageBuffer, _ w: Int, _ h: Int) -> Plane {
        var g = Plane(width: w, height: h)
        let weights = RGBColorSpace.rec2020.luminanceWeights
        for y in 0..<h {
            for x in 0..<w {
                let c = MaskRaster.srcColor(src, x, y, w, h)
                let luminance = weights.r * c.r + weights.g * c.g + weights.b * c.b
                g[x, y] = Num.safeLog2(luminance.isFinite ? luminance : 0, floorEV: -16)
            }
        }
        var sorted = g.values
        sorted.sort()
        guard let first = sorted.first, let last = sorted.last else { return g }
        let loIndex = Swift.min(sorted.count - 1, Swift.max(0, Int(Double(sorted.count) * 0.02)))
        let hiIndex = Swift.min(sorted.count - 1, Swift.max(0, Int(Double(sorted.count) * 0.98)))
        var lo = Double(sorted[loIndex])
        var hi = Double(sorted[hiIndex])
        if !(hi > lo) { lo = Double(first); hi = Double(last) }
        let span = Swift.max(hi - lo, 1e-6)
        return g.map { Num.saturate(($0 - lo) / span) }
    }

    // MARK: - Fixtures

    /// Deterministic LCG so a failure reproduces.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private func buffer(_ w: Int, _ h: Int, _ grey: (Int, Int) -> Float) -> ImageBuffer {
        var px = [Float](repeating: 1, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let v = grey(x, y)
                px[i] = v; px[i + 1] = v; px[i + 2] = v
            }
        }
        return ImageBuffer(width: w, height: h, pixels: px)
    }

    private func assertGuideMatchesSort(_ src: ImageBuffer, _ w: Int, _ h: Int,
                                        _ label: String, file: StaticString = #filePath,
                                        line: UInt = #line) {
        let got = MaskRaster.guidePlane(source: src, width: w, height: h)
        let want = sortedReferenceGuide(src, w, h)
        XCTAssertEqual(got.values, want.values, label, file: file, line: line)
    }

    // MARK: - guidePlane against the sort

    func testRandomPlanesMatchTheSortedGuideExactly() {
        var rng = LCG(state: 0x9E37_79B9)
        for (w, h) in [(37, 29), (64, 64), (200, 150)] {
            let src = buffer(w, h) { _, _ in Float(pow(2, rng.next() * 20 - 12)) }
            assertGuideMatchesSort(src, w, h, "random \(w)×\(h)")
        }
    }

    func testTieHeavyPlanesMatchTheSortedGuideExactly() {
        // Constant: p2 == p98 == min == max, the `!(hi > lo)` fallback with zero span.
        assertGuideMatchesSort(buffer(48, 48) { _, _ in 0.18 }, 48, 48, "constant")
        // Two-valued, 99% one value: p2 and p98 coincide, the fallback widens to min/max.
        assertGuideMatchesSort(buffer(100, 40) { x, y in (x + y * 100) % 100 == 0 ? 4 : 0.05 },
                               100, 40, "two-valued 99%")
        // 95% at the −16 EV floor — a black frame or astro sky — with a bright tail.
        var rng = LCG(state: 42)
        assertGuideMatchesSort(buffer(120, 90) { _, _ in
            rng.next() < 0.95 ? 0 : Float(rng.next() * 8)
        }, 120, 90, "95% floor")
        // A handful of distinct levels, heavily repeated.
        assertGuideMatchesSort(buffer(77, 51) { x, y in Float(1 + (x * 7 + y * 3) % 5) },
                               77, 51, "five levels")
    }

    func testTinyPlanesMatchTheSortedGuideExactly() {
        for (w, h) in [(1, 1), (2, 1), (3, 1), (3, 3)] {
            let src = buffer(w, h) { x, y in Float(1 + x * 3 + y) * 0.1 }
            assertGuideMatchesSort(src, w, h, "\(w)×\(h)")
        }
    }

    func testResampledSourceMatchesTheSortedGuideExactly() {
        // The bake samples a source of a different size bilinearly; same select either way.
        var rng = LCG(state: 7)
        let src = buffer(90, 70) { _, _ in Float(rng.next() * 3) }
        assertGuideMatchesSort(src, 61, 47, "resampled")
    }

    func testDifferentPlanesGiveDifferentGuides() {
        // The other half: the selection is not a constant answer that happens to match.
        // (Not x against x²: in log space that is a pure scale, which the percentile
        // normalization exists to cancel — the two guides would rightly be equal.)
        let a = MaskRaster.guidePlane(source: buffer(32, 32) { x, _ in Float(x + 1) }, width: 32, height: 32)
        let b = MaskRaster.guidePlane(source: buffer(32, 32) { x, _ in Float(32 - x) }, width: 32, height: 32)
        XCTAssertNotEqual(a.values, b.values)
        XCTAssertEqual(a[0, 0], 0)
        XCTAssertEqual(b[0, 0], 1)
    }

    // MARK: - kthSmallest

    func testKthSmallestIsTheSortedValueForEveryRank() {
        var rng = LCG(state: 2026)
        let shapes: [[Float]] = [
            (0..<200).map { _ in Float(rng.next()) },
            (0..<200).map { _ in Float(Int(rng.next() * 4)) },
            [Float](repeating: -16, count: 150) + [1, 2, 3],
            [Float](repeating: 5, count: 64),
            (0..<3000).map { _ in rng.next() < 0.9 ? -16 : Float(rng.next()) },
            [7], [2, 1],
        ]
        for values in shapes {
            let sorted = values.sorted()
            for k in values.indices {
                var a = values
                XCTAssertEqual(MaskRaster.kthSmallest(&a, k, in: 0..<a.count), sorted[k],
                               "n=\(values.count) k=\(k)")
                // The partition contract the second select depends on.
                XCTAssertTrue(a[..<k].allSatisfy { $0 <= a[k] }, "below k, n=\(values.count) k=\(k)")
                XCTAssertTrue(a[(k + 1)...].allSatisfy { $0 >= a[k] }, "above k, n=\(values.count) k=\(k)")
                XCTAssertEqual(a.sorted(), sorted, "kthSmallest must permute, not alter")
            }
        }
    }

    func testSecondSelectOnTheTailMatchesTheSortedValue() {
        var rng = LCG(state: 99)
        for n in [5, 50, 2000, 5000] {
            let values: [Float] = (0..<n).map { _ in
                rng.next() < 0.5 ? -16 : Float(Int(rng.next() * 9))
            }
            let sorted = values.sorted()
            let loK = Swift.min(n - 1, Int(Double(n) * 0.02))
            for hiK in Set([loK + 1, n / 2, Swift.min(n - 1, Int(Double(n) * 0.98)), n - 1]) where hiK > loK && hiK < n {
                var a = values
                XCTAssertEqual(MaskRaster.kthSmallest(&a, loK, in: 0..<n), sorted[loK])
                XCTAssertEqual(MaskRaster.kthSmallest(&a, hiK, in: (loK + 1)..<n), sorted[hiK],
                               "n=\(n) hiK=\(hiK)")
            }
        }
    }
}
