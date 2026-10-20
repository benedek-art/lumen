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
// longer reach for the shift it carries — on the hue term only, and only on the side the
// shift turns toward, which is the only side that can fold (`ColorEngine.applySwatch`).

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

    // MARK: - The wider reach is along hue, ahead of the swatch, and nowhere else

    /// A big Hue turn must not reach pixels the swatch never selected on LIGHTNESS or
    /// CHROMA. The first version of this fix widened the edge on the whole L/C/H
    /// distance, so turning mid-tone skin +60° also turned dark hair and saturated
    /// clothing of the very same hue by about 30° — pixels Saturation and Luminance
    /// still (rightly) treated as unselected. Same hue as the sample and 1.2 sigmas off
    /// on L or on C is outside the selection, and must come back untouched — on the
    /// engine and on the exact stage's twin.
    func testABigHueShiftDoesNotReachColoursOutsideTheSelectionOnLightnessOrChroma() {
        let scale = ColorEngine.pointRangeBase + (1 - ColorEngine.pointRangeBase) * 0.5
        let sigmaL = ColorEngine.pointSigmaL * scale
        let sigmaC = ColorEngine.pointSigmaC * scale
        let pixels = [
            ("darker", OKLCh(L: 0.60 - 1.2 * sigmaL, C: 0.10, h: 60)),
            ("more chromatic", OKLCh(L: 0.60, C: 0.10 + 1.2 * sigmaC, h: 60)),
            // Ahead of the swatch along hue too, where the rotation's reach IS longer:
            // that reach must still stop at the selection's own L and C edges.
            ("more chromatic, 10° ahead", OKLCh(L: 0.60, C: 0.10 + 1.2 * sigmaC, h: 70)),
            ("more chromatic, 10° behind", OKLCh(L: 0.60, C: 0.10 + 1.2 * sigmaC, h: 50)),
        ]
        for shift in [-60.0, 60] {
            let e = engine(range: 50, shift: shift)
            let stage = e.exactStage
            for (name, lch) in pixels {
                let pixel = space.toRGB(lch)
                let out = e.apply(pixel, localMean: pixel)
                let turned = Num.hueDelta(lch.h, space.toLCh(out).h)
                XCTAssertEqual(turned, 0, accuracy: 1e-9,
                               "Hue \(shift)°: a \(name) colour the swatch does not "
                               + "select turned \(turned)°")
                let twin = Num.hueDelta(lch.h, space.toLCh(stage.apply(pixel)).h)
                XCTAssertEqual(twin, 0, accuracy: 1e-3,
                               "exact stage, Hue \(shift)°, \(name): turned \(twin)°")
            }
        }
    }

    /// Behind the swatch — on the side the shift turns AWAY from — the rotation cannot
    /// fold (the weight rises toward the swatch, so the map's slope only grows), and so
    /// it keeps the selection's own falloff at every shift. This is what leaves Range in
    /// charge of how far a big turn reaches: stretching this side too made every +40°
    /// turn claim the same width whatever the Range, and Range's authority on the
    /// colour chart fell from 56 to 16 code values (`ControlProofTests`).
    func testBehindTheSwatchABigShiftKeepsTheSelectionsOwnFalloff() {
        for range in [0.0, 50, 100] {
            let sigmaH = ColorEngine.pointSigmaH
                * (ColorEngine.pointRangeBase + (1 - ColorEngine.pointRangeBase) * range / 100)
            for shift in [-60.0, 60] {
                let e = engine(range: range, shift: shift)
                // 0.7 of the selection's hue radius, on the trailing side.
                let behind = 60 - (shift > 0 ? 1 : -1) * 0.7 * 180 * sigmaH
                let expected = shift * (1 - Num.smoothstep(0.5, 1.0, 0.7))
                let pixel = space.toRGB(OKLCh(L: 0.60, C: 0.10, h: behind))
                let turned = Num.hueDelta(behind, space.toLCh(e.apply(pixel, localMean: pixel)).h)
                XCTAssertEqual(turned, expected, accuracy: 1e-6,
                               "Range \(range), Hue \(shift)°")
            }
        }
    }

    /// The longer reach ahead of the swatch stops at the opposite hue. Holding the
    /// steepest slope to 0.98 alone would carry a 60° turn 184° round, past the
    /// antipode, where it would meet the trailing side's zero in a seam of about a
    /// quarter of a degree. So the colour opposite the swatch is left where it is, on
    /// both sides of it.
    func testTheReachAheadStopsAtTheOppositeHue() {
        for range in [0.0, 50, 100] {
            for shift in [-60.0, 60] {
                let e = engine(range: range, shift: shift)
                for h in [239.75, 240.25] {
                    let pixel = space.toRGB(OKLCh(L: 0.60, C: 0.10, h: h))
                    let turned = Num.hueDelta(h, space.toLCh(e.apply(pixel, localMean: pixel)).h)
                    XCTAssertLessThan(abs(turned), 0.01,
                                      "Range \(range), Hue \(shift)°: the colour at \(h)°, "
                                      + "opposite the swatch, turned \(turned)°")
                }
            }
        }
    }
}
