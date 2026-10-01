// CurveBlackLiftTests.swift
// AI-04: a luma curve that lifts black, `[[0, .2], [1, 1]]`.
//
// The luma stage is `e · f(L) / L` — curve the luminance, carry the chroma ratios. At
// L = 0 that ratio has no value, and the stage simply skipped black: pure black stayed
// black while a pixel 1e−7 above it jumped to the plotted 0.2 (0.0331 linear). The
// graph promises 0.2 at the black end; the picture broke that promise at exactly one
// input. Worse, near black the ratio `f(L)/L` is enormous, so a dark blue lattice
// corner of the finish cube came out as a fully saturated blue, and trilinear
// interpolation between that corner and its red and green neighbours turned a NEUTRAL
// near-black pixel purple on both render paths — `RenderPlan.finishedColor` is the
// table both of them read.
//
// The limit these tests pin: the black lift is NEUTRAL. Below the lift the stage adds
// `f(0)` as grey and applies only the curve's remaining rise as a ratio, which has a
// finite limit (the curve's slope) at L = 0. Luminance is `f(L)` exactly in every form,
// a neutral input is neutral out, and a curve whose black end is not lifted takes the
// old arithmetic untouched.

import XCTest
@testable import LumenCore

final class CurveBlackLiftTests: XCTestCase {

    private let lifted = CurveSet(luma: [[0, 0.2], [1, 1]])

    /// Display-linear grey that, sRGB-encoded, sits at `encoded`.
    private func encodedValue(_ c: RGB) -> RGB { TransferFunction.srgb.encode(c) }

    /// The plotted endpoint holds AT black and continuously into it.
    func testALiftedLumaBlackIsTheValueTheGraphPlotsAtAndNearZero() {
        let stack = CurveStack(lifted)
        var failures: [String] = []
        for g in [0.0, 1e-12, 1e-9, 1e-7, 1e-6, 1e-5, 1e-4, 1e-3] {
            let out = encodedValue(stack.apply(RGB(g, g, g)))
            let expected = stack.lumaCurve(TransferFunction.srgb.encode(g))
            for (name, v) in [("r", out.r), ("g", out.g), ("b", out.b)]
            where abs(v - expected) > 1e-9 {
                failures.append("grey \(g): \(name) = \(v), the curve plots \(expected)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures: \(failures)")
    }

    /// A coloured pixel approaching black must approach what black renders as: the
    /// lifted grey, not a saturated primary.
    func testColouredNearBlackConvergesOnTheLiftedGrey() {
        let stack = CurveStack(lifted)
        let black = stack.apply(RGB(0, 0, 0))
        var worst = 0.0
        var witness = ""
        for primary in [RGB(1, 0, 0), RGB(0, 1, 0), RGB(0, 0, 1), RGB(1, 0, 1)] {
            for scale in [1e-9, 1e-8, 1e-7, 1e-6] {
                let out = stack.apply(primary * scale)
                let d = Swift.max(abs(out.r - black.r), abs(out.g - black.g),
                                  abs(out.b - black.b))
                if d > worst { worst = d; witness = "\(primary * scale) -> \(out)" }
            }
        }
        XCTAssertLessThan(worst, 1e-4,
                          "black renders \(black) but a pixel beside it renders \(witness)")
    }

    /// Luminance is still the curve's own value off the neutral axis — the stage stays a
    /// LUMA curve, it only stops lifting black through a ratio.
    func testLuminanceIsTheCurvesValueForColouredPixelsToo() {
        let stack = CurveStack(lifted)
        var failures: [String] = []
        for c in [RGB(0.02, 0.01, 0.005), RGB(0.001, 0.002, 0.0005), RGB(0.3, 0.2, 0.1),
                  RGB(0.0004, 0.0001, 0.0002)] {
            let e = encodedValue(c)
            let L = RGBColorSpace.rec2020.luminance(e)
            let out = encodedValue(stack.apply(c))
            // a channel the clamp to [0, 1] touched cannot keep luminance; none here do
            let got = RGBColorSpace.rec2020.luminance(out)
            if abs(got - stack.lumaCurve(L)) > 1e-9 {
                failures.append("\(c): luminance \(got), curve says \(stack.lumaCurve(L))")
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
    }

    /// A luma curve that does NOT lift black renders exactly what it always did. This
    /// is the arithmetic the old stage used, restated, so any drift is visible.
    func testACurveThatDoesNotLiftBlackIsUntouched() {
        let unlifted = CurveSet(luma: [[0, 0], [0.4, 0.55], [1, 1]])
        let stack = CurveStack(unlifted)
        let f = MonotoneCubic(points: [[0, 0], [0.4, 0.55], [1, 1]])
        var rng = SplitMix64(seed: 0xB1AC_B1AC_B1AC_B1AC)
        for _ in 0..<2000 {
            func u() -> Double { Double(rng.next() % 1_000_001) / 1_000_000 }
            let c = RGB(u() * u(), u() * u(), u() * u())
            var e = TransferFunction.srgb.encode(c.clamped(0, 1))
            let L = Num.saturate(RGBColorSpace.rec2020.luminance(e))
            if L > 1e-6 { e = e * (f.evaluate(L) / L) }
            let old = TransferFunction.srgb.decode(e.clamped(0, 1))
            let now = stack.apply(c)
            XCTAssertEqual(now, old, "\(c): an unlifted luma curve changed its output")
            if now != old { return }
        }
    }

    // MARK: - the table both renderers read

    /// Core Image's `CIColorCube` — what `RenderGraph` applies `finishLUT` with — is a
    /// TRILINEAR filter. `LUT3D.sample` is tetrahedral, which keeps a neutral on the
    /// cube's diagonal by construction and so cannot see the cast at all. This is the
    /// GPU's interpolant, restated over the same stored floats.
    private func trilinear(_ lut: LUT3D, _ c: RGB) -> RGB {
        let n = lut.size, m = n - 1
        func axis(_ v: Double) -> (Int, Int, Double) {
            let f = Num.saturate(v) * Double(m)
            let i0 = Swift.min(Int(f), m)
            return (i0, Swift.min(i0 + 1, m), f - Double(i0))
        }
        let (r0, r1, tr) = axis(c.r)
        let (g0, g1, tg) = axis(c.g)
        let (b0, b1, tb) = axis(c.b)
        func at(_ r: Int, _ g: Int, _ b: Int) -> RGB {
            let i = ((b * n + g) * n + r) * 4
            return RGB(Double(lut.data[i]), Double(lut.data[i + 1]),
                       Double(lut.data[i + 2]))
        }
        func lerp(_ a: RGB, _ b: RGB, _ t: Double) -> RGB { a + (b - a) * t }
        let x00 = lerp(at(r0, g0, b0), at(r1, g0, b0), tr)
        let x10 = lerp(at(r0, g1, b0), at(r1, g1, b0), tr)
        let x01 = lerp(at(r0, g0, b1), at(r1, g0, b1), tr)
        let x11 = lerp(at(r0, g1, b1), at(r1, g1, b1), tr)
        return lerp(lerp(x00, x10, tg), lerp(x01, x11, tg), tb)
    }

    /// THE FINDING, end to end. A neutral scene value just above zero goes through the
    /// finish cube at both production sizes, sampled the way each renderer samples it:
    /// tetrahedrally (`finishedColor`, the reference path) and trilinearly (the GPU's
    /// `CIColorCube`). It must come out neutral and at the curve's black lift.
    func testANeutralNearBlackStaysNeutralThroughTheFinishCube() {
        var recipe = Recipe()
        recipe.develop.curve = lifted
        var failures: [String] = []
        for size in [LUT3D.interactiveSize, LUT3D.exportSize] {
            let plan = RenderPlan(recipe: recipe, lutSize: size)
            for scene in [1e-8, 1e-6, 1e-4, 1e-3] {
                let grey = RGB(scene, scene, scene)
                let encoded = LumenLog.encode(grey)
                let exact = plan.exactColor(grey)
                let paths: [(String, RGB)] = [
                    ("reference", plan.finishedColor(encoded: encoded)),
                    ("gpu", trilinear(plan.finishLUT, encoded) * plan.finishScale)
                ]
                for (path, out) in paths {
                    let spread = out.maxComponent - Swift.min(out.r, out.g, out.b)
                    // relative to the value: the audit's purple was a spread of 0.06 on
                    // a value of 0.067
                    if spread > 0.02 * Swift.max(out.maxComponent, 1e-6) {
                        failures.append("\(path) \(size), scene \(scene): \(out) is not "
                                        + "neutral (exact \(exact))")
                    }
                    if abs(out.g - exact.g) > 0.02 * Swift.max(exact.g, 1e-6) {
                        failures.append("\(path) \(size), scene \(scene): table \(out) "
                                        + "against exact \(exact)")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures: \(failures)")
    }
}
