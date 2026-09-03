// BrushStabilizerTests.swift
// docs/36 §4 item 24's last piece — the reason a mask painted by hand looks painted by
// hand rather than by a hand that had had too much coffee.
//
// A pointer is not steady, and a brush that follows it exactly records every tremor into
// the stroke, which is then rasterized into the mask's edge at full resolution. The
// wobble is invisible while painting at fit-to-window and obvious at 1:1 — exactly the
// wrong way round. Photoshop and Krita solve it; Lightroom and Capture One do not.
//
// The implementation is a pulled string, and the tests are written against the two
// properties that make a string better than the exponential average everyone reaches for
// first:
//
//   Jitter smaller than the rope does not move the brush AT ALL — not attenuated, not
//   at all, so a held pointer is perfectly still.
//
//   A turn is ROUNDED by the rope rather than cut across it. An average crosses the
//   inside of every corner, which takes a bite out of whatever you were painting round.

import XCTest
@testable import LumenCore

final class BrushStabilizerTests: XCTestCase {

    private func run(_ strength: Double, _ points: [(Double, Double)],
                     finish: Bool = false) -> [(x: Double, y: Double)] {
        var s = BrushStabilizer(strength: strength)
        var out: [(x: Double, y: Double)] = []
        for (x, y) in points {
            if let p = s.next(x: x, y: y) { out.append(p) }
        }
        if finish, let last = points.last, let p = s.finish(x: last.0, y: last.1) {
            out.append(p)
        }
        return out
    }

    /// A straight run with a fine tremor across it — a hand drawing a horizon.
    private func jitteredLine(_ n: Int, amplitude: Double) -> [(Double, Double)] {
        (0..<n).map { i in
            let t = Double(i) / Double(n - 1)
            // Deterministic, and at a frequency well above anything a hand means.
            return (0.1 + t * 0.8, 0.5 + sin(Double(i) * 2.7) * amplitude)
        }
    }

    private func deviation(_ points: [(x: Double, y: Double)]) -> Double {
        points.map { abs($0.y - 0.5) }.max() ?? 0
    }

    // MARK: - Off is off

    func testStrengthZeroIsTheBrushThatShipped() {
        let input = jitteredLine(50, amplitude: 0.004)
        let out = run(0, input)
        XCTAssertEqual(out.count, input.count, "every sample is recorded")
        for (a, b) in zip(out, input) {
            XCTAssertEqual(a.x, b.0, accuracy: 0)
            XCTAssertEqual(a.y, b.1, accuracy: 0)
        }
    }

    func testAStrokeRecordedBeforeThisExistedReplaysIdentically() {
        // The additive-field rule, in gesture form: the default is 0 and 0 is a rigid
        // connection, so nothing about painting changed for anyone who does not turn it
        // on.
        XCTAssertEqual(BrushStabilizer(strength: 0).length, 0, accuracy: 0)
    }

    // MARK: - It removes the tremor

    func testTheWobbleIsGoneAndTheLineIsNot() {
        let input = jitteredLine(200, amplitude: 0.003)
        let raw = run(0, input)
        let smooth = run(60, input)
        XCTAssertGreaterThan(deviation(raw), 0.0029, "the fixture must actually wobble")
        XCTAssertLessThan(deviation(smooth), deviation(raw) / 3,
                          "and the wobble must mostly go")
        XCTAssertGreaterThan(smooth.count, 10, "while still being a stroke")
        // It travelled: a smoother that removed the wobble by removing the stroke would
        // pass everything above.
        let travelled = (smooth.last?.x ?? 0) - (smooth.first?.x ?? 0)
        XCTAssertGreaterThan(travelled, 0.6, "the line still crosses the frame")
    }

    func testAHeldPointerIsPerfectlyStillAndNotMerelyDamped() {
        // The property an exponential average cannot have: inside the rope, nothing
        // moves. A damped brush creeps toward the pointer forever, and a creeping brush
        // keeps depositing flow on a stroke the photographer thinks has stopped.
        var s = BrushStabilizer(strength: 50)
        _ = s.next(x: 0.5, y: 0.5)
        for i in 0..<200 {
            let wobble = sin(Double(i)) * 0.0005
            XCTAssertNil(s.next(x: 0.5 + wobble, y: 0.5 + wobble),
                         "a tremor inside the rope moved the brush")
        }
    }

    // MARK: - It rounds corners rather than cutting them

    func testTheBrushNeverGoesWhereTheHandDidNot() {
        // A right angle. Every stabilized point must lie within the rope of some point
        // the pointer actually visited — which is what "rounds the corner" means and
        // what an average violates by crossing the inside of the turn.
        var input: [(Double, Double)] = []
        for i in 0...100 { input.append((0.2 + Double(i) / 100 * 0.5, 0.3)) }
        for i in 1...100 { input.append((0.7, 0.3 + Double(i) / 100 * 0.5)) }

        let stabilizer = BrushStabilizer(strength: 70)
        let out = run(70, input)
        for p in out {
            let nearest = input.map { hypot(p.x - $0.0, p.y - $0.1) }.min() ?? .infinity
            XCTAssertLessThanOrEqual(nearest, stabilizer.length + 1e-9,
                                     "the brush left the path the hand drew")
        }
    }

    func testItIsAContractionSoItCanNeverOvershoot() {
        // Between any two consecutive samples the brush moves no further than the
        // pointer did. A smoother that can overshoot has a spring in it, and a spring
        // rings after a fast stroke stops.
        var s = BrushStabilizer(strength: 45)
        var previousBrush: (x: Double, y: Double)?
        var previousPointer: (Double, Double)?
        for i in 0..<300 {
            let t = Double(i) / 299
            let point = (0.1 + t * 0.8, 0.5 + sin(t * 19) * 0.2)
            let moved = s.next(x: point.0, y: point.1)
            if let moved, let pb = previousBrush, let pp = previousPointer {
                XCTAssertLessThanOrEqual(hypot(moved.x - pb.x, moved.y - pb.y),
                                         hypot(point.0 - pp.0, point.1 - pp.1) + 1e-12)
            }
            if let moved { previousBrush = moved }
            previousPointer = point
        }
    }

    func testTheBrushIsAlwaysWithinTheRopeOfThePointer() {
        var s = BrushStabilizer(strength: 80)
        var brush: (x: Double, y: Double)?
        for i in 0..<400 {
            let t = Double(i) / 399
            let point = (0.5 + cos(t * 12) * 0.3, 0.5 + sin(t * 7) * 0.3)
            if let moved = s.next(x: point.0, y: point.1) { brush = moved }
            guard let brush else { continue }
            XCTAssertLessThanOrEqual(hypot(brush.x - point.0, brush.y - point.1),
                                     s.length + 1e-9)
        }
    }

    // MARK: - The lag, and paying it back

    func testAStrokeEndsWhereTheHandLetGo() {
        // Without `finish` a stabilized stroke stops one rope short of the release,
        // every time — a systematic error rather than smoothing, and a visible gap on a
        // stroke drawn to meet another one.
        let input = (0...100).map { (0.2 + Double($0) / 100 * 0.6, 0.4) }
        let out = run(90, input, finish: true)
        XCTAssertEqual(out.last?.x ?? 0, 0.8, accuracy: 1e-9)
        XCTAssertEqual(out.last?.y ?? 0, 0.4, accuracy: 1e-9)

        let unfinished = run(90, input)
        XCTAssertLessThan(unfinished.last?.x ?? 1, 0.8,
                          "and it really does stop short without it")
    }

    func testFinishOnAStrokeThatNeverStartedIsNothing() {
        var s = BrushStabilizer(strength: 50)
        XCTAssertNil(s.finish(x: 0.5, y: 0.5))
    }

    func testFinishAtTheBrushesOwnPositionRecordsNoDuplicate() {
        var s = BrushStabilizer(strength: 0)
        _ = s.next(x: 0.3, y: 0.7)
        XCTAssertNil(s.finish(x: 0.3, y: 0.7))
    }

    // MARK: - The slider

    func testTheStrengthCurveIsSquaredSoTheUsefulRangeIsSpread() {
        // A linear slider spends four fifths of its travel where nobody can tell the
        // settings apart: the difference between 0 and 10 is a jittery edge versus a
        // clean one, and 60 versus 70 is two flavours of very smooth.
        let quarter = BrushStabilizer(strength: 25).length
        let half = BrushStabilizer(strength: 50).length
        let full = BrushStabilizer(strength: 100).length
        XCTAssertEqual(full, BrushStabilizer.maxLength, accuracy: 1e-12)
        XCTAssertEqual(half, full * 0.25, accuracy: 1e-12)
        XCTAssertEqual(quarter, full * 0.0625, accuracy: 1e-12)
        XCTAssertLessThan(half, full / 2, "the bottom of the range gets the resolution")
    }

    func testAnAbsurdStrengthIsClampedAndAPoisonedOneIsOff() {
        XCTAssertEqual(BrushStabilizer(strength: 500).length,
                       BrushStabilizer.maxLength, accuracy: 1e-12)
        XCTAssertEqual(BrushStabilizer(strength: -20).length, 0, accuracy: 0)
        XCTAssertEqual(BrushStabilizer(strength: .nan).length, 0, accuracy: 0)
    }

    func testAPoisonedSampleIsDroppedRatherThanRecorded() {
        var s = BrushStabilizer(strength: 40)
        _ = s.next(x: 0.4, y: 0.4)
        XCTAssertNil(s.next(x: .nan, y: 0.5))
        XCTAssertNil(s.next(x: 0.5, y: .infinity))
        // And the stroke carries on from where it was, not from the poison.
        let after = s.next(x: 0.9, y: 0.4)
        XCTAssertNotNil(after)
        XCTAssertTrue((after?.x ?? .nan).isFinite && (after?.y ?? .nan).isFinite)
    }
}
