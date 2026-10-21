// UprightTests.swift
// WS-25 spec lines 12-17: Upright's detector and solver on a synthetic facade whose
// vanishing points are known exactly, because the camera that "took" it is written down.

import XCTest
@testable import LumenCore

final class UprightTests: XCTestCase {

    // MARK: The facade

    struct Camera {
        var pitch: Double   // degrees, positive looks up
        var yaw: Double
        var roll: Double
        var focal: Double = UprightSolver.focal

        /// World → camera rotation, row-major.
        var rotation: [[Double]] {
            func rx(_ a: Double) -> [[Double]] {
                let c = cos(a), s = sin(a); return [[1, 0, 0], [0, c, -s], [0, s, c]]
            }
            func ry(_ a: Double) -> [[Double]] {
                let c = cos(a), s = sin(a); return [[c, 0, s], [0, 1, 0], [-s, 0, c]]
            }
            func rz(_ a: Double) -> [[Double]] {
                let c = cos(a), s = sin(a); return [[c, -s, 0], [s, c, 0], [0, 0, 1]]
            }
            let d = Double.pi / 180
            return mul(rz(roll * d), mul(rx(-pitch * d), ry(yaw * d)))
        }

        /// Where a world point lands, in normalized centred y-up image coordinates.
        func project(_ p: (Double, Double, Double)) -> (Double, Double) {
            let r = rotation
            let c = (r[0][0] * p.0 + r[0][1] * p.1 + r[0][2] * p.2,
                     r[1][0] * p.0 + r[1][1] * p.1 + r[1][2] * p.2,
                     r[2][0] * p.0 + r[2][1] * p.1 + r[2][2] * p.2)
            return (focal * c.0 / c.2, focal * c.1 / c.2)
        }

        /// The world direction a camera ray points along.
        func ray(_ q: (Double, Double)) -> (Double, Double, Double) {
            let r = rotation
            let d = (q.0 / focal, q.1 / focal, 1.0)
            // Rᵀ d
            return (r[0][0] * d.0 + r[1][0] * d.1 + r[2][0] * d.2,
                    r[0][1] * d.0 + r[1][1] * d.1 + r[2][1] * d.2,
                    r[0][2] * d.0 + r[1][2] * d.1 + r[2][2] * d.2)
        }
    }

    static func mul(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    static let wallZ = 6.0
    static let wall = (x0: -3.2, x1: 3.2, y0: -2.0, y1: 4.5)

    /// Scene-linear radiance on the facade plane z = 6: wall, windows, pilasters, ledges.
    static func facade(_ x: Double, _ y: Double) -> Double {
        guard x > wall.x0, x < wall.x1, y > wall.y0, y < wall.y1 else { return 0.55 }
        let cx = (x - wall.x0).truncatingRemainder(dividingBy: 0.8)
        let cy = (y - wall.y0).truncatingRemainder(dividingBy: 1.1)
        if cx > 0.2, cx < 0.6, cy > 0.25, cy < 0.85 { return 0.035 }
        if cy < 0.06 { return 0.12 }
        return 0.26
    }

    static func render(_ cam: Camera, width: Int = 900, height: Int = 600) -> ImageBuffer {
        let long = Double(Swift.max(width, height))
        var out = ImageBuffer(width: width, height: height)
        for py in 0..<height {
            for px in 0..<width {
                var sum = 0.0
                for sy in 0..<3 {
                    for sx in 0..<3 {
                        let x = Double(px) + (Double(sx) + 0.5) / 3
                        let y = Double(py) + (Double(sy) + 0.5) / 3
                        let q = ((x - Double(width) / 2) / long, (Double(height) / 2 - y) / long)
                        let d = cam.ray(q)
                        if d.2 <= 1e-6 { sum += 0.55; continue }
                        let t = wallZ / d.2
                        sum += facade(t * d.0, t * d.1)
                    }
                }
                let v = sum / 9
                out[px, py] = RGB(v, v, v)
            }
        }
        return out
    }

    static let camera = Camera(pitch: 12, yaw: 9, roll: 2)
    static let image: ImageBuffer = render(camera)
    static let detected: [Upright.Segment] = UprightDetector.detect(image)

    // MARK: Helpers

    /// Degrees from the nearest axis of a segment after the full geometry, in the
    /// OUTPUT frame, with which axis it is nearest.
    func deviations(_ segments: [Upright.Segment], geometry: Geometry,
                    width: Int = 900, height: Int = 600) -> (vertical: [(Double, Double)],
                                                              horizontal: [(Double, Double)]) {
        let map = GeometryMap(geometry: geometry, sourceWidth: width, sourceHeight: height)
        var v: [(Double, Double)] = [], h: [(Double, Double)] = []
        for s in segments {
            let a = map.sourceToOutput.apply(s.x0 * Double(width), s.y0 * Double(height))
            let b = map.sourceToOutput.apply(s.x1 * Double(width), s.y1 * Double(height))
            let len = hypot(b.x - a.x, b.y - a.y)
            var angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
            while angle <= -90 { angle += 180 }
            while angle > 90 { angle -= 180 }
            if abs(abs(angle) - 90) < 30 { v.append((abs(angle) - 90 < 0 ? 90 - abs(angle) : abs(angle) - 90, len)) }
            else if abs(angle) < 40 { h.append((abs(angle), len)) }
        }
        return (v, h)
    }

    func weightedRMS(_ xs: [(Double, Double)]) -> Double {
        let w = xs.reduce(0) { $0 + $1.1 }
        guard w > 0 else { return .nan }
        return (xs.reduce(0) { $0 + $1.0 * $1.0 * $1.1 } / w).squareRoot()
    }

    func weightedMedian(_ xs: [(Double, Double)]) -> Double {
        let sorted = xs.sorted { $0.0 < $1.0 }
        let half = sorted.reduce(0) { $0 + $1.1 } / 2
        var run = 0.0
        for (x, w) in sorted { run += w; if run >= half { return x } }
        return .nan
    }

    func geometry(_ mode: Upright.Mode, segments: [Upright.Segment] = detected,
                  guides: [Upright.Segment] = []) -> Geometry {
        Geometry(upright: Upright(mode: mode, segments: segments, guides: guides))
    }

    // MARK: 13: detection

    func testDetectorFindsTheFacadeAndItsVerticalVanishingPoint() {
        let before = deviations(Self.detected, geometry: Geometry())
        print("spec 13: \(Self.detected.count) segments; \(before.vertical.count) near-vertical, "
              + "\(before.horizontal.count) near-horizontal")
        XCTAssertGreaterThanOrEqual(before.vertical.count, 8)
        XCTAssertGreaterThanOrEqual(before.horizontal.count, 4)

        let solution = UprightSolver.solve(Upright(mode: .vertical, segments: Self.detected),
                                           sourceWidth: 900, sourceHeight: 600)
        guard let v = solution.verticalVP else { return XCTFail("no vertical vanishing point") }
        // Truth: the camera-space direction of world up.
        let r = Self.camera.rotation
        let up = (r[0][1], r[1][1], r[2][1])
        let f = UprightSolver.focal
        let est = (v.0 / f, v.1 / f, v.2)
        let dot = abs(up.0 * est.0 + up.1 * est.1 + up.2 * est.2)
            / ((est.0 * est.0 + est.1 * est.1 + est.2 * est.2).squareRoot())
        let error = acos(Swift.min(1, dot)) * 180 / .pi
        print(String(format: "spec 13: vertical vanishing direction error %.3f°", error))
        XCTAssertLessThan(error, 0.5)
    }

    // MARK: 14-16: the modes

    func testLevelOnlyRolls() {
        let s = UprightSolver.solve(Upright(mode: .level, segments: Self.detected),
                                    sourceWidth: 900, sourceHeight: 600)
        XCTAssertEqual(s.pitch, 0)
        XCTAssertEqual(s.yaw, 0)
        // Levelled against the vertical vanishing DIRECTION, so the median vertical sits
        // on the axis while converging verticals still lean symmetrically about it.
        let after = deviations(Self.detected, geometry: geometry(.level))
        let signed = Self.detected.compactMap { seg -> (Double, Double)? in
            let map = GeometryMap(geometry: geometry(.level), sourceWidth: 900, sourceHeight: 600)
            let a = map.sourceToOutput.apply(seg.x0 * 900, seg.y0 * 600)
            let b = map.sourceToOutput.apply(seg.x1 * 900, seg.y1 * 600)
            var angle = atan2(b.y - a.y, b.x - a.x) * 180 / .pi
            while angle <= 0 { angle += 180 }
            while angle > 180 { angle -= 180 }
            guard abs(angle - 90) < 30 else { return nil }
            return (angle - 90, hypot(b.x - a.x, b.y - a.y))
        }
        let median = weightedMedian(signed)
        print(String(format: "spec 14: Level roll %.3f°, signed median vertical deviation after %.3f°, "
                     + "%d verticals", s.roll * 180 / .pi, median, after.vertical.count))
        XCTAssertLessThan(abs(median), 0.2)
    }

    func testVerticalMakesVerticalsVertical() {
        let before = deviations(Self.detected, geometry: Geometry())
        let after = deviations(Self.detected, geometry: geometry(.vertical))
        let s = UprightSolver.solve(Upright(mode: .vertical, segments: Self.detected),
                                    sourceWidth: 900, sourceHeight: 600)
        print(String(format: "spec 15: Vertical solved roll %.2f° pitch %.2f° (camera: roll 2, pitch 12); "
                     + "vertical RMS deviation %.3f° → %.3f°", s.roll * 180 / .pi,
                     s.pitch * 180 / .pi, weightedRMS(before.vertical), weightedRMS(after.vertical)))
        XCTAssertLessThan(weightedRMS(after.vertical), 0.3)
        XCTAssertEqual(s.yaw, 0)

        // Re-detected on the corrected PIXELS, not just the transformed segments.
        let corrected = GeometryStage.apply(Self.image, geometry: geometry(.vertical))
        let redetected = UprightDetector.detect(corrected)
        let again = deviations(redetected, geometry: Geometry(),
                               width: corrected.width, height: corrected.height)
        print(String(format: "spec 15: re-detected on the rendered result: vertical RMS %.3f° over %d lines",
                     weightedRMS(again.vertical), again.vertical.count))
        XCTAssertLessThan(weightedRMS(again.vertical), 0.3)
    }

    func testFullAlsoLevelsTheHorizontals() {
        let before = deviations(Self.detected, geometry: Geometry())
        let after = deviations(Self.detected, geometry: geometry(.full))
        let s = UprightSolver.solve(Upright(mode: .full, segments: Self.detected),
                                    sourceWidth: 900, sourceHeight: 600)
        print(String(format: "spec 16: Full solved roll %.2f° pitch %.2f° yaw %.2f° shear %.4f; "
                     + "horizontal RMS %.3f° → %.3f°, vertical RMS → %.3f°",
                     s.roll * 180 / .pi, s.pitch * 180 / .pi, s.yaw * 180 / .pi, s.shear,
                     weightedRMS(before.horizontal), weightedRMS(after.horizontal),
                     weightedRMS(after.vertical)))
        XCTAssertLessThan(weightedRMS(after.horizontal), 0.5)
        XCTAssertLessThan(weightedRMS(after.vertical), 0.3)
    }

    func testAutoIsBetweenVerticalAndFull() {
        let auto = UprightSolver.solve(Upright(mode: .auto, segments: Self.detected),
                                       sourceWidth: 900, sourceHeight: 600)
        let full = UprightSolver.solve(Upright(mode: .full, segments: Self.detected),
                                       sourceWidth: 900, sourceHeight: 600)
        XCTAssertEqual(auto.pitch, full.pitch, accuracy: 1e-12)
        XCTAssertLessThanOrEqual(abs(auto.yaw), abs(full.yaw) + 1e-12)
        let after = deviations(Self.detected, geometry: geometry(.auto))
        XCTAssertLessThan(weightedRMS(after.vertical), 0.3)
    }

    // MARK: 17: guided, constraints, fill

    /// The image of a world segment on the facade, as a source-normalized segment.
    func guide(_ a: (Double, Double), _ b: (Double, Double)) -> Upright.Segment {
        let p = Self.camera.project((a.0, a.1, Self.wallZ))
        let q = Self.camera.project((b.0, b.1, Self.wallZ))
        // normalized centred y-up → source normalized (900 × 600, long edge 900)
        return Upright.Segment(x0: p.0 * 900 / 900 + 0.5, y0: 0.5 - p.1 * 900 / 600,
                               x1: q.0 + 0.5, y1: 0.5 - q.1 * 900 / 600)
    }

    func testGuidesBecomeExactlyAxisAligned() {
        let v1 = guide((-2.4, -1), (-2.4, 3)), v2 = guide((1.6, -1), (1.6, 3.5))
        let h1 = guide((-2.5, 0), (2.5, 0)), h2 = guide((-2, 2.2), (2.8, 2.2))
        let two = deviations([v1, v2], geometry: geometry(.guided, guides: [v1, v2]))
        let four = deviations([v1, v2, h1, h2],
                              geometry: geometry(.guided, guides: [v1, v2, h1, h2]))
        let worstTwo = two.vertical.map(\.0).max() ?? .nan
        let worstFour = (four.vertical + four.horizontal).map(\.0).max() ?? .nan
        print(String(format: "spec 17: two vertical guides → worst %.5f°; four guides → worst %.5f° "
                     + "(%d/%d classified)", worstTwo, worstFour, four.vertical.count,
                     four.horizontal.count))
        XCTAssertEqual(two.vertical.count, 2)
        XCTAssertEqual(four.vertical.count + four.horizontal.count, 4)
        XCTAssertLessThan(worstTwo, 0.05)
        XCTAssertLessThan(worstFour, 0.05)
    }

    func testEveryCorrectionFillsTheFrameAndIsConstrained() {
        var rng = SplitMix(seed: 11)
        var worstOutside = 0.0
        for i in 0..<120 {
            var u = Upright(vertical: (rng.next() - 0.5) * 200, horizontal: (rng.next() - 0.5) * 200,
                            rotate: (rng.next() - 0.5) * 20, aspect: (rng.next() - 0.5) * 200)
            u.mode = [.off, .vertical, .full, .auto, .level][i % 5]
            u.segments = Self.detected
            // A wild guide pair: VP nearly in the frame, which must be clamped, not obeyed.
            if i % 7 == 0 {
                u.mode = .guided
                u.guides = [Upright.Segment(x0: 0.1, y0: 0.9, x1: 0.45, y1: 0.1),
                            Upright.Segment(x0: 0.9, y0: 0.9, x1: 0.55, y1: 0.1)]
            }
            let s = UprightSolver.solve(u, sourceWidth: 900, sourceHeight: 600)
            for a in [s.roll, s.pitch, s.yaw] where u.mode != .guided {
                XCTAssertLessThanOrEqual(abs(a), Double.pi / 2)
            }
            let map = GeometryMap(geometry: Geometry(upright: u), sourceWidth: 900, sourceHeight: 600)
            for (x, y) in [(0.0, 0.0), (Double(map.outputWidth), 0), (0, Double(map.outputHeight)),
                           (Double(map.outputWidth), Double(map.outputHeight))] {
                let p = map.outputToSource.apply(x, y)
                let outside = Swift.max(-p.x, p.x - 900, -p.y, p.y - 600, 0)
                worstOutside = Swift.max(worstOutside, outside)
            }
        }
        print(String(format: "spec 17: worst output corner outside the source over 120 random "
                     + "corrections: %.2e px", worstOutside))
        XCTAssertLessThan(worstOutside, 1e-6)
    }

    func testManualSliderSignsMatchLightroom() {
        // Vertical +: the top of the frame narrows (Lightroom's sign).
        let h = UprightSolver.homography(Upright(vertical: 50), sourceWidth: 900, sourceHeight: 600)
        let tl = h.apply(-0.5, 1.0 / 3), tr = h.apply(0.5, 1.0 / 3)
        let bl = h.apply(-0.5, -1.0 / 3), br = h.apply(0.5, -1.0 / 3)
        XCTAssertLessThan(tr.x - tl.x, br.x - bl.x)
        // Rotate +: clockwise, like the straighten angle.
        let r = UprightSolver.homography(Upright(rotate: 5), sourceWidth: 900, sourceHeight: 600)
        let p = r.apply(0.3, 0)
        XCTAssertLessThan(p.y, 0)
    }
}
