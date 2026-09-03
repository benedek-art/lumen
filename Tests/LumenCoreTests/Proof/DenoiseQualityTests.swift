// DenoiseQualityTests.swift
//
// DETAIL-15: what `DenoiseTests` could not see.
//
// That file asserts, correctly and usefully, that noise σ falls as each master slider
// rises. Every one of those assertions stays green while the stage destroys the picture
// — a denoiser that returns a flat grey frame removes 100% of the noise — and that is
// exactly what happened: Colour 100 was measurably worse than Colour 25 on residual
// error AND on colour-edge survival, and Luminance was worse than leaving the noise in
// over three quarters of its travel, for as long as anyone had been running the suite.
//
// A quality proof needs GROUND TRUTH, which docs/20's frame set provides:
// `ProofFrames.noisyISO6400()` has a noise-free twin, and `ProofFrames.chromaEdge()` is
// a saturated boundary at deliberately equal luminance, so only a chroma operation can
// move it. `ProofMetrics.rmsAgainst` and `.edgeRetention` score against both.
//
// The bars below are stated numbers rather than "better than before", because the point
// of a bar is that a future change has to argue with it.

import XCTest
@testable import LumenCore

final class DenoiseQualityTests: XCTestCase {

    private let profile = NoiseProfile.forISO(6400)

    private func denoised(luma: Double, chroma: Double,
                          colorSmoothness: Double = 50,
                          _ frame: ImageBuffer) -> ImageBuffer {
        ClassicalDenoise(ClassicNR(luma: luma, chroma: chroma,
                                   colorSmoothness: colorSmoothness),
                         profile: profile).apply(frame)
    }

    // MARK: - The residual-error axis

    /// The floor under the whole stage: at maximum, denoise must still be an improvement
    /// on leaving the noise alone.
    ///
    /// It sounds too weak to be worth writing. It was FALSE. With both masters at 100 the
    /// residual error against the clean twin was 3.5524 against an undenoised 3.6235 —
    /// the stage was returning 98% of the error it was asked to remove, having spent the
    /// whole slider doing it. On a noisy colour chart at ISO 6400 the shipped ISO default
    /// was over 100%: worse than off.
    func testDenoiseAtMaximumStillBeatsLeavingTheNoiseIn() {
        let clean = ProofFrames.cleanISO6400()
        let noisy = ProofFrames.noisyISO6400()
        let base = ProofMetrics.rmsAgainst(clean, noisy)
        XCTAssertGreaterThan(base, 3.0, "the proof frame carries no noise to remove")

        let full = ProofMetrics.rmsAgainst(clean, denoised(luma: 100, chroma: 100, noisy))
        XCTAssertLessThan(full, base * 0.90,
                          "both masters at 100 left \(full / base) of the residual error "
                              + "against ground truth — a denoiser at full deflection "
                              + "that removes under a tenth of the error it exists to "
                              + "remove is spending the whole slider on nothing")
    }

    /// And the shape of the travel, not just its end: the top of the range may cost
    /// something against the best setting, but it may not cost half again.
    ///
    /// Measured at 1.730 before the travel was bounded — the last three quarters of both
    /// sliders bought negative quality and nothing in the suite could say so.
    func testTheTopOfTheTravelDoesNotGiveBackWhatTheMiddleWon() {
        let clean = ProofFrames.cleanISO6400()
        let noisy = ProofFrames.noisyISO6400()

        var best = Double.infinity
        var byStep = [(slider: Double, rms: Double)]()
        for step in 0...20 {
            let s = Double(step) * 5
            let rms = ProofMetrics.rmsAgainst(clean, denoised(luma: s, chroma: s, noisy))
            byStep.append((s, rms))
            best = Swift.min(best, rms)
        }
        let top = byStep[byStep.count - 1].rms
        XCTAssertLessThan(top / best, 1.50,
                          "the top of the master travel scores \(top / best)× the best "
                              + "point on it (\(top) against \(best)); a control whose "
                              + "top half undoes its own middle is mis-scaled. Travel: "
                              + byStep.map { String(format: "%.0f:%.3f", $0.slider, $0.rms) }
                              .joined(separator: " "))
    }

    /// The Colour axis, scored where it can actually be scored.
    ///
    /// On `noisyISO6400` this assertion is a tautology and was written as one first: the
    /// clean twin is neutral, so there is no chroma signal to lose and a stage that
    /// zeroes both chroma planes scores the theoretical floor. Substituting the whole
    /// defect back left it green, which is the same failure `DenoiseTests` had.
    /// `ProofFrames.noisyChromaEdge` is the composition that can fail: chroma noise to
    /// remove and a saturated chroma boundary to keep, scored by one residual.
    ///
    /// Colour Smoothness sits at the ISO 6400 resolution rather than at 50, because that
    /// is the setting a high-ISO import is actually handed and the one the harm showed
    /// up at. Measured across the travel before the ceilings came down: 0 → 3.181,
    /// 10 → 2.313, **40 → 3.300**, 100 → 6.205 — the shipped default for that ISO was
    /// worse than leaving the noise in, and full deflection was twice as bad.
    func testEveryColourSettingBeatsLeavingTheChromaNoiseIn() {
        let clean = ProofFrames.chromaEdge()
        let noisy = ProofFrames.noisyChromaEdge()
        let smoothness = ISODefaults.classic(forISO: 6400).colorSmoothness
        let base = ProofMetrics.rmsAgainst(clean, noisy)
        XCTAssertGreaterThan(base, 1.0, "the frame carries no chroma noise to remove")

        for step in 1...20 {
            let s = Double(step) * 5
            let rms = ProofMetrics.rmsAgainst(
                clean, denoised(luma: 0, chroma: s, colorSmoothness: smoothness, noisy))
            XCTAssertLessThan(
                rms, base * 0.95,
                "Colour \(s) scored \(rms) against \(base) for the undenoised frame. "
                    + "A setting the user can reach that leaves the picture further "
                    + "from the truth than no denoise at all is not a setting")
        }
    }

    // MARK: - The colour-edge axis

    /// `chromaEdge` is red against blue at equal luminance, so nothing but a chroma
    /// operation can move the step. Colour 100 destroyed 29% of it; the ISO 25600
    /// default destroyed 26%.
    ///
    /// The bound is on the OPERATION, so it is asserted at the sub-slider defaults the
    /// panel ships and at the two ISO-adaptive resolutions a high-ISO import actually
    /// gets — a bar that only held at Colour Smoothness 50 would miss both of those.
    func testASaturatedColourEdgeSurvivesColourAtFullDeflection() {
        let edge = ProofFrames.chromaEdge()
        let column = edge.width / 2

        for (chroma, smoothness, label) in [(100.0, 50.0, "Colour 100, shipped defaults"),
                                            (40.0, 69.85, "the ISO 6400 default"),
                                            (55.0, 83.86, "the ISO 25600 default")] {
            let out = denoised(luma: 0, chroma: chroma, colorSmoothness: smoothness, edge)
            let kept = ProofMetrics.edgeRetention(out, against: edge, acrossColumn: column)
            XCTAssertGreaterThan(kept, 0.90,
                                 "\(label) left \(kept) of a saturated colour edge. The "
                                     + "Colour slider is allowed to be aggressive on "
                                     + "chroma NOISE; it is not allowed to eat a tenth "
                                     + "of a colour boundary")
            // The other half of the pin: a stage that stopped shrinking chroma entirely
            // would score 1.0 here and satisfy the line above.
            XCTAssertLessThan(kept, 1.0,
                              "\(label) did not touch the chroma planes at all")
        }
    }

    /// Which mechanism eats the edge is worth pinning separately, because the bound that
    /// holds it is one constant and a future edit to `blotchMaxMix` would otherwise show
    /// up only as a number moving in the test above.
    ///
    /// The blotch pass is guided by LUMINANCE. Across a boundary that is pure chroma the
    /// guide is flat, so the filter has nothing to stop it and blurs colour straight
    /// through. At the old mix of 0.5 it took 22 points of the edge on its own.
    func testTheBlotchPassIsMixedBelowWhereItStartsEatingColourBoundaries() {
        XCTAssertLessThanOrEqual(ClassicalDenoise.blotchMaxMix, 0.10,
                                 "the luminance-guided blotch pass is mixed at "
                                     + "\(ClassicalDenoise.blotchMaxMix); measured on "
                                     + "chromaEdge it costs about 45 points of colour "
                                     + "edge per 0.1 of mix and buys 1.7 points of "
                                     + "chroma noise")
        let plan = ClassicalDenoise(ClassicNR(luma: 0, chroma: 100, colorSmoothness: 100),
                                    profile: profile)
            .gpuPlan(width: 512, height: 512)
        XCTAssertEqual(plan.blotchMix, ClassicalDenoise.blotchMaxMix, accuracy: 1e-12,
                       "the GPU plan does not carry the bound the reference shrinks with")
    }

    /// DETAIL-16: the ISO-adaptive Colour default is the number most photographs are
    /// actually developed at, so it is the one setting on the travel that has to be near
    /// the optimum rather than merely inside the legal range.
    ///
    /// Scored on the composite frame at each ISO, against the best point on that ISO's
    /// own travel. The anchors used to resolve to Colour 40 at ISO 6400 and 55 at
    /// 25600 — 7.0% and 10.3% off their optima with the bounded curve, and worse than
    /// no denoise at all with the curve as shipped. "Profiled and ISO-adaptive rather
    /// than fixed" is the flagship departure from Lightroom's flat 25; it has to be a
    /// better number, not just a different one.
    func testTheISOAdaptiveColourDefaultsLandNearTheirMeasuredOptimum() {
        let clean = ProofFrames.chromaEdge()
        for iso in [6400.0, 25600.0] {
            let noisy = ProofFrames.noisyChromaEdge(iso: iso)
            let block = ISODefaults.classic(forISO: iso)
            let isoProfile = NoiseProfile.forISO(iso)
            func score(_ chroma: Double) -> Double {
                ProofMetrics.rmsAgainst(clean, ClassicalDenoise(
                    ClassicNR(luma: 0, chroma: chroma,
                              colorSmoothness: block.colorSmoothness),
                    profile: isoProfile).apply(noisy))
            }
            var best = Double.infinity
            var bestAt = 0.0
            for step in 0...10 {
                let s = Double(step) * 10
                let r = score(s)
                if r < best { best = r; bestAt = s }
            }
            let resolved = score(block.chroma)
            XCTAssertLessThan(resolved / best, 1.05,
                              "ISO \(Int(iso)) resolves to Colour \(block.chroma), which "
                                  + "scores \(resolved) against \(best) at the travel's "
                                  + "best point (Colour \(bestAt)) — the adaptive "
                                  + "default is \(resolved / best)× the optimum")
        }
    }

    /// The Luminance twin of the colour-defaults pin above (docs/23 dossier queue
    /// item 7): the same σ double-count was measured-and-fixed for chroma and
    /// UNMEASURED for luma, whose anchors climb 0 → 25 → 40 with ISO on the same
    /// "noise rises with gain" reasoning the chroma measurement convicted. The sweep
    /// below is the measurement; the assertion pins whatever the anchors resolve to
    /// against the best point on that ISO's own travel, so the curve has to be a
    /// better number at every gain, not just a plausible one.
    ///
    /// Printed as a table (PERFPROBE-style) so the lane's log carries the optimum per
    /// ISO — the number the anchors are answerable to.
    func testTheISOAdaptiveLuminanceDefaultsLandNearTheirMeasuredOptimum() {
        let clean = ProofFrames.cleanISO6400()
        for iso in [400.0, 1600.0, 6400.0, 25600.0] {
            let noisy = ProofFrames.noisyLumaFrame(iso: iso)
            let block = ISODefaults.classic(forISO: iso)
            let isoProfile = NoiseProfile.forISO(iso)
            func score(_ luma: Double) -> Double {
                ProofMetrics.rmsAgainst(clean, ClassicalDenoise(
                    ClassicNR(luma: luma, chroma: 0),
                    profile: isoProfile).apply(noisy))
            }
            var best = Double.infinity
            var bestAt = 0.0
            var travel: [String] = []
            for step in 0...10 {
                let s = Double(step) * 10
                let r = score(s)
                travel.append(String(format: "%.0f:%.4f", s, r))
                if r < best { best = r; bestAt = s }
            }
            let resolved = score(block.luma)
            print("LUMAPROBE ISO \(Int(iso)): default \(block.luma) scores "
                  + String(format: "%.4f", resolved) + " best "
                  + String(format: "%.4f", best) + " at \(Int(bestAt))  travel: "
                  + travel.joined(separator: " "))
            XCTAssertLessThan(resolved / best, 1.05,
                              "ISO \(Int(iso)) resolves to Luminance \(block.luma), "
                                  + "which scores \(resolved) against \(best) at the "
                                  + "travel's best point (Luminance \(bestAt)) — the "
                                  + "adaptive default is \(resolved / best)× the optimum")
        }
    }

    // MARK: - The texture axis

    /// Residual error is an average and can be satisfied by a stage that keeps the ramp
    /// and eats every fine detail on it. So: the finest wavelet band of the render must
    /// still correlate with the finest wavelet band of the CLEAN frame.
    ///
    /// It fell 0.856 → 0.748 over the Luminance travel, and the docs/19 measurement on
    /// its own frame put the collapse at 0.155 → 0.025 between 50 and 100.
    func testLuminanceAtFullDeflectionStillCorrelatesWithRealTexture() {
        let clean = ProofFrames.cleanISO6400()
        let noisy = ProofFrames.noisyISO6400()

        func fineBand(_ image: ImageBuffer) -> [Double] {
            SpatialOps.atrousWavelet(image.luminancePlane(space: .rec2020), levels: 2)
                .details[0].values.map { Double($0) }
        }
        func correlation(_ a: [Double], _ b: [Double]) -> Double {
            let ma = a.reduce(0, +) / Double(a.count)
            let mb = b.reduce(0, +) / Double(b.count)
            var num = 0.0, da = 0.0, db = 0.0
            for i in 0..<a.count {
                let x = a[i] - ma, y = b[i] - mb
                num += x * y; da += x * x; db += y * y
            }
            return num / (da * db).squareRoot()
        }

        let truth = fineBand(clean)
        let untouched = correlation(truth, fineBand(noisy))
        XCTAssertGreaterThan(untouched, 0.80,
                             "the noisy frame's fine band does not carry the clean "
                                 + "frame's texture, so this metric proves nothing")

        let full = correlation(truth, fineBand(denoised(luma: 100, chroma: 0, noisy)))
        XCTAssertGreaterThan(full, 0.78,
                             "Luminance 100 left \(full) correlation with real texture "
                                 + "against \(untouched) before denoising — the fine "
                                 + "band is being emptied, not cleaned")
    }

    // MARK: - The bound is on the curve, not on one call site

    /// Both master curves are bounded at the same measured ceiling and anchored so the
    /// mid travel keeps its authority. Pinning the anchors here means a future edit that
    /// re-raises the ceiling has to come past a named number rather than a magic one.
    func testBothMasterCurvesAreBoundedAtTheMeasuredCeiling() {
        XCTAssertEqual(ClassicalDenoise.lumaK(100), ClassicalDenoise.lumaMaxK,
                       accuracy: 1e-12)
        XCTAssertEqual(ClassicalDenoise.chromaK(100), ClassicalDenoise.chromaMaxK,
                       accuracy: 1e-12)
        XCTAssertLessThanOrEqual(ClassicalDenoise.lumaMaxK, 2.5,
                                 "past 2.5σ a soft threshold keeps under 5% of a band "
                                     + "and every further step is paid in texture")
        XCTAssertLessThanOrEqual(ClassicalDenoise.chromaMaxK, 2.5)

        // The anchors are what stop the bound from being a quiet weakening: each master
        // must still reach its stated strength at its stated setting.
        XCTAssertEqual(ClassicalDenoise.lumaK(ClassicalDenoise.lumaAnchorSlider),
                       ClassicalDenoise.lumaAnchorK, accuracy: 1e-9)
        XCTAssertEqual(ClassicalDenoise.chromaK(ClassicalDenoise.chromaAnchorSlider),
                       ClassicalDenoise.chromaAnchorK, accuracy: 1e-9)

        // And they stay alive across the bounded travel — a ceiling applied as a clamp
        // rather than as a curve buys the residual number by killing the top half.
        var previousL = 0.0, previousC = 0.0
        for step in 1...20 {
            let s = Double(step) * 5
            let l = ClassicalDenoise.lumaK(s), c = ClassicalDenoise.chromaK(s)
            XCTAssertGreaterThan(l, previousL, "Luminance is flat at \(s)")
            XCTAssertGreaterThan(c, previousC, "Colour is flat at \(s)")
            previousL = l
            previousC = c
        }
    }
}
