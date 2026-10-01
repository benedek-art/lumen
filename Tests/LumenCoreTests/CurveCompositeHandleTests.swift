// CurveCompositeHandleTests.swift
// AI-05: the Point graph draws the MASTER curve — parametric first, then the points —
// because that is what the pipeline applies. A point is stored on the point curve's
// own input axis, which is the parametric curve's output. With a parametric slider off
// zero those axes differ, and the handles were drawn at their raw stored coordinates:
// Lights 50, point (.6, .7), and the trace under the handle was at .7565 — 17 px off
// on a 300 px plot, 32 px at Lights 100.
//
// The contract: a handle is drawn at `compositeHandles`, which lies ON the drawn trace;
// a press at a graph x stores the point at `pointInput(atCompositeX:)`, so the curve
// passes through where the hand put it.

import XCTest
@testable import LumenCore

final class CurveCompositeHandleTests: XCTestCase {

    private let plotPixels = 300.0

    private func stack(_ parametric: ParametricCurve,
                       _ points: [[Double]] = [[0, 0], [0.6, 0.7], [1, 1]]) -> CurveStack {
        CurveStack(CurveSet(parametric: parametric, point: points))
    }

    private var parametricSettings: [ParametricCurve] {
        [ParametricCurve(lights: 50), ParametricCurve(lights: 100),
         ParametricCurve(highlights: -80, darks: 40),
         ParametricCurve(darks: -100, shadows: 100),     // the limiter's plateau case
         ParametricCurve(highlights: 30, lights: -60, darks: 70, shadows: -20,
                         splits: [0.15, 0.4, 0.8])]
    }

    /// THE FINDING. Every drawn handle is on the drawn trace.
    func testEveryHandleLiesOnTheDisplayedCompositeTrace() {
        let shapes: [[[Double]]] = [
            [[0, 0], [0.6, 0.7], [1, 1]],
            [[0, 0.05], [0.2, 0.1], [0.45, 0.5], [0.8, 0.92], [1, 0.97]],
        ]
        var failures: [String] = []
        for parametric in parametricSettings {
            for points in shapes {
                let s = stack(parametric, points)
                let handles = s.compositeHandles(points)
                XCTAssertEqual(handles.count, points.count)
                for (h, p) in zip(handles, points) {
                    XCTAssertEqual(h[1], p[1], "a handle's height is the stored output")
                    let gap = abs(s.master(h[0]) - h[1]) * plotPixels
                    if gap > 0.01 {
                        failures.append("\(parametric) point \(p): handle at \(h) is "
                                        + "\(gap) px off the trace (\(s.master(h[0])))")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures.count) failures: \(failures)")
    }

    /// The premise of the test above: with Lights 50 the raw stored point is NOT on the
    /// trace, by the audit's own number, so a pass-through `compositeHandles` would fail.
    func testTheRawStoredPointIsOffTheTraceUnderLights() {
        let s = stack(ParametricCurve(lights: 50))
        XCTAssertGreaterThan(abs(s.master(0.6) - 0.7) * plotPixels, 10)
    }

    /// A press at graph (X, Y) stores a point the curve then passes through AT X.
    func testAPointPlacedOnTheGraphLandsWhereTheHandPutIt() {
        var failures: [String] = []
        for parametric in parametricSettings {
            let base = stack(parametric, [[0, 0], [1, 1]])
            for (X, Y) in [(0.3, 0.45), (0.6, 0.55), (0.82, 0.9)] {
                let stored = CurveStack.settingPoint([[0, 0], [1, 1]],
                                                     x: base.pointInput(atCompositeX: X),
                                                     y: Y)
                let after = stack(parametric, stored)
                let gap = abs(after.master(X) - Y) * plotPixels
                if gap > 0.01 {
                    failures.append("\(parametric): placed at (\(X), \(Y)), the curve "
                                    + "passes \(after.master(X)) there")
                }
                // and the handle drawn for it is under the pointer
                let index = CurveEditing.nearestIndexByX(stored,
                                                         x: base.pointInput(atCompositeX: X))!
                let drawn = after.compositeHandles(stored)[index]
                if abs(drawn[0] - X) * plotPixels > 0.01 {
                    failures.append("\(parametric): placed at x \(X), drawn at \(drawn[0])")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, "\(failures)")
    }

    /// The two maps are inverse wherever the parametric curve is strictly rising, and
    /// the composite x is monotone in the stored x — the handles keep their order.
    func testTheTwoAxesMapOntoEachOther() {
        for parametric in parametricSettings {
            let s = stack(parametric)
            var previous = -1.0
            for i in 0...200 {
                let u = Double(i) / 200
                let x = s.compositeX(atPointInput: u)
                XCTAssertGreaterThanOrEqual(x, previous, "\(parametric) at \(u)")
                previous = x
                XCTAssertEqual(s.pointInput(atCompositeX: x), u, accuracy: 1e-9,
                               "\(parametric): u \(u) -> x \(x) -> "
                               + "\(s.pointInput(atCompositeX: x))")
            }
            XCTAssertEqual(s.compositeX(atPointInput: 0), 0, accuracy: 1e-12)
            XCTAssertEqual(s.compositeX(atPointInput: 1), 1, accuracy: 1e-12)
        }
    }

    /// No parametric edit, no change: the handles are the stored points exactly.
    func testWithoutAParametricEditTheHandlesAreTheStoredPoints() {
        let points: [[Double]] = [[0, 0], [0.25, 0.3], [0.6, 0.7], [1, 1], [0.5]]
        let s = stack(ParametricCurve(), points)
        XCTAssertEqual(s.compositeHandles(points), points)
        XCTAssertEqual(s.pointInput(atCompositeX: 0.37), 0.37)
    }

    /// A malformed row stays where it is, so handle indices still name stored points.
    func testAMalformedRowKeepsItsIndex() {
        let points: [[Double]] = [[0, 0], [0.5], [1, 1]]
        let handles = stack(ParametricCurve(lights: 50), points).compositeHandles(points)
        XCTAssertEqual(handles.count, 3)
        XCTAssertEqual(handles[1], [0.5])
    }

    /// The target-adjustment drag is the same gesture pointed at the image: a nudge at
    /// picture input x must move the curve AT x.
    func testATargetedNudgeMovesTheCurveAtThePictureInputItWasAimedAt() {
        for parametric in parametricSettings {
            let s = stack(parametric, [[0, 0], [1, 1]])
            let x = 0.4
            let before = s.master(x)
            let after = stack(parametric, s.nudged(at: x, by: 0.1))
            XCTAssertEqual(after.master(x), Num.saturate(before + 0.1), accuracy: 1e-9,
                           "\(parametric): nudging at \(x) moved the curve somewhere else")
        }
    }
}
