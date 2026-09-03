// GradeLuminanceInversionTests.swift
// docs/31 round two §1 — the grading wheels' Luminance inverted the tone response at
// the shipped defaults, and the Colour Balance grid's Brilliance had no limiter at all.
//
// The mechanism, measured before it was reasoned about: a wheel's Luminance is applied
// through `LumenUCS.scaleBrightness`, which scales the H-K brightness J. J tracks OKLab
// L, and L is the CUBE ROOT of linear luminance on the neutral axis — so a gain of
// `2^stops` on J is a gain of `2^(3·stops)` on the light. The realised tone response is
// therefore `1 + 3·scale·slope`, while `solveLumScale` solved `1 + scale·slope`: a
// limiter 2.85× too permissive, reporting "nothing to limit" on settings that fold the
// curve. Midtones +1 against Highlights −1 — one drag on each wheel — gave 33 code
// values of reversal across 1.75 stops of midtone; 345 of 810 sampled combinations
// inverted. `ColorBalanceGrid.apply`'s Brilliance is the same shape one disclosure
// down: a per-zone H-K brightness gain crossing the same crossfades, with no limiter.
//
// Every test in this file was run against the pre-fix engine and watched fail before
// the fix landed (the numbers in the assertions' messages are from those runs).
//
// WIDENED, because this file's own blind spot cost a second defect. Every sweep below
// held `colourBalance` at zero throughout, so the wheels were only ever measured with
// nothing else grading the same crossfade — and the Brilliance row one disclosure down
// is exactly that. The two limiters each solved `1 + 3·slope ≥ margin` against a full
// budget of 0.95 and neither knew about the other, so a lone Midtones +0.3 — which
// `testGentleSettingsAreNotWeakened` below calls "nowhere near the monotonicity limit",
// correctly — folded the picture by 4.4 sRGB code values the moment a ±15 Brilliance
// sat beside it, with BOTH limiters reporting exactly 1.0. The fix is
// `GradeEngine.solveJointScale`; the composed space has its own file
// (`GradeJointLimiterTests`), and every sweep here now crosses the wheels with a
// Brilliance setting instead of assuming the rest of the panel is at rest.

import XCTest
@testable import LumenCore

final class GradeLuminanceInversionTests: XCTestCase {

    /// The Brilliance settings every wheel sweep in this file is crossed with. Zero
    /// first, so the original reading is still taken; then the everyday row the panel
    /// documents (±20), an opposed pair inside it, and the full deflection.
    ///
    /// Opposed across the mid/highlight crossfade because that is where the wheels'
    /// own worst case lives — the two controls have to be measured folding the SAME
    /// boundary, not two different ones.
    private static let brillianceCompanions: [(String, ColorBalanceAxis)] = [
        ("none", ColorBalanceAxis()),
        ("mid +15 / high −15", ColorBalanceAxis(mid: 15, high: -15)),
        ("shadows +20 / high −20", ColorBalanceAxis(shadows: 20, high: -20)),
        ("mid +100 / high −100", ColorBalanceAxis(mid: 100, high: -100)),
        ("global −40, shadows −100 / mid +50",
         ColorBalanceAxis(global: -40, shadows: -100, mid: 50)),
    ]

    /// Realised scene-linear luminance of a neutral grey at `t` stops over mid-grey,
    /// after the grade.
    private func realisedLuminance(_ engine: GradeEngine, at t: Double) -> Double {
        let scene = RGB(gray: 0.18 * pow(2.0, t))
        let out = engine.apply(scene)
        let w = GradeEngine.workingLuminanceWeights
        return w.r * out.r + w.g * out.g + w.b * out.b
    }

    /// The audit's own numeric case: Midtones +1 with Highlights −1, everything else
    /// at the shipped defaults, must be monotone in realised luminance.
    ///
    /// On the pre-fix solve this reverses: the limiter measured the slope of the
    /// REQUESTED stops and found nothing to limit (`lumScale == 1`), while the realised
    /// response — three times steeper — folded across the mid/highlight crossfade.
    ///
    /// CROSSED WITH BRILLIANCE, which is what this test could not see when it was
    /// written: at the fourth companion the same two wheels fold by 46.87 code values
    /// behind two limiters that each report their setting safe.
    func testMidtonesUpHighlightsDownIsMonotone() {
        for (label, companion) in Self.brillianceCompanions {
            var wheels = GradingWheels()
            wheels.mid.lum = 1
            wheels.high.lum = -1
            wheels.colorBalance.brilliance = companion
            let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())

            var previous = -Double.infinity
            var worstDropEV = 0.0
            var t = -9.0
            while t <= 5.0 {
                let lum = realisedLuminance(engine, at: t)
                if lum < previous {
                    worstDropEV = Swift.max(worstDropEV,
                                            log2(previous / Swift.max(lum, 1e-12)))
                }
                XCTAssertGreaterThanOrEqual(
                    lum, previous * (1 - 1e-9),
                    "Midtones +1 / Highlights −1 with Brilliance \(label) rendered a "
                        + "brighter scene darker at t = \(t) EV — the realised response "
                        + "is 1 + 3·scale·slope, the limiter must solve against that 3× "
                        + "slope (pre-fix this fell 0.284 EV across the crossfade with "
                        + "no Brilliance at all), and the two limiters must solve "
                        + "against ONE budget rather than a full one each")
                previous = lum
                t += 0.02
            }
            XCTAssertEqual(worstDropEV, 0, accuracy: 1e-12,
                           "the ramp handed back \(worstDropEV) EV somewhere with "
                               + "Brilliance \(label)")
        }
    }

    /// The full-wheel opposition the fixture generator sweeps — Shadows +1 against
    /// Highlights −1 — at several Blending settings, including the hard crossover, and
    /// against every Brilliance companion. The wheels' worst case and the grid's worst
    /// case are the same crossfade, so the cross is the point of the sweep and not a
    /// widening for its own sake.
    func testOpposedWheelsAreMonotoneAtEveryBlending() {
        for blending in [0.0, 10.0, 50.0, 100.0] {
            for (label, companion) in Self.brillianceCompanions {
                var wheels = GradingWheels()
                wheels.shadows.lum = 1
                wheels.mid.lum = 0
                wheels.high.lum = -1
                wheels.blending = blending
                wheels.colorBalance.brilliance = companion
                let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())
                var previous = -Double.infinity
                var t = -9.0
                while t <= 5.0 {
                    let lum = realisedLuminance(engine, at: t)
                    XCTAssertGreaterThanOrEqual(
                        lum, previous * (1 - 1e-9),
                        "Shadows +1 / Highlights −1 at Blending \(blending) with "
                            + "Brilliance \(label) inverted at t = \(t) EV")
                    previous = lum
                    t += 0.02
                }
            }
        }
    }

    /// The corrected solve must not quietly weaken ordinary settings: a single wheel at
    /// a gentle deflection stays exactly unlimited, and even a full single wheel at the
    /// default Blending keeps effectively all of its strength (the knee engages by a
    /// quarter of a percent — invisible — where a hard cap would have stepped).
    ///
    /// "A LONE MIDTONES +0.3" IS DOING WORK IN THAT SENTENCE, and it did not used to
    /// be. `lumScale == 1` here is a true and useful statement about the WHEELS' solve,
    /// and this test read it as a statement about the picture — which it is only while
    /// nothing else grades the same crossfade. Beside a ±15 Brilliance, both limiters
    /// still report exactly 1.0 and the composed response folds by 4.4 code values. So
    /// the last third of this test asks the question the first two thirds cannot: with
    /// the same gentle wheel and an everyday Brilliance next to it, does the RAMP still
    /// come out monotone?
    func testGentleSettingsAreNotWeakened() {
        var gentle = GradingWheels()
        gentle.mid.lum = 0.3
        let engine = GradeEngine(wheels: gentle, printerLights: PrinterLights())
        XCTAssertEqual(engine.lumScale, 1.0, accuracy: 1e-12,
                       "a lone Midtones +0.3 is nowhere near the wheels' own "
                           + "monotonicity limit and must not be scaled at all")
        XCTAssertEqual(engine.jointScale, 1.0, accuracy: 0,
                       "and with nothing else grading the crossfade it must not be "
                           + "scaled by the joint correction either — bit-exactly, "
                           + "because that is what keeps every single-tool recipe "
                           + "rendering what it always rendered")

        var full = GradingWheels()
        full.mid.lum = 1
        let fullEngine = GradeEngine(wheels: full, printerLights: PrinterLights())
        XCTAssertGreaterThan(fullEngine.lumScale, 0.99,
                             "a lone full-deflection wheel at default Blending should "
                                 + "keep effectively all of its strength")

        // The same gentle wheel with the everyday Brilliance row beside it: 4.39 sRGB
        // code values of fold, pre-fix, with both limiters reporting 1.0.
        var composed = GradingWheels()
        composed.mid.lum = 0.3
        composed.high.lum = -0.3
        composed.colorBalance.brilliance = ColorBalanceAxis(mid: 15, high: -15)
        let composedEngine = GradeEngine(wheels: composed,
                                         printerLights: PrinterLights())
        var previous = -Double.infinity
        var t = -9.0
        while t <= 5.0 {
            let lum = realisedLuminance(composedEngine, at: t)
            XCTAssertGreaterThanOrEqual(
                lum, previous * (1 - 1e-9),
                "wheels ±0.3 with Brilliance ±15 rendered a brighter scene darker at "
                    + "t = \(t) EV. Both limiters report nothing to limit — lumScale "
                    + "\(composedEngine.lumScale), brillianceScale "
                    + "\(composedEngine.colorBalance.brillianceScale) — and 'nowhere "
                    + "near the limit' is a statement about one control at a time.")
            previous = lum
            t += 0.01
        }
    }

    /// The limiter must leave the Luminance ring ALIVE across its travel — the eased
    /// knee, not a hard cap. `deflection × cap` is constant once a hard cap binds, so
    /// clipping produced one identical value over most of the ring's travel.
    func testTheLuminanceRingKeepsDoingMoreUnderTheCorrectedSolve() {
        for blending in [0.0, 10.0, 50.0] {
            var previous = -Double.infinity
            for step in 1...40 {
                let lum = Double(step) / 40
                var wheels = GradingWheels()
                wheels.blending = blending
                wheels.mid.lum = lum
                wheels.high.lum = -lum
                let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())
                let applied = GradeEngine.lumRangeStops * lum * engine.lumScale
                // Strictly increasing, with no epsilon: at Blending 0 a full ring runs
                // ~48× past the corrected cap, where the knee's power tail gains about
                // 1e-9 per step — all the tenth-of-a-stop crossfade can afford, and
                // exactly representable in a double.
                XCTAssertGreaterThan(applied, previous,
                                     "the ring at \(lum) (Blending \(blending)) applied "
                                         + "no more than the step before it")
                previous = applied
            }
        }
    }

    // MARK: - The Colour Balance grid's Brilliance

    /// Brilliance is a per-zone H-K brightness gain crossing the same crossfades the
    /// wheels grade through, and it shipped with NO limiter: Shadows +100 asks the
    /// shadow zone for +1 stop of brightness (3 stops of light) falling to nothing
    /// across a 3 EV crossfade — a composed slope of about −0.5 at the shipped
    /// defaults. A brighter pixel rendered darker, in bands, across the zone boundary.
    ///
    /// CROSSED WITH THE WHEELS, in both directions: this half of the file was as blind
    /// as the other half, and for the mirror-image reason. A Brilliance row that is
    /// safe alone is not safe beside a Luminance ring grading the same crossfade, and
    /// the second wheel companion below is a gentle one — the setting a photographer
    /// reaches for, not a stress test.
    func testBrillianceCannotInvertTheToneResponse() {
        let wheelCompanions: [(String, Double, Double, Double)] = [
            ("none", 0, 0, 0),
            ("mid +0.3 / high −0.3", 0, 0.3, -0.3),
            ("shadows +1 / high −1", 1, 0, -1),
            ("mid +1 / high −1", 0, 1, -1),
        ]
        for (shadows, mid, high) in [(100.0, 0.0, 0.0),
                                     (0.0, 0.0, -100.0),
                                     (100.0, -60.0, 100.0),
                                     (0.0, 100.0, -100.0)] {
            for (label, wheelShadows, wheelMid, wheelHigh) in wheelCompanions {
                var wheels = GradingWheels()
                wheels.shadows.lum = wheelShadows
                wheels.mid.lum = wheelMid
                wheels.high.lum = wheelHigh
                wheels.colorBalance.brilliance = ColorBalanceAxis(global: 0,
                                                                  shadows: shadows,
                                                                  mid: mid, high: high)
                let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())
                var previous = -Double.infinity
                var t = -9.0
                while t <= 5.0 {
                    let lum = realisedLuminance(engine, at: t)
                    XCTAssertGreaterThanOrEqual(
                        lum, previous * (1 - 1e-9),
                        "Brilliance \(shadows)/\(mid)/\(high) with wheels \(label) "
                            + "rendered a brighter scene darker at t = \(t) EV — the "
                            + "grid needs the same realised-response limiter the wheels "
                            + "have, and the two need to share one budget")
                    previous = lum
                    t += 0.02
                }
            }
        }
    }

    /// Global Brilliance rides on top of the partition and contributes no slope, so it
    /// is outside the limiter — exactly as the Global wheel is outside `lumScale`.
    func testGlobalBrillianceIsNeverLimited() {
        var wheels = GradingWheels()
        wheels.colorBalance.brilliance = ColorBalanceAxis(global: 80)
        let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())
        XCTAssertEqual(engine.colorBalance.brillianceScale, 1.0, accuracy: 1e-12,
                       "a uniform gain cannot fold the curve and must not be touched")
    }

    /// And the everyday range — the panel warns past ±20 — is essentially untouched:
    /// a lone zone at ±20 is exactly unlimited, gentle mixed settings are exactly
    /// unlimited, and even ±20 OPPOSED across every zone — which genuinely sits at
    /// ~92% of the fold threshold once the realised 3× slope is counted — keeps over
    /// nine tenths of its strength through the knee.
    func testOrdinaryBrillianceIsNotWeakened() {
        var lone = GradingWheels()
        lone.colorBalance.brilliance = ColorBalanceAxis(shadows: 20)
        let loneEngine = GradeEngine(wheels: lone, printerLights: PrinterLights())
        XCTAssertEqual(loneEngine.colorBalance.brillianceScale, 1.0, accuracy: 1e-12,
                       "a lone zone at +20 is nowhere near the monotonicity limit")

        var gentle = GradingWheels()
        gentle.colorBalance.brilliance = ColorBalanceAxis(shadows: 10, mid: -10, high: 10)
        let gentleEngine = GradeEngine(wheels: gentle, printerLights: PrinterLights())
        XCTAssertEqual(gentleEngine.colorBalance.brillianceScale, 1.0, accuracy: 1e-12,
                       "±10 across the zones is nowhere near the monotonicity limit")

        var opposed = GradingWheels()
        opposed.colorBalance.brilliance = ColorBalanceAxis(shadows: 20, mid: -20,
                                                           high: 20)
        let opposedEngine = GradeEngine(wheels: opposed, printerLights: PrinterLights())
        XCTAssertGreaterThan(opposedEngine.colorBalance.brillianceScale, 0.9,
                             "±20 opposed across every zone may ease slightly but "
                                 + "must keep the bulk of its strength")

        // And the everyday range stays untouched with a gentle wheel beside it. The
        // joint correction exists for the pair that composes past the bound, not for
        // the pair that happens to be non-zero: a ±10 Brilliance with a ±0.1 Luminance
        // ring is still exactly unlimited, on both sides.
        var everyday = GradingWheels()
        everyday.mid.lum = 0.1
        everyday.high.lum = -0.1
        everyday.colorBalance.brilliance = ColorBalanceAxis(mid: 10, high: -10)
        let everydayEngine = GradeEngine(wheels: everyday,
                                         printerLights: PrinterLights())
        XCTAssertEqual(everydayEngine.jointScale, 1.0, accuracy: 0,
                       "±10 Brilliance beside a ±0.1 Luminance ring is nowhere near "
                           + "the composed limit and must not be scaled at all")
    }

    /// The Brilliance zones must keep doing more across their travel under the limiter
    /// — the same aliveness property the ring test above pins for the wheels, so the
    /// eased knee cannot regress into a hard cap during a future retune.
    func testBrillianceKeepsDoingMoreAcrossItsTravel() {
        var previousGain = 0.0
        for step in 1...40 {
            let v = Double(step) / 40 * 100
            var wheels = GradingWheels()
            wheels.colorBalance.brilliance = ColorBalanceAxis(shadows: v)
            let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())
            // Deep in the shadow zone (t = −8 EV) the shadow weight is 1, so the
            // realised gain is the zone's own, scaled by the limiter.
            let gain = realisedLuminance(engine, at: -8) / (0.18 * pow(2.0, -8))
            XCTAssertGreaterThan(gain, previousGain + 1e-9,
                                 "Brilliance Shadows at \(v) applied no more than the "
                                     + "step before it — the limiter has become a cap")
            previousGain = gain
        }
    }
}
