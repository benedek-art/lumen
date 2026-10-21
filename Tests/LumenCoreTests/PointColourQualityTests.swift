// PointColourQualityTests.swift
// WS-32 (quality lane K3): what a Lightroom user expects of Point Colour, measured.
//
// Three defects, each found by rendering real frames at 100% (docs/quality/lanes/WS-32):
//
//  1. A soft edge was cut, not followed. A defocused petal blending into a plate is a
//     MIXTURE of the swatch's colour and a neutral; the selection held 1.0 down to an
//     85% mix and was zero by 40%, so Saturation −100 left a saturated ring round every
//     petal on frame 2062 and Luminance −80 cut each one out with a jagged edge. On
//     2348 the satin sheen of the red stripe (a lighter tint of the same red) fell out
//     of the selection and stayed pink inside the darkened stripe.
//  2. Variance −100 halved lightness detail: on the flat path it converged L at half
//     weight toward the sample, and pore texture fell to 0.50 of itself.
//  3. One master Range and nothing else. Lightroom refines it per axis.

import XCTest
@testable import LumenCore

final class PointColourQualityTests: XCTestCase {

    private let space = OKLabTransform.working

    private func rgb(_ L: Double, _ C: Double, _ h: Double) -> RGB {
        space.toRGB(OKLCh(L: L, C: C, h: h))
    }

    private func engine(_ swatches: [PointColor]) -> ColorEngine {
        ColorEngine(mixer: Mixer(), pointColors: swatches, color: ColorAdjust(),
                    primaries: Primaries(), bw: nil, bandMeanHues: nil)
    }

    private func swatch(_ c: RGB, range: Double = 50, variance: Double = 0,
                        shift: HSLShift = HSLShift(l: -100),
                        hue: Double? = nil, sat: Double? = nil,
                        lum: Double? = nil) -> PointColor {
        PointColor(sample: [c.r, c.g, c.b], range: range, variance: variance, shift: shift,
                   hueRange: hue, satRange: sat, lumRange: lum)
    }

    /// Linear-light mixture: `alpha` of `a`, the rest `b` — what a defocused edge is.
    private func mix(_ a: RGB, _ b: RGB, _ alpha: Double) -> RGB {
        RGB(a.r * alpha + b.r * (1 - alpha), a.g * alpha + b.g * (1 - alpha),
            a.b * alpha + b.b * (1 - alpha))
    }

    // MARK: - Soft edges follow the photograph's own blend

    /// A red blending into a light neutral: the selection must FADE across the blend,
    /// monotonically, reaching zero only at the neutral itself. Before: 0.000 at a 50%
    /// mix (the cut-off sat between 70% and 80%).
    func testAMixtureWithANeutralFadesAcrossTheBlendInsteadOfBeingCut() {
        let red = rgb(0.55, 0.15, 28)
        let plate = RGB(0.62, 0.62, 0.62)
        let s = swatch(red)
        var previous = 1.0
        var weights: [Double] = []
        for step in stride(from: 1.0, through: 0.0, by: -0.1) {
            let w = ColorEngine.pointSelectionWeight(mix(red, plate, step), of: s)
            weights.append(w)
            XCTAssertLessThanOrEqual(w, previous + 1e-12,
                                     "the weight rose as the mix lost red, at \(step)")
            previous = w
        }
        // Close to the blend fraction itself across the whole edge — the effect fades
        // the way the photograph's own edge does.
        for (k, w) in weights.enumerated() {
            let alpha = 1 - Double(k) * 0.1
            XCTAssertLessThan(abs(w - alpha), 0.35, "at \(alpha): \(weights)")
        }
        let half = ColorEngine.pointSelectionWeight(mix(red, plate, 0.5), of: s)
        XCTAssertGreaterThanOrEqual(half, 0.15, "a 50% blend is cut out: \(weights)")
        XCTAssertEqual(ColorEngine.pointSelectionWeight(plate, of: s), 0,
                       "the neutral itself came along")
    }

    /// The same for a shade (a mixture toward black): the swatch's colour in shadow.
    func testAShadeOfTheSwatchIsPartlySelected() {
        let red = rgb(0.55, 0.15, 28)
        let s = swatch(red)
        let shade = mix(red, RGB(0.01, 0.01, 0.01), 0.5)
        XCTAssertGreaterThan(ColorEngine.pointSelectionWeight(shade, of: s), 0.3)
    }

    /// The mixture reading is only ever MORE inclusive along the swatch's own
    /// tint/shade line, and a neutral is the far end of that line: out at every Range,
    /// and with the Hue refinement wide open. (Saturation and Luminance refinements are
    /// ALLOWED to reach the greys of a low-chroma swatch: widening those tolerances is
    /// what asking for "paler / lighter versions too" means, as in Lightroom.)
    func testANeutralIsNotSelectedAtAnyRangeOrHueRefinement() {
        for sample in [rgb(0.55, 0.15, 28), rgb(0.70, 0.08, 56), rgb(0.60, 0.12, 255)] {
            for (range, refine) in [(0.0, 50.0), (50, 50), (100, 50), (100, 100)] {
                let s = swatch(sample, range: range, hue: refine)
                for L in [0.2, 0.4, 0.6, 0.8] {
                    let w = ColorEngine.pointSelectionWeight(rgb(L, 0, 0), of: s)
                    XCTAssertLessThan(w, 0.05, "grey L \(L) at Range \(range)")
                }
            }
        }
    }

    /// The mixture reading belongs to samples with real chroma. A near-neutral sample
    /// (below the chroma gate) selects exactly as it did before this lane.
    func testANearNeutralSampleKeepsTheAbsoluteDistance() {
        let warmGrey = rgb(0.6, 0.012, 60)
        let s = swatch(warmGrey)
        let paler = rgb(0.6, 0.004, 60)
        // Pure absolute reading: ΔC 0.008 against σC 0.09·0.775 — deep in the plateau.
        XCTAssertEqual(ColorEngine.pointSelectionWeight(paler, of: s), 1, accuracy: 1e-12)
        // Lighter and paler: exactly the absolute distance, no lightness damping.
        let scale = ColorEngine.pointRangeBase + (1 - ColorEngine.pointRangeBase) * 0.5
        let target = space.toLCh(warmGrey)
        let lighterLCh = space.toLCh(rgb(0.6 + 0.7 * ColorEngine.pointSigmaL * scale, 0.004, 60))
        let tL = (lighterLCh.L - target.L) / (ColorEngine.pointSigmaL * scale)
        let tC = (lighterLCh.C - target.C) / (ColorEngine.pointSigmaC * scale)
        let expected = 1 - Num.smoothstep(0.5, 1, (tL * tL + tC * tC).squareRoot())
        XCTAssertEqual(ColorEngine.pointSelectionWeight(space.toRGB(lighterLCh), of: s),
                       expected, accuracy: 1e-9)
    }

    // MARK: - Range refinements

    /// A nil refinement and an explicit 50 are the same swatch, bit for bit.
    func testAnUnsetRefinementIsExactlyTheMasterRange() {
        let sky = rgb(0.60, 0.12, 255)
        let a = engine([swatch(sky)])
        let b = engine([swatch(sky, hue: 50, sat: 50, lum: 50)])
        for c in [rgb(0.6, 0.1, 280), rgb(0.5, 0.08, 240), rgb(0.7, 0.14, 260), sky] {
            XCTAssertEqual(a.apply(c), b.apply(c))
        }
        XCTAssertEqual(PointColor.axisFactor(nil), 1)
        XCTAssertEqual(PointColor.axisFactor(50), 1)
        XCTAssertEqual(PointColor.axisFactor(0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(PointColor.axisFactor(100), 2, accuracy: 1e-12)
    }

    /// Each refinement widens or narrows its own axis and leaves the other two alone.
    func testEachRefinementActsOnItsOwnAxisOnly() {
        let sky = rgb(0.60, 0.12, 255)
        let hueAway = rgb(0.60, 0.12, 300)          // 45° along
        let darker = rgb(0.60 - 0.20, 0.12, 255)    // lightness only
        func w(_ c: RGB, _ s: PointColor) -> Double {
            ColorEngine.pointSelectionWeight(c, of: s)
        }
        let base = swatch(sky)
        XCTAssertGreaterThan(w(hueAway, swatch(sky, hue: 100)), w(hueAway, base) + 0.2)
        XCTAssertLessThan(w(hueAway, swatch(sky, hue: 0)), w(hueAway, base))
        XCTAssertEqual(w(hueAway, swatch(sky, lum: 0)), w(hueAway, base), accuracy: 1e-12)
        XCTAssertEqual(w(hueAway, swatch(sky, lum: 100)), w(hueAway, base), accuracy: 1e-12)
        XCTAssertGreaterThan(w(darker, swatch(sky, lum: 100)), w(darker, base) + 0.2)
        XCTAssertLessThan(w(darker, swatch(sky, lum: 0)), w(darker, base))
        XCTAssertEqual(w(darker, swatch(sky, hue: 100)), w(darker, base), accuracy: 1e-12)
    }

    /// The panel's selection strip reads the same weight the render applies.
    func testTheSelectionWeightIsTheOneTheRenderApplies() {
        let sky = rgb(0.60, 0.12, 255)
        let e = engine([swatch(sky, range: 70, hue: 30, lum: 80)])
        let s = swatch(sky, range: 70, hue: 30, lum: 80)
        func drop(_ c: RGB) -> Double { space.toLCh(c).L - space.toLCh(e.apply(c)).L }
        let full = drop(sky)
        for c in [rgb(0.6, 0.1, 280), rgb(0.5, 0.08, 240), rgb(0.7, 0.05, 250),
                  mix(sky, RGB(0.7, 0.7, 0.7), 0.5)] {
            XCTAssertEqual(drop(c) / full, ColorEngine.pointSelectionWeight(c, of: s),
                           accuracy: 0.03, "\(c)")
        }
    }

    /// The panel's strip: the sample sits where the strip says, fully selected, and
    /// each refinement visibly widens its own strip.
    func testTheSelectionStripShowsTheSampleAndEachRefinementsReach() {
        let red = rgb(0.55, 0.15, 28)
        for axis in ColorEngine.PointAxis.allCases {
            let strip = ColorEngine.pointSelectionStrip(swatch(red), axis: axis)
            XCTAssertEqual(strip.colours.count, 49)
            let at = Int((strip.samplePosition * 48).rounded())
            XCTAssertGreaterThan(strip.weights[at], 0.95, "\(axis)")
            XCTAssertLessThan(strip.weights.min() ?? 1, 0.05, "\(axis) selects its whole strip")
        }
        func reach(_ s: PointColor, _ axis: ColorEngine.PointAxis) -> Double {
            ColorEngine.pointSelectionStrip(s, axis: axis).weights.reduce(0, +)
        }
        XCTAssertGreaterThan(reach(swatch(red, hue: 100), .hue), 1.5 * reach(swatch(red), .hue))
        XCTAssertGreaterThan(reach(swatch(red, lum: 100), .luminance),
                             1.3 * reach(swatch(red), .luminance))
        XCTAssertGreaterThan(reach(swatch(red, sat: 100), .saturation),
                             1.1 * reach(swatch(red), .saturation))
    }

    /// Old recipes decode with no refinements, and a swatch without them encodes
    /// without the keys — the stored form of every existing edit is unchanged.
    func testRefinementsAreOptionalOnTheWire() throws {
        let json = #"{"sample":[0.1,0.2,0.3],"range":40,"variance":0,"shift":{"h":0,"s":0,"l":0}}"#
        let decoded = try JSONDecoder().decode(PointColor.self, from: Data(json.utf8))
        XCTAssertNil(decoded.hueRange)
        XCTAssertNil(decoded.satRange)
        XCTAssertNil(decoded.lumRange)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Range\""), encoded)
        var refined = decoded
        refined.hueRange = 80
        let again = try JSONDecoder().decode(
            PointColor.self, from: try JSONEncoder().encode(refined))
        XCTAssertEqual(again, refined)
    }

    // MARK: - Variance evens colour, keeps texture

    /// −100 converges hue and chroma toward the swatch and leaves lightness EXACTLY
    /// alone. Before: lightness moved halfway to the sample's, which on the flat path
    /// halves pore texture.
    func testVarianceConvergesHueAndChromaButNotLightness() {
        let skin = rgb(0.70, 0.08, 50)
        let e = engine([swatch(skin, variance: -100, shift: HSLShift())])
        for (dL, dC, dh) in [(0.04, 0.012, 7.0), (-0.05, -0.015, -6.0), (0.02, 0.0, 9.0)] {
            let input = space.toLCh(rgb(0.70 + dL, 0.08 + dC, 50 + dh))
            let out = space.toLCh(e.apply(rgb(input.L, input.C, input.h)))
            XCTAssertEqual(out.L, input.L, accuracy: 1e-9, "lightness moved")
            XCTAssertLessThan(abs(Num.hueDelta(50, out.h)), 0.1 * abs(dh) + 1e-6)
            XCTAssertLessThan(abs(out.C - 0.08), 0.1 * abs(dC) + 1e-6)
        }
    }

    // MARK: - The twin and the kernel run the same selection

    func testTheTwinMatchesTheEngineAcrossMixturesRefinementsAndVariance() {
        let red = rgb(0.55, 0.15, 28)
        let skin = rgb(0.70, 0.08, 50)
        let cases: [(String, [PointColor])] = [
            ("mixture", [swatch(red, shift: HSLShift(h: 25, s: -60, l: -40))]),
            ("refined", [swatch(red, range: 80, shift: HSLShift(h: -45, s: 30, l: 20),
                                hue: 90, sat: 10, lum: 70)]),
            ("variance", [swatch(skin, variance: -100, shift: HSLShift(s: -10))]),
            ("lowChromaSample", [swatch(rgb(0.6, 0.03, 70), shift: HSLShift(h: 20, l: 30))]),
        ]
        for (name, swatches) in cases {
            let e = engine(swatches)
            let worst = ExactColorStageTests.worstGateRatio(e)
            XCTAssertLessThanOrEqual(worst.ratio, 1, "\(name): \(worst.error) at \(worst.at)")
            // The blend itself, which the shared corpus samples only sparsely.
            let stage = e.exactStage
            let target = RGB(swatches[0].sample[0], swatches[0].sample[1], swatches[0].sample[2])
            for step in stride(from: 0.0, through: 1.0, by: 0.05) {
                let c = mix(target, RGB(0.6, 0.6, 0.6), step)
                XCTAssertLessThan(stage.apply(c).maxAbsDifference(e.apply(c)), 1e-4,
                                  "\(name) at mix \(step)")
            }
        }
    }
}
