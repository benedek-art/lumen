// SliderScaleTests.swift
// Whether the Temp slider is worth dragging along its whole length.
//
// The report this arbitrates: "why does it go from 2,000 Kelvin to 50,000 Kelvin?
// Also, I don't think that anything even changes above like 15,000 Kelvin." Unlike the
// dropped-gesture theory in SliderDragTests, this one survives contact with the
// arithmetic — on a linear Kelvin axis it is very nearly a precise description of the
// control, and these tests pin both halves: that the complaint was true, and that the
// mired axis answers it.
//
// The measure of "how much does this part of the track do" used throughout is the path
// length a neutral traces through sRGB code values as the target temperature sweeps —
// the same quantity ProofMetrics uses, and the one that corresponds to what the eye is
// being asked to notice.

import Foundation
import XCTest
@testable import LumenCore

final class SliderScaleTests: XCTestCase {

    /// The Temp row as it actually ships: the develop column's track width, the
    /// documented range, the step the panel passes.
    private var tempTrack: SliderTrack {
        SliderTrack(width: 158, lowerBound: 2000, upperBound: 50000, step: 10,
                    scale: .reciprocal)
    }

    private var linearTempTrack: SliderTrack {
        SliderTrack(width: 158, lowerBound: 2000, upperBound: 50000, step: 10)
    }

    // MARK: - The scale itself

    func testTheReciprocalAxisIsExactlyInvertible() {
        for kelvin in stride(from: 2000.0, through: 50000.0, by: 137.0) {
            let round = SliderScale.reciprocal.value(atAxis: SliderScale.reciprocal.axis(kelvin))
            XCTAssertEqual(round, kelvin, accuracy: 1e-9,
                           "\(kelvin) K did not survive a round trip through the axis")
        }
    }

    func testBothScalesIncreaseWithValue() {
        // Every method on SliderTrack does its arithmetic in axis space and converts at
        // the boundary, which is only sound while the axis is monotone increasing.
        for scale in SliderScale.allCases {
            var previous = -Double.infinity
            for value in stride(from: 2000.0, through: 50000.0, by: 251.0) {
                let a = scale.axis(value)
                XCTAssertGreaterThan(a, previous, "\(scale) is not increasing at \(value)")
                previous = a
            }
        }
    }

    func testAReciprocalTrackRejectsARangeThroughZero() {
        let straddling = SliderTrack(width: 158, lowerBound: -100, upperBound: 100,
                                     step: 1, scale: .reciprocal)
        XCTAssertFalse(straddling.isUsable)
        // Unusable means every entry point hands the value back rather than dividing
        // by a range it cannot represent.
        XCTAssertEqual(straddling.value(from: 40, travelled: 80), 40)
        XCTAssertEqual(straddling.travelNeeded(from: 0, to: 100), 0)
        XCTAssertEqual(straddling.fraction(of: 50), 0)
    }

    func testTheDefaultScaleIsLinearSoEveryOtherControlIsUnchanged() {
        let tone = SliderTrack(width: 158, lowerBound: -100, upperBound: 100, step: 1)
        XCTAssertEqual(tone.scale, .linear)
        XCTAssertEqual(tone.fraction(of: 0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(tone.valueAtPress(x: 79), 0)
    }

    // MARK: - The ends of the track still mean what they say

    func testTheTrackEndsLandOnTheRangeEnds() {
        let track = tempTrack
        XCTAssertEqual(track.valueAtPress(x: 0), 2000)
        XCTAssertEqual(track.valueAtPress(x: track.width), 50000)
        XCTAssertEqual(track.fraction(of: 2000), 0, accuracy: 1e-12)
        XCTAssertEqual(track.fraction(of: 50000), 1, accuracy: 1e-12)
    }

    func testTravelIsPinnedAtBothEnds() {
        let track = tempTrack
        // Drag far past either end; the value stops at the bound rather than passing
        // through the reciprocal axis's singularity at zero and changing sign.
        XCTAssertEqual(track.value(from: 5500, travelled: -10000), 2000)
        XCTAssertEqual(track.value(from: 5500, travelled: 10000), 50000)
        XCTAssertTrue(track.value(from: 5500, travelled: 10000).isFinite)
    }

    // MARK: - The complaint, measured

    /// Path length in sRGB code values that a neutral travels as the target temperature
    /// sweeps `from`→`to`, against a 5500 K as-shot neutral.
    private func change(from: Double, to: Double, steps: Int = 2000) -> Double {
        let neutral = RGB(0.18, 0.18, 0.18)
        var previous: RGB?
        var total = 0.0
        for i in 0...steps {
            let kelvin = from + (to - from) * Double(i) / Double(steps)
            let engine = WhiteBalanceEngine(asShotKelvin: 5500, asShotTint: 0,
                                            targetKelvin: kelvin, targetTint: 0)
            let code = SliderScaleTests.codeValues(engine.apply(neutral))
            if let previous {
                total += sqrt(pow(code.r - previous.r, 2)
                            + pow(code.g - previous.g, 2)
                            + pow(code.b - previous.b, 2))
            }
            previous = code
        }
        return total
    }

    private static func codeValues(_ c: RGB) -> RGB {
        let xyz = RGBColorSpace.rec2020.toXYZ.apply(c)
        let srgb = RGBColorSpace.srgb.fromXYZ.apply(xyz)
        func encode(_ v: Double) -> Double {
            min(max(TransferFunction.srgb.encode(max(v, 0)), 0), 1) * 255
        }
        return RGB(encode(srgb.r), encode(srgb.g), encode(srgb.b))
    }

    func testTheOwnerWasRightThatTheTopOfTheKelvinSliderDoesNothing() {
        // The complaint, as a number. Above 15000 K is 72.9% of a LINEAR track.
        let low = change(from: 2000, to: 15000)
        let high = change(from: 15000, to: 50000)
        let share = high / (low + high)

        let linearShareOfTrack = linearTempTrack.travelNeeded(from: 15000, to: 50000)
            / linearTempTrack.width
        XCTAssertGreaterThan(linearShareOfTrack, 0.70,
                             "above 15000 K should be most of a linear track")
        XCTAssertLessThan(share, 0.06,
                          "…and it carries almost none of the change: \(share * 100)%")
    }

    func testTheMiredAxisSpendsTravelWhereTheChangeIs() {
        // The fix, as the same number: the share of the TRACK given to a span should
        // match the share of the CHANGE that span carries. That is the whole property
        // a perceptually even axis has, and the linear one misses it by 16×.
        let low = change(from: 2000, to: 15000)
        let high = change(from: 15000, to: 50000)
        let shareOfChange = high / (low + high)

        let shareOfTrack = tempTrack.travelNeeded(from: 15000, to: 50000) / tempTrack.width
        // 0.053 as measured; the linear axis misses by 0.685, so this still
        // discriminates the two by better than 8×.
        XCTAssertEqual(shareOfTrack, shareOfChange, accuracy: 0.08,
                       "mired track share \(shareOfTrack) vs change share \(shareOfChange)")

        let linearShare = linearTempTrack.travelNeeded(from: 15000, to: 50000)
            / linearTempTrack.width
        XCTAssertGreaterThan(abs(linearShare - shareOfChange), 0.60,
                             "the linear axis should be badly mismatched, for contrast")
    }

    func testNoFifthOfTheMiredTrackIsDeadAndOneFifthOfTheLinearOneIs() {
        func shares(_ track: SliderTrack) -> [Double] {
            var out: [Double] = []
            var total = 0.0
            for fifth in 0..<5 {
                let a = track.valueAtPress(x: track.width * Double(fifth) / 5)
                let b = track.valueAtPress(x: track.width * Double(fifth + 1) / 5)
                let d = change(from: a, to: b, steps: 600)
                out.append(d)
                total += d
            }
            return out.map { $0 / total }
        }

        let mired = shares(tempTrack)
        for (index, share) in mired.enumerated() {
            XCTAssertGreaterThan(share, 0.08,
                                 "fifth \(index) of the mired track carries \(share * 100)%")
        }

        let linear = shares(linearTempTrack)
        XCTAssertGreaterThan(linear[0], 0.85, "the linear track's first fifth is the control")
        XCTAssertLessThan(linear[4], 0.01, "…and its last fifth is inert")
    }
}
