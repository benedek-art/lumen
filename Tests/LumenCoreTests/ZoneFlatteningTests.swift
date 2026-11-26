// ZoneFlatteningTests.swift
//
// Astra AI-07: the forward clamp in `ToneEngine.bakeGainLUT` keeps the response monotone
// by rendering a whole band of input tones as one output value, and `zoneFlattening`
// measures that band. It was the Zones register's only limiter; `projectZoneEV` now is,
// so the audit's trigger is measured on the unprojected probe, and the register itself
// is pinned to never reach the clamp.

import XCTest
@testable import LumenCore

final class ZoneFlatteningTests: XCTestCase {

    /// Darks alone, applied as requested: the response the clamp used to flatten.
    private func darks(_ ev: Double) -> ToneEngine {
        var zones = Zones()
        zones.dark.ev = ev
        return ToneEngine(unprojectedTone: Tone(), zones: zones)
    }

    func testAnUntouchedToneStackFlattensNothing() {
        XCTAssertNil(ToneEngine().zoneFlattening())
    }

    /// The audit's trigger: default pivots, Darks alone, unprojected. Measured on Linux
    /// against the 1024-sample bake.
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

    /// The tester's plateau (grey ramp Shadows +2 rendered −2, −1 and 0 EV as 116 / 131 /
    /// 129; Shadows +3 as 175 / 174 / 175): every single zone and every adjacent pair
    /// at ±1…±5 EV now renders without the clamp and keeps at least
    /// `zoneMinimumSlopeFraction` of the identity's slope across the pivots.
    func testTheZonesRegisterKeepsTonesApartAcrossItsRange() {
        let paths: [WritableKeyPath<Zones, ZoneAdjust>] =
            [\.dark, \.shadow, \.mid, \.light, \.bright]
        let values: [Double] = [-5, -3, -2, -1.25, 1.25, 2, 3, 5]
        var cases: [Zones] = []
        for p in paths { for v in values { var z = Zones(); z[keyPath: p].ev = v; cases.append(z) } }
        for i in 0..<(paths.count - 1) { for v in values {
            var z = Zones(); z[keyPath: paths[i]].ev = v; z[keyPath: paths[i + 1]].ev = -v
            cases.append(z)
        } }
        let floor = ToneEngine.zoneMinimumSlopeFraction - 1e-6
        for zones in cases {
            let engine = ToneEngine(zones: zones)
            XCTAssertNil(engine.zoneFlattening(), "\(ToneEngine.requestedZoneEV(zones))")
            var t = -4.0
            while t < 4 {
                let a = t + engine.stops(at: t)
                let b = t + 0.05 + engine.stops(at: t + 0.05)
                XCTAssertGreaterThanOrEqual((b - a) / 0.05, floor,
                                            "\(ToneEngine.requestedZoneEV(zones)) at \(t) EV")
                t += 0.05
            }
        }
    }

    /// Inside the limit nothing moves; past it the slider keeps moving the picture.
    func testTheProjectionIsExactInsideItsLimitAndStillMovesPastIt() {
        var small = Zones()
        small.shadow.ev = 0.75
        small.light.ev = -0.5
        XCTAssertEqual(ToneEngine(zones: small).appliedZoneEV, [0, 0.75, 0, -0.5, 0])
        var previous = -Double.infinity
        for v in stride(from: 1.0, through: 5.0, by: 0.25) {
            var z = Zones()
            z.shadow.ev = v
            let applied = ToneEngine(zones: z).appliedZoneEV
            XCTAssertGreaterThan(applied[1], previous + 0.05, "Shadows \(v) stopped moving")
            XCTAssertLessThanOrEqual(applied[1], v + 1e-12)
            previous = applied[1]
        }
    }

    /// The projection is a least-squares one: a single violating pair moves to its mean
    /// plus and minus half the allowed drop.
    func testAViolatingPairMovesToItsMean() {
        let out = ToneEngine.projectZoneEV([0, 3, 0, 0, 0], drop: [1, 1, 1, 1])
        XCTAssertEqual(out[0], 0)
        XCTAssertEqual(out[1], 2, accuracy: 1e-12)
        XCTAssertEqual(out[2], 1, accuracy: 1e-12)
        XCTAssertEqual(out[3], 0)
        XCTAssertEqual(out[4], 0)
    }
}
