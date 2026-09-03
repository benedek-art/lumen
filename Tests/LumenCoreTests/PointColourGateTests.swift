// PointColourGateTests.swift
// The chroma gate is the engine's law, not Variance's local variable.
//
// `ColorEngine`'s header states it as a shared design rule: every hue-selective tool
// applies the chroma gate, so near-neutral pixels — whose hue is numerically noise —
// are never rotated by one. `applyMixer` obeys it. Point Colour computed the gate
// inside its Variance branch and left its three shift lines ungated, so a swatch could
// rotate the hue of a pixel the Mixer refuses to touch at all.
//
// Nothing tested this: `ColorScienceTests` has no Point Colour case, and
// `RobustnessTests` only checks the control is alive.

import XCTest
@testable import LumenCore

final class PointColourGateTests: XCTestCase {

    /// A warm near-neutral at exactly `gateLoChroma`, where the Mixer's authority is 0.
    private func warmGrey() -> RGB {
        OKLabTransform.working.toRGB(OKLCh(L: 0.62, C: ColorEngine.gateLoChroma, h: 60))
    }

    private func engine(shiftH: Double, range: Double = 100) -> ColorEngine {
        let grey = warmGrey()
        let swatch = PointColor(sample: [grey.r, grey.g, grey.b], range: range,
                                variance: 0,
                                shift: HSLShift(h: shiftH, s: 0, l: 0))
        return ColorEngine(mixer: Mixer(), pointColors: [swatch], color: ColorAdjust(),
                           primaries: Primaries(), bw: nil, bandMeanHues: nil)
    }

    private func hue(_ c: RGB) -> Double { OKLabTransform.working.toLCh(c).h }

    /// The defect: a swatch sampled ON the near-neutral still rotated it, at essentially
    /// full strength, because selection weight was 1 and the gate was never consulted.
    func testASwatchDoesNotRotateAPixelTheMixerRefusesToTouch() {
        let grey = warmGrey()
        let out = engine(shiftH: 60).apply(grey, localMean: grey)
        let rotated = abs(Num.wrapHue(hue(out) - hue(grey)))
        XCTAssertEqual(ColorEngine.chromaGate(ColorEngine.gateLoChroma), 0, accuracy: 1e-9,
                       "the fixture must sit where the gate is closed, or this proves "
                       + "nothing about the gate")
        XCTAssertLessThan(rotated, 1.0,
                          "a +60° Point Colour shift rotated a C = 0.02 grey by \(rotated)°"
                          + " — the Mixer's authority on that pixel is zero, and the "
                          + "engine's header says every hue-selective tool shares the gate")
    }

    /// And it still works where there IS hue: the gate must not disable the control.
    func testASwatchStillRotatesARealColour() {
        let blue = OKLabTransform.working.toRGB(OKLCh(L: 0.60, C: 0.12, h: 255))
        let swatch = PointColor(sample: [blue.r, blue.g, blue.b], range: 100,
                                variance: 0, shift: HSLShift(h: 40, s: 0, l: 0))
        let e = ColorEngine(mixer: Mixer(), pointColors: [swatch], color: ColorAdjust(),
                            primaries: Primaries(), bw: nil, bandMeanHues: nil)
        let rotated = abs(Num.wrapHue(hue(e.apply(blue, localMean: blue)) - hue(blue)))
        XCTAssertGreaterThan(rotated, 20,
                             "gating the shift must not disable the control on a colour "
                             + "that has a hue — it rotated only \(rotated)°")
    }

    /// The gate is a ramp, not a cliff: a pixel above `gateHiChroma` is fully authored.
    func testTheGateRampsRatherThanSwitching() {
        XCTAssertEqual(ColorEngine.chromaGate(0), 0, accuracy: 1e-9)
        XCTAssertGreaterThan(ColorEngine.chromaGate(0.05), 0)
        XCTAssertLessThan(ColorEngine.chromaGate(0.05), 1)
    }
}
