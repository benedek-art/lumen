// ZoneFlatteningTests.swift
//
// Astra AI-07: the Zones panel has no limiter of its own. Its only guard is the forward
// clamp in `ToneEngine.bakeGainLUT`, which keeps the response monotone by rendering a
// whole band of input tones as one output value — and nothing measured how wide that
// band is, so nothing could tell the photographer. `zoneFlattening` is that measurement.
// These tests pin what it reports on the audit's own trigger, and that it reports
// nothing where the six tone sliders' solved limits already keep the clamp idle.

import XCTest
@testable import LumenCore

final class ZoneFlatteningTests: XCTestCase {

    private func darks(_ ev: Double) -> ToneEngine {
        var zones = Zones()
        zones.dark.ev = ev
        return ToneEngine(zones: zones)
    }

    func testAnUntouchedToneStackFlattensNothing() {
        XCTAssertNil(ToneEngine().zoneFlattening())
    }

    /// The audit's trigger: default pivots, Darks alone. Measured on Linux against the
    /// 1024-sample bake the renderer uses.
    func testDarksAloneFlattensTheBandTheAuditMeasured() throws {
        let expected: [(ev: Double, low: Double, high: Double, worst: Double)] = [
            (2, -3.531, -1.795, 0.421),
            (4, -3.765, 0.082, 2.204),
        ]
        for e in expected {
            let f = try XCTUnwrap(darks(e.ev).zoneFlattening(),
                                  "Darks +\(e.ev) EV flattens part of the response and "
                                      + "zoneFlattening reported nothing")
            XCTAssertEqual(f.lowEV, e.low, accuracy: 0.002, "Darks +\(e.ev): low end")
            XCTAssertEqual(f.highEV, e.high, accuracy: 0.002, "Darks +\(e.ev): high end")
            XCTAssertEqual(f.worstEV, e.worst, accuracy: 0.002, "Darks +\(e.ev): worst")
            XCTAssertGreaterThan(f.fraction, 0)
        }
        // And it grows with the request — the panel's warning should too.
        let two = try XCTUnwrap(darks(2).zoneFlattening())
        let four = try XCTUnwrap(darks(4).zoneFlattening())
        XCTAssertGreaterThan(four.widthEV, two.widthEV)
    }

    /// The report describes the table the renderer bakes, not a parallel computation:
    /// inside the flattened band every baked sample renders the same output tone.
    func testTheReportedBandIsFlatInTheBakedTable() throws {
        let engine = darks(4)
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
