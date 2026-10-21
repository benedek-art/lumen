// MaskRefineQualityTests.swift
// The refine chain's acceptance lines (docs/quality/lanes/WS-50/SPEC.md R1–R11) that a
// unit test can hold: identity at the defaults, Expand monotone at every pixel and free
// of new speckle, Expand matching an exact disc, Follow seeing colour, and the whole
// chain staying finite and inside [0, 1].

import XCTest
@testable import LumenCore

final class MaskRefineQualityTests: XCTestCase {

    // MARK: - Fixtures

    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private func radial(_ cx: Double, _ cy: Double, _ r: Double, feather: Double,
                        amount: Double = 100) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial, amount: amount)
        c.center = [cx, cy]
        c.radii = [r, r]
        c.feather = feather
        c.rotation = 0
        return c
    }

    private func folded(_ components: [MaskComponent], _ n: Int,
                        refine: MaskRefine = MaskRefine(), source: ImageBuffer? = nil) -> Plane {
        var m = Mask(components: components)
        m.refine = refine
        return MaskRaster.combine(mask: m, size: (width: n, height: n), source: source)
    }

    /// A range-mask stand-in: a soft radial with per-pixel noise on it, so the plane is
    /// full of one- and two-pixel features — the texture a colour or luminance range
    /// produces and the case the old advection broke on.
    private func speckled(_ n: Int, seed: UInt64 = 7) -> Plane {
        var rng = LCG(state: seed)
        let base = folded([radial(0.5, 0.5, 0.3, feather: 60)], n)
        return base.map { Num.saturate($0 + 0.9 * (rng.next() - 0.5)) }
    }

    /// Hard radial beside a soft one: the fixture that named the old erosion defect.
    private func mixed(_ n: Int) -> Plane {
        folded([radial(0.30, 0.50, 0.15, feather: 0), radial(0.70, 0.50, 0.20, feather: 100)], n)
    }

    /// Components smaller than 16 px of the α > 0.5 set and of its complement,
    /// 4-connected — the speckle count `refcheck.py` reports on the corpus.
    private func speckleCount(_ p: Plane) -> Int {
        let w = p.width, h = p.height
        var seen = [Bool](repeating: false, count: w * h)
        var small = 0
        var stack: [Int] = []
        for start in 0..<(w * h) where !seen[start] {
            let side = p.values[start] > 0.5
            var size = 0
            seen[start] = true
            stack.append(start)
            while let i = stack.popLast() {
                size += 1
                let x = i % w, y = i / w
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                where nx >= 0 && nx < w && ny >= 0 && ny < h {
                    let j = ny * w + nx
                    if !seen[j] && (p.values[j] > 0.5) == side {
                        seen[j] = true
                        stack.append(j)
                    }
                }
            }
            if size < 16 { small += 1 }
        }
        return small
    }

    private let edgeSweep: [Double] = [-50, -30, -18, -10, -6, -3, -1, -0.4, 0,
                                       0.4, 1, 3, 6, 10, 18, 30, 50]

    // MARK: - R1 identity

    func testDefaultsAreAnExactIdentity() {
        let n = 96
        var rng = LCG(state: 3)
        let source = ImageBuffer(width: n, height: n) { _, _ in
            let v = 0.02 + rng.next()
            return RGB(v, v * 0.8, v * 0.6)
        }
        for components in [[radial(0.5, 0.5, 0.3, feather: 40)],
                           [radial(0.3, 0.5, 0.2, feather: 0),
                            radial(0.7, 0.5, 0.2, feather: 100)]] {
            var bare = Plane(width: n, height: n)
            for c in components {
                let raw = MaskRaster.rasterize(component: c, size: (width: n, height: n))
                for i in 0..<bare.values.count {
                    bare.values[i] = Swift.max(bare.values[i], raw.values[i])
                }
            }
            XCTAssertEqual(folded(components, n, source: source).values, bare.values,
                           "MaskRefine() changed the fold")
            XCTAssertEqual(MaskRaster.edgeShifted(bare, edge: 0, longEdge: n).values,
                           bare.values)
            XCTAssertEqual(MaskRaster.refined(bare, refine: MaskRefine(), source: source).values,
                           bare.values)
        }
    }

    // MARK: - R2 / R3 Expand: monotone, no new speckle

    func testExpandIsMonotoneAtEveryPixel() {
        for (name, plane) in [("speckled", speckled(128)), ("mixed", mixed(128)),
                              ("partial plateau",
                               folded([radial(0.5, 0.5, 0.25, feather: 0, amount: 60)], 128))] {
            var previous: Plane?
            var previousEdge = 0.0
            for edge in edgeSweep {
                let p = MaskRaster.edgeShifted(plane, edge: edge, longEdge: 1280)
                if let prev = previous {
                    var worst: Float = 0
                    for i in 0..<p.values.count {
                        worst = Swift.max(worst, prev.values[i] - p.values[i])
                    }
                    XCTAssertLessThanOrEqual(worst, 1e-6,
                                             "\(name): Edge \(previousEdge) → \(edge) "
                                             + "lowered a pixel by \(worst)")
                }
                previous = p
                previousEdge = edge
            }
        }
    }

    func testExpandNeverAddsSpeckle() {
        let plane = speckled(160)
        let base = speckleCount(plane)
        XCTAssertGreaterThan(base, 20, "the fixture is not speckled enough to measure")
        for edge in edgeSweep where edge != 0 {
            let c = speckleCount(MaskRaster.edgeShifted(plane, edge: edge, longEdge: 1600))
            XCTAssertLessThanOrEqual(c, base, "Edge \(edge) made speckle: \(base) → \(c)")
        }
    }

    // MARK: - R4 / R5 Expand moves the boundary by the shift and keeps the profile

    func testFullTravelIsOnePercentOfTheLongEdge() {
        let n = 400
        let plane = folded([radial(0.5, 0.5, 0.25, feather: 0)], n)
        /// The 0.5 crossing along the centre row, to the right of the centre, interpolated.
        func crossing(_ p: Plane) -> Double {
            let y = n / 2
            for x in (n / 2)..<(n - 1) where p[x, y] >= 0.5 && p[x + 1, y] < 0.5 {
                return Double(x) + (p[x, y] - 0.5) / (p[x, y] - p[x + 1, y])
            }
            return .nan
        }
        let base = crossing(plane)
        // Ten times the raster's long edge, so 1 % is 40 px and the octagon's ±4 % shows.
        for edge in [50.0, -50.0] {
            let moved = crossing(MaskRaster.edgeShifted(plane, edge: edge, longEdge: 4000))
            let wanted = 40.0 * (edge > 0 ? 1 : -1)
            XCTAssertEqual(moved - base, wanted, accuracy: abs(wanted) * 0.06,
                           "Edge \(edge) moved the boundary \(moved - base) px, not \(wanted)")
        }
    }

    func testErosionNeverRaisesAPixel() {
        let plane = folded([radial(0.5, 0.5, 0.3, feather: 100)], 160)
        for edge in edgeSweep where edge < 0 {
            let p = MaskRaster.edgeShifted(plane, edge: edge, longEdge: 1600)
            var worst: Float = 0
            for i in 0..<p.values.count { worst = Swift.max(worst, p.values[i] - plane.values[i]) }
            XCTAssertLessThanOrEqual(worst, 1e-6, "Edge \(edge) raised a pixel by \(worst)")
        }
    }

    /// The profile claim, against the definition: a flat dilation by an exact disc of the
    /// same radius, brute force. The octagon may differ by its ±4 % in radius; on a soft
    /// radial that is a small fraction of one ramp step.
    func testExpandMatchesAnExactDisc() {
        let n = 128
        let plane = folded([radial(0.5, 0.5, 0.28, feather: 70)], n)
        let longEdge = 1280
        for edge in [50.0, -50.0] {
            let radius = 0.01 * Double(longEdge)
            let r = Int(radius.rounded(.up))
            var exact = Plane(width: n, height: n)
            for y in 0..<n {
                for x in 0..<n {
                    var best: Float = edge > 0 ? 0 : 1
                    for dy in -r...r {
                        for dx in -r...r where Double(dx * dx + dy * dy) <= radius * radius {
                            let v = plane.values[Swift.min(Swift.max(y + dy, 0), n - 1) * n
                                                 + Swift.min(Swift.max(x + dx, 0), n - 1)]
                            best = edge > 0 ? Swift.max(best, v) : Swift.min(best, v)
                        }
                    }
                    exact[x, y] = Double(best)
                }
            }
            let ours = MaskRaster.edgeShifted(plane, edge: edge, longEdge: longEdge)
            var sum = 0.0
            for i in 0..<ours.values.count { sum += abs(Double(ours.values[i] - exact.values[i])) }
            XCTAssertLessThan(sum / Double(n * n), 0.01,
                              "Edge \(edge) is \(sum / Double(n * n)) from an exact disc")
        }
    }

    // MARK: - R7 Follow sees colour

    /// Red beside green at the SAME luminance, and a rough selection that overshoots the
    /// red into the green by 2 px. A brightness guide sees no edge there and can only
    /// blur; the colour guide sees the hue edge. A guided filter transfers structure
    /// rather than snapping to it, so the claim is "half the overshoot", which is what
    /// the numpy prototype measures too (0.28 against 0.55), not "none".
    func testFollowSeparatesEquallyBrightColours() {
        let n = 128
        let space = RGBColorSpace.rec2020
        let red = RGB(0.30, 0.05, 0.05)
        let greenRaw = RGB(0.05, 0.30, 0.05)
        let green = greenRaw * (space.luminance(red) / space.luminance(greenRaw))
        let source = ImageBuffer(width: n, height: n) { u, _ in u < 0.5 ? red : green }
        let overshootPx = 2
        var rough = Plane(width: n, height: n)
        for y in 0..<n { for x in 0..<(n / 2 + overshootPx) { rough[x, y] = 1 } }

        // Follow 100 on a 128-px plane is r = 3 px; drive the filter directly at r = 10,
        // the radius it has at Follow 100 on a 500-px plane.
        let guide = MaskRaster.colourGuide(source: source, width: n, height: n)
        let colour = MaskRaster.colourGuidedFilter(rough, guide: guide, radius: 10, epsilon: 1e-4)
        let luma = SpatialOps.guidedFilter(input: rough, guide: guide[0], radius: 10, epsilon: 1e-4)
        func overshoot(_ p: Plane) -> Double {
            var s = 0.0
            for y in 20..<(n - 20) {
                for x in (n / 2)..<(n / 2 + overshootPx) { s += Num.saturate(p[x, y]) }
            }
            return s / Double((n - 40) * overshootPx)
        }
        XCTAssertGreaterThan(overshoot(luma), 0.5, "the brightness guide should not see this edge")
        XCTAssertLessThan(overshoot(colour), 0.6 * overshoot(luma),
                          "Follow did not pull the selection toward the hue edge "
                          + "(colour \(overshoot(colour)), brightness \(overshoot(luma)))")
        XCTAssertGreaterThan(colour[n / 4, n / 2], 0.95, "the red side lost its selection")
    }

    // MARK: - R11 range

    func testWholeChainStaysInRange() {
        let n = 96
        var rng = LCG(state: 11)
        let source = ImageBuffer(width: n, height: n) { u, v in
            RGB(0.01 + u * u * 4, 0.02 + rng.next() * 0.5, 0.01 + v)
        }
        let settings: [MaskRefine] = [
            MaskRefine(feather: 100, edge: 50, blur: 100, levelsLo: 90, levelsHi: 10, levelsGamma: 5),
            MaskRefine(feather: 100, edge: -50, blur: 0, levelsLo: 0, levelsHi: 1, levelsGamma: 0.2),
            MaskRefine(feather: 37, edge: 0.3, blur: 2, levelsLo: 50, levelsHi: 50, levelsGamma: 1),
            MaskRefine(feather: .nan, edge: .infinity, blur: -.infinity,
                       levelsLo: .nan, levelsHi: .nan, levelsGamma: .nan),
        ]
        for refine in settings {
            for components in [[radial(0.5, 0.5, 0.3, feather: 50)],
                               [radial(0.3, 0.5, 0.2, feather: 0, amount: 60),
                                radial(0.7, 0.5, 0.2, feather: 100)]] {
                let p = folded(components, n, refine: refine, source: source)
                for v in p.values {
                    XCTAssertTrue(v.isFinite && v >= 0 && v <= 1, "\(refine): alpha \(v)")
                }
            }
        }
    }
}
