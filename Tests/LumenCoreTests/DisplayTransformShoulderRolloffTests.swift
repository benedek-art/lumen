// DisplayTransformShoulderRolloffTests.swift
// A shoulder is a promise about the LAST stop before the white anchor: the picture's
// slope falls toward zero there, so a lamp or a specular eases into display white
// instead of running into it. docs/04's HDR mode promises that "the sigmoid's
// shoulder does at 400% white exactly what it did at 100%".
//
// The two-power construction only keeps that promise while the shoulder's exponent
// stays above 1: with s = u^p, the normalized slope near the anchor is p·u^(p−1),
// which tends to 0 for p > 1 and grows without bound for p < 1. The exponent is
// m·(1−pivotX)/(1−pivotY), and in HDR pivotY falls (mid-grey stays at 0.18 absolute
// while the encoded peak rises), so at 400% it measured 0.82 and at 1600% 0.39: the
// slope ROSE into the anchor (log-log 0.68 at +4 EV, 1.26 at +4.99 EV at 400%) and
// then stopped dead at the white target — a clip edge in every HDR rendition. Low
// Contrast or strongly negative Skew did the same to SDR, and at Contrast 0.1 /
// Skew −1 the old 0.05 power floor bent the pivot slope off its contract.

import XCTest
@testable import LumenCore

final class DisplayTransformShoulderRolloffTests: XCTestCase {

    private func logLogSlope(_ t: DisplayTransform, ev: Double, h: Double = 0.01) -> Double {
        let hi = t.tone(0.18 * pow(2, ev + h))
        let lo = t.tone(0.18 * pow(2, ev - h))
        return (log2(hi) - log2(lo)) / (2 * h)
    }

    func testTheShoulderRollsOffIntoTheWhiteAnchorAtEveryDisplayPeak() {
        // WS-13 SPEC 2.2: the lower white anchors WS-05 is weighing (+3, +3.5 EV) roll
        // off too, in SDR and HDR.
        let cases: [(white: Double, contrast: Double, skew: Double, anchor: Double)] = [
            (100, 1.5, 0, 5), (400, 1.5, 0, 5), (1600, 1.5, 0, 5), (100, 0.6, 0, 5),
            (400, 1.5, -1, 5), (100, 1.5, -1, 5), (1600, 0.6, -1, 5),
            (100, 1.5, 0, 3), (100, 1.5, 0, 3.5), (400, 1.5, 0, 3), (100, 2.1, -0.15, 3),
        ]
        for c in cases {
            var p = DisplayTransformParams()
            p.whiteTarget = c.white
            p.contrast = c.contrast
            p.skew = c.skew
            p.whiteAnchorEV = c.anchor
            let t = DisplayTransform(p)
            let anchor = p.whiteAnchorEV
            let stopBefore = logLogSlope(t, ev: anchor - 1)
            let atAnchor = logLogSlope(t, ev: anchor - 0.05, h: 0.005)
            let label = "white \(c.white)%, contrast \(c.contrast), skew \(c.skew), anchor +\(c.anchor)"
            XCTAssertLessThan(atAnchor, stopBefore,
                              "\(label): the slope rises into the white anchor (\(stopBefore) a stop "
                              + "before, \(atAnchor) at the anchor) — a clip, not a shoulder")
            XCTAssertLessThan(atAnchor, 0.3,
                              "\(label): log-log slope \(atAnchor) just below the white anchor")
            // Still reaches the white target: the rolloff is not bought by
            // giving up the anchor.
            XCTAssertEqual(t.tone(0.18 * pow(2, anchor)), t.white, accuracy: t.white * 1e-9, label)
        }
    }

    func testThePivotSlopeIsContrastEvenAtTheExtremesOfContrastAndSkew() {
        // The power floor used to bind at Contrast 0.1 with full Skew, which moved
        // the pivot slope (0.113 against the promised 0.1). Rolling off through the
        // skew term instead keeps the exponent at or above 1.5 without a floor.
        for white in [100.0, 400, 1600] {
            for contrast in [0.1, 0.6, 1.5] {
                for skew in [-1.0, 1.0] {
                    var p = DisplayTransformParams()
                    p.whiteTarget = white
                    p.contrast = contrast
                    p.skew = skew
                    let t = DisplayTransform(p)
                    let slope = logLogSlope(t, ev: 0, h: 0.001)
                    XCTAssertEqual(slope, contrast, accuracy: contrast * 0.02,
                                   "white \(white)%, contrast \(contrast), skew \(skew)")
                    var previous = -Double.infinity
                    for i in 0...4000 {
                        let y = t.normalizedCurve(Double(i) / 4000)
                        XCTAssertGreaterThanOrEqual(y, previous - 1e-12,
                                                    "not monotone at white \(white)%, "
                                                    + "contrast \(contrast), skew \(skew)")
                        previous = y
                    }
                }
            }
        }
    }

    func testTheSDRPresetsKeepTheirShape() {
        // Every shipped SDR preset already had shoulder and toe exponents above 1.5;
        // the rolloff guarantee must not move them by a single code value.
        for name in DisplayTransformParams.presetNames where name != "Linear" {
            let p = DisplayTransformParams.preset(named: name)
            let t = DisplayTransform(p)
            for i in 0...140 {
                let ev = -9 + Double(i) * 0.1
                let x = 0.18 * pow(2, ev)
                let y = t.tone(x)
                XCTAssertEqual(y, Self.legacyTone(p, x), accuracy: 1e-12, "\(name) at \(ev) EV")
            }
        }
    }

    /// The pre-fix construction, for presets whose exponents never reach the new
    /// bound: identical there by construction, so any drift is a regression.
    private static func legacyTone(_ p: DisplayTransformParams, _ x: Double) -> Double {
        let curve = DisplayTransform.shapingCurve
        let w = max(p.whiteTarget, 1) / 100
        let black = min(Num.clamp(p.blackTarget, 0, 15) / 100, 0.09)
        let hi = max(p.whiteAnchorEV, 0.5), lo = min(p.blackAnchorEV, -0.5)
        let px = -lo / (hi - lo)
        let eb = curve.encode(black), ew = curve.encode(w), ep = curve.encode(0.18)
        let span = max(ew - eb, 1e-6)
        let py = Num.clamp((ep - eb) / span, 0.01, 0.99)
        let c = Num.clamp(p.contrast, 0.1, 10)
        let h = 1e-6
        let sd = max((curve.decode(ep + h) - curve.decode(ep - h)) / (2 * h), 1e-9)
        let m = c * 0.18 * log(2.0) * (hi - lo) / (sd * span)
        let aT = m * px / py, aS = m * (1 - px) / (1 - py)
        let sk = Num.clamp(p.skew, -1, 1)
        // WS-13's skew mapping: the side gaining curvature takes skew·min(½, room),
        // the side losing it takes the full skew (was ±skew/2 both ways).
        func lambda(_ s: Double, _ room: Double) -> Double {
            s > 0 ? s * min(0.5, room) : Num.clamp(s, -1, room)
        }
        let lT = lambda(sk, aT / 2 * 0.9)
        let lS = lambda(-sk, aS / 2 * 0.9)
        let pT = max(aT - lT * 2, 0.05), pS = max(aS - lS * 2, 0.05)
        guard x > 0 else { return black }
        let X = Num.saturate((log2(x / 0.18) - lo) / (hi - lo))
        let Y: Double
        if X < px {
            let u = X / px
            Y = py * pow(u, pT) * (1 - lT + lT * u * u)
        } else {
            let u = (1 - X) / (1 - px)
            Y = 1 - (1 - py) * pow(u, pS) * (1 - lS + lS * u * u)
        }
        return curve.decode(eb + (ew - eb) * Y)
    }
}
