// ZoneFlatteningTests.swift
//
// Astra AI-07: the Zones panel had no limiter of its own. Its only guard was the forward
// clamp in `ToneEngine.bakeGainLUT`, which keeps the response monotone by rendering a
// whole band of input tones as one output value — and nothing measured how wide that
// band is, so nothing could tell the photographer. `zoneFlattening` is that measurement.
//
// WS-08 gave the register its own limiter (`ToneEngine.appliedZoneEV`), so on its own it
// no longer reaches the clamp: Darks +2 and +4, the audit's trigger, now report nothing.
// The clamp is still the backstop for the register combined with Contrast or the six
// sliders, which the ease does not see, so the measurement is pinned on Contrast −100
// with Darks +3: Contrast −100 runs the tones below mid-grey at 0.4 stops per stop and
// the eased Darks seam takes 0.75 of that away.

import XCTest
@testable import LumenCore

final class ZoneFlatteningTests: XCTestCase {

    private func darks(_ ev: Double, contrast: Double = 0) -> ToneEngine {
        var zones = Zones()
        zones.dark.ev = ev
        return ToneEngine(tone: Tone(contrast: contrast), zones: zones)
    }

    func testAnUntouchedToneStackFlattensNothing() {
        XCTAssertNil(ToneEngine().zoneFlattening())
    }

    /// The audit's trigger, default pivots and Darks alone, no longer reaches the clamp;
    /// a recipe that still does is measured instead. Measured on Linux against the
    /// 1024-sample bake the renderer uses.
    func testDarksAloneNoLongerFlattensAndContrastWithDarksIsMeasured() throws {
        // Darks +2 EV flattened −3.53…−1.80 EV and +4 EV −3.77…+0.08 EV before the ease.
        XCTAssertNil(darks(2).zoneFlattening(), "Darks +2 EV alone reached the clamp")
        XCTAssertNil(darks(4).zoneFlattening(), "Darks +4 EV alone reached the clamp")

        let f = try XCTUnwrap(darks(3, contrast: -100).zoneFlattening(),
                              "Contrast −100 with Darks +3 flattens part of the response "
                                  + "and zoneFlattening reported nothing")
        XCTAssertEqual(f.lowEV, -3.179, accuracy: 0.002, "low end")
        XCTAssertEqual(f.highEV, 2.217, accuracy: 0.002, "high end")
        XCTAssertEqual(f.worstEV, 0.402, accuracy: 0.002, "worst")
        XCTAssertGreaterThan(f.fraction, 0)
    }

    /// The report describes the table the renderer bakes, not a parallel computation:
    /// inside the flattened band every baked sample renders the same output tone.
    ///
    /// Darks +0.95 rather than +3: at +3 the Darks excess spills up the axis and the
    /// clamp fires in two places, which the report merges into one span (audit Z-10,
    /// WS-07's) that is not flat end to end. +0.95 is inside one seam's limit, so it
    /// flattens one band.
    func testTheReportedBandIsFlatInTheBakedTable() throws {
        let engine = darks(0.95, contrast: -100)
        let f = try XCTUnwrap(engine.zoneFlattening())
        let lut = engine.bakeGainLUT()
        var outputs: [Double] = []
        for i in 0..<lut.samples.count {
            let y = Double(i) / Double(lut.samples.count - 1)
            let t = Num.safeLog2(LumenLog.decode(y) / 0.18)
            guard t > f.lowEV, t <= f.highEV else { continue }
            outputs.append(t + Num.safeLog2(lut.samples[i]))
        }
        XCTAssertGreaterThan(outputs.count, 10)
        let spread = (outputs.max() ?? 0) - (outputs.min() ?? 0)
        XCTAssertLessThan(spread, 1e-9, "the band zoneFlattening reports is not flat in the bake")
    }

    /// The six-slider path solves its own limits, so the clamp should never fire on it.
    /// Every corner of the five zonal sliders at −100/0/+100, the case `bakeGainLUT`'s
    /// own comment states.
    func testTheSixSlidersNeverReachTheClamp() {
        let values: [Double] = [-100, 0, 100]
        for h in values { for s in values { for w in values { for b in values {
            for c in values {
                var tone = Tone()
                tone.highlights = h
                tone.shadows = s
                tone.whites = w
                tone.blacks = b
                tone.contrast = c
                let f = ToneEngine(tone: tone).zoneFlattening()
                XCTAssertNil(f, "highlights \(h) shadows \(s) whites \(w) blacks \(b) "
                                 + "contrast \(c) reached the clamp: \(String(describing: f))")
            }
        } } } }
    }
}
