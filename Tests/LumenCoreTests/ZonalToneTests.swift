// ZonalToneTests.swift
// WS-05's acceptance lines (docs/quality/lanes/WS-05/SPEC.md) held at engine level,
// without renders: what Shadows +100 does to the black point (S1/S5), where Whites puts
// the white clip point and how far down it reaches (W2/W4), that Highlights still
// recovers two stops (R1), that no tone slider re-hues a colour it did not ask to (H6),
// and that zero is still an exact identity (M3).

import XCTest
@testable import LumenCore

final class ZonalToneTests: XCTestCase {

    // MARK: - Helpers

    /// sRGB code value (0…255) of a display-linear value, the way the PNGs encode it.
    private func code(_ y: Double) -> Double {
        let v = y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
        return Num.saturate(v) * 255
    }

    /// Neutral scene tone `t` (EV from mid-grey) through a recipe's own display transform.
    private func rendered(_ t: Double, _ recipe: Recipe = Recipe()) -> Double {
        let transform = DisplayTransform.forRecipe(recipe)
        return code(transform.tone(0.18 * pow(2, t)) / transform.white)
    }

    private func oklabHue(_ c: RGB) -> (C: Double, h: Double) {
        let l = cbrt(0.4122214708 * c.r + 0.5363325363 * c.g + 0.0514459929 * c.b)
        let m = cbrt(0.2119034982 * c.r + 0.6806995451 * c.g + 0.1073969566 * c.b)
        let s = cbrt(0.0883024619 * c.r + 0.2817188376 * c.g + 0.6299787005 * c.b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(b, a) * 180 / .pi
        if h < 0 { h += 360 }
        return (hypot(a, b), h)
    }

    // MARK: - S1 / S5: Shadows opens the quarter tones and leaves the black point to Blacks

    func testShadowsLiftsTheQuarterTonesAndNotTheBlackPoint() {
        let shadows = ToneEngine(tone: Tone(shadows: 100))
        let blacks = ToneEngine(tone: Tone(blacks: 100))
        // At contrast 0 a single slider is applied exactly.
        XCTAssertEqual(shadows.effectiveShadows, 1, accuracy: 1e-12)
        // It still opens the quarter tones: more than a stop at −2.5 … −3 EV.
        XCTAssertGreaterThan(shadows.stops(at: -3), 1.2)
        XCTAssertGreaterThan(shadows.stops(at: -2.5), 1.2)
        XCTAssertGreaterThan(shadows.stops(at: -2), 0.85)
        // The 1st percentile of a real frame sits near −4 EV; the lift there is a small
        // fraction of the quarter tones', which is what keeps the black point (S1).
        XCTAssertLessThan(shadows.stops(at: -4), 0.25 * shadows.stops(at: -2.5),
                          "Shadows +100 lifts the black point")
        // Zone 0 is Blacks': below −5 EV Blacks +100 moves more than Shadows +100 (S5).
        for t in [-5.0, -6.0, -7.0] {
            XCTAssertLessThan(shadows.stops(at: t), blacks.stops(at: t),
                              "Shadows out-lifts Blacks at \(t) EV")
            XCTAssertLessThan(shadows.stops(at: t), 0.1)
        }
        // And a deep tone still renders near black: −6 EV at most 4 codes (S5).
        let deep = rendered(-6 + shadows.stops(at: -6))
        XCTAssertLessThanOrEqual(deep, 4)
    }

    /// Shadows −100 is the old shelf: darkening deep tones further is harmless, and the
    /// taper is there for one direction only.
    func testShadowsDarkensWithTheShelfAndLiftsWithTheBump() {
        let down = ToneEngine(tone: Tone(shadows: -100))
        XCTAssertEqual(down.stops(at: -6), -ToneEngine.highlightShadowRangeEV, accuracy: 1e-9)
        XCTAssertEqual(down.stops(at: 0), 0, accuracy: 1e-12)
        let up = ToneEngine(tone: Tone(shadows: 100))
        XCTAssertEqual(up.stops(at: 0), 0, accuracy: 1e-12)
        // It peaks in the quarter tones and is nearly gone below the taper.
        XCTAssertGreaterThan(up.shadowLiftWeight(up.blackAnchorEV * ToneEngine.shadowTaperStart),
                             0.95)
        XCTAssertLessThan(up.shadowLiftWeight(up.blackAnchorEV * ToneEngine.shadowTaperEnd),
                          0.06)
    }

    // MARK: - W2 / W4: Whites moves the white clip point, by gain, at the top only

    func testWhitesMovesTheWhiteClipPointByGain() {
        let c0 = ToneEngine.defaultWhiteAnchorEV
        let up = ToneEngine(tone: Tone(whites: 100))
        let down = ToneEngine(tone: Tone(whites: -100))
        // The display anchor stays put; the clip point moves through the gain.
        XCTAssertEqual(up.whiteAnchorEV, c0)
        XCTAssertEqual(down.whiteAnchorEV, c0)
        XCTAssertEqual(up.effectiveWhites, 1, accuracy: 1e-12)
        XCTAssertEqual(down.effectiveWhites, -1, accuracy: 1e-12,
                       "a single Whites move is eased at Contrast 0")
        // +100 clips somewhere between 1.5 and 0.5 stops under the default clip point.
        XCTAssertLessThanOrEqual(c0 - 1.5 + up.stops(at: c0 - 1.5), c0,
                                 "Whites +100 clips more than 1.5 stops of headroom")
        XCTAssertGreaterThanOrEqual(c0 - 0.5 + up.stops(at: c0 - 0.5), c0,
                                    "Whites +100 does not move the clip point half a stop")
        // −100 carries tones nearly a stop over the anchor back under it.
        XCTAssertLessThan(c0 + 0.9 + down.stops(at: c0 + 0.9), c0)
        // It stays out of Highlights' territory: up to +1.3 EV (zone 6/7 on the grey
        // ramp) Whites +100 gains no more than Highlights +100, and nothing at all below
        // its shelf.
        let highlights = ToneEngine(tone: Tone(highlights: 100))
        for t in stride(from: 0.0, through: 1.3, by: 0.05) {
            XCTAssertLessThanOrEqual(up.stops(at: t), highlights.stops(at: t) + 1e-12,
                                     "Whites out-gains Highlights at \(t) EV")
        }
        XCTAssertEqual(up.stops(at: c0 - ToneEngine.whiteShelfStartBelowAnchorEV), 0,
                       accuracy: 1e-12)
        // Linear in the slider in stops (W1): +50 is exactly half of +100.
        let half = ToneEngine(tone: Tone(whites: 50))
        for t in [1.0, 1.5, 2.0, 2.5] {
            XCTAssertEqual(half.stops(at: t), 0.5 * up.stops(at: t), accuracy: 1e-12)
        }
    }

    /// Highlights −100 still recovers two stops past the default clip point (R1), with
    /// its 0 … +5 EV shelf.
    func testHighlightsStillRecoversTwoStopsPastWhite() {
        let c0 = ToneEngine.defaultWhiteAnchorEV
        let down = ToneEngine(tone: Tone(highlights: -100))
        XCTAssertEqual(down.effectiveHighlights, -1, accuracy: 1e-12)
        XCTAssertEqual(c0 + 2 + down.stops(at: c0 + 2), c0, accuracy: 1e-9)
        XCTAssertEqual(down.highlightWeight(5), 1, accuracy: 1e-12)
        XCTAssertEqual(down.highlightWeight(0), 0, accuracy: 1e-12)
    }

    // MARK: - H6: no slider adds hue drift beyond the display transform

    /// S7 multiplies RGB by a scalar gain, so a uniform patch at slider value v must
    /// render exactly as the default recipe renders the same colour times that gain —
    /// an exposure move of equal luminance. Whites used to fail this by 14° on
    /// rec709 blue: it moved the white anchor, and the transform's path-to-white blend
    /// is normalised by the anchor.
    func testNoToneSliderAddsHueDriftBeyondTheDisplayTransform() {
        let blues: [(Double, Double, Double)] = [(90, 140, 200), (40, 90, 190), (140, 180, 225),
                                                 (30, 120, 220), (20, 30, 255), (100, 190, 235)]
        let from709 = RGBColorSpace.srgb.matrix(to: .rec2020)
        let to709 = RGBColorSpace.rec2020.matrix(to: .srgb)
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func display(_ c: RGB) -> RGB {
            let o = to709.apply(c)
            return RGB(Num.saturate(o.r), Num.saturate(o.g), Num.saturate(o.b))
        }
        let base = RenderPlan(recipe: Recipe(), lutSize: 17)
        let paths: [WritableKeyPath<Tone, Double>] = [\.highlights, \.shadows, \.whites, \.blacks]
        for path in paths {
            for value in [-100.0, -50, 50, 100] {
                var recipe = Recipe()
                recipe.develop.tone[keyPath: path] = value
                let plan = RenderPlan(recipe: recipe, lutSize: 17)
                var worst = 0.0
                for (r, g, b) in blues {
                    let colour = from709.apply(RGB(lin(r / 255), lin(g / 255), lin(b / 255)))
                    let y = RGBColorSpace.rec2020.luminance(colour)
                    for ev in stride(from: -2.0, through: 3.5, by: 0.5) {
                        let s = colour * (0.18 * pow(2, ev) / y)
                        let gain = plan.toneStageGain(plan.linear.apply(s), space: .rec2020)
                        let a = oklabHue(display(plan.exactColor(s)))
                        let d = oklabHue(display(base.exactColor(s * gain)))
                        guard a.C >= 0.03, d.C >= 0.03 else { continue }
                        var dh = abs(a.h - d.h)
                        if dh > 180 { dh = 360 - dh }
                        worst = Swift.max(worst, dh)
                    }
                }
                XCTAssertLessThanOrEqual(worst, 0.5, "\(path) \(value) adds \(worst)° of hue")
            }
        }
        // And, in particular, Whites leaves the transform itself alone.
        for whites in [-100.0, 100] {
            var recipe = Recipe()
            recipe.develop.tone.whites = whites
            XCTAssertEqual(DisplayTransform.forRecipe(recipe).params,
                           DisplayTransform.forRecipe(Recipe()).params,
                           "Whites \(whites) changed the display transform")
        }
    }

    // MARK: - M3: zero is an exact identity

    func testZeroIsAnExactIdentityAndAnyOneSliderIsNot() {
        let anchors = ToneEngine.anchors(for: Tone())
        XCTAssertEqual(anchors.white, ToneEngine.defaultWhiteAnchorEV)
        XCTAssertEqual(anchors.black, -9)
        XCTAssertTrue(ToneEngine(tone: Tone()).isIdentity)
        XCTAssertTrue(RenderPlan(recipe: Recipe(), lutSize: 17).toneIsIdentity)
        let paths: [WritableKeyPath<Tone, Double>] = [\.highlights, \.shadows, \.whites, \.blacks]
        for path in paths {
            for value in [-1.0, 1.0] {
                var tone = Tone()
                tone[keyPath: path] = value
                XCTAssertFalse(ToneEngine(tone: tone).isIdentity, "\(path) \(value)")
            }
        }
    }

    /// The limiter's promise, kept through the reshaping: one of the four sliders at
    /// either end, with Contrast at 0, is applied exactly — never scaled.
    func testASingleZonalSliderIsNeverScaledAtContrastZero() {
        for value in [-100.0, 100] {
            XCTAssertEqual(ToneEngine(tone: Tone(highlights: value)).zonalScale, 1, accuracy: 1e-12)
            XCTAssertEqual(ToneEngine(tone: Tone(shadows: value)).zonalScale, 1, accuracy: 1e-12)
            XCTAssertEqual(ToneEngine(tone: Tone(whites: value)).zonalScale, 1, accuracy: 1e-12)
            XCTAssertEqual(ToneEngine(tone: Tone(blacks: value)).zonalScale, 1, accuracy: 1e-12)
        }
    }
}
