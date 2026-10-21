// ContrastCurveTests.swift
// WS-06: the Contrast curve's contract, one test per measurable line of
// docs/quality/lanes/WS-06/SPEC.md, at the spec's thresholds. The spec's runner
// (`measure/run_all.sh`) measures the same things on the release build and on rendered
// photographs; these are the unit-test form, so a regression fails `swift test` and not
// only a lane script nobody re-runs.

import XCTest
@testable import LumenCore

final class ContrastCurveTests: XCTestCase {

    // The S1/S3 grid: pivots including the clamp edges and values past the lowest live
    // white anchor (3.5 under Whites +100), against the anchors Whites and Blacks move.
    private static let pivots: [Double] = [-4, -3, -2, -1.3, 0, 2, 2.37, 3, 3.5, 4]
    private static let whites: [Double] = [-100, 0, 67, 100]
    private static let blacks: [Double] = [-100, 0, 100]
    private static let contrasts: [Double] =
        stride(from: -100.0, through: 100, by: 5).filter { $0 != 0 }

    private func slopeAtPivot(_ tone: Tone) -> Double {
        let e = ToneEngine(tone: tone)
        let p = e.tone.contrastPivot
        return (e.contrastMapped(p + 1e-4) - e.contrastMapped(p - 1e-4)) / 2e-4
    }

    // MARK: S1

    /// Contrast 0 is an exact identity, bitwise, everywhere on the log scale and at every
    /// pivot and anchor; the engine, the plan and the baked LUT all say so.
    func testContrastZeroIsABitwiseIdentityAtEveryPivotAndAnchor() {
        let defaultLUT = ToneEngine().bakeGainLUT().samples
        for pivot in Self.pivots { for w in Self.whites { for b in Self.blacks {
            let e = ToneEngine(tone: Tone(contrast: 0, contrastPivot: pivot,
                                          whites: w, blacks: b))
            var mismatches = 0
            var t = -LumenLog.maxEV
            while t <= LumenLog.maxEV {
                if e.contrastMapped(t) != t { mismatches += 1 }
                t += 0.001
            }
            XCTAssertEqual(mismatches, 0, "pivot \(pivot) whites \(w) blacks \(b)")
            if w == 0 && b == 0 {
                XCTAssertTrue(e.isIdentity, "pivot \(pivot)")
                var r = Recipe()
                r.develop.tone.contrastPivot = pivot
                XCTAssertTrue(RenderPlan(recipe: r).toneIsIdentity, "pivot \(pivot)")
                XCTAssertEqual(e.bakeGainLUT().samples, defaultLUT, "pivot \(pivot)")
            }
        }}}
    }

    // MARK: S3

    /// Monotone with margin inside the live anchors: the secant derivative at 0.001 EV
    /// never falls below 0.40 (contrast −100's own pivot slope is 0.420), and for
    /// positive contrast never below 0.50 (the shoulder and toe keep real slope). And no
    /// inversion anywhere on the ±12 EV scale.
    func testContrastIsMonotoneWithMarginInsideTheLiveAnchors() {
        var minimum = Double.infinity, minimumPositive = Double.infinity
        var at = "", atPositive = ""
        var inversions = 0
        let h = 1e-3
        for c in Self.contrasts { for pivot in Self.pivots {
            for w in Self.whites { for b in Self.blacks {
                let e = ToneEngine(tone: Tone(contrast: c, contrastPivot: pivot,
                                              whites: w, blacks: b))
                var t = e.blackAnchorEV
                var previous = e.contrastMapped(t)
                while t + h <= e.whiteAnchorEV {
                    let v = e.contrastMapped(t + h)
                    let d = (v - previous) / h
                    if d < minimum { minimum = d; at = "c \(c) p \(pivot) w \(w) b \(b) t \(t)" }
                    if c > 0 && d < minimumPositive {
                        minimumPositive = d
                        atPositive = "c \(c) p \(pivot) w \(w) b \(b) t \(t)"
                    }
                    previous = v
                    t += h
                }
                var q = -LumenLog.maxEV
                var pq = e.contrastMapped(q)
                while q <= LumenLog.maxEV {
                    let v = e.contrastMapped(q)
                    if v < pq { inversions += 1 }
                    pq = v
                    q += 0.01
                }
            }}
        }}
        XCTAssertGreaterThanOrEqual(minimum, 0.40, at)
        XCTAssertGreaterThanOrEqual(minimumPositive, 0.50, atPositive)
        XCTAssertEqual(inversions, 0)
    }

    // MARK: S4

    /// The pivot (as clamped) and both live anchors map to themselves, and so does
    /// everything 0.01-4 EV beyond either anchor.
    func testContrastFixesThePivotAndBothLiveAnchors() {
        for c in Self.contrasts { for pivot in Self.pivots {
            for w in Self.whites { for b in Self.blacks {
                let e = ToneEngine(tone: Tone(contrast: c, contrastPivot: pivot,
                                              whites: w, blacks: b))
                let lo = e.blackAnchorEV, hi = e.whiteAnchorEV
                let p = Swift.min(Swift.max(pivot, Swift.max(-4, lo)), Swift.min(4, hi))
                let label = "c \(c) pivot \(pivot) whites \(w) blacks \(b)"
                for x in [p, lo, hi] {
                    XCTAssertEqual(e.contrastMapped(x), x, accuracy: 1e-12, "\(label) at \(x)")
                }
                for x in [hi + 0.01, hi + 1, hi + 4, lo - 0.01, lo - 1, lo - 4] {
                    XCTAssertEqual(e.contrastMapped(x), x, accuracy: 1e-12, "\(label) at \(x)")
                }
            }}
        }}
    }

    // MARK: S5

    /// The slope at the pivot: in [1.60, 2.00] at +100 and [0.40, 0.50] at −100, the law's
    /// own values, and rising with every unit of the slider.
    func testContrastSlopeLaw() {
        let plus = slopeAtPivot(Tone(contrast: 100))
        let minus = slopeAtPivot(Tone(contrast: -100))
        XCTAssertTrue((1.60...2.00).contains(plus), "slope at +100 is \(plus)")
        XCTAssertTrue((0.40...0.50).contains(minus), "slope at −100 is \(minus)")
        // log2 σ = 0.96u − 0.17u² + 0.12u³.
        for (c, expected) in [(100.0, 1.8790), (50.0, 1.3684), (-50.0, 0.6890),
                              (-100.0, 0.4204)] {
            XCTAssertEqual(ToneEngine.contrastPivotSlope(c / 100), expected,
                           accuracy: 1e-4, "σ(\(c))")
            XCTAssertEqual(slopeAtPivot(Tone(contrast: c)), expected, accuracy: 1e-3,
                           "measured slope at the pivot, contrast \(c)")
        }
        var previous = slopeAtPivot(Tone(contrast: -100))
        for c in stride(from: -99.0, through: 100, by: 1) {
            let s = slopeAtPivot(Tone(contrast: c))
            XCTAssertGreaterThan(s, previous, "the slope did not rise from \(c - 1) to \(c)")
            previous = s
        }
    }

    // MARK: S6

    /// The zonal limiter scales the four zonal windows, never Contrast: the pivot slope
    /// is the same with the zonal sliders pushed as without them.
    func testContrastIsNeverScaledByTheZonalLimiter() {
        let plus = slopeAtPivot(Tone(contrast: 100))
        let minus = slopeAtPivot(Tone(contrast: -100))
        XCTAssertEqual(slopeAtPivot(Tone(contrast: 100, highlights: -100, shadows: 100)),
                       plus, accuracy: 1e-9)
        XCTAssertEqual(slopeAtPivot(Tone(contrast: -100, highlights: -100, shadows: 100,
                                         whites: -100, blacks: 100)),
                       minus, accuracy: 1e-9)
    }

    // MARK: S7

    /// The softer toe: at +100, pivot 0, −6 EV moves at most 0.55 EV and −7 EV at most
    /// 0.30 EV. The old curve moved them 1.354 and 0.792 and crushed them to code 0.
    func testContrastLeavesTheDeepShadowsAlmostAlone() {
        let e = ToneEngine(tone: Tone(contrast: 100))
        XCTAssertLessThanOrEqual(abs(e.contrastMapped(-6) + 6), 0.55)
        XCTAssertLessThanOrEqual(abs(e.contrastMapped(-7) + 7), 0.30)
        // Still a darkening, not a no-op: the toe is softer, not gone.
        XCTAssertLessThan(e.contrastMapped(-6), -6)
    }

    // MARK: S8

    /// The top two stops keep their separation: on a rendered grey ramp at pivot 0 with
    /// the export tables, the codes spanned by +2…+4 EV are at least 0.55 of contrast 0's
    /// at +100 and 0.75 at +50. The old curve kept 0.42 and 0.69.
    func testContrastKeepsTheTopTwoStopsApart() {
        let width = 1040, height = 8
        let lo = -8.0, hi = 5.0
        let ramp = ImageBuffer(width: width, height: height) { u, _ in
            RGB(gray: ProofFrames.midGrey * exp2(lo + (hi - lo) * u))
        }
        func code(_ contrast: Double, at ev: Double) -> Double {
            var r = Recipe()
            r.develop.tone.contrast = contrast
            let img = ReferenceRenderer.render(ramp, plan: RenderPlan(recipe: r,
                                                                      lutSize: LUT3D.exportSize))
            let codes = ProofMetrics.codeValues(img)
            let row = height / 2
            func green(_ x: Int) -> Double { codes[(row * width + x) * 3 + 1] }
            // Column centres sit at u = (x + 0.5)/width; interpolate between two.
            let fx = (ev - lo) / (hi - lo) * Double(width) - 0.5
            let x0 = Int(fx.rounded(.down)), f = fx - Double(x0)
            return green(x0) + (green(x0 + 1) - green(x0)) * f
        }
        func span(_ contrast: Double) -> Double {
            code(contrast, at: 4) - code(contrast, at: 2)
        }
        let neutral = span(0)
        XCTAssertGreaterThan(neutral, 30, "the ramp is not rendering the top stops at all")
        XCTAssertGreaterThanOrEqual(span(100) / neutral, 0.55, "contrast +100")
        XCTAssertGreaterThanOrEqual(span(50) / neutral, 0.75, "contrast +50")
    }

    // MARK: S14

    /// What Contrast costs the four zonal sliders through the limiter, measured. The
    /// floors are the spec's (none may fall below the old curve's number except the
    /// four-way corner, which may fall to the generator's 0.62); the pinned values are
    /// this curve's, so a change that moves them is seen.
    func testContrastTradeTable() {
        func scale(_ t: Tone) -> Double { ToneEngine(tone: t).zonalScale }

        let highlights = ToneEngine(tone: Tone(contrast: 100, highlights: -100))
            .effectiveHighlights / -1
        XCTAssertGreaterThanOrEqual(highlights, 0.845)
        XCTAssertEqual(highlights, 0.998, accuracy: 0.002)

        let shadows = ToneEngine(tone: Tone(contrast: -100, shadows: 100)).effectiveShadows
        XCTAssertGreaterThanOrEqual(shadows, 0.619)
        // WS-05: 0.909 before Shadows +100 became a lift that tapers at the black point;
        // its slope peaks deeper in the toe, where Contrast −100 leaves less to borrow.
        XCTAssertEqual(shadows, 0.842, accuracy: 0.002)

        var paired = 1.0
        for c in [100.0, -100] { for v in [-100.0, 100] {
            paired = Swift.min(paired, scale(Tone(contrast: c, highlights: v)),
                               scale(Tone(contrast: c, shadows: v)),
                               scale(Tone(contrast: c, whites: v)),
                               scale(Tone(contrast: c, blacks: v)))
        }}
        XCTAssertGreaterThanOrEqual(paired, 0.619)
        XCTAssertEqual(paired, 0.842, accuracy: 0.002)   // WS-05: the Shadows case above

        var corner = 1.0
        for c in [80.0, 100] { for h in [-100.0, 0, 100] { for s in [-100.0, 0, 100] {
            for w in [-100.0, 100] { for b in [-100.0, 100] {
                corner = Swift.min(corner, scale(Tone(contrast: c, highlights: h,
                                                      shadows: s, whites: w, blacks: b)))
            }}
        }}}
        XCTAssertGreaterThanOrEqual(corner, 0.620)
        // WS-05: 0.627 before the Whites −100 hold was spread over +0.5 … +3.2 EV, off the
        // band where this curve's shoulder is flat (ToneEngine.whiteHoldStartBelowAnchorEV).
        XCTAssertEqual(corner, 0.669, accuracy: 0.002)

        var moderate = 1.0
        for c in stride(from: -60.0, through: 60, by: 20) {
            for h in stride(from: -60.0, through: 60, by: 20) {
                for s in stride(from: -60.0, through: 60, by: 20) {
                    for w in stride(from: -40.0, through: 40, by: 20) {
                        for b in stride(from: -40.0, through: 40, by: 20) {
                            moderate = Swift.min(moderate, scale(Tone(
                                contrast: c, highlights: h, shadows: s,
                                whites: w, blacks: b)))
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(moderate, 0.990)
    }

    // MARK: S15

    /// The CPU's gain LUT and the GPU's gain cube both come from `stops(at:)`, so a
    /// contrast recipe's baked LUT is exactly 2^stops at every sample.
    func testTheBakedGainLUTIsStopsForContrastRecipes() {
        for c in [-100.0, -37, 50, 100] { for pivot in [-3.0, 0, 2.5] {
            var r = Recipe()
            r.develop.tone.contrast = c
            r.develop.tone.contrastPivot = pivot
            let plan = RenderPlan(recipe: r)
            XCTAssertEqual(plan.toneGainLUT, plan.tone.bakeGainLUT(), "c \(c) pivot \(pivot)")
            let n = plan.toneGainLUT.samples.count
            var worst = 0.0
            for i in 0..<n {
                let y = Double(i) / Double(n - 1)
                let t = log2(Swift.max(LumenLog.decode(y), 1e-30) / 0.18)
                guard t.isFinite else { continue }
                worst = Swift.max(worst, abs(log2(plan.toneGainLUT.samples[i])
                                             - plan.tone.stops(at: t)))
            }
            XCTAssertLessThanOrEqual(worst, 1e-9, "c \(c) pivot \(pivot)")
        }}
    }

    /// The GPU reads the gain through a cube of 32 (interactive) or 65 (export) knots on
    /// the shaper axis, linearly interpolated. Every transition of the curve is wide
    /// enough that the knots follow it: over −9…+5 EV, at most 0.105 / 0.035 EV of error
    /// against the 1024-sample LUT, and at the macOS parity golden's contrast +60 no
    /// more than the old curve's 0.036 / 0.0090.
    func testTheGainCubeCanFollowTheContrastCurve() {
        func worstError(_ lut: LUT1D, knots: Int) -> Double {
            var worst = 0.0
            var y = LumenLog.encode(0.18 * exp2(-9))
            let yHi = LumenLog.encode(0.18 * exp2(5))
            while y <= yHi {
                let k = y * Double(knots - 1)
                let i = Swift.min(Int(k), knots - 2), f = k - Double(i)
                let g0 = lut.evaluate(Double(i) / Double(knots - 1))
                let g1 = lut.evaluate(Double(i + 1) / Double(knots - 1))
                worst = Swift.max(worst, abs(log2((g0 + (g1 - g0) * f) / lut.evaluate(y))))
                y += 1e-4
            }
            return worst
        }
        for (knots, bound) in [(32, 0.105), (65, 0.035)] {
            for c in [-100.0, -50, 50, 100] { for pivot in [-3.0, 0, 3] {
                var r = Recipe()
                r.develop.tone.contrast = c
                r.develop.tone.contrastPivot = pivot
                let e = worstError(RenderPlan(recipe: r).toneGainLUT, knots: knots)
                XCTAssertLessThanOrEqual(e, bound, "\(knots) knots, c \(c) pivot \(pivot)")
            }}
        }
        var golden = Recipe()
        golden.develop.tone.contrast = 60
        let lut = RenderPlan(recipe: golden).toneGainLUT
        XCTAssertLessThanOrEqual(worstError(lut, knots: 32), 0.036)
        XCTAssertLessThanOrEqual(worstError(lut, knots: 65), 0.0090)
    }

    // MARK: S13

    /// The proof's own measurement of `tone.contrast` on the neutral ramp: authority
    /// stays above its floor of 55 with margin (≥ 57), the travel is balanced (the share
    /// delivered by +10 of the −100…+100 sweep is 0.42-0.58; the old curve's 0.635 was a
    /// slider doing most of its work before the middle), and no step is dead.
    func testContrastTravelIsBalancedOnTheProofRamp() throws {
        let spec = try XCTUnwrap(ProofRegistry.all.first { $0.id == "tone.contrast" })
        let record = ProofRunner.measured(spec)
        XCTAssertGreaterThanOrEqual(record.authority, 57)
        XCTAssertGreaterThanOrEqual(record.frontLoading, 0.42)
        XCTAssertLessThanOrEqual(record.frontLoading, 0.58)
        XCTAssertEqual(record.deadSteps, 0)
    }
}
