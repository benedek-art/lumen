// BrushRasterTests.swift
// WS-44 (docs/quality/lanes/WS-44/SPEC.md): the brush stroke is the swept dab, composited
// once. Each test names the spec line it pins. The numbers before the fix are in the
// header of Sources/LumenCore/Image/BrushRaster.swift.

import XCTest
@testable import LumenCore

final class BrushRasterTests: XCTestCase {

    private let w = 256
    private let h = 160
    /// size 0.16 at a 256 long edge: a 20.48 px radius.
    private let size = 0.16

    private func horizontal(y: Double = 80, from x0: Double = 40, to x1: Double = 216,
                            count: Int = 40, pressure: (Int) -> Double = { _ in 1 }) -> [BrushPoint] {
        (0..<count).map { i in
            let x = x0 + (x1 - x0) * Double(i) / Double(count - 1)
            return BrushPoint(x: x / Double(w), y: y / Double(h), pressure: pressure(i), t: i * 8)
        }
    }

    private func vertical(x: Double, count: Int = 40) -> [BrushPoint] {
        (0..<count).map { i in
            BrushPoint(x: x / Double(w), y: (10 + 140 * Double(i) / Double(count - 1)) / Double(h))
        }
    }

    private func paint(_ strokes: [BrushStroke], source: ImageBuffer? = nil) -> Plane {
        MaskRaster.accumulatedBrushPlane(strokes: BrushStrokeSet(strokes: strokes),
                                         size: (width: w, height: h), source: source)
    }

    private func at(_ p: Plane, _ x: Int, _ y: Int) -> Double { Double(p.values[y * p.width + x]) }

    // S1, S2: the stroke's cross-section IS the dab's radial profile.
    func testAStraightStrokesCrossSectionIsTheDabProfileAtEveryFeather() {
        let r = size / 2 * Double(w)
        for feather in [0.0, 25, 50, 75, 100] {
            let p = paint([BrushStroke(points: horizontal(), size: size, feather: feather)])
            let hardness = Swift.min(1 - feather / 100, Swift.max(0, 1 - 1 / r))
            var worst = 0.0
            for y in 0..<h {
                let d = abs(Double(y) + 0.5 - 80)
                let expected = MaskRaster.stampProfile(d / r, hardness: hardness)
                worst = Swift.max(worst, abs(at(p, 128, y) - expected))
            }
            XCTAssertLessThanOrEqual(worst, 0.02, "feather \(feather)")
        }
    }

    // S4: Flow is a per-pass deposit.
    func testFlowFiftyIsHalfPerPassAndThreeQuartersAfterTwo() {
        let a = BrushStroke(points: horizontal(), size: size, feather: 0, flow: 50)
        let b = BrushStroke(points: vertical(x: 100), size: size, feather: 0, flow: 50)
        let p = paint([a, b])
        XCTAssertEqual(at(p, 180, 80), 0.5, accuracy: 0.01)
        XCTAssertEqual(at(p, 100, 80), 0.75, accuracy: 0.01)
    }

    // S5: Density is a ceiling no number of passes crosses.
    func testDensityIsACeilingOverRepeatedPasses() {
        let a = BrushStroke(points: horizontal(), size: size, feather: 0, density: 60)
        let p = paint([a, a, a])
        XCTAssertLessThanOrEqual(p.values.max() ?? 0, 0.6 + 1e-6)
        XCTAssertEqual(at(p, 128, 80), 0.6, accuracy: 0.01)
    }

    // S6: one stroke going back over itself does not build up.
    func testAStrokeDoesNotBuildUpOverItself() {
        let there = horizontal()
        let back = Array(there.reversed())
        let p = paint([BrushStroke(points: there + back, size: size, feather: 0, flow: 50)])
        XCTAssertEqual(at(p, 128, 80), 0.5, accuracy: 0.01)
    }

    // S7: the eraser's Flow is how much it removes.
    func testEraseFlowRemovesThatFraction() {
        let base = BrushStroke(points: horizontal(), size: 0.3, feather: 0)
        let full = BrushStroke(points: vertical(x: 80), size: size, feather: 0, erase: true)
        let half = BrushStroke(points: vertical(x: 170), size: size, feather: 0, flow: 50,
                               erase: true)
        let p = paint([base, full, half])
        XCTAssertEqual(at(p, 128, 80), 1, accuracy: 1e-6)
        XCTAssertEqual(at(p, 80, 80), 0, accuracy: 0.005)
        XCTAssertEqual(at(p, 170, 80), 0.5, accuracy: 0.01)
    }

    // S8: pressure scales the deposit (the strongest dab within reach wins).
    func testPressureScalesTheDeposit() {
        let flat = paint([BrushStroke(points: horizontal(pressure: { _ in 0.3 }), size: size,
                                      feather: 0)])
        XCTAssertEqual(at(flat, 128, 80), 0.3, accuracy: 0.01)
        let ramp = paint([BrushStroke(points: horizontal(pressure: { Double($0) / 39 }),
                                      size: size, feather: 0)])
        var last = -1.0
        for x in stride(from: 50, through: 200, by: 10) {
            let v = at(ramp, x, 80)
            XCTAssertGreaterThanOrEqual(v, last - 1e-6, "pressure ramp must not fall at x \(x)")
            last = v
        }
        XCTAssertLessThan(at(ramp, 50, 80), 0.35)
    }

    // S9: two events across the frame paint a continuous, even band — no beading.
    func testAFastStrokeIsContinuousAndEven() {
        let flick = [BrushPoint(x: 10 / Double(w), y: 0.5), BrushPoint(x: 246 / Double(w), y: 0.5)]
        let p = paint([BrushStroke(points: flick, size: 0.03, feather: 50, flow: 30)])
        var lo = 1.0, hi = 0.0
        for x in 20..<236 {
            let v = at(p, x, 80)
            lo = Swift.min(lo, v); hi = Swift.max(hi, v)
        }
        XCTAssertEqual(lo, 0.3, accuracy: 0.005)
        XCTAssertLessThanOrEqual(hi - lo, 0.005)
    }

    // S13: the live path (point by point) is the committed path, exactly.
    func testPaintingPointByPointEqualsPaintingWhole() {
        let points = (0..<25).map { i -> BrushPoint in
            let u = Double(i) / 24
            return BrushPoint(x: 0.1 + 0.8 * u, y: 0.5 + 0.3 * sin(u * 7), pressure: 0.4 + 0.6 * u)
        }
        let stroke = BrushStroke(points: points, size: 0.12, feather: 70, flow: 80, density: 90)
        let whole = paint([stroke])

        var live = BrushStrokeRaster(stroke: stroke, width: w, height: h)
        var dirty = BrushStrokeRaster.Rect.empty
        for q in points {
            live.append(q)
            dirty = dirty.union(live.takeDirty())
        }
        live.finish()
        dirty = dirty.union(live.takeDirty())
        var plane = Plane(width: w, height: h)
        live.composite(into: &plane)
        var worst: Float = 0
        for i in 0..<plane.values.count { worst = Swift.max(worst, abs(plane.values[i] - whole.values[i])) }
        XCTAssertLessThanOrEqual(worst, 1e-6)
        // Everything painted lies inside what was reported dirty.
        for y in 0..<h { for x in 0..<w where whole.values[y * w + x] > 0 {
            XCTAssertTrue(x >= dirty.x0 && x < dirty.x1 && y >= dirty.y0 && y < dirty.y1)
        } }
    }

    // S14: identities.
    func testNothingPaintsWhereNothingShould() {
        XCTAssertEqual(paint([]).values.max(), 0)
        XCTAssertEqual(paint([BrushStroke(points: horizontal(), size: size, flow: 0)]).values.max(), 0)
        XCTAssertEqual(paint([BrushStroke(points: horizontal(), size: size, density: 0)]).values.max(), 0)
        XCTAssertEqual(paint([BrushStroke(points: [], size: size)]).values.max(), 0)
        let nan = [BrushPoint(x: .nan, y: 0.5), BrushPoint(x: .infinity, y: 0.5)]
        XCTAssertEqual(paint([BrushStroke(points: nan, size: size)]).values.max(), 0)
    }

    // MARK: Auto Mask (S10, S11)

    /// Left half red, right half green, with a third red block on the right separated
    /// from the left half by green — a disconnected region of the same colour.
    private func twoObjects() -> ImageBuffer {
        var img = ImageBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let red = x < 128 || (x >= 200 && y >= 60 && y < 100)
                img[x, y] = red ? RGB(0.40, 0.05, 0.04) : RGB(0.06, 0.25, 0.05)
            }
        }
        return img
    }

    func testAutoMaskStaysOnTheObjectTheStrokeStartedOn() {
        let src = twoObjects()
        // Starts on red at x 40, runs across the edge at 128 and over the red island at 200+.
        let stroke = BrushStroke(points: horizontal(), size: size, feather: 0, automask: true)
        let p = paint([stroke], source: src)
        var inside = 0.0, outside = 0.0
        for y in 0..<h { for x in 0..<w {
            let v = at(p, x, y)
            if x < 128 { inside += v } else { outside += v }
        } }
        XCTAssertGreaterThan(at(p, 100, 80), 0.99)
        XCTAssertLessThan(outside / Swift.max(inside + outside, 1e-9), 0.03,
                          "the stroke followed its centre onto the other object")
        XCTAssertLessThan(at(p, 210, 80), 0.01, "a same-coloured island beyond the edge was painted")
    }

    func testAutoMaskAlongAnEdgeKeepsTheOtherSideClean() {
        let src = twoObjects()
        // Centre 8 px inside the red half, radius 20 px: half the brush hangs over green.
        let stroke = BrushStroke(points: vertical(x: 120), size: size, feather: 0, automask: true)
        let p = paint([stroke], source: src)
        var leak = 0.0, total = 0.0
        for y in 0..<h { for x in 0..<w {
            let v = at(p, x, y)
            total += v
            if x >= 128 { leak += v }
        } }
        XCTAssertLessThan(leak / total, 0.03)
        XCTAssertGreaterThan(at(p, 126, 80), 0.9, "the object was not painted to its edge")
        // Without Auto Mask the same stroke paints well over the edge.
        let plain = paint([BrushStroke(points: vertical(x: 120), size: size, feather: 0)], source: src)
        XCTAssertGreaterThan(at(plain, 135, 80), 0.9)
    }

    // The live canvas shows the committed stroke: its alpha is the committed coverage
    // times the overlay strength, everywhere, and `patch` returns those same bytes.
    func testTheLivePreviewShowsTheStrokeThatWillBeCommitted() {
        let points = (0..<12).map { i -> BrushPoint in
            let u = Double(i) / 11
            return BrushPoint(x: 0.1 + 0.8 * u, y: 0.5 + 0.2 * sin(u * 5), pressure: 0.5 + 0.5 * u)
        }
        let stroke = BrushStroke(points: points, size: 0.1, feather: 60, flow: 70)
        let whole = paint([stroke])
        var live = BrushLivePreview(stroke: stroke, width: w, height: h,
                                    diameterPx: 0.1 * Double(w), strength: 0.5)
        for q in points { live.append(x: q.x * Double(w), y: q.y * Double(h), pressure: q.pressure) }
        live.finish()
        var worst = 0.0
        for i in 0..<(w * h) {
            let alpha = Double(live.rgba[i * 4 + 3]) / 255
            worst = Swift.max(worst, abs(alpha - 0.5 * Double(whole.values[i])))
        }
        XCTAssertLessThanOrEqual(worst, 1.0 / 255 + 1e-9)
        let r = live.touched
        XCTAssertFalse(r.isEmpty)
        let patch = live.patch(r)
        XCTAssertEqual(patch.count, r.width * r.height * 4)
        let y = (r.y0 + r.y1) / 2, x = (r.x0 + r.x1) / 2
        XCTAssertEqual(patch[((y - r.y0) * r.width + (x - r.x0)) * 4 + 3], live.rgba[(y * w + x) * 4 + 3])
    }
}
