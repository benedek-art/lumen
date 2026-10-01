// CurveAdversarialTests.swift
// Attempts to REFUTE the tone-curve editing invariants: that the black and white
// anchors cannot be lost, that a moved point always leaves a strictly increasing x
// list, that a group move is a rigid reversible translation, and that sanitising a
// curve is a fixed point.
//
// Every test here was written to fail. The ones that do are defects.

import XCTest
@testable import LumenCore

final class CurveAdversarialTests: XCTestCase {

    // MARK: - deleting: can any input remove an end point?

    /// Empty, one point, two, three, and every index in a wide band around range.
    func testDeletingNeverRemovesAnEndPointForAnyShapeOrIndex() {
        let shapes: [[[Double]]] = [
            [],
            [[0, 0]],
            [[0, 0], [1, 1]],
            [[0, 0], [0.5, 0.5], [1, 1]],
            [[0, 0], [0.25, 0.3], [0.5, 0.5], [0.75, 0.7], [1, 1]],
            // duplicate x on both ends
            [[0, 0], [0, 0.4], [0.5, 0.5], [1, 0.6], [1, 1]],
            // a curve whose first and last are the same coordinate
            [[0.5, 0.5], [0.5, 0.5]],
            // malformed rows mixed in
            [[0, 0], [0.5], [1, 1]]
        ]
        for points in shapes {
            for index in -4...(points.count + 4) {
                guard let out = CurveEditing.deleting(points, at: index) else { continue }
                XCTAssertEqual(out.count, points.count - 1,
                               "deleting removed \(points.count - out.count) at \(index)")
                XCTAssertEqual(out.first ?? [], points.first ?? [],
                               "first point changed deleting index \(index) of \(points)")
                XCTAssertEqual(out.last ?? [], points.last ?? [],
                               "last point changed deleting index \(index) of \(points)")
            }
        }
    }

    /// A one-point curve, and a zero-point curve, must have nothing deletable at all.
    func testDegenerateCurvesHaveNothingDeletable() {
        for count in 0...2 {
            for index in -2...(count + 2) {
                XCTAssertFalse(CurveEditing.isDeletable(index: index, count: count),
                               "index \(index) deletable in a \(count)-point curve")
            }
        }
    }

    /// Out-of-range indices must not trap and must not delete.
    func testDeletingOutOfRangeIndexIsRefusedNotTrapped() {
        let points: [[Double]] = [[0, 0], [0.5, 0.5], [1, 1]]
        XCTAssertNil(CurveEditing.deleting(points, at: Int.max))
        XCTAssertNil(CurveEditing.deleting(points, at: Int.min))
        XCTAssertNil(CurveEditing.deleting(points, at: 3))
        XCTAssertNil(CurveEditing.deleting(points, at: -1))
    }

    // MARK: - the gap clamp

    /// After ANY single move of ANY index on a strictly increasing list, the list is
    /// still strictly increasing — which is the property that stops `MonotoneCubic`
    /// silently dropping a point.
    func testAMoveNeverProducesAListMonotoneCubicWouldDropAPointFrom() {
        var rng = SplitMix64(seed: 0x9E3779B97F4A7C15)
        var failures: [String] = []
        for _ in 0..<20000 {
            let n = 2 + Int(rng.next() % 6)
            var xs: [Double] = []
            for _ in 0..<n { xs.append(Double(rng.next() % 1_000_001) / 1_000_000.0) }
            xs.sort()
            // strictly increasing input only — that is the editor's own precondition
            var strict = true
            for i in 1..<xs.count where !(xs[i] > xs[i - 1]) { strict = false }
            guard strict else { continue }
            let points = xs.map { [$0, Double(rng.next() % 1001) / 1000.0] }
            let index = Int(rng.next() % UInt64(n))
            let targets: [Double] = [
                -5, 0, 1, 5,
                Double(rng.next() % 1_000_001) / 1_000_000.0,
                index > 0 ? xs[index - 1] : 0,
                index < n - 1 ? xs[index + 1] : 1,
                index > 0 ? xs[index - 1] + CurveEditing.minimumPointGap : 0,
                index < n - 1 ? xs[index + 1] - CurveEditing.minimumPointGap : 1,
                index > 0 ? xs[index - 1].nextUp : 0,
                index < n - 1 ? xs[index + 1].nextDown : 1
            ]
            for t in targets {
                let out = CurveEditing.moved(points, index: index, toX: t, toY: 0.5)
                for i in 1..<out.count where !(out[i][0] > out[i - 1][0]) {
                    failures.append("moved(\(points), index: \(index), toX: \(t)) -> \(out)")
                }
                let curve = MonotoneCubic(points: out)
                if curve.xs.count != out.count {
                    failures.append("MonotoneCubic dropped \(out.count - curve.xs.count) "
                                    + "of \(out.count) from \(out) "
                                    + "[moved index \(index) toX \(t)]")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) failures, first: \(failures.first ?? "")")
    }

    /// Squeezed from both sides at once: drive the left point as far right as it goes,
    /// then the right point as far left as it goes, and repeat. The pair must never
    /// touch, and a "move left" must never come out to the RIGHT of where the point was.
    func testSqueezingAPairFromBothSidesNeitherTouchesNorMovesTheWrongWay() {
        var failures: [String] = []
        for seedX in stride(from: 0.0, through: 0.99, by: 0.0137) {
            var points: [[Double]] = [[0, 0], [seedX, 0.4],
                                      [Swift.min(seedX + 0.01, 0.99), 0.6], [1, 1]]
            for round in 0..<6 {
                points = CurveEditing.moved(points, index: 1, toX: 1, toY: 0.4)
                points = CurveEditing.moved(points, index: 2, toX: 0, toY: 0.6)
                for i in 1..<points.count where !(points[i][0] > points[i - 1][0]) {
                    failures.append("order lost at seed \(seedX) round \(round): \(points)")
                }
                let gap = points[2][0] - points[1][0]
                if !(gap > 0) {
                    failures.append("pair collided at seed \(seedX) round \(round): \(points)")
                }
                if MonotoneCubic(points: points).xs.count != points.count {
                    failures.append("point dropped at seed \(seedX) round \(round): \(points)")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) failures, first: \(failures.first ?? "")")
    }

    /// Exactly `minimumPointGap` from a neighbour, and one ulp inside it.
    func testTargetsAtExactlyTheGapAndOneUlpInsideIt() {
        let points: [[Double]] = [[0, 0], [0.4, 0.4], [0.8, 0.8], [1, 1]]
        let gap = CurveEditing.minimumPointGap

        let atGapBelow = CurveEditing.clampedX(points, moving: 1, toX: 0.8 - gap)
        XCTAssertEqual(atGapBelow, 0.8 - gap, accuracy: 0,
                       "a target exactly at the gap was altered")
        let insideGap = CurveEditing.clampedX(points, moving: 1, toX: (0.8 - gap).nextUp)
        XCTAssertLessThanOrEqual(insideGap, 0.8 - gap,
                                 "one ulp inside the gap was not pulled back")
        XCTAssertLessThan(insideGap, 0.8, "clamped x reached its neighbour")

        let atGapAbove = CurveEditing.clampedX(points, moving: 2, toX: 0.4 + gap)
        XCTAssertEqual(atGapAbove, 0.4 + gap, accuracy: 0)
        let insideGapAbove = CurveEditing.clampedX(points, moving: 2, toX: (0.4 + gap).nextDown)
        XCTAssertGreaterThanOrEqual(insideGapAbove, 0.4 + gap)
        XCTAssertGreaterThan(insideGapAbove, 0.4)
    }

    /// The window between neighbours SMALLER than the gap: the move must be refused in
    /// x, and — this is the part that would still lose shadows — the list it hands back
    /// must not be one `MonotoneCubic` will drop a point from.
    func testACollapsedWindowRefusesInXAndStillFeedsMonotoneCubicEveryPoint() {
        // neighbours 0.005 apart: less than 2 * 0.004, so index 1's window is inverted
        let points: [[Double]] = [[0.30, 0.2], [0.3025, 0.4], [0.305, 0.6], [1, 1]]
        XCTAssertLessThan(points[2][0] - points[0][0],
                          2 * CurveEditing.minimumPointGap,
                          "test premise: the window must be collapsed")
        for target in [-1.0, 0.0, 0.3, 0.3025, 0.305, 0.5, 1.0, 2.0] {
            let out = CurveEditing.moved(points, index: 1, toX: target, toY: 0.9)
            XCTAssertEqual(out[1][0], points[1][0], accuracy: 0,
                           "collapsed window let x move to \(target)")
            XCTAssertEqual(out[1][1], 0.9, accuracy: 1e-15, "y should still move")
            XCTAssertEqual(MonotoneCubic(points: out).xs.count, out.count,
                           "MonotoneCubic dropped a point from \(out)")
        }
    }

    // MARK: - sanitized as the repair point

    /// Sanitising twice must land on the same list. With duplicate x it is sorting an
    /// array that already has ties, and `Array.sort` is not stable.
    func testSanitizingIsAFixedPoint() {
        var rng = SplitMix64(seed: 0xDEADBEEFCAFEF00D)
        var failures: [String] = []
        for _ in 0..<5000 {
            let n = 2 + Int(rng.next() % 10)
            var raw: [[Double]] = []
            for _ in 0..<n {
                // draw x from a tiny alphabet so ties are common
                let x = Double(rng.next() % 4) / 3.0
                let y = Double(rng.next() % 1001) / 1000.0
                raw.append([x, y])
            }
            let once = CurveEditing.sanitized(raw)
            let twice = CurveEditing.sanitized(once)
            if once != twice {
                failures.append("sanitized(\(raw)) = \(once) but again = \(twice)")
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) failures, first: \(failures.first ?? "")")
    }

    /// A sanitised curve is the one thing the editor ever indexes. If it can still
    /// contain a duplicate x, the editor draws N points while the render uses fewer —
    /// and two points at one x collapse the whole image to a constant.
    func testSanitizedNeverHandsBackACurveMonotoneCubicWillShrink() {
        let hostile: [[[Double]]] = [
            [[0.5, 0.1], [0.5, 0.9]],
            [[0, 0], [0.3, 0.0], [0.3, 0.95], [1, 1]],
            [[0, 0], [0, 0.9], [1, 1]],
            [[2, 2], [3, 3]],                       // both clamp to 1
            [[-1, 0.2], [-5, 0.8], [1, 1]]          // both clamp to 0
        ]
        for raw in hostile {
            let clean = CurveEditing.sanitized(raw)
            let curve = MonotoneCubic(points: clean)
            XCTAssertEqual(curve.xs.count, clean.count,
                           "sanitized(\(raw)) = \(clean); MonotoneCubic keeps "
                           + "\(curve.xs.count) of \(clean.count)")
        }
    }

    /// The specific catastrophe: a two-point curve at one x makes MonotoneCubic
    /// constant, so every pixel in the picture renders one value.
    func testTwoPointsAtOneXFlattenTheEntirePicture() {
        let clean = CurveEditing.sanitized([[0.5, 0.1], [0.5, 0.9]])
        let curve = MonotoneCubic(points: clean)
        let lut = curve.bakeLUT(size: 64)
        XCTAssertFalse(lut.allSatisfy { abs($0 - lut[0]) < 1e-12 },
                       "sanitized produced \(clean), which bakes to the constant "
                       + "\(lut[0]) at every one of 64 samples")
    }

    /// `isIdentity` must be true for exactly what `identity` produces, and false for
    /// everything that renders differently.
    func testIsIdentityIsTrueForExactlyTheIdentity() {
        XCTAssertTrue(CurveEditing.isIdentity(CurveEditing.identity))
        XCTAssertTrue(CurveEditing.isIdentity(CurveEditing.sanitized(nil)))
        XCTAssertTrue(CurveEditing.isIdentity(CurveEditing.sanitized([])))
        let notIdentity: [[[Double]]] = [
            [[0, 0], [0.5, 0.5], [1, 1]],
            [[0, 0], [1, 0.999]],
            [[0.001, 0], [1, 1]],
            [[0, 0], [1, 1], [1, 1]],
            [[1, 1], [0, 0]]
        ]
        for points in notIdentity {
            XCTAssertFalse(CurveEditing.isIdentity(points),
                           "\(points) reported as the identity")
        }
        // and the one that matters: a curve isIdentity calls identity must render as
        // the identity, since the editor stores it as nil.
        for points in notIdentity where CurveEditing.isIdentity(points) {
            let curve = MonotoneCubic(points: points)
            for i in 0...20 {
                let x = Double(i) / 20
                XCTAssertEqual(curve.evaluate(x), x, accuracy: 1e-12)
            }
        }
    }

    // MARK: - GroupMove

    // S-06 — what these assert, and what they deliberately do not.
    //
    // They used to demand a group move be BIT-EXACT: a round trip returning the same
    // doubles, every member shifted by the identical double. IEEE 754 cannot do that in
    // general (`v + d − d` is not `v`), and the measured miss is a few ulps of a ±100
    // slider — ≈1e−14, against a 0.05 display step. Demanding it would mislabel
    // round-off as an image error. The contract `GroupMove.moved` states instead:
    //
    //   · from a legal set, a move is rigid and reversible to 1e-12 — which still fails
    //     loudly on any real squeeze (the old per-band clamp missed by 50 units, a rail
    //     clipping one member misses by at least the 0.01 grid these sets live on);
    //   · zero is the one value where an ulp is visible — the Reset dot lights on
    //     `!= 0` — so zero comes home EXACTLY;
    //   · an illegal set (out of range, non-finite) is made legal on first touch,
    //     coherently with what the row displays, and from then on is an ordinary set.

    /// To a rail and back restores the set: within round-off everywhere, exactly at 0.
    func testGroupMoveToARailAndBackRestoresTheSet() {
        var rng = SplitMix64(seed: 0x0123456789ABCDEF)
        var failures: [String] = []
        for _ in 0..<20000 {
            let n = 1 + Int(rng.next() % 8)
            var values: [Double] = []
            for _ in 0..<n {
                values.append(Double(Int(rng.next() % 20001) - 10000) / 100.0)  // -100…100
            }
            for request in [200.0, -200.0, 37.5, -37.5, 1e9, -1e9] {
                let applied = GroupMove.allowed(values, requested: request,
                                                lower: -100, upper: 100)
                let out = GroupMove.moved(values, by: request, lower: -100, upper: 100)
                let back = GroupMove.moved(out, by: -applied, lower: -100, upper: 100)
                for i in values.indices {
                    let err = abs(back[i] - values[i])
                    if err > 1e-12 || (values[i] == 0 && back[i] != 0) {
                        failures.append("round trip off by \(err): \(values[i]) -> "
                                        + "\(back[i]) [\(values) by \(request), "
                                        + "applied \(applied)]")
                    }
                }
                // rigid: every member moved by the same amount
                for i in values.indices
                where abs((out[i] - values[i]) - (out[0] - values[0])) > 1e-12 {
                    failures.append("not rigid: \(values) by \(request) -> \(out)")
                    break
                }
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) failures, first: \(failures.first ?? "")")
    }

    /// Rigidity on its own, for values that start inside the rails: every pairwise
    /// difference survives a group move to round-off.
    func testGroupMoveIsRigidForEveryInRangeSet() {
        var rng = SplitMix64(seed: 0x5EED5EED5EED5EED)
        var failures: [String] = []
        for _ in 0..<200000 {
            let n = 1 + Int(rng.next() % 8)
            var values: [Double] = []
            for _ in 0..<n {
                values.append(Double(Int(rng.next() % 20001) - 10000) / 100.0)
            }
            let request = Double(Int(rng.next() % 100001) - 50000) / 100.0
            let out = GroupMove.moved(values, by: request, lower: -100, upper: 100)
            let shift = out[0] - values[0]
            for i in values.indices where abs((out[i] - values[i]) - shift) > 1e-12 {
                failures.append("\(values) by \(request) -> \(out): member \(i) "
                                + "shifted \(out[i] - values[i]) not \(shift)")
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) failures, first: \(failures.first ?? "")")
    }

    /// The mixer's Reset dot lights on `!= 0`. A band that starts at exactly 0 and is
    /// dragged out and back must come home to exactly 0, or the panel reports the photo
    /// as modified for the rest of its life. This one stays EXACT: it is the case the
    /// audit measured coming home as −7.1e−15.
    func testAZeroBandComesHomeToExactlyZero() {
        var rng = SplitMix64(seed: 0x1BADB0021BADB002)
        var worst = 0.0
        var witness = ""
        for _ in 0..<200000 {
            var values: [Double] = [0]
            for _ in 0..<7 {
                values.append(Double(Int(rng.next() % 20001) - 10000) / 100.0)
            }
            let request = Double(Int(rng.next() % 40001) - 20000) / 100.0
            let applied = GroupMove.allowed(values, requested: request,
                                            lower: -100, upper: 100)
            let out = GroupMove.moved(values, by: request, lower: -100, upper: 100)
            let back = GroupMove.moved(out, by: -applied, lower: -100, upper: 100)
            if back[0] != 0 && abs(back[0]) >= worst {
                worst = abs(back[0])
                witness = "0 came back as \(back[0]) after \(values) by \(request)"
            }
        }
        XCTAssertEqual(worst, 0, "\(witness)")
    }

    /// A set that already touches the ceiling cannot move up at all, and moving down
    /// then up must return it exactly.
    func testASetAlreadyAtTheCeiling() {
        let values: [Double] = [100, 20, -30, 100]
        XCTAssertEqual(GroupMove.allowed(values, requested: 5, lower: -100, upper: 100), 0)
        XCTAssertEqual(GroupMove.moved(values, by: 5, lower: -100, upper: 100), values)
        let down = GroupMove.moved(values, by: -60, lower: -100, upper: 100)
        XCTAssertEqual(down, [40, -40, -90, 40])
        XCTAssertEqual(GroupMove.moved(down, by: 60, lower: -100, upper: 100), values)
    }

    /// A member already outside the range — only a foreign sidecar can write one. The
    /// first touch clamps it to its rail (what the row then shows), and from there the
    /// move is an ordinary rigid, reversible translation.
    func testGroupMoveOnValuesOutsideTheRange() {
        let values: [Double] = [150, 0]
        let legal = GroupMove.legal(values, lower: -100, upper: 100)
        XCTAssertEqual(legal, [100, 0], "out of range is clamped to the rail")
        let down = GroupMove.moved(values, by: -10, lower: -100, upper: 100)
        XCTAssertEqual(down[0] - down[1], legal[0] - legal[1], accuracy: 1e-12,
                       "moved(\(values), by: -10) = \(down): the spread of the set the "
                       + "row shows changed from \(legal[0] - legal[1]) to "
                       + "\(down[0] - down[1])")
        XCTAssertEqual(GroupMove.mean(down), GroupMove.mean(legal) - 10, accuracy: 1e-12,
                       "the row's number did not move by what the drag asked")
        let back = GroupMove.moved(down, by: 10, lower: -100, upper: 100)
        XCTAssertEqual(back, legal, "\(legal) -> \(down) -> \(back) is not reversible")
    }

    /// A spread wider than the range, straddling both rails: the first touch brings it
    /// into range — not left outside it with every drag silently refused. Once legal
    /// its spread IS the range, so it has nowhere to translate, which is true of the
    /// legal set `[-100, 100]` too.
    func testGroupMoveOnASpreadWiderThanTheRange() {
        let values: [Double] = [-150, 150]
        for request in [10.0, -10.0] {
            let out = GroupMove.moved(values, by: request, lower: -100, upper: 100)
            XCTAssertEqual(out, [-100, 100],
                           "\(values) by \(request) -> \(out): an out-of-range set must "
                           + "come back legal, not untouched")
        }
    }

    /// `mean` is what the row DISPLAYS and `moved` is what the row DOES. They must agree
    /// about which sets are live: a set the row shows a number for must be draggable,
    /// and the drag must move that number by what was asked. NaN is latent — JSON
    /// cannot carry it and the recipe decoder refuses it (below) — but the two halves
    /// read it the same way regardless.
    func testMeanAndMovedAgreeAboutWhichSetsAreLive() {
        let withNaN: [Double] = [10, Double.nan, -10, 0, 0, 0, 0, 0]
        let shown = GroupMove.mean(withNaN)
        XCTAssertTrue(shown.isFinite, "premise: the row displays \(shown)")
        XCTAssertEqual(GroupMove.mean(GroupMove.legal(withNaN, lower: -100, upper: 100)),
                       shown, "the row's number is the legal set's mean")
        let moved = GroupMove.moved(withNaN, by: 5, lower: -100, upper: 100)
        let headroom = GroupMove.allowed(withNaN, requested: 5, lower: -100, upper: 100)
        XCTAssertTrue(moved.allSatisfy(\.isFinite),
                      "the row displays \(shown) but the drag kept a NaN: \(moved)")
        XCTAssertEqual(GroupMove.mean(moved), shown + 5, accuracy: 1e-12,
                       "the row displays \(shown) but the drag did not move it by 5: "
                       + "\(moved), allowed() on the raw set = \(headroom)")
    }

    /// NaN is refused where it would enter: the recipe decoder. A sidecar carrying one
    /// in a mixer band does not decode, while the same document with a number does —
    /// so the refusal is about the NaN, not the shape.
    func testANaNMixerBandIsRefusedOnDecode() throws {
        func json(_ hue: String) -> Data {
            Data("{\"develop\":{\"mixer\":{\"bands\":[{\"hue\":\(hue),\"sat\":0,\"lum\":0}]}}}"
                .utf8)
        }
        let ok = try CanonicalJSON.decodeRecipe(from: json("12.5"))
        XCTAssertEqual(ok.develop.mixer.bands.first?.hue, 12.5, "premise: the shape decodes")
        for poison in ["NaN", "nan", "Infinity", "-Infinity", "1e400"] {
            XCTAssertThrowsError(try CanonicalJSON.decodeRecipe(from: json(poison)),
                                 "a mixer band of \(poison) decoded")
        }
    }

    func testMeanOnAnEmptySetAndAnAllNaNSet() {
        XCTAssertEqual(GroupMove.mean([]), 0)
        XCTAssertEqual(GroupMove.mean([Double.nan, Double.nan]), 0)
        XCTAssertEqual(GroupMove.mean([Double.infinity, 2]), 1, accuracy: 1e-12)
        XCTAssertEqual(GroupMove.allowed([], requested: 5, lower: -100, upper: 100), 0)
        XCTAssertEqual(GroupMove.moved([], by: 5, lower: -100, upper: 100), [])
    }

    /// An inverted range must not invent headroom.
    func testGroupMoveWithAnInvertedOrEmptyRange() {
        XCTAssertEqual(GroupMove.allowed([0, 1], requested: 5, lower: 100, upper: -100), 0)
        XCTAssertEqual(GroupMove.moved([0, 1], by: 5, lower: 100, upper: -100), [0, 1])
        // a degenerate range: everything is pinned to the single legal value
        XCTAssertEqual(GroupMove.allowed([5, 5], requested: 1, lower: 5, upper: 5), 0)
    }

    // MARK: - the undo key

    /// Two different points of one channel, inside the coalescing window, must be two
    /// undo steps. Place-then-drag of the SAME point must be one.
    func testTheUndoKeySeparatesTwoPointsAndJoinsOneDrag() {
        let url = Set([URL(fileURLWithPath: "/photo.dng")])
        let placed = CurveEditing.pointCoalescingKey(prefix: "curve.", channel: "point",
                                                     index: 1)
        let other = CurveEditing.pointCoalescingKey(prefix: "curve.", channel: "point",
                                                    index: 2)
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: placed, openURLs: url, key: other, urls: url,
            sinceLastEdit: 0.05, window: 1.2),
            "two different points folded into one undo step")
        XCTAssertTrue(HistoryCoalescing.shouldCoalesce(
            openKey: placed, openURLs: url, key: placed, urls: url,
            sinceLastEdit: 0.05, window: 1.2),
            "place-then-drag of one point did not stay one undo step")
    }

    /// Two SEPARATE deletions landing on the same index must not fold into one step —
    /// the same defect class the point key was split to fix (S-05). The editor keyed a
    /// deletion `<prefix>delete.<channel>.<index>`, so deleting index 1 twice removed
    /// two different points under one key.
    ///
    /// Replayed as the editor does it: `CurveEditing.deleting` makes each edit, each
    /// records under `CurveEditing.deletionCoalescingKey` — the constant the editor
    /// passes — and the fold decision is `HistoryCoalescing`, the rule `HistoryStack`
    /// calls. Each ⌥-click is its own gesture, so the epochs differ. The stack itself
    /// is macOS-only; `CurveDeletionHistoryTests` drives it there with undo.
    func testTwoDeletionsAtOneIndexAreTwoUndoSteps() {
        let url = Set([URL(fileURLWithPath: "/photo.dng")])
        var curve: [[Double]] = [[0, 0], [0.25, 0.2], [0.5, 0.55], [0.75, 0.8], [1, 1]]
        var steps: [(key: String?, epoch: Int, after: [[Double]])] = []
        for epoch in [7, 8] {
            guard let next = CurveEditing.deleting(curve, at: 1) else {
                return XCTFail("index 1 of \(curve) is deletable")
            }
            if let open = steps.last,
               HistoryCoalescing.shouldCoalesce(
                   openKey: open.key, openURLs: url,
                   key: CurveEditing.deletionCoalescingKey, urls: url,
                   sinceLastEdit: 0.3, window: 1.2,
                   openEpoch: open.epoch, epoch: epoch) {
                steps[steps.count - 1].after = next
            } else {
                steps.append((CurveEditing.deletionCoalescingKey, epoch, next))
            }
            curve = next
        }
        XCTAssertEqual(steps.count, 2,
                       "two ⌥-clicks removing two different points folded into ONE "
                       + "undo step")
        XCTAssertEqual(steps.first?.after.count, 4, "one undo must bring back one point")
    }

    /// A deletion is discrete, but the drag-out that ends in one is still ONE gesture:
    /// sharing the drag's epoch folds the deletion into that drag's step.
    func testADragOutToDeleteIsStillOneStepWithItsDrag() {
        let url = Set([URL(fileURLWithPath: "/photo.dng")])
        let drag = CurveEditing.pointCoalescingKey(prefix: "curve.", channel: "point",
                                                   index: 2)
        XCTAssertTrue(HistoryCoalescing.shouldCoalesce(
            openKey: drag, openURLs: url, key: CurveEditing.deletionCoalescingKey,
            urls: url, sinceLastEdit: 0.05, window: 1.2, openEpoch: 3, epoch: 3))
    }

    /// A drag of one point and a drag of the point that inherits its index after a
    /// delete must not share an undo step.
    func testAnIndexReusedAfterADeleteIsStillDistinguishable() {
        let url = Set([URL(fileURLWithPath: "/photo.dng")])
        let dragBefore = CurveEditing.pointCoalescingKey(prefix: "curve.",
                                                         channel: "point", index: 2)
        let deleteKey = CurveEditing.deletionCoalescingKey
        let dragAfter = CurveEditing.pointCoalescingKey(prefix: "curve.",
                                                        channel: "point", index: 2)
        // the delete between them is what has to break the chain
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: dragBefore, openURLs: url, key: deleteKey, urls: url,
            sinceLastEdit: 0.1, window: 1.2))
        XCTAssertFalse(HistoryCoalescing.shouldCoalesce(
            openKey: deleteKey, openURLs: url, key: dragAfter, urls: url,
            sinceLastEdit: 0.1, window: 1.2))
    }

    // MARK: - the whole shadow question, end to end

    /// The route the fix closed: place a third point, then try every deletion the
    /// editor exposes on the anchors. The curve must still start at x = 0 and the
    /// shadows must still be distinguishable.
    func testNoDeletionRouteFlattensTheShadows() {
        var points: [[Double]] = CurveEditing.identity
        points = CurveEditing.sanitized(CurveStack.settingPoint(points, x: 0.5, y: 0.6))
        XCTAssertEqual(points.count, 3)
        for index in [0, points.count - 1] {
            XCTAssertNil(CurveEditing.deleting(points, at: index))
        }
        // drag the black point down and to the left, then "release outside": the
        // escape is detected but the deletion must be refused.
        let dragged = CurveEditing.moved(points, index: 0, toX: -0.2, toY: -0.2)
        XCTAssertTrue(CurveEditing.escapes(x: -0.2, y: -0.2, marginX: 0.03, marginY: 0.03))
        XCTAssertNil(CurveEditing.deleting(dragged, at: 0))
        XCTAssertEqual(dragged[0][0], 0, accuracy: 0)
        let curve = MonotoneCubic(points: dragged)
        XCTAssertEqual(curve.xs.first ?? -1, 0, accuracy: 0,
                       "the curve no longer starts at x = 0: \(curve.xs)")
        // shadows are not one value
        XCTAssertNotEqual(curve.evaluate(0.01), curve.evaluate(0.2), accuracy: 1e-6)
    }

    /// Every gesture the editor exposes, in random order, starting from the identity:
    /// place a point, drag one, ⌥-click one, drag one out of the graph. However long the
    /// session runs, the curve must keep an anchor at each end of its own span, must
    /// never lose a point to `MonotoneCubic`, and must never render the shadows as one
    /// flat value.
    func testNoSequenceOfEditorGesturesFlattensTheShadows() {
        var rng = SplitMix64(seed: 0xA5A5A5A5C3C3C3C3)
        var failures: [String] = []
        for session in 0..<3000 {
            var points: [[Double]] = CurveEditing.identity
            for _ in 0..<24 {
                let x = Double(rng.next() % 1_000_001) / 1_000_000.0
                let y = Double(rng.next() % 1_000_001) / 1_000_000.0
                switch rng.next() % 4 {
                case 0:   // click on empty graph: place and pick up
                    points = CurveEditing.sanitized(
                        CurveStack.settingPoint(points, x: x, y: y))
                case 1:   // drag a point anywhere, including far outside the graph
                    let i = Int(rng.next() % UInt64(points.count))
                    let far = Double(Int(rng.next() % 300) - 100) / 100.0
                    points = CurveEditing.moved(points, index: i, toX: far, toY: y)
                case 2:   // option-click / context menu delete
                    let i = Int(rng.next() % UInt64(points.count))
                    points = CurveEditing.deleting(points, at: i) ?? points
                default:  // release outside the graph
                    let i = Int(rng.next() % UInt64(points.count))
                    points = CurveEditing.moved(points, index: i, toX: -0.4, toY: -0.4)
                    if CurveEditing.escapes(x: -0.4, y: -0.4,
                                            marginX: 0.03, marginY: 0.03) {
                        points = CurveEditing.deleting(points, at: i) ?? points
                    }
                }
                if points.count < 2 {
                    failures.append("session \(session) dropped below two points")
                    break
                }
                let curve = MonotoneCubic(points: points)
                if curve.xs.count != points.count {
                    failures.append("session \(session): MonotoneCubic keeps "
                                    + "\(curve.xs.count) of \(points.count): \(points)")
                    break
                }
                // the curve must still span whatever range its own anchors define, and
                // an identity-shaped curve must still be an identity
                if CurveEditing.isIdentity(points) {
                    for k in 0...10 where abs(curve.evaluate(Double(k) / 10)
                                              - Double(k) / 10) > 1e-12 {
                        failures.append("session \(session): isIdentity but not identity")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) failures, first: \(failures.first ?? "")")
    }

    /// Hit testing must never return an index the caller cannot use, including on a
    /// list with malformed rows.
    func testHitIndexOnlyReturnsUsableIndices() {
        let points: [[Double]] = [[0, 0], [0.5], [0.6, 0.6], [1, 1]]
        for x in stride(from: -0.2, through: 1.2, by: 0.01) {
            for y in stride(from: -0.2, through: 1.2, by: 0.05) {
                guard let i = CurveEditing.hitIndex(points, x: x, y: y,
                                                    toleranceX: 0.03, toleranceY: 0.03)
                else { continue }
                XCTAssertTrue(points.indices.contains(i))
                XCTAssertGreaterThanOrEqual(points[i].count, 2,
                                            "hit a malformed row at \(i)")
            }
        }
        XCTAssertNil(CurveEditing.hitIndex([], x: 0.5, y: 0.5,
                                           toleranceX: 0.03, toleranceY: 0.03))
    }

    /// `nearestIndexByX` is how the editor picks up the point a click just created.
    /// It must never point at a malformed row either.
    func testNearestIndexByXNeverPointsAtAMalformedRow() {
        XCTAssertNil(CurveEditing.nearestIndexByX([], x: 0.5))
        XCTAssertNil(CurveEditing.nearestIndexByX([[0.5]], x: 0.5))
        XCTAssertNil(CurveEditing.nearestIndexByX([[0, 0], [1, 1]], x: Double.nan))
        let points: [[Double]] = [[0.5], [0, 0], [1, 1]]
        guard let i = CurveEditing.nearestIndexByX(points, x: 0.4) else {
            return XCTFail("no index for a list with a usable row")
        }
        XCTAssertGreaterThanOrEqual(points[i].count, 2,
                                    "nearestIndexByX returned malformed row \(i)")
    }

    // MARK: - splits

    /// Whatever arrives, the repaired splits are inside the bounds, ascending, and
    /// separated by at least the minimum gap.
    func testSplitRepairAlwaysSatisfiesItsOwnBounds() {
        var rng = SplitMix64(seed: 0xFEEDFACEDEADC0DE)
        var failures: [String] = []
        let specials: [Double] = [0, 1, 0.10, 0.90, -1e9, 1e9, .nan, .infinity, -.infinity,
                                 0.899999999, 0.9000000001, 0.11, 0.115]
        for _ in 0..<20000 {
            var raw: [Double] = []
            for _ in 0..<3 {
                if rng.next() % 3 == 0 {
                    raw.append(specials[Int(rng.next() % UInt64(specials.count))])
                } else {
                    raw.append(Double(rng.next() % 1_000_001) / 1_000_000.0)
                }
            }
            let out = CurveEditing.sanitizedSplits(raw)
            if out.count != 3 { failures.append("count \(out.count) from \(raw)") ; continue }
            for v in out where !(v >= CurveEditing.splitFloor && v <= CurveEditing.splitCeiling) {
                failures.append("\(raw) -> \(out): \(v) outside bounds")
            }
            for i in 1..<3 where !(out[i] > out[i - 1]) {
                failures.append("\(raw) -> \(out): not ascending")
            }
            for i in 1..<3
            where out[i] - out[i - 1] < CurveEditing.minimumSplitGap - 1e-12 {
                failures.append("\(raw) -> \(out): gap \(out[i] - out[i - 1])")
            }
            if CurveEditing.sanitizedSplits(out) != out {
                failures.append("\(raw) -> \(out) is not a fixed point: "
                                + "\(CurveEditing.sanitizedSplits(out))")
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) failures, first: \(failures.first ?? "")")
    }
}

/// A deterministic generator, so a failure here reproduces exactly.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
