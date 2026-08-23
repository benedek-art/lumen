// RunningExtremes.swift
//
// Running maxima and minima for the suite's accumulators, which — unlike `Swift.max`
// and `Swift.min` — do not swallow a NaN (TEST-01).
//
// `Swift.max(_:_:)` is `y >= x ? y : x`, and every comparison against a NaN is false.
// So the order the argument sits in decides whether a NaN survives:
//
//     Swift.max(3.0, .nan) == 3.0     <- the shape every accumulator in the suite used
//     Swift.max(.nan, 3.0) == .nan    <- the other order
//
// An accumulator is always written the first way — `worst = Swift.max(worst, measured)`
// — so it stepped silently over every non-finite pixel in a frame, and the bound
// assertion it feeds then passed on a render that had produced nothing but NaN. A check
// that cannot fail, hiding inside the checks. It was found by an agent removing a clamp
// to prove one of its own new tests could go red, and watching the test stay green.
//
// These two propagate instead, which is all the fix needs to be: `XCTAssertLessThan`
// then fails on its own, because `NaN < bar` is false, and so does
// `XCTAssertGreaterThan`, because `NaN > floor` is false too. The assertion that was
// already written becomes the one that catches it, rather than a second assertion
// bolted on beside it.
//
// NOT for clamps. `Swift.max(x, 0)` is a floor, its result is not what an assertion
// reads, and it already propagates a NaN because the value sits in the first position.
// Those are left exactly as they are.

import Foundation
import XCTest

/// Running maximum that reports a NaN instead of stepping over it.
///
/// Returns NaN if either side is NaN — the accumulator too, so that once a non-finite
/// measurement has been seen no later finite one can bury it.
func runningMax(_ accumulator: Double, _ measured: Double) -> Double {
    if accumulator.isNaN || measured.isNaN { return .nan }
    return Swift.max(accumulator, measured)
}

/// Running minimum with the same property. Needed wherever a swing or a span is read
/// off a pair: with both left at their sentinels `hi - lo` comes out NEGATIVE, and an
/// outer running maximum then reports the span as zero — a *smaller* number than the
/// truth, which passes an upper bound instead of failing it.
func runningMin(_ accumulator: Double, _ measured: Double) -> Double {
    if accumulator.isNaN || measured.isNaN { return .nan }
    return Swift.min(accumulator, measured)
}

/// The helper's own proof. Every assertion here was watched failing before it was
/// believed: substituting `Swift.max`/`Swift.min` back into the helper turns the NaN
/// assertions red, and the standard-library assertions are that substituted behaviour
/// pinned, so nobody can simplify the helper back into the defect.
final class RunningExtremesTests: XCTestCase {

    /// The defect itself, measured rather than argued from the standard library's
    /// source: which argument position a NaN has to sit in to survive.
    func testTheStandardLibraryExtremesSwallowANaNInTheAccumulatorOrder() {
        XCTAssertEqual(Swift.max(3.0, Double.nan), 3.0,
                       "max(accumulator, measured) is the shape every accumulator uses")
        XCTAssertTrue(Swift.max(Double.nan, 3.0).isNaN, "the other order propagates")
        XCTAssertEqual(Swift.min(3.0, Double.nan), 3.0)
        XCTAssertTrue(Swift.min(Double.nan, 3.0).isNaN)
    }

    func testARunningExtremeReportsANaNRatherThanSteppingOverIt() {
        XCTAssertTrue(runningMax(3.0, .nan).isNaN)
        XCTAssertTrue(runningMax(.nan, 3.0).isNaN)
        XCTAssertTrue(runningMin(3.0, .nan).isNaN)
        XCTAssertTrue(runningMin(.nan, 3.0).isNaN)
        // Once a non-finite measurement has been seen, no later finite one may bury it.
        XCTAssertTrue(runningMax(runningMax(0, .nan), 7).isNaN)
        XCTAssertTrue(runningMin(runningMin(9, .nan), 7).isNaN)
        // And nothing else about a running extreme changes.
        XCTAssertEqual(runningMax(3, 7), 7)
        XCTAssertEqual(runningMax(7, 3), 7)
        XCTAssertEqual(runningMin(3, 7), 3)
        XCTAssertEqual(runningMin(7, 3), 3)
    }

    /// The consequence, which is the whole reason the helper exists: a bound fed by a
    /// running maximum can no longer pass on a frame that produced a NaN, in either
    /// direction. `NaN < bar` is false and `NaN > floor` is false, so the assertion
    /// that was already written is the one that catches it.
    func testABoundFedByARunningMaximumCanNoLongerPassOnANaN() {
        var worst = 0.0
        for measured in [0.1, Double.nan, 0.2] { worst = runningMax(worst, measured) }
        XCTAssertFalse(worst < 1.0,
                       "an upper bound on \(worst) still passes — the accumulator "
                           + "stepped over the non-finite measurement")
        XCTAssertFalse(worst > 0.0,
                       "a lower bound on \(worst) still passes — the accumulator "
                           + "stepped over the non-finite measurement")
    }

    /// A span read off a pair of sentinels is the second shape, and it fails the other
    /// way: with the standard-library extremes both sentinels survive a plane that is
    /// entirely non-finite, and `hi - lo` comes out NEGATIVE — which passes every upper
    /// bound in the suite rather than failing one.
    func testASpanReadOffTwoSentinelsCanNoLongerPassOnANaN() {
        var lo = Double.infinity, hi = -Double.infinity
        for measured in [Double.nan, .nan, .nan] {
            lo = runningMin(lo, measured)
            hi = runningMax(hi, measured)
        }
        XCTAssertFalse(hi - lo < 1.0,
                       "a span of \(hi - lo) passes an upper bound on a plane that is "
                           + "entirely non-finite")
    }
}
