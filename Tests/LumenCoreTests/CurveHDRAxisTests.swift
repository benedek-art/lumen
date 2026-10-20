// CurveHDRAxisTests.swift
// The tone curve's axis on an HDR rendition (docs/14 §2.2 item 3, §7).
//
// The display transform keeps mid-grey at 0.18 in ABSOLUTE display-linear terms at
// every peak — HDR is SDR with the highlights let out, not SDR multiplied by the peak
// (`EngineTests.testHDRPeakRaisesWhiteButNotMidGrey`). The curve used to divide by the
// display peak before encoding, which only means "the same curve" if HDR were SDR × peak.
// It is not, so at a 400 % peak mid-grey entered the curve at encoded 0.235 instead of
// 0.461: Shadows +60 lifted mid-grey half a stop in HDR and not at all in SDR, an S-curve
// darkened it 0.65 EV instead of 0.08, and the two renditions of one gain-map export
// carried two different grades. These pin the absolute axis: SDR white is encoded 1 at
// every peak, and the headroom above it rides a unit-slope extension of the curve.
// The mask's curve, which runs through the same `apply`, is pinned beside its siblings:
// `MaskingTests.testLocalCurveReadsTheSameAbsoluteAxisAtEveryDisplayWhite`.

import XCTest
@testable import LumenCore

final class CurveHDRAxisTests: XCTestCase {

    private func shadowsLift() -> CurveSet {
        CurveSet(parametric: ParametricCurve(shadows: 60))
    }

    private func sCurve() -> CurveSet {
        CurveSet(point: [[0, 0], [0.25, 0.2], [0.75, 0.8], [1, 1]])
    }

    /// The headline: whatever the display peak, a curve does the same thing to every
    /// tone at or below SDR white — the tones the display transform itself leaves
    /// alone when the peak rises.
    func testACurveTreatsMidGreyAlikeAtEveryDisplayPeak() {
        let probes = [RGB(gray: 0.18), RGB(0.30, 0.12, 0.05), RGB(gray: 0.8),
                      RGB(gray: 0.02)]
        for (name, set) in [("Shadows +60", shadowsLift()), ("S-curve", sCurve()),
                            ("per-channel", CurveSet(r: [[0, 0], [0.5, 0.6], [1, 1]],
                                                     preserveLuminance: false))] {
            let stack = CurveStack(set)
            for c in probes {
                let sdr = stack.apply(c, white: 1)
                for white in [2.0, 4.0] {
                    let hdr = stack.apply(c, white: white)
                    for k in 0..<3 {
                        XCTAssertEqual(hdr[k], sdr[k], accuracy: 1e-9,
                                       "\(name) on \(c) at peak \(white): channel \(k) "
                                           + "is \(hdr[k]) in HDR but \(sdr[k]) in SDR "
                                           + "— the curve's axis moved with the peak")
                    }
                }
            }
        }
    }

    /// The same contract end to end, through the plan the renderers use: scene
    /// mid-grey through a recipe with a curve renders the same at 100 % and 400 %.
    func testAnHDRPlanGradesMidGreyAsTheSDRPlanDoes() {
        var recipe = Recipe()
        let grey = RGB(gray: 0.18)
        let plainSDR = RenderPlan(recipe: recipe, displayWhiteTarget: 100).exactColor(grey)
        let plainHDR = RenderPlan(recipe: recipe, displayWhiteTarget: 400).exactColor(grey)
        // Premise: the display transform alone agrees on mid-grey at both peaks.
        XCTAssertEqual(plainHDR.g, plainSDR.g, accuracy: 1e-6,
                       "premise: the display transform moved mid-grey with the peak")

        recipe.develop.curve = shadowsLift()
        let sdr = RenderPlan(recipe: recipe, displayWhiteTarget: 100).exactColor(grey)
        let hdr = RenderPlan(recipe: recipe, displayWhiteTarget: 400).exactColor(grey)
        XCTAssertEqual(hdr.g, sdr.g, accuracy: 1e-6,
                       "Shadows +60 renders mid-grey \(hdr.g) on the HDR rendition and "
                           + "\(sdr.g) on the SDR one")
    }

    /// Above SDR white the curve is extended at unit slope from its value at 1, so a
    /// curve that pins white leaves HDR highlights exactly where the display transform
    /// put them, a curve that lowers white lowers them by the same encoded amount with
    /// no step at 1, and nothing leaves the display's peak.
    func testHDRHighlightsRideAUnitSlopeExtensionAboveSDRWhite() {
        let pinned = CurveStack(sCurve())
        for v in [1.5, 2.0, 3.9] {
            XCTAssertEqual(pinned.apply(RGB(gray: v), white: 4).g, v, accuracy: 1e-9,
                           "a curve pinned at white moved an HDR highlight at \(v)")
        }
        XCTAssertLessThanOrEqual(pinned.apply(RGB(gray: 10), white: 4).g, 4 + 1e-9,
                                 "the curve pushed a highlight past the display peak")

        let lowered = CurveStack(CurveSet(point: [[0, 0], [1, 0.9]]))
        let below = lowered.apply(RGB(gray: 1 - 1e-7), white: 4).g
        let above = lowered.apply(RGB(gray: 1 + 1e-7), white: 4).g
        XCTAssertLessThan(abs(above - below), 1e-5,
                          "a lowered white point steps at SDR white: \(below) → \(above)")
        var previous = -Double.infinity
        for i in 0...400 {
            let v = Double(i) / 100
            let out = lowered.apply(RGB(gray: v), white: 4).g
            XCTAssertGreaterThanOrEqual(out, previous - 1e-12,
                                        "the extended curve inverts at \(v)")
            previous = out
        }
    }

    /// The SDR rendition is the one every saved look was graded on; the new axis must
    /// not move it. At white 1 the extension is unreachable, so the curve is evaluated
    /// on exactly the clamped [0, 1] axis it always was.
    func testTheSDRRenditionIsTheCurveItAlwaysWas() {
        let stack = CurveStack(sCurve())
        let enc = TransferFunction.srgb
        for c in [RGB(gray: 0.18), RGB(0.9, 0.4, 0.1), RGB(gray: 1.6)] {
            let clamped = c.clamped(0, 1)
            let lum = Num.saturate(RGBColorSpace.rec2020.luminance(enc.encode(clamped)))
            let e = enc.encode(clamped)
            let expected = enc.decode((e * (stack.master(lum) / lum)).clamped(0, 1))
            let got = stack.apply(c, white: 1)
            for k in 0..<3 {
                XCTAssertEqual(got[k], expected[k], accuracy: 1e-15,
                               "the SDR curve moved on \(c), channel \(k)")
            }
        }
    }
}
