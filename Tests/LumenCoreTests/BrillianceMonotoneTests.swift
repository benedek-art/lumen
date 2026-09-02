// BrillianceMonotoneTests.swift
// docs/audit-2026-09/w2/B2.md §B2-01 — the Brilliance limiter reported "nothing to
// limit" on the settings that fold hardest.
//
// `ColorBalanceGrid.solveBrillianceScale` searched for the largest scale its sampled
// profile survives, and it asked one trial scale — 64× the request — whether there was
// anything to limit at all. The predicate it asked is right about any ONE scale and is
// NOT monotone in the scale: push the scale far enough and every sample hits the gain
// floor at zero, the profile goes flat, and a flat profile reads as monotone. So on the
// settings that drive two zones hard negative the ceiling test passed, the guard
// returned 1, and the bisection under it never ran.
//
// Measured here, on the audit's own grid — shadows/mid/high ∈ {−100, −50, 0, +50, +100}
// at Blending ∈ {0, 25, 50, 75, 100} — against the realised response of a neutral ramp,
// `Y = 0.18·2^t·G(t)³`:
//
//   · SEVEN of the 125 combinations reversed by more than a millionth of a code value,
//     at EVERY Blending including the shipped 50, with `brillianceScale` reading 1.0.
//     Brilliance −50 / −50 / −100 was brightest at −0.705 EV and pure black by
//     +1.880 EV: 28.53 sRGB code values handed back, the highlights rendering BELOW the
//     midtones.
//   · The audit counts twelve. The other five are the uniform crushes — every zone at
//     −100, or −100/−100/x — where the gain reaches zero across the whole shadow and
//     mid stretch and the frame really is black. Their "reversal" is 3e-50 of
//     luminance, the last bits of the weighted sum of three equal values, and it is
//     0.0000 code values. They are not folds and they are byte-identical before and
//     after this fix; counting them by strict inequality on a double is what makes the
//     headline twelve rather than seven. This file counts what a photographer could
//     see, and pins the five separately as the crush they are.
//
// Every assertion below was reasoned against the pre-fix engine, and the transcription
// of its search in `previouslyShippedScale` is what lets the last test check — rather
// than assert — that the fix moved those seven and nothing else.

import XCTest
@testable import LumenCore

final class BrillianceMonotoneTests: XCTestCase {

    /// The grid the audit swept.
    private static let levels: [Double] = [-100, -50, 0, 50, 100]
    private static let blendings: [Double] = [0, 25, 50, 75, 100]

    /// A reversal smaller than this is float noise, not a control changing its mind —
    /// the same millionth of a code value `ProofRecord.agrees` calls agreement.
    private static let noise: Double = 1e-6

    // MARK: - Reading the realised tone response

    private func engine(shadows: Double, mid: Double, high: Double,
                        blending: Double = 50) -> GradeEngine {
        var wheels = GradingWheels()
        wheels.blending = blending
        wheels.colorBalance.brilliance = ColorBalanceAxis(global: 0, shadows: shadows,
                                                          mid: mid, high: high)
        return GradeEngine(wheels: wheels, printerLights: PrinterLights())
    }

    /// Realised scene luminance of a neutral at `t` stops over mid-grey, after the
    /// grade — the engine itself, not a model of it.
    private func realisedLuminance(_ engine: GradeEngine, at t: Double) -> Double {
        let out: RGB = engine.apply(RGB(gray: LumenLog.midGrey * pow(2.0, t)))
        let w: RGB = GradeEngine.workingLuminanceWeights
        return w.r * out.r + w.g * out.g + w.b * out.b
    }

    /// The currency the audit measured in and the photographer sees, through the
    /// engine's own sRGB encoding rather than a second copy of it.
    private func codeValue(_ luminance: Double) -> Double {
        255 * TransferFunction.srgb.encode(Swift.max(0, luminance))
    }

    /// The same response written out of the documented model: the zone gain
    /// `G = max(0, 1 + zoneScale·Σ w_z·v_z/100)` cubed back to light. It exists so a
    /// test can render what the PRE-FIX engine rendered — whose scale was exactly 1 on
    /// every setting that folded — without a second engine. `testTheModelIsTheEngine`
    /// is what makes it evidence rather than assertion.
    private func modelledLuminance(shadows: Double, mid: Double, high: Double,
                                   windows: ZoneWindows, zoneScale: Double,
                                   at t: Double) -> Double {
        let w = windows.weights(at: t)
        let zoned: Double = w.shadows * shadows + w.mid * mid + w.high * high
        let gain: Double = Swift.max(0, 1 + zoneScale * zoned / 100)
        return LumenLog.midGrey * pow(2.0, t) * gain * gain * gain
    }

    /// Worst peak-to-trough reversal of a response over the whole −9…+5 EV axis, in
    /// sRGB code values, with the two positions it happened between.
    private func worstReversal(step: Double = 0.01,
                               _ luminance: (Double) -> Double)
        -> (code: Double, peakEV: Double, troughEV: Double) {
        var peak: Double = -.infinity
        var peakEV: Double = -9
        var worst: Double = 0
        var worstPeakEV: Double = -9
        var worstTroughEV: Double = -9
        var t: Double = -9
        while t <= 5 + 1e-12 {
            let value: Double = codeValue(luminance(t))
            if value > peak {
                peak = value
                peakEV = t
            }
            if peak - value > worst {
                worst = peak - value
                worstPeakEV = peakEV
                worstTroughEV = t
            }
            t += step
        }
        return (worst, worstPeakEV, worstTroughEV)
    }

    /// Worst difference between the ramps two limiter scales render, in sRGB code
    /// values — how much of a setting's picture a change to the solve actually moved.
    private func worstRampDifference(shadows: Double, mid: Double, high: Double,
                                     windows: ZoneWindows,
                                     between one: Double, and other: Double) -> Double {
        var worst: Double = 0
        var t: Double = -9
        while t <= 5 + 1e-12 {
            let a = codeValue(modelledLuminance(shadows: shadows, mid: mid, high: high,
                                                windows: windows, zoneScale: one, at: t))
            let b = codeValue(modelledLuminance(shadows: shadows, mid: mid, high: high,
                                                windows: windows, zoneScale: other, at: t))
            worst = Swift.max(worst, abs(a - b))
            t += 0.01
        }
        return worst
    }

    // MARK: - The model is the engine

    /// The neutral axis is the one place the grid's three quadratics are exact by
    /// inspection: a neutral has zero chroma, so the H-K term drops out, brilliance
    /// rides `L` alone, and `L` cubes back to light. Every pre-fix number below is read
    /// through `modelledLuminance`, so this is the test that makes it readable: the
    /// model against `apply`, at the scale the engine actually applies. They agree to
    /// 1.3e-15 relative, six orders inside the accuracy asserted here.
    func testTheModelIsTheEngine() {
        for blending in Self.blendings {
            for (shadows, mid, high) in [(60.0, 0.0, 0.0), (0.0, -40.0, 20.0),
                                         (-50.0, -50.0, -100.0), (100.0, -100.0, 50.0)] {
                let graded = engine(shadows: shadows, mid: mid, high: high,
                                    blending: blending)
                let scale = graded.colorBalance.brillianceScale
                var t: Double = -9
                while t <= 5 + 1e-12 {
                    let fromEngine = realisedLuminance(graded, at: t)
                    let fromModel = modelledLuminance(
                        shadows: shadows, mid: mid, high: high,
                        windows: graded.windows, zoneScale: scale, at: t)
                    XCTAssertEqual(
                        fromEngine, fromModel,
                        accuracy: Swift.max(fromModel * 1e-9, 1e-18),
                        "the neutral model and the engine disagree at t = \(t) EV on "
                            + "Brilliance \(shadows)/\(mid)/\(high) at Blending "
                            + "\(blending) — every pre-fix number in this file is read "
                            + "through that model")
                    t += 0.25
                }
            }
        }
    }

    // MARK: - The sweep

    /// All 125 zone combinations at five Blending settings, against the engine itself.
    ///
    /// RED BEFORE THE FIX on seven of the 125, at every one of the five Blending
    /// settings: −100/−50/−100 and −50/−50/−100 hand back 28.53 code values, and the
    /// five −50/−100/x hand back 1.46 (at Blending 50; the reversal grows as Blending
    /// falls, to 46.87 at Blending 0). All seven reported `brillianceScale == 1.0`.
    func testEveryZoneCombinationIsMonotoneAtEveryBlending() {
        for blending in Self.blendings {
            for shadows in Self.levels {
                for mid in Self.levels {
                    for high in Self.levels {
                        let graded = engine(shadows: shadows, mid: mid, high: high,
                                            blending: blending)
                        let reversal = worstReversal { realisedLuminance(graded, at: $0) }
                        XCTAssertLessThan(
                            reversal.code, Self.noise,
                            "Brilliance \(shadows)/\(mid)/\(high) at Blending "
                                + "\(blending) renders \(reversal.troughEV) EV darker "
                                + "than \(reversal.peakEV) EV — \(reversal.code) sRGB "
                                + "code values handed back, with brillianceScale "
                                + "reading \(graded.colorBalance.brillianceScale). A "
                                + "profile flattened by the gain floor is not a "
                                + "monotone profile.")
                    }
                }
            }
        }
    }

    // MARK: - The reported case

    /// B2-01's own number, pinned from both ends so a regression names itself: what the
    /// setting did before the fix, and what it does now.
    ///
    /// Brilliance −50 / −50 / −100 at the shipped Blending. The zone term falls from
    /// −0.5 to −1.0 across the mid/highlight crossfade, so at full strength the gain
    /// falls from 0.5 to zero — and cubed, the highlights go out while the midtones
    /// still render. Brightest at −0.705 EV (luminance 0.011966, 28.53 code values),
    /// pure black from +1.880 EV up.
    func testTheReportedCaseNoLongerRendersTheHighlightsBelowTheMidtones() {
        let graded = engine(shadows: -50, mid: -50, high: -100, blending: 50)

        // What the pre-fix engine rendered: its scale on this setting was exactly 1.
        let before = worstReversal(step: 0.005) {
            modelledLuminance(shadows: -50, mid: -50, high: -100,
                              windows: graded.windows, zoneScale: 1, at: $0)
        }
        XCTAssertEqual(before.code, 28.5288, accuracy: 0.01,
                       "the defect's own magnitude moved — B2-01 measured 28.5 sRGB "
                           + "code values of reversal on this setting")
        XCTAssertEqual(before.peakEV, -0.705, accuracy: 0.01,
                       "the reversal used to start at −0.71 EV")
        XCTAssertEqual(before.troughEV, 1.880, accuracy: 0.01,
                       "the picture used to be pure black from +1.88 EV up")

        // And what it renders now.
        let after = worstReversal(step: 0.005) { realisedLuminance(graded, at: $0) }
        XCTAssertLessThan(after.code, Self.noise,
                          "the reported case still hands back \(after.code) code values")

        // The guard, not only the symptom — the assertion B2-01 asked for by name.
        XCTAssertLessThan(
            graded.colorBalance.brillianceScale, 1.0,
            "the limiter still reports nothing to limit on the setting that folds "
                + "hardest")
        XCTAssertEqual(
            graded.colorBalance.brillianceScale, 0.505495666646, accuracy: 1e-9,
            "the solved cap moved. It is the scale at which the steepest sampled "
                + "interval of the crossfade first breaks the composed bound "
                + "1 + 3·Δlog2(G)/ΔEV ≥ 0.05, eased onto through the same knee the "
                + "wheels use, and it is what leaves this setting a −25/−25/−51 "
                + "Brilliance rather than a black band across the top of the scale.")
    }

    /// The one genuinely flat setting. Every zone at −100 takes the gain to zero
    /// everywhere, so the frame is black from end to end — a crush, not an inversion,
    /// and the limiter must leave it exactly alone. This is the case a fix that read
    /// every floored sample as a fold would have quietly turned into dark grey.
    func testAUniformCrushIsLeftExactlyAlone() {
        for blending in Self.blendings {
            let graded = engine(shadows: -100, mid: -100, high: -100, blending: blending)
            XCTAssertEqual(
                graded.colorBalance.brillianceScale, 1.0, accuracy: 0,
                "Brilliance −100 across every zone is a uniform gain of zero at "
                    + "Blending \(blending) — flat, and nothing a multiplier can "
                    + "improve. It must not be limited.")
            var t: Double = -9
            while t <= 5 + 1e-12 {
                XCTAssertLessThan(realisedLuminance(graded, at: t), 1e-30,
                                  "a full crush stopped being black at t = \(t) EV")
                t += 0.25
            }
        }
    }

    // MARK: - Nothing else moved

    /// The search this fix replaced, transcribed from the shipped source so that "the
    /// other 118 are unchanged" can be CHECKED rather than asserted. Global is left out
    /// because this file sweeps the zones only, which is where the limiter lives.
    ///
    /// The whole defect is visible in it: `isMonotone` is correct about any one scale,
    /// and both the ceiling guard and the bisection under it assume the answer is
    /// monotone in the scale. It is not — at 64× the request every sample of a
    /// two-zone-negative profile has hit the gain floor, `safeLog2` reads them all as
    /// the same floor value, and the flattened profile passes.
    private func previouslyShippedScale(shadows: Double, mid: Double, high: Double,
                                        windows: ZoneWindows) -> Double {
        guard shadows != 0 || mid != 0 || high != 0 else { return 1 }
        let span: Double = windows.spanEV
        let narrowest: Double = Swift.min(windows.shadowHalfWidth,
                                          windows.highlightHalfWidth)
        let step: Double = Num.clamp(narrowest / 8, 1e-4, 0.01)
        var zoned: [Double] = []
        var x: Double = 0
        while x < 1 {
            let w = windows.weights(atNormalized: x)
            zoned.append((w.shadows * Num.clamp(shadows, -100, 100)
                + w.mid * Num.clamp(mid, -100, 100)
                + w.high * Num.clamp(high, -100, 100)) / 100)
            x += step
        }
        let wEnd = windows.weights(atNormalized: 1)
        zoned.append((wEnd.shadows * Num.clamp(shadows, -100, 100)
            + wEnd.mid * Num.clamp(mid, -100, 100)
            + wEnd.high * Num.clamp(high, -100, 100)) / 100)

        let margin: Double = 0.05
        func isMonotone(at s: Double) -> Bool {
            var previous: Double = Num.safeLog2(Swift.max(1 + s * zoned[0], 0))
            for i in 1..<zoned.count {
                let g: Double = Num.safeLog2(Swift.max(1 + s * zoned[i], 0))
                let slope: Double = GradeEngine.realisedStopsPerJStop
                    * (g - previous) / (step * span)
                if 1 + slope < margin { return false }
                previous = g
            }
            return true
        }

        let ceiling: Double = 64
        guard !isMonotone(at: ceiling) else { return 1 }
        var lo: Double = 0
        var hi: Double = ceiling
        var i: Int = 0
        while i < 40 {
            let trial: Double = 0.5 * (lo + hi)
            if isMonotone(at: trial) { lo = trial } else { hi = trial }
            i += 1
        }
        let cap: Double = lo
        guard cap.isFinite, cap > 0 else { return 1 }
        let normalized: Double = 1 / cap
        return Swift.min(Num.softKnee(normalized) / normalized, 1)
    }

    /// The fix is allowed to move the seven settings that folded and nothing else.
    ///
    /// Of the other 118 at each Blending, every one the old search left EXACTLY
    /// unlimited is still exactly 1.0, bit for bit — the uniform crushes included. The
    /// rest were already limited, and the closed form returns the same crossing the old
    /// bisection was converging on: it differs only by the residual that bisection
    /// leaves, at most `64/2^40` in the cap and 7.7e-9 relative in the applied scale,
    /// which is 3.7e-8 sRGB code values on the rendered ramp — four orders of magnitude
    /// below the millionth of a code value the proof records call agreement, and below
    /// what a float32 render can represent at all.
    func testTheFixMovesTheSevenThatFoldedAndNothingElse() {
        for blending in Self.blendings {
            var folded = 0
            for shadows in Self.levels {
                for mid in Self.levels {
                    for high in Self.levels {
                        let graded = engine(shadows: shadows, mid: mid, high: high,
                                            blending: blending)
                        let windows = graded.windows
                        let before = previouslyShippedScale(
                            shadows: shadows, mid: mid, high: high, windows: windows)
                        let now = graded.colorBalance.brillianceScale
                        let reversal = worstReversal {
                            modelledLuminance(shadows: shadows, mid: mid, high: high,
                                              windows: windows, zoneScale: before, at: $0)
                        }
                        let label = "Brilliance \(shadows)/\(mid)/\(high) at Blending "
                            + "\(blending)"
                        if reversal.code >= Self.noise {
                            folded += 1
                            XCTAssertEqual(before, 1.0, accuracy: 0,
                                           "\(label) folded by \(reversal.code) code "
                                               + "values and the old search still "
                                               + "reported nothing to limit — this "
                                               + "test's picture of the defect is wrong")
                            XCTAssertLessThan(now, before,
                                              "\(label) folded and is still unlimited")
                        } else if before == 1 {
                            XCTAssertEqual(
                                now, 1.0, accuracy: 0,
                                "\(label) was exactly unlimited and this fix limited it "
                                    + "to \(now). A setting that does not fold must not "
                                    + "be touched.")
                        } else {
                            // Already limited, and the closed form lands on the same
                            // crossing the bisection was closing on: at most 64/2^40
                            // of cap, which is 7.7e-9 of the applied scale at the
                            // smallest cap on this grid (0.00701, at −100/+100/−100,
                            // Blending 0).
                            XCTAssertEqual(
                                now, before, accuracy: before * 1e-7,
                                "\(label) was limited to \(before) and is now \(now) — "
                                    + "further than the residual the old bisection left "
                                    + "behind, so this is a behaviour change and not "
                                    + "the search becoming exact.")
                        }
                        // And the claim in the currency that decides it: whatever the
                        // two scales are, the picture they render is the same one. The
                        // worst reading on this grid is 3.7e-8 code values, against the
                        // millionth of a code value the proof records call agreement —
                        // so no committed record can move behind this fix.
                        if reversal.code < Self.noise {
                            XCTAssertLessThan(
                                worstRampDifference(shadows: shadows, mid: mid,
                                                    high: high, windows: windows,
                                                    between: before, and: now),
                                Self.noise,
                                "\(label) renders differently before and after a fix "
                                    + "that was not supposed to touch it")
                        }
                    }
                }
            }
            XCTAssertEqual(folded, 7,
                           "\(folded) of the 125 combinations folded under the old "
                               + "search at Blending \(blending), against the seven "
                               + "B2-01 measured (its headline twelve counts five "
                               + "uniform crushes whose reversal is 3e-50 of "
                               + "luminance on an all-black frame)")
        }
    }
}
