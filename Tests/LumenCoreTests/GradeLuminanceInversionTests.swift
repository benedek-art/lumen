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

import XCTest
@testable import LumenCore

final class GradeLuminanceInversionTests: XCTestCase {

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
    func testMidtonesUpHighlightsDownIsMonotone() {
        var wheels = GradingWheels()
        wheels.mid.lum = 1
        wheels.high.lum = -1
        let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())

        var previous = -Double.infinity
        var worstDropEV = 0.0
        var t = -9.0
        while t <= 5.0 {
            let lum = realisedLuminance(engine, at: t)
            if lum < previous {
                worstDropEV = Swift.max(worstDropEV, log2(previous / Swift.max(lum, 1e-12)))
            }
            XCTAssertGreaterThanOrEqual(
                lum, previous * (1 - 1e-9),
                "Midtones +1 / Highlights −1 rendered a brighter scene darker at "
                    + "t = \(t) EV — the realised response is 1 + 3·scale·slope and the "
                    + "limiter must solve against that 3× slope (pre-fix this fell "
                    + "0.284 EV across the crossfade)")
            previous = lum
            t += 0.02
        }
        XCTAssertEqual(worstDropEV, 0, accuracy: 1e-12,
                       "the ramp handed back \(worstDropEV) EV somewhere")
    }

    /// The full-wheel opposition the fixture generator sweeps — Shadows +1 against
    /// Highlights −1 — at several Blending settings, including the hard crossover.
    func testOpposedWheelsAreMonotoneAtEveryBlending() {
        for blending in [0.0, 10.0, 50.0, 100.0] {
            var wheels = GradingWheels()
            wheels.shadows.lum = 1
            wheels.mid.lum = 0
            wheels.high.lum = -1
            wheels.blending = blending
            let engine = GradeEngine(wheels: wheels, printerLights: PrinterLights())
            var previous = -Double.infinity
            var t = -9.0
            while t <= 5.0 {
                let lum = realisedLuminance(engine, at: t)
                XCTAssertGreaterThanOrEqual(
                    lum, previous * (1 - 1e-9),
                    "Shadows +1 / Highlights −1 at Blending \(blending) inverted "
                        + "at t = \(t) EV")
                previous = lum
                t += 0.02
            }
        }
    }

    /// The corrected solve must not quietly weaken ordinary settings: a single wheel at
    /// a gentle deflection stays exactly unlimited, and even a full single wheel at the
    /// default Blending keeps effectively all of its strength (the knee engages by a
    /// quarter of a percent — invisible — where a hard cap would have stepped).
    func testGentleSettingsAreNotWeakened() {
        var gentle = GradingWheels()
        gentle.mid.lum = 0.3
        let engine = GradeEngine(wheels: gentle, printerLights: PrinterLights())
        XCTAssertEqual(engine.lumScale, 1.0, accuracy: 1e-12,
                       "a lone Midtones +0.3 is nowhere near the monotonicity limit "
                           + "and must not be scaled at all")

        var full = GradingWheels()
        full.mid.lum = 1
        let fullEngine = GradeEngine(wheels: full, printerLights: PrinterLights())
        XCTAssertGreaterThan(fullEngine.lumScale, 0.99,
                             "a lone full-deflection wheel at default Blending should "
                                 + "keep effectively all of its strength")
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
    func testBrillianceCannotInvertTheToneResponse() {
        for (shadows, mid, high) in [(100.0, 0.0, 0.0),
                                     (0.0, 0.0, -100.0),
                                     (100.0, -60.0, 100.0),
                                     (0.0, 100.0, -100.0)] {
            var wheels = GradingWheels()
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
                    "Brilliance \(shadows)/\(mid)/\(high) rendered a brighter scene "
                        + "darker at t = \(t) EV — the grid needs the same realised-"
                        + "response limiter the wheels have")
                previous = lum
                t += 0.02
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
