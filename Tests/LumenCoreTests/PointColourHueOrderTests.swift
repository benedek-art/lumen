// PointColourHueOrderTests.swift
// A Point Colour Hue shift never reverses the order of hues round the wheel.
//
// It did, from about 21° of shift at the default Range. The swatch rotates a pixel's hue
// by `weight · shift`, and the weight falls off with hue distance through a smoothstep
// whose steepest slope is 3 per unit of normalized distance — 3/(180·σH) per degree. So
// along the hue line the map is `Δh ↦ Δh + w(Δh)·shift`, and its slope
// `1 − 3·shift/(180·σH)` goes NEGATIVE once |shift| > 60·σH: 15° of shift at Range 0,
// 21° at Range 50, 28° at Range 100, against a slider that runs to 60°. Past that, a
// pixel in the falloff band is pushed further round than a pixel nearer the swatch that
// started ahead of it. Measured at +60° and the default Range: a 31° reversal, about
// 40–60° from the sampled colour — a smooth sky or skin gradient arrives with a band
// running the wrong way through it.
//
// The selection sigmas are right for selection (`PointColourSelectionTests`); the defect
// is that the HUE ROTATION shared their falloff. The fix gives the rotation alone a
// falloff wide enough for the shift it carries.

import XCTest
@testable import LumenCore

final class PointColourHueOrderTests: XCTestCase {

    private let space = OKLabTransform.working

    /// Walks the whole wheel at fixed L and C in quarter-degree steps and returns how
    /// far the output hue, unwrapped against the input, ever falls behind the furthest
    /// it has already reached — how many degrees of later input were overtaken. Zero
    /// when the order is kept.
    private func worstReversal(apply: (RGB) -> RGB) -> (reversal: Double, at: Double) {
        var reached = -Double.infinity
        var worst = (reversal: 0.0, at: 0.0)
        var h = 0.0
        while h <= 360 {
            let input = space.toRGB(OKLCh(L: 0.60, C: 0.10, h: h))
            let output = space.toLCh(apply(input))
            let unwrapped = h + Num.hueDelta(h, output.h)
            if reached - unwrapped > worst.reversal { worst = (reached - unwrapped, h) }
            reached = Swift.max(reached, unwrapped)
            h += 0.25
        }
        return worst
    }

    private func engine(range: Double, shift: Double) -> ColorEngine {
        let sample = space.toRGB(OKLCh(L: 0.60, C: 0.10, h: 60))
        let swatch = PointColor(sample: [sample.r, sample.g, sample.b], range: range,
                                variance: 0, shift: HSLShift(h: shift, s: 0, l: 0))
        return ColorEngine(mixer: Mixer(), pointColors: [swatch], color: ColorAdjust(),
                           primaries: Primaries(), bw: nil, bandMeanHues: nil)
    }

    /// THE DEFECT. Every Range, both directions, the full slider travel: walking round
    /// the wheel must never walk the output backwards.
    func testAPointHueShiftNeverReversesTheOrderOfHues() {
        for range in [0.0, 50, 100] {
            for shift in [-60.0, -30, 30, 60] {
                let e = engine(range: range, shift: shift)
                let worst = worstReversal {
                    e.apply($0, localMean: $0)
                }
                XCTAssertLessThan(worst.reversal, 1e-6,
                                  "Range \(range), Hue \(shift)°: the output hue ran "
                                  + "\(worst.reversal)° backwards near input hue "
                                  + "\(worst.at)° — a pixel further from the swatch "
                                  + "overtook one nearer it")
            }
        }
    }

    /// The GPU's Swift twin carries the same rotation, so it must keep the order too
    /// (the twin-vs-engine gate in `ExactColorStageTests` holds them to each other).
    func testTheExactStageTwinKeepsTheOrderOfHuesToo() {
        for range in [0.0, 50, 100] {
            let stage = engine(range: range, shift: 60).exactStage
            let worst = worstReversal { stage.apply($0) }
            XCTAssertLessThan(worst.reversal, 1e-3,
                              "exact stage, Range \(range): \(worst.reversal)° backwards "
                              + "near \(worst.at)°")
        }
    }

    // MARK: - What must NOT change

    /// The slider still means what it says: the sampled colour turns by the full shift.
    func testTheSampledColourStillTurnsByTheWholeShift() {
        for range in [0.0, 50, 100] {
            for shift in [-60.0, 60] {
                let e = engine(range: range, shift: shift)
                let sample = space.toRGB(OKLCh(L: 0.60, C: 0.10, h: 60))
                let turned = Num.hueDelta(60, space.toLCh(e.apply(sample, localMean: sample)).h)
                XCTAssertEqual(turned, shift, accuracy: 1e-6, "Range \(range)")
            }
        }
    }

    /// A shift small enough not to fold renders exactly as it always did: the wider
    /// falloff is spent only where the shift needs it.
    func testAShiftThatCouldNotFoldKeepsItsOriginalFalloff() {
        // Range 50: σH = 0.46·0.775, so 60·σH ≈ 21.4°. A 15° shift is inside it, and a
        // pixel 45° away sits in the selection's own falloff band.
        let e = engine(range: 50, shift: 15)
        let sigmaH = ColorEngine.pointSigmaH
            * (ColorEngine.pointRangeBase + (1 - ColorEngine.pointRangeBase) * 0.5)
        let d = 45.0 / (180 * sigmaH)
        let expected = 15 * (1 - Num.smoothstep(0.5, 1.0, d))
        let pixel = space.toRGB(OKLCh(L: 0.60, C: 0.10, h: 105))
        let turned = Num.hueDelta(105, space.toLCh(e.apply(pixel, localMean: pixel)).h)
        XCTAssertEqual(turned, expected, accuracy: 1e-6)
    }

    /// The rotation's wider reach is the hue rotation's alone: Saturation and Luminance
    /// keep the selection's own falloff, so a colour ninety degrees away is still not
    /// SELECTED even while a big hue shift is live on the same swatch.
    func testAWideHueShiftDoesNotWidenTheSelectionForSaturationAndLuminance() {
        let sample = space.toRGB(OKLCh(L: 0.60, C: 0.10, h: 60))
        let swatch = PointColor(sample: [sample.r, sample.g, sample.b], range: 50,
                                variance: 0, shift: HSLShift(h: 60, s: 0, l: -100))
        let e = ColorEngine(mixer: Mixer(), pointColors: [swatch], color: ColorAdjust(),
                            primaries: Primaries(), bw: nil, bandMeanHues: nil)
        let far = space.toRGB(OKLCh(L: 0.60, C: 0.10, h: 150))
        let drop = space.toLCh(far).L - space.toLCh(e.apply(far, localMean: far)).L
        XCTAssertEqual(drop, 0, accuracy: 1e-9)
    }
}
