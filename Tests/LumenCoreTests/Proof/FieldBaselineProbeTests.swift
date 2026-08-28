// FieldBaselineProbeTests.swift
//
// The Lumen columns for docs/26 §4–5 (P6 baselines, docs/23 M2): the SAME two
// experiments `scripts/baselines/crosscheck.py` runs against RawTherapee 5.10 and
// darktable 4.6, printed as TONEBASE and HAZEBASE lines on every Linux lane run so
// the numbers in the document stay re-measurable on both sides of the comparison.
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
