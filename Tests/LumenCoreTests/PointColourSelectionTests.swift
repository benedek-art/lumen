// PointColourSelectionTests.swift
// A Point Colour swatch selects its own colour (B1-01).
//
// It did not. The three selection sigmas were 0.60 / 0.25 / 0.30, and each spans most
// or all of its own axis — OKLab L runs 0…1 and photographic chroma tops out near 0.25
// — so neither lightness nor chroma could exclude anything, and the hue term was a
// CHORD, whose maximum at ordinary chroma is about 0.24 against a sigma of 0.30, so a
// full 180° reversal was still inside the selection.
//
// Measured on a swatch sampled on a blue sky at Range 100: weight 1.000 on the sampled
// colour and 1.000 on pure neutral grey. Click a sky, pull Luminance to −100 to deepen
// it, and the concrete, the wall and the faces in the frame darken with it — the grey
// by seventy sRGB code values. The control read as broken selection rather than as a
// global slider, so there was no way to attribute the result to anything.
//
// Both ENDS of Range were dead too, for opposite reasons: the scale was `range/100`
// floored at 1e-4, so Range 0 matched only a bit-exact colour (no pixels) and Range 100
// matched everything.
//
// Nothing tested any of this: `ColorScienceTests` has no Point Colour case and
// `RobustnessTests` only checks the control is alive.

import XCTest
@testable import LumenCore

final class PointColourSelectionTests: XCTestCase {

    private let space = OKLabTransform.working

    private func rgb(_ L: Double, _ C: Double, _ h: Double) -> RGB {
        space.toRGB(OKLCh(L: L, C: C, h: h))
    }

    /// The sky the swatch is sampled on, and the audit's fixture.
    private var sky: RGB { rgb(0.60, 0.12, 255) }

    /// Selection weight, read through the engine rather than re-derived: a big
    /// Luminance shift makes the weight visible as a lightness move, and the ratio to
    /// the fully-selected sample's move IS the weight.
    private func selection(of pixel: RGB, range: Double) -> Double {
        let swatch = PointColor(sample: [sky.r, sky.g, sky.b], range: range,
                                variance: 0, shift: HSLShift(h: 0, s: 0, l: -100))
        let e = ColorEngine(mixer: Mixer(), pointColors: [swatch], color: ColorAdjust(),
                            primaries: Primaries(), bw: nil, bandMeanHues: nil)
        func drop(_ c: RGB) -> Double {
            space.toLCh(c).L - space.toLCh(e.apply(c, localMean: c)).L
        }
        let full = drop(sky)
        guard abs(full) > 1e-9 else { return 0 }
        return drop(pixel) / full
    }

    // MARK: - The defect

    /// THE ONE THAT MOVED THE WHOLE FRAME. A neutral grey has no hue to select on and
    /// no chroma near the sample's; it must not come along.
    func testANeutralGreyIsNotSelectedAtAnyRange() {
        for range in [0.0, 25, 50, 75, 100] {
            let w = selection(of: rgb(0.60, 0.0, 255), range: range)
            XCTAssertLessThan(abs(w), 0.05,
                              "at Range \(range) a pure neutral grey came along at "
                              + "\(w) of the sampled colour's own move — the concrete "
                              + "and the wall darken with the sky")
        }
    }

    /// Hue must be able to EXCLUDE, which the chordal term could not do: same lightness,
    /// same chroma, ninety degrees round the wheel.
    func testAColourNinetyDegreesAwayIsNotSelected() {
        for range in [0.0, 50, 100] {
            let w = selection(of: rgb(0.60, 0.12, 345), range: range)
            XCTAssertLessThan(abs(w), 0.05,
                              "at Range \(range) a colour 90° away weighed \(w)")
        }
    }

    /// The two the photographer would notice first in a real frame.
    func testSkinAndFoliageAreNotSelectedBySkyBlue() {
        for range in [0.0, 50, 100] {
            XCTAssertLessThan(abs(selection(of: rgb(0.70, 0.08, 56), range: range)), 0.05,
                              "skin, at Range \(range)")
            XCTAssertLessThan(abs(selection(of: rgb(0.45, 0.12, 140), range: range)), 0.05,
                              "foliage, at Range \(range)")
        }
    }

    // MARK: - What must NOT change: it is still a selection, not a pixel match

    /// The sampled colour is fully selected wherever Range sits.
    func testTheSampledColourIsAlwaysFullySelected() {
        for range in [0.0, 25, 50, 75, 100] {
            XCTAssertEqual(selection(of: sky, range: range), 1, accuracy: 1e-9)
        }
    }

    /// NEITHER END OF THE SLIDER IS DEAD. Range 0 used to select only a bit-exact match
    /// — no pixels — and Range 100 selected everything. Both ends must now be
    /// tolerances, and the top must reach further than the bottom.
    func testBothEndsOfRangeAreUsefulAndTheTopReachesFurther() {
        let near = rgb(0.60, 0.12, 285)          // 30° along the wheel
        let atZero = selection(of: near, range: 0)
        let atFull = selection(of: near, range: 100)
        XCTAssertGreaterThan(atZero, 0.05,
                             "Range 0 selects nothing but a bit-exact match again — the "
                             + "bottom of the slider is inert")
        XCTAssertGreaterThan(atFull, atZero,
                             "Range must widen the selection: 0 gave \(atZero) and 100 "
                             + "gave \(atFull)")
        let far = rgb(0.60, 0.12, 315)           // 60° along
        XCTAssertGreaterThan(selection(of: far, range: 100), 0.05,
                             "Range 100 must reach further than Range 0 does")
        XCTAssertLessThan(selection(of: far, range: 0), 0.05,
                          "and Range 0 must not")
    }

    /// A neighbouring blue is GRADED, not switched. A selection that is 1 on the sample
    /// and 0 on everything else is a hard mask and would band.
    func testANeighbouringColourIsPartlySelected() {
        // 45° round the wheel at the default Range — inside the falloff, not the
        // plateau. A stop of lightness (ΔL 0.10) is deliberately still fully selected:
        // the same colour at a different exposure IS the same colour, which is what a
        // lightness tolerance of about a stop and a half is for.
        let w = selection(of: rgb(0.60, 0.12, 300), range: 50)
        XCTAssertGreaterThan(w, 0.05,
                             "45° away at the default Range selects nothing — the "
                             + "falloff has become a cliff in the other direction")
        XCTAssertLessThan(w, 0.99,
                          "45° away at the default Range is FULLY selected, so the "
                          + "weight is a switch rather than a falloff and the control "
                          + "will band")
    }
}
