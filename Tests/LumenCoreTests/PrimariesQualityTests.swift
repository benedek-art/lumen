// PrimariesQualityTests.swift
// WS-33 (quality lane K3): Primaries do what a colourist reaches for in Lightroom's
// Calibration panel, over the whole travel, and greys stay grey.
//
// The remap used to move each primary's xy chromaticity and refuse anything off the
// spectral locus. Rec.2020's primaries sit ON it, so Red Saturation's positive half was
// a clamp (byte-identical from +10 to +100), Green's died past +25, Blue's past +31,
// and turning red toward orange desaturated it. `ColorEngine.primariesMatrix` now moves
// each primary's chroma in linear opponent space, where nothing can leave the domain.

import XCTest
@testable import LumenCore

final class PrimariesQualityTests: XCTestCase {

    private let space = OKLabTransform.working

    private func engine(_ p: Primaries) -> ColorEngine {
        ColorEngine(mixer: Mixer(), pointColors: [], color: ColorAdjust(), primaries: p,
                    bw: nil, bandMeanHues: nil)
    }

    private func lch(_ c: RGB) -> OKLCh { space.toLCh(c) }

    /// A colour mostly made of one primary, the kind the Calibration sliders are read
    /// on: a saturated red, green and blue that are inside every gamut in play.
    private func probe(_ i: Int) -> RGB {
        [RGB(0.50, 0.10, 0.06), RGB(0.10, 0.40, 0.08), RGB(0.05, 0.08, 0.45)][i]
    }

    private func set(_ p: inout Primaries, _ i: Int, hue: Double? = nil, sat: Double? = nil) {
        if let hue { if i == 0 { p.rHue = hue } else if i == 1 { p.gHue = hue } else { p.bHue = hue } }
        if let sat {
            if i == 0 { p.rPurity = sat } else if i == 1 { p.gPurity = sat } else { p.bPurity = sat }
        }
    }

    // MARK: - Greys stay grey

    /// At every corner of the six remap sliders (3⁶ settings of −100/0/+100) a neutral
    /// ramp from deep shadow to four stops over comes back neutral and unchanged, on
    /// the engine (Double) and on the exact stage's Float32 twin.
    func testGreysStayGreyAtEveryCornerOfTheSixRemapSliders() {
        let values: [Double] = [-100, 0, 100]
        var worstEngine = 0.0
        var worstTwin = 0.0
        for a in values { for b in values { for c in values {
            for d in values { for e in values { for f in values {
                let p = Primaries(rHue: a, rPurity: b, gHue: c, gPurity: d, bHue: e, bPurity: f)
                let engine = self.engine(p)
                let stage = engine.exactStage
                for y in [0.002, 0.02, 0.18, 0.9, 2.9] {
                    let grey = RGB(y, y, y)
                    let out = engine.apply(grey)
                    worstEngine = Swift.max(worstEngine, out.maxAbsDifference(grey) / y)
                    let twin = stage.apply(grey)
                    worstTwin = Swift.max(worstTwin, twin.maxAbsDifference(grey) / y)
                }
            }}}
        }}}
        XCTAssertLessThan(worstEngine, 1e-9, "a grey moved on the engine")
        XCTAssertLessThan(worstTwin, 2e-5, "a grey moved on the Float32 twin")
    }

    // MARK: - No dead range, smooth, monotonic

    /// Each of the six sliders moves its own primary's colour strictly monotonically in
    /// 10-step increments across the whole −100…+100 travel, and no step is less than a
    /// fifth of the average step (no plateau, no front-loading). Hue rows are read on
    /// OKLab hue, saturation rows on OKLab chroma.
    func testEverySliderRunsItsWholeTravelSmoothly() {
        for i in 0..<3 {
            for isHue in [true, false] {
                var readings: [Double] = []
                for v in stride(from: -100.0, through: 100, by: 10) {
                    var p = Primaries()
                    if isHue { set(&p, i, hue: v) } else { set(&p, i, sat: v) }
                    let out = lch(engine(p).apply(probe(i)))
                    readings.append(isHue ? out.h : out.C)
                }
                if isHue {
                    // Unwrap around the probe's own hue.
                    let h0 = readings[10]
                    readings = readings.map { h0 + Num.hueDelta(h0, $0) }
                }
                let steps = zip(readings.dropFirst(), readings).map { $0 - $1 }
                let mean = (readings.last! - readings.first!) / Double(steps.count)
                let label = "\(["red", "green", "blue"][i]) \(isHue ? "hue" : "saturation")"
                XCTAssertGreaterThan(mean, 0, "\(label) runs backwards: \(readings)")
                for (k, step) in steps.enumerated() {
                    XCTAssertGreaterThan(step, 0.2 * mean,
                                         "\(label): step \(k) is \(step) against a mean "
                                         + "of \(mean) — a plateau or a reversal")
                }
            }
        }
    }

    // MARK: - What a colourist expects

    /// Positive Hue turns each primary the way Lightroom's Calibration does — red
    /// toward orange, green toward cyan, blue toward purple (all up OKLab's hue
    /// angle) — and by an amount a colourist would call a real move: 10°…40° at ±100
    /// on the primary's own colour, within a factor of two each way.
    func testHueTurnsEachPrimaryTheWayCalibrationDoesAndByARealAmount() {
        for i in 0..<3 {
            let h0 = lch(probe(i)).h
            var up = Primaries(), down = Primaries()
            set(&up, i, hue: 100)
            set(&down, i, hue: -100)
            let plus = Num.hueDelta(h0, lch(engine(up).apply(probe(i))).h)
            let minus = Num.hueDelta(h0, lch(engine(down).apply(probe(i))).h)
            XCTAssertGreaterThan(plus, 10, "primary \(i) +100 turned \(plus)°")
            XCTAssertLessThan(plus, 40, "primary \(i) +100 turned \(plus)°")
            XCTAssertLessThan(minus, -10, "primary \(i) −100 turned \(minus)°")
            XCTAssertGreaterThan(minus, -40, "primary \(i) −100 turned \(minus)°")
            XCTAssertLessThan(Swift.max(plus, -minus) / Swift.min(plus, -minus), 2,
                              "primary \(i) is lopsided: +\(plus)° / \(minus)°")
        }
    }

    /// Saturation ±100 makes the primary's own colour clearly more and less colourful
    /// (at least +9% / −12% OKLab chroma — blue is the weakest, see
    /// `ColorEngine.primaryPurityStops`) without turning it (under 6°).
    func testSaturationChangesColourfulnessWithoutTurningTheHue() {
        for i in 0..<3 {
            let base = lch(probe(i))
            for v in [-100.0, 100] {
                var p = Primaries()
                set(&p, i, sat: v)
                let out = lch(engine(p).apply(probe(i)))
                let ratio = out.C / base.C
                if v > 0 {
                    XCTAssertGreaterThan(ratio, 1.09, "primary \(i) +100: ×\(ratio)")
                } else {
                    XCTAssertLessThan(ratio, 0.88, "primary \(i) −100: ×\(ratio)")
                }
                XCTAssertLessThan(abs(Num.hueDelta(base.h, out.h)), 6,
                                  "primary \(i) saturation \(v) turned the hue")
            }
        }
    }

    /// Lightness of the primary's own colour barely moves under any single slider: the
    /// remap is a colour move, not a tone move (under 0.04 OKLab L at the extremes).
    func testNoSliderIsSecretlyATonalMove() {
        for i in 0..<3 {
            let baseL = lch(probe(i)).L
            for isHue in [true, false] {
                for v in [-100.0, 100] {
                    var p = Primaries()
                    if isHue { set(&p, i, hue: v) } else { set(&p, i, sat: v) }
                    let L = lch(engine(p).apply(probe(i))).L
                    XCTAssertLessThan(abs(L - baseL), 0.04, "primary \(i) \(isHue ? "hue" : "sat") \(v)")
                }
            }
        }
    }
}
