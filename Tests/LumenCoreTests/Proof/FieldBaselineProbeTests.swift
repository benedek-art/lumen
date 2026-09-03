// FieldBaselineProbeTests.swift
//
// The Lumen columns for docs/26 §4–6 (P6 baselines, docs/23 M2): the SAME
// experiments `scripts/baselines/crosscheck.py` runs against RawTherapee 5.10 and
// darktable 4.6, printed as TONEBASE / HAZEBASE / SHARPBASE lines on every Linux
// lane run so the numbers stay re-measurable on both sides of the comparison.
//
// Same posture as the other probes: the print is the deliverable, the assertions are
// the claims Lumen actually makes — Highlights/Shadows own ±2.0 EV and mid-grey is
// EXACTLY still (the hard partition RT's S&H does not have; RT moves mid-grey ±0.25
// EV at full deflection), and dehaze recovers ground contrast without pushing
// anything negative.

import XCTest
@testable import LumenCore

final class FieldBaselineProbeTests: XCTestCase {

    // MARK: - §4  Shadow / highlight recovery

    func testPrintsTheToneRecoveryBaseline() {
        let evs = [-5.0, -3.0, -1.0, 0.0, 1.0, 2.0, 2.32]

        func shifts(_ mutate: (inout Tone) -> Void) -> [Double] {
            var tone = Tone()
            mutate(&tone)
            let engine = ToneEngine(tone: tone, zones: Zones())
            return evs.map { Num.safeLog2(engine.gain(at: $0)) }
        }

        let highlights = shifts { $0.highlights = -100 }
        let shadows = shifts { $0.shadows = 100 }

        func row(_ label: String, _ values: [Double]) -> String {
            label + " " + values.map { String(format: "%+5.2f", $0) }
                .joined(separator: "  ")
        }
        print("TONEBASE scene EV        "
              + evs.map { String(format: "%+5.2f", $0) }.joined(separator: "  "))
        print("TONEBASE " + row("Highlights -100", highlights))
        print("TONEBASE " + row("Shadows    +100", shadows))

        // Where each control actually peaks, over the whole domain — RT's brightest
        // patch (+2.32, a 5× card) sits well below Lumen's highlight-weight centre,
        // so the window rows above never show Highlights' full −2.0. The doc quotes
        // this line for the peak; the window rows for the like-for-like patches.
        func fullRangePeak(_ mutate: (inout Tone) -> Void) -> (ev: Double, shift: Double) {
            var tone = Tone()
            mutate(&tone)
            let engine = ToneEngine(tone: tone, zones: Zones())
            var peak = (ev: 0.0, shift: 0.0)
            for ev in stride(from: -14.0, through: 9.0, by: 0.125) {
                let shift = Num.safeLog2(engine.gain(at: ev))
                if abs(shift) > abs(peak.shift) { peak = (ev, shift) }
            }
            return peak
        }
        let highlightPeak = fullRangePeak { $0.highlights = -100 }
        let shadowPeak = fullRangePeak { $0.shadows = 100 }
        print(String(format: "TONEBASE full-range peaks: Highlights %+.2f EV at "
                     + "scene %+.1f, Shadows %+.2f EV at scene %+.1f",
                     highlightPeak.shift, highlightPeak.ev,
                     shadowPeak.shift, shadowPeak.ev))

        // The claims the table carries (docs/26 §4). The hard partition: mid-grey and
        // the OTHER control's half of the axis are EXACTLY still — RT's S&H, same
        // experiment, moves mid-grey −0.26/+0.24 EV and each control leaks across it.
        for i in 0...3 {
            XCTAssertEqual(highlights[i], 0, accuracy: 1e-9,
                           "Highlights moved scene \(evs[i]) EV — the partition IS the design")
        }
        for i in 3..<evs.count {
            XCTAssertEqual(shadows[i], 0, accuracy: 1e-9,
                           "Shadows moved scene \(evs[i]) EV — the partition IS the design")
        }
        // Shadows reach their full documented +2.0 EV inside the window; Highlights
        // engage monotonically through it (the full −2.0, asserted over the whole
        // domain by AccuracyProbeTests, peaks above +2.32 — printed above).
        XCTAssertEqual(shadows.max() ?? 0, ToneEngine.highlightShadowRangeEV,
                       accuracy: 0.05)
        for i in 4..<evs.count {
            XCTAssertLessThan(highlights[i], highlights[i - 1],
                              "Highlights must deepen monotonically above mid-grey")
        }
        XCTAssertLessThan(highlights[6], -0.5,
                          "Highlights barely engaged at the +2.32 patch")
        XCTAssertEqual(abs(highlightPeak.shift), ToneEngine.highlightShadowRangeEV,
                       accuracy: 0.05)
        XCTAssertEqual(shadowPeak.shift, ToneEngine.highlightShadowRangeEV,
                       accuracy: 0.05)
    }

    // MARK: - §5  Dehaze

    /// The same veiled scene `crosscheck.py` builds (`hazy_scene`, itself the shape
    /// of ProofFrames.hazySky): textured dark ground under a sky gradient, veiled by
    /// airlight (0.55, 0.62, 0.78), transmission falling toward the top.
    private func hazyScene(size: Int = 128) -> ImageBuffer {
        let air = RGB(0.55, 0.62, 0.78)
        return ImageBuffer(width: size, height: size) { u, v in
            let clear: RGB
            if v < 0.6 {
                clear = RGB(0.10 + 0.05 * v, 0.16 + 0.08 * v, 0.34 + 0.10 * v)
            } else {
                let t = 1 + 0.25 * sin(2 * Double.pi * u * Double(size) / 5.0)
                clear = RGB(0.13 * t, 0.11 * t, 0.08 * t)
            }
            let transmission = 0.25 + 0.65 * v
            return clear * transmission + air * (1 - transmission)
        }
    }

    /// RMS contrast of the ground band's luminance — the thing dehaze exists to
    /// recover. Same band (bottom 20%) and same weights as the Python side.
    private func groundContrast(_ image: ImageBuffer) -> Double {
        let start = Int(Double(image.height) * 0.8)
        var sum = 0.0, count = 0.0
        for y in start..<image.height {
            for x in 0..<image.width {
                sum += RGBColorSpace.rec2020.luminance(image[x, y])
                count += 1
            }
        }
        let mean = sum / count
        guard mean > 1e-9 else { return 0 }
        var variance = 0.0
        for y in start..<image.height {
            for x in 0..<image.width {
                let d = RGBColorSpace.rec2020.luminance(image[x, y]) - mean
                variance += d * d
            }
        }
        return (variance / count).squareRoot() / mean
    }

    private func topVeilLuminance(_ image: ImageBuffer) -> Double {
        var sum = 0.0, count = 0.0
        for y in 0..<8 {
            for x in 0..<image.width {
                sum += RGBColorSpace.rec2020.luminance(image[x, y])
                count += 1
            }
        }
        return sum / count
    }

    // MARK: - §6  Sharpening

    /// The same known-blur edge `crosscheck.py rt_sharpen` builds: a vertical
    /// dark → bright linear edge, capture-blurred by an EXACT Gaussian of σ 1.5 px,
    /// so "how much of the blur does each sharpener undo" has a ground truth.
    private func blurredEdge(dark: Double = 0.06, bright: Double = 0.35,
                             sigma: Double = 1.5) -> ImageBuffer {
        // 2560, spelled as the constant rather than as a number, because this probe's
        // ground truth is a sigma of 1.5 PIXELS and `spatialReferenceLongEdge` is the one
        // width at which a picture-denominated Radius of 1.5 is also 1.5 pixels. At
        // exactly this width `frameDenominatedSigma(1.5, 2560) == 1.5` and
        // `fineBandLevel(2560, 5) == 0`, so both halves of E2-04 are the identity and
        // `applySharpen` computes byte for byte what it computed before that landing.
        //
        // At 128 the scaled sigma never cleared `gaussianBlur`'s own support floor, so
        // the sharpener was inert and this probe read "manual 100 recovered no edge
        // rise" — the finding, not a regression. 2048 does not fix it either: the halo
        // probe's `worstShift` reads 0.00786 against its 0.01 floor and stays red.
        //
        // The width is not "bigger", it is the identity, and the evidence is committed:
        // every Lumen figure in docs/26 §6's cross-check table against RawTherapee comes
        // back exactly here and at no other width — rise 1.54, recovery ×1.36, overshoot
        // 6.0%, undershoot 1.7%, capture ×1.53 — and the halo docstring's own "measured
        // 0.048 linear at full deflection" is 0.048356. Too small and the stage is
        // inert; too large and the pinned halo equality flips and the test would report
        // the defect as fixed.
        let w = Int(SpatialOps.spatialReferenceLongEdge), h = 64
        let step = ImageBuffer(width: w, height: h) { u, _ in
            RGB(gray: u < 0.5 ? dark : bright)
        }
        return SpatialOps.gaussianBlur(step, sigma: sigma)
    }

    /// Mean edge-spread function metrics, same definitions as the Python side:
    /// 25%→75% crossing distance in px (robust to overshoot), and the over/
    /// undershoot as fractions of the edge step — the halo measurements.
    private func edgeProfile(_ image: ImageBuffer)
        -> (rise: Double, overshoot: Double, undershoot: Double)
    {
        let w = image.width
        var esf = [Double](repeating: 0, count: w)
        for x in 0..<w {
            var sum = 0.0
            for y in 0..<image.height {
                sum += RGBColorSpace.rec2020.luminance(image[x, y])
            }
            esf[x] = sum / Double(image.height)
        }
        let dark = esf[0..<8].reduce(0, +) / 8
        let bright = esf[(w - 8)..<w].reduce(0, +) / 8
        let step = bright - dark

        func crossing(_ level: Double) -> Double {
            guard let idx = esf.firstIndex(where: { $0 >= level }), idx > 0 else {
                return 0
            }
            let a = esf[idx - 1], b = esf[idx]
            return Double(idx - 1) + (level - a) / Swift.max(b - a, 1e-12)
        }
        let rise = crossing(dark + 0.75 * step) - crossing(dark + 0.25 * step)
        return (rise,
                ((esf.max() ?? bright) - bright) / step,
                (dark - (esf.min() ?? dark)) / step)
    }

    func testPrintsTheSharpenBaseline() {
        let sigma = 1.5
        let scene = blurredEdge(sigma: sigma)
        let base = edgeProfile(scene)
        XCTAssertGreaterThan(base.rise, 1.5, "the probe edge carries no blur")

        let node = DetailEngine.Decomposition(image: scene, workingRadius: 3)
        let rows: [(String, ImageBuffer)] = [
            ("manual 100", DetailEngine.applySharpen(
                scene, params: ManualSharpen(amount: 100, radius: sigma),
                decomposition: node)),
            ("capture RL psf 1.5", DetailEngine.captureSharpen(
                scene, CaptureSharpen(auto: true, radius: sigma, amount: 100))),
        ]

        print(String(format: "SHARPBASE blurred input      rise %.2f px",
                     base.rise))
        for (label, image) in rows {
            let p = edgeProfile(image)
            print("SHARPBASE " + label.padding(toLength: 19, withPad: " ",
                                               startingAt: 0)
                  + String(format: "rise %.2f px  recovery x%.2f   "
                           + "overshoot %4.1f%%   undershoot %4.1f%%",
                           p.rise, base.rise / p.rise,
                           p.overshoot * 100, p.undershoot * 100))

            // The claim every row makes: the sharpener SHARPENS the edge it was
            // pointed at, by well more than measurement noise.
            XCTAssertGreaterThan(base.rise / p.rise, 1.1,
                                 "\(label) recovered no edge rise")
        }
    }

    /// DEFECT RECORD (docs/23 audit queue; docs/24-detail gap list) — the measured
    /// truth about `haloSuppression`, found writing §6 and pinned here so the fix
    /// has its failing test pre-written.
    ///
    /// docs/06 §11.3's claim: damp the BRIGHT overshoot ("a rim"), never the edge
    /// definition. The implementation (reference and GPU kernel share it) gates the
    /// damp on the LOCAL usm value, `smoothstep(0.15, 0.60, usm)` — and on a real
    /// edge those two things live at DIFFERENT columns. Measured on a σ1.5-blurred
    /// 5.1 EV edge at radius 1.5, halo 100: the ESF's rim maximum sits 2–3 px onto
    /// the bright plateau where usm has decayed to ~0.148 (below the 0.15 floor) —
    /// untouched. The damp instead lands mid-edge (usm 0.25–0.33), where pulling v
    /// down just DULLS the edge — the exact thing the doc says the asymmetry
    /// exists to avoid. Net: at these settings the slider softens the slope and
    /// delivers zero rim reduction.
    ///
    /// The fix is a designed change (damp against the local plateau — a
    /// local-range clamp — not against usm magnitude), in BOTH paths, with the
    /// constants re-measured. When it lands, the Equal below must flip to
    /// LessThan(damped, free − 0.005): that is the contract this test exists for.
    func testHaloSuppressionCurrentlyMissesTheRimItExistsToDamp() {
        let scene = blurredEdge(dark: 0.02, bright: 0.70)
        let node = DetailEngine.Decomposition(image: scene, workingRadius: 3)
        func sharpened(halo: Double) -> ImageBuffer {
            DetailEngine.applySharpen(
                scene,
                params: ManualSharpen(amount: 100, radius: 1.5,
                                      haloSuppression: halo),
                decomposition: node)
        }
        let free = sharpened(halo: 0)
        let damped = sharpened(halo: 100)
        let freeProfile = edgeProfile(free)
        let dampedProfile = edgeProfile(damped)
        print(String(format: "SHARPBASE hard edge (5.1 EV): overshoot halo0 "
                     + "%4.1f%% -> halo100 %4.1f%%   undershoot %4.1f%% -> %4.1f%%",
                     freeProfile.overshoot * 100, dampedProfile.overshoot * 100,
                     freeProfile.undershoot * 100, dampedProfile.undershoot * 100))

        // The mechanism runs — the parameter is not dead. It moves mid-edge
        // pixels by a visible amount (measured 0.048 linear at full deflection).
        var worstShift = 0.0
        for y in 0..<free.height {
            for x in 0..<free.width {
                worstShift = Swift.max(worstShift,
                                       free[x, y].maxAbsDifference(damped[x, y]))
            }
        }
        XCTAssertGreaterThan(worstShift, 0.01,
                             "halo suppression stopped reaching pixels at all")

        // One true half of the contract: the dark-side undershoot is never touched.
        XCTAssertEqual(dampedProfile.undershoot, freeProfile.undershoot,
                       accuracy: 0.005)

        // THE DEFECT, pinned: the rim maximum survives full suppression. A fix
        // that damps the actual rim BREAKS this line — flip it to
        // XCTAssertLessThan(dampedProfile.overshoot, freeProfile.overshoot - 0.005)
        // and delete this record's defect wording when it does.
        XCTAssertEqual(dampedProfile.overshoot, freeProfile.overshoot,
                       accuracy: 5e-4,
                       "the rim responded to halo suppression — the defect is "
                           + "fixed; promote this test to the contract claim")
    }

    func testPrintsTheDehazeBaseline() {
        let scene = hazyScene()
        let base = groundContrast(scene)
        let baseVeil = topVeilLuminance(scene)
        XCTAssertGreaterThan(base, 0.05, "the probe scene carries no veiled texture")

        for strength in [50.0, 100.0] {
            var detail = Detail()
            detail.dehaze = strength
            let radius = Swift.max(Int(Double(scene.width) * 0.02), 3)
            let node = DetailEngine.Decomposition(image: scene,
                                                  workingRadius: radius)
            let out = DetailEngine.apply(scene, detail: detail, decomposition: node)

            let gain = groundContrast(out) / base
            let veil = topVeilLuminance(out) / baseVeil
            var negatives = 0
            for y in 0..<out.height {
                for x in 0..<out.width where out[x, y].minComponent < -1e-6 {
                    negatives += 1
                }
            }
            print(String(format:
                "HAZEBASE Lumen strength %3.0f: ground contrast x%.2f   "
                + "far-veil luminance x%.2f   negative pixels %d",
                strength, gain, veil, negatives))

            // The claims: dehaze RECOVERS (contrast up, monotone with strength is
            // read off the print), and the He-et-al construction cannot push a
            // recovered pixel negative — the defect class the per-channel
            // normalisation fix closed.
            XCTAssertGreaterThan(gain, 1.05,
                                 "dehaze \(strength) recovered no ground contrast")
            XCTAssertEqual(negatives, 0,
                           "dehaze \(strength) pushed \(negatives) pixels negative")
        }
    }
}
