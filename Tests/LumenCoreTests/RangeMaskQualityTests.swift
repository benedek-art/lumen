import XCTest
@testable import LumenCore

/// WS-47 (Luminance Range) and WS-48 (Colour Range) acceptance lines that a synthetic
/// frame can state exactly. The corpus measurements (precision, recall, speckle on real
/// photographs) live in docs/quality/lanes/WS-48/probe.py; these are the guarantees
/// underneath them.
final class RangeMaskQualityTests: XCTestCase {

    // MARK: - Helpers

    private func nev(_ ev: Double) -> Double { (ev - MaskRaster.evMin) / (MaskRaster.evMax - MaskRaster.evMin) }

    /// A horizontal neutral ramp, linear in EV from `from` to `to`.
    private func evRamp(width: Int = 1400, height: Int = 8, from: Double = -10,
                        to: Double = 4) -> (ImageBuffer, [Double]) {
        let evs = (0..<width).map { from + (to - from) * (Double($0) + 0.5) / Double(width) }
        var img = ImageBuffer(width: width, height: height)
        for y in 0..<height {
            for x in 0..<width {
                let v = pow(2, evs[x])
                img[x, y] = RGB(v, v, v)
            }
        }
        return (img, evs)
    }

    private func band(_ lo: Double, _ hi: Double, smooth: Double?) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .lumaRange)
        c.lo = nev(lo)
        c.hi = nev(hi)
        c.smooth = smooth
        return c
    }

    /// Deterministic standard normal (Box–Muller over a 64-bit LCG).
    private struct Gauss {
        var state: UInt64
        mutating func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return (Double(state >> 11) + 0.5) / Double(1 << 53)
        }
        mutating func next() -> Double {
            (-2 * log(uniform())).squareRoot() * cos(2 * .pi * uniform())
        }
    }

    // MARK: - WS-47 Luminance Range

    /// L1. The handles are the edge: half selected exactly at From and To, nothing
    /// beyond half a shoulder outside the band (1 EV at Smooth 100), and the
    /// alpha > 0.5 region is the same at every Smooth.
    func testHandlesAreTheEdgeAtEverySmooth() {
        let lo = nev(-5), hi = nev(-1)
        for smooth in [0.0, 25, 50, 75, 100] {
            let half = smooth / 100 * 2 / 2   // EV
            XCTAssertEqual(MaskRaster.lumaRangeValue(lo, lo: lo, hi: hi, smooth: smooth), 0.5,
                           accuracy: smooth == 0 ? 0.5 : 1e-9)
            for ev in stride(from: -10.0, through: 4.0, by: 0.01) {
                let a = MaskRaster.lumaRangeValue(nev(ev), lo: lo, hi: hi, smooth: smooth)
                if ev < -5 - half - 1e-9 || ev > -1 + half + 1e-9 {
                    XCTAssertEqual(a, 0, "Smooth \(smooth): \(ev) EV is outside the band")
                }
                if ev > -5 + half + 1e-9 && ev < -1 - half - 1e-9 {
                    XCTAssertEqual(a, 1, "Smooth \(smooth): \(ev) EV is inside the band")
                }
                if abs(ev + 5) > 1e-6 && abs(ev + 1) > 1e-6 {
                    let inside = ev > -5 && ev < -1
                    XCTAssertEqual(a > 0.5, inside,
                                   "Smooth \(smooth) moved the edge at \(ev) EV (alpha \(a))")
                }
            }
        }
    }

    /// L1 through the rasterizer, on a ramp: the measurement denoise must not move the
    /// edge either.
    func testRasterizedBandKeepsItsEdges() {
        let (img, evs) = evRamp()
        for smooth in [0.0, 50, 100] {
            let p = MaskRaster.rasterize(component: band(-5, -1, smooth: smooth),
                                         size: (img.width, img.height), source: img)
            for x in 0..<img.width {
                let a = p[x, 4]
                let ev = evs[x]
                if ev < -5 - smooth / 100 - 0.02 || ev > -1 + smooth / 100 + 0.02 {
                    XCTAssertLessThan(a, 1e-6, "Smooth \(smooth) selected \(ev) EV")
                }
                if abs(ev + 5) > 0.03 && abs(ev + 1) > 0.03 {
                    XCTAssertEqual(a > 0.5, ev > -5 && ev < -1,
                                   "Smooth \(smooth): edge moved at \(ev) EV (alpha \(a))")
                }
            }
        }
    }

    /// L2. Smooth 0 is a step; the ramp widens monotonically with Smooth.
    func testSmoothWidensTheRampMonotonically() {
        let lo = nev(-5), hi = nev(0)
        func width(_ smooth: Double) -> Double {
            var first: Double?
            var last: Double?
            for ev in stride(from: -7.0, through: -3.0, by: 0.001) {
                let a = MaskRaster.lumaRangeValue(nev(ev), lo: lo, hi: hi, smooth: smooth)
                if a > 0.02 && first == nil { first = ev }
                if a < 0.98 { last = ev }
            }
            return (last ?? 0) - (first ?? 0)
        }
        XCTAssertLessThanOrEqual(width(0), 0.05)
        var previous = width(0)
        for smooth in stride(from: 10.0, through: 100, by: 10) {
            let w = width(smooth)
            XCTAssertGreaterThan(w, previous, "Smooth \(smooth) did not widen the ramp")
            previous = w
        }
    }

    /// L3. A handle at an end of the axis is open-ended.
    func testHandlesAtTheEndsOfTheAxisAreOpen() {
        let (img, _) = evRamp(width: 64, from: 5, to: 7)
        let top = MaskRaster.rasterize(component: band(-2, 4, smooth: 100),
                                       size: (img.width, img.height), source: img)
        XCTAssertEqual(Double(top.values.min() ?? 0), 1, accuracy: 1e-6,
                       "To at +4 must take +5…+7 EV too")
        let (dark, _) = evRamp(width: 64, from: -15, to: -12)
        let bottom = MaskRaster.rasterize(component: band(-10, -6, smooth: 100),
                                          size: (dark.width, dark.height), source: dark)
        XCTAssertEqual(Double(bottom.values.min() ?? 0), 1, accuracy: 1e-6,
                       "From at −10 must take −15…−12 EV too")
    }

    /// L9. No handles: nothing.
    func testBandWithoutHandlesSelectsNothing() {
        let (img, _) = evRamp(width: 32)
        var c = MaskComponent(op: .add, kind: .lumaRange)
        c.lo = nil
        c.hi = nil
        let p = MaskRaster.rasterize(component: c, size: (img.width, img.height), source: img)
        XCTAssertEqual(p.values.max() ?? 1, 0)
    }

    /// L6/L7 in miniature: a band edge sitting inside a noisy tone. Per pixel, a 0.5 EV
    /// noise at the threshold is salt and pepper; measured through the denoise it is a
    /// soft field.
    func testNoisyToneAtTheBandEdgeDoesNotSpeckle() {
        // 1600 px long edge: the filter's radius is a fraction of the frame, so the frame
        // has to be photograph-sized for it to run at the size it does in an export.
        let w = 1600, h = 160
        var g = Gauss(state: 7)
        var img = ImageBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let v = pow(2, -4.6 + 0.5 * g.next())
                img[x, y] = RGB(v, v, v)
            }
        }
        let p = MaskRaster.rasterize(component: band(-10, -4.6, smooth: 50),
                                     size: (w, h), source: img)
        let mean = p.values.reduce(0, +) / Float(p.values.count)
        let sd = (p.values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(p.values.count))
            .squareRoot()
        // Per pixel this is ≈ 0.38 (a 1 EV ramp over a 0.5 EV spread).
        XCTAssertLessThan(sd, 0.1, "alpha spread \(sd): the band edge speckles")
        XCTAssertEqual(Double(mean), 0.5, accuracy: 0.1)
    }

    // MARK: - WS-48 Colour Range

    private let ctx = OKLabTransform.working

    private func rgb(_ lab: OKLab) -> RGB { ctx.toRGB(lab) }

    private func colourRange(_ samples: [RGB], refine: Double?) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .colorRange)
        c.samples = samples.map { [$0.r, $0.g, $0.b] }
        c.rangeAmount = refine
        return c
    }

    /// C9. A chromatic sample never selects a neutral, at any Refine.
    func testChromaticSampleNeverSelectsANeutral() {
        for hue in stride(from: 0.0, to: 360, by: 30) {
            for chroma in [0.10, 0.15, 0.25] {
                let ref = OKLCh(L: 0.6, C: chroma, h: hue).lab
                for refine in [0.0, 50, 75, 100] {
                    let tol = MaskRaster.colorRangeTolerances(refine: refine)
                    for L in stride(from: 0.1, through: 1.0, by: 0.05) {
                        let a = MaskRaster.colorRangeValue(OKLab(L: L, a: 0, b: 0), ref: ref,
                                                           tolerances: tol)
                        XCTAssertLessThan(a, 0.01, "h \(hue) C \(chroma) Refine \(refine) "
                                          + "selected grey L \(L) at \(a)")
                    }
                }
            }
        }
    }

    /// C9 the other way round: a grey sample selects greys at every lightness near it.
    func testNeutralSampleSelectsNeutrals() {
        let ref = OKLab(L: 0.6, a: 0, b: 0)
        let tol = MaskRaster.colorRangeTolerances(refine: 50)
        for L in stride(from: 0.45, through: 0.8, by: 0.05) {
            XCTAssertGreaterThan(MaskRaster.colorRangeValue(OKLab(L: L, a: 0, b: 0), ref: ref,
                                                            tolerances: tol), 0.9)
        }
    }

    /// C10. The sampled colour in shade and in light is still the sampled colour.
    func testShadingDoesNotChangeTheColour() {
        let red = RGB(0.40, 0.06, 0.04)
        var img = ImageBuffer(width: 96, height: 32)
        for y in 0..<32 {
            for x in 0..<96 {
                let k = x < 32 ? 0.5 : (x < 64 ? 1.0 : 2.0)
                img[x, y] = RGB(red.r * k, red.g * k, red.b * k)
            }
        }
        let p = MaskRaster.rasterize(component: colourRange([red], refine: 50),
                                     size: (96, 32), source: img)
        for x in [16, 48, 80] {
            XCTAssertGreaterThanOrEqual(p[x, 16], 0.9, "x \(x)")
        }
    }

    /// C11. Refine only ever widens: alpha never falls as Refine rises.
    func testRefineIsMonotone() {
        let refs = [OKLCh(L: 0.55, C: 0.12, h: 25).lab, OKLCh(L: 0.5, C: 0.02, h: 130).lab,
                    OKLab(L: 0.7, a: 0, b: 0)]
        var violations = 0
        for ref in refs {
            for L in stride(from: 0.1, through: 0.95, by: 0.085) {
                for C in stride(from: 0.0, through: 0.3, by: 0.03) {
                    for h in stride(from: 0.0, to: 360, by: 20) {
                        let px = OKLCh(L: L, C: C, h: h).lab
                        var previous = -1.0
                        for refine in stride(from: 0.0, through: 100, by: 5) {
                            let a = MaskRaster.colorRangeValue(
                                px, ref: ref, tolerances: MaskRaster.colorRangeTolerances(refine: refine))
                            if a < previous - 1e-12 { violations += 1 }
                            previous = a
                        }
                    }
                }
            }
        }
        XCTAssertEqual(violations, 0)
    }

    /// C12. No usable sample: nothing.
    func testNoSamplesSelectNothing() {
        let img = ImageBuffer(width: 16, height: 16) { _, _ in RGB(0.3, 0.1, 0.1) }
        var none = MaskComponent(op: .add, kind: .colorRange)
        none.samples = [[.nan, 0.1, 0.1], [0.2]]
        let p = MaskRaster.rasterize(component: none, size: (16, 16), source: img)
        XCTAssertEqual(p.values.max() ?? 1, 0)
    }

    /// C4/C5 in miniature: a red field with ISO-6400-sized chroma noise next to a white
    /// one. Inside the red the matte is solid, inside the white it is empty, and neither
    /// has islands.
    func testChromaNoiseDoesNotSpeckleTheMatte() {
        let side = 1600, h = 120
        let red = OKLCh(L: 0.45, C: 0.11, h: 30).lab
        let white = OKLab(L: 0.5, a: 0.0, b: 0.01)
        var g = Gauss(state: 11)
        var img = ImageBuffer(width: side, height: h)
        for y in 0..<h {
            for x in 0..<side {
                let base = x < side / 2 ? red : white
                let lab = OKLab(L: base.L + 0.02 * g.next(), a: base.a + 0.025 * g.next(),
                                b: base.b + 0.025 * g.next())
                img[x, y] = rgb(lab)
            }
        }
        let p = MaskRaster.rasterize(component: colourRange([rgb(red)], refine: 50),
                                     size: (side, h), source: img)
        var holes = 0, islands = 0
        for y in 8..<(h - 8) {
            for x in 8..<(side / 2 - 8) where p[x, y] < 0.5 { holes += 1 }
            for x in (side / 2 + 8)..<(side - 8) where p[x, y] > 0.5 { islands += 1 }
        }
        XCTAssertLessThan(holes, 50, "\(holes) unselected pixels inside the red")
        XCTAssertLessThan(islands, 50, "\(islands) selected pixels inside the white")
    }
}
