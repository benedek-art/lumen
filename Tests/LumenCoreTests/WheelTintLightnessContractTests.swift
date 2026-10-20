// B2-03 — what a grading wheel's tint holds constant.
//
// The GradeEngine header said a tint is a "CONSTANT-LUMINANCE" offset that "carries no
// luminance contamination", and docs/05 §D15 said the same. The code translates the
// OKLab (a, b) pair and leaves OKLab L alone, which holds perceptual LIGHTNESS, not CIE
// luminance Y: OKLab L is a cube-root predictor of a weighted LMS mix, and moving a and
// b changes that mix. Measured at full deflection (sat = 1, an ab offset of 0.15) in the
// Rec.2020 working context, a tint moves a mid-grey's Y by roughly −10 % (red, 0°) to
// +10 % (teal, 180°), and a −3 EV shadow's by −21 % to +22 %, which is enough to push a
// channel below zero.
//
// Holding lightness is a defensible grading model: holding Y exactly would make a tinted
// grey look brighter than its neighbours (Helmholtz–Kohlrausch). Whether to restore Y or
// H-K brightness, or to scale the offset by L the way darktable does, is the owner's open
// DECISION 2 (docs/audit-2026-10/streams/P13-sweepB.md), because either one moves every
// saved wheel look. Until then the comments say what the code does, and this file pins
// both halves so the words and the code cannot come apart again: L is held to rounding,
// and Y is NOT held. If the second test starts failing, someone moved pixels, and the
// header, docs/05 §D15 and this note have to change with it.
import XCTest
@testable import LumenCore

final class WheelTintLightnessContractTests: XCTestCase {

    private func engine(hue: Double) -> GradeEngine {
        var wheels = GradingWheels()
        // The global wheel, so the zone crossfade does not scale the offset: the
        // measurement is of the tint itself at full deflection.
        wheels.global = Wheel(hue: hue, sat: 1, lum: 0)
        return GradeEngine(wheels: wheels, printerLights: PrinterLights())
    }

    private func luminance(_ c: RGB) -> Double {
        let w = GradeEngine.workingLuminanceWeights
        return w.r * c.r + w.g * c.g + w.b * c.b
    }

    /// The contract the header now states: a wheel tint holds OKLab L exactly, at every
    /// hue, from deep shadow to above mid-grey, and it really does add the chroma.
    func testAWheelTintHoldsOKLabLightnessAtEveryHue() {
        for grey in [0.02, 0.18, 0.72] {
            let input = RGB(gray: grey)
            let lIn = OKLabTransform.working.toLCh(input).L
            for hue in stride(from: 0.0, to: 360.0, by: 15) {
                let out = engine(hue: hue).apply(input)
                let lch = OKLabTransform.working.toLCh(out)
                XCTAssertEqual(lch.L, lIn, accuracy: 1e-9,
                               "grey \(grey), hue \(hue)°: the tint moved OKLab L from "
                                   + "\(lIn) to \(lch.L)")
                XCTAssertEqual(lch.C, GradeEngine.maxABOffset, accuracy: 1e-6,
                               "grey \(grey), hue \(hue)°: the tint did not add its chroma")
            }
        }
    }

    /// The consequence the old header denied: constant lightness is not constant
    /// luminance. Bounds are loose on purpose (measured ≈ 0.90 / 1.10 at mid-grey and
    /// ≈ 0.79 / 1.22 at 0.02), so they pin the direction and the order of magnitude,
    /// not a number an H-K or OKLab recalibration would nudge.
    func testAWheelTintDoesNotHoldSceneLuminance() {
        let mid = RGB(gray: 0.18)
        let yMid = luminance(mid)
        let redRatio = luminance(engine(hue: 0).apply(mid)) / yMid
        let tealRatio = luminance(engine(hue: 180).apply(mid)) / yMid
        XCTAssertLessThan(redRatio, 0.95,
                          "a full red tint on mid-grey kept Y within 5 % (\(redRatio)): if "
                              + "the tint now holds luminance, rewrite the GradeEngine header "
                              + "and docs/05 §D15 to say so")
        XCTAssertGreaterThan(tealRatio, 1.05,
                             "a full teal tint on mid-grey kept Y within 5 % (\(tealRatio))")

        let shadow = RGB(gray: 0.02)
        let tealShadow = luminance(engine(hue: 180).apply(shadow)) / luminance(shadow)
        XCTAssertGreaterThan(tealShadow, 1.15,
                             "a full teal tint at −3 EV brightened Y by only \(tealShadow)")
    }
}
