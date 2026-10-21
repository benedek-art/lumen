// GradientLaneTests.swift
// Lane M3 (WS-45): the linear and radial gradients against Lightroom's grammar, and the
// rendered alpha against the handles drawn for it. Each test names the SPEC line it
// measures (docs/quality/lanes/WS-45/SPEC.md).

import XCTest
@testable import LumenCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class GradientLaneTests: XCTestCase {

    private func linear(_ line: [Double]) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .linear)
        c.line = line
        return c
    }

    private func radial(centre: [Double], radii: [Double], rotation: Double,
                        feather: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = centre
        c.radii = radii
        c.rotation = rotation
        c.feather = feather
        return c
    }

    /// Bilinear-free sample: the pixel whose centre is nearest a source-normalized point.
    private func sample(_ p: Plane, _ nx: Double, _ ny: Double) -> Double? {
        let x = Int((nx * Double(p.width)).rounded(.down))
        let y = Int((ny * Double(p.height)).rounded(.down))
        guard x >= 0, x < p.width, y >= 0, y < p.height else { return nil }
        return Double(p[x, y])
    }

    // MARK: S1 — the full end is where the drag began

    func testDrawnGradientIsFullWhereTheDragStarted() {
        // Top of a 1500×1000 view, dragged down to the horizon: the sky must be full.
        let press = CGPoint(x: 750, y: 100), release = CGPoint(x: 750, y: 600)
        let drawn = MaskHandles.drawnGradient(from: press, to: release,
                                              fromCentre: false, snap: false)
        let line = [Double(drawn.start.x) / 1500, Double(drawn.start.y) / 1000,
                    Double(drawn.end.x) / 1500, Double(drawn.end.y) / 1000]
        let plane = MaskRaster.linearPlane(linear(line), 1500, 1000)
        XCTAssertGreaterThanOrEqual(sample(plane, 0.5, 0.05)!, 0.999, "the sky above the press")
        XCTAssertGreaterThanOrEqual(sample(plane, 0.5, 100.5 / 1000)!, 0.999)
        XCTAssertLessThanOrEqual(sample(plane, 0.5, 600.5 / 1000)!, 0.001, "the release")
        XCTAssertLessThanOrEqual(sample(plane, 0.5, 0.9)!, 0.001, "the ground")

        // ⌥ from the centre: still full on the side the hand moved AWAY from.
        let centred = MaskHandles.drawnGradient(from: CGPoint(x: 750, y: 400),
                                                to: CGPoint(x: 750, y: 600),
                                                fromCentre: true, snap: false)
        XCTAssertEqual(centred.end.y, 200, accuracy: 1e-9)
        XCTAssertEqual(centred.start.y, 600, accuracy: 1e-9)
    }

    // MARK: S2 — three lines

    private let a = CGPoint(x: 800, y: 300)   // start: alpha 0
    private let b = CGPoint(x: 800, y: 800)   // end: alpha 1

    private func grab(_ x: Double, _ y: Double) -> MaskHandles.LinearGrab {
        MaskHandles.linearGrab(press: CGPoint(x: x, y: y), start: a, end: b)
    }

    func testThreeLineGrammar() {
        let r = MaskHandles.grabRadius
        // The pin moves.
        for (dx, dy) in [(0.0, 0.0), (r - 1, 0.0), (0.0, r - 1), (-7.0, 7.0)] {
            XCTAssertEqual(grab(800 + dx, 550 + dy), .move, "pin at (\(dx), \(dy))")
        }
        // The centre line, anywhere across the frame away from the pin, turns.
        for x in [0.0, 300.0, 780.0, 830.0, 1500.0] {
            for dy in [-(r - 1), 0, r - 1] {
                XCTAssertEqual(grab(x, 550 + dy), .rotate, "centre line at x \(x), dy \(dy)")
            }
        }
        // Each outer line, away from its dot, feathers.
        for x in [0.0, 400.0, 1500.0] {
            for dy in [-(r - 1), 0, r - 1] {
                XCTAssertEqual(grab(x, 300 + dy), .startBand, "start line x \(x)")
                XCTAssertEqual(grab(x, 800 + dy), .endBand, "end line x \(x)")
            }
        }
        // The strip between the lines moves.
        for y in [320.0, 400.0, 520.0, 580.0, 700.0, 780.0] {
            for x in [10.0, 800.0, 1590.0] where !(x == 800 && abs(y - 550) <= r) {
                XCTAssertEqual(grab(x, y), .move, "strip at (\(x), \(y))")
            }
        }
        // And the dots still swing their end.
        XCTAssertEqual(grab(803, 302), .startHandle)
        XCTAssertEqual(grab(797, 798), .endHandle)
    }

    // MARK: S3 — feathering from an outer line keeps the centre line where it is

    func testOuterLineFeathersAboutTheCentre() {
        let s = CGPoint(x: 100, y: 200), e = CGPoint(x: 100, y: 400)
        for (start, slide) in [(true, -30.0), (true, 40.0), (false, 25.0), (false, -60.0)] {
            let f = MaskHandles.featheredLine(start: s, end: e, grabbedStart: start,
                                              slide: slide, oneSided: false)
            XCTAssertEqual(Double(f.start.y + f.end.y) / 2, 300, accuracy: 1e-9,
                           "the centre line moved")
            let outward = start ? -slide : slide
            XCTAssertEqual(Double(f.end.y - f.start.y), 200 + 2 * outward, accuracy: 1e-9)
            XCTAssertEqual(Double(f.start.x), 100, accuracy: 1e-9)
        }
        // ⌥: the grabbed line alone.
        let one = MaskHandles.featheredLine(start: s, end: e, grabbedStart: false,
                                            slide: 50, oneSided: true)
        XCTAssertEqual(Double(one.start.y), 200, accuracy: 1e-9)
        XCTAssertEqual(Double(one.end.y), 450, accuracy: 1e-9)
        // Never below the floor, and never crossed.
        for oneSided in [false, true] {
            let tight = MaskHandles.featheredLine(start: s, end: e, grabbedStart: true,
                                                  slide: 500, oneSided: oneSided)
            XCTAssertEqual(Double(tight.end.y - tight.start.y), MaskHandles.grabRadius,
                           accuracy: 1e-9)
        }
    }

    // MARK: S5 — the radial draws from its centre

    func testRadialDrawsFromItsCentre() {
        let d = MaskHandles.drawnEllipse(from: (0.4, 0.5), to: (0.55, 0.42),
                                         cornerToCorner: false)
        XCTAssertEqual(d.centre[0], 0.4, accuracy: 1e-12)
        XCTAssertEqual(d.centre[1], 0.5, accuracy: 1e-12)
        XCTAssertEqual(d.radii[0], 0.15, accuracy: 1e-12)
        XCTAssertEqual(d.radii[1], 0.08, accuracy: 1e-12)
        let box = MaskHandles.drawnEllipse(from: (0.4, 0.5), to: (0.6, 0.3),
                                           cornerToCorner: true)
        XCTAssertEqual(box.centre[0], 0.5, accuracy: 1e-12)
        XCTAssertEqual(box.centre[1], 0.4, accuracy: 1e-12)
        XCTAssertEqual(box.radii[0], 0.1, accuracy: 1e-12)
        XCTAssertEqual(box.radii[1], 0.1, accuracy: 1e-12)
    }

    // MARK: S6 — Feather 0 is an anti-aliased edge, not a staircase

    func testFeatherZeroRadialIsAntialiased() {
        let w = 600, h = 400
        let c = radial(centre: [0.5, 0.5], radii: [0.3, 0.25], rotation: 20, feather: 0)
        let plane = MaskRaster.radialPlane(c, w, h)
        let core = MaskRaster.radialCore(radii: (0.3, 0.25), feather: 0, width: w, height: h)
        XCTAssertEqual(core, 1 - 1.5 / 100.0, accuracy: 1e-12, "1.5 px of the 100 px minor radius")
        // A hard step has no partial pixels at all (the shipped rin, 1 − 1e-6, left
        // none on this frame). An anti-aliased rim has about one per pixel of perimeter;
        // demand half of that, which no stair-stepped edge can reach.
        var partial = 0
        for y in 0..<h { for x in 0..<w where plane[x, y] > 0.02 && plane[x, y] < 0.98 {
            partial += 1
        } }
        let rx = 0.3 * Double(w), ry = 0.25 * Double(h)
        let perimeter = 2 * Double.pi * ((rx * rx + ry * ry) / 2).squareRoot()
        XCTAssertGreaterThanOrEqual(Double(partial), 0.5 * perimeter,
                                    "\(partial) partial pixels on a \(Int(perimeter)) px rim")
        // Feather 100 keeps its one-pixel core.
        XCTAssertEqual(MaskRaster.radialCore(radii: (0.3, 0.25), feather: 100,
                                             width: w, height: h), 0.01, accuracy: 1e-12)
    }

    // MARK: S7 — a sub-pixel linear gradient is a one-pixel ramp

    func testSubPixelLinearIsOnePixelRamp() {
        let w = 400, h = 300
        // A 0.05 px span, centred on y = 150.25 px.
        let y0 = (150.25 - 0.025) / Double(h), y1 = (150.25 + 0.025) / Double(h)
        let plane = MaskRaster.linearPlane(linear([0.5, y0, 0.5, y1]), w, h)
        let column = (0..<h).map { Double(plane[200, $0]) }
        let partial = column.filter { $0 > 0.02 && $0 < 0.98 }
        XCTAssertGreaterThanOrEqual(partial.count, 1, "a hard step, not an anti-aliased one")
        XCTAssertEqual(column[140], 0, accuracy: 1e-12)
        XCTAssertEqual(column[160], 1, accuracy: 1e-12)
    }

    // MARK: S8 — the alpha sits on the three drawn lines

    func testLinearAlphaSitsOnItsThreeLines() {
        let w = 1500, h = 1000
        let long = Double(Swift.max(w, h))
        // A 300 px axis at 30° in PIXEL space, from (600, 400) — expressed per-axis
        // normalized, which is how the recipe stores it.
        let ang = 30 * Double.pi / 180
        let x0 = 600.0, y0 = 400.0
        let x1 = x0 + 300 * cos(ang), y1 = y0 + 300 * sin(ang)
        let plane = MaskRaster.linearPlane(
            linear([x0 / Double(w), y0 / Double(h), x1 / Double(w), y1 / Double(h)]), w, h)
        _ = long
        // Along each line (perpendicular to the axis in PIXELS), five points.
        let nx = -sin(ang), ny = cos(ang)
        for (t, expected) in [(0.0, 0.0), (0.5, 0.5), (1.0, 1.0)] {
            let cx = x0 + (x1 - x0) * t, cy = y0 + (y1 - y0) * t
            for along in [-200.0, -80.0, 0.0, 90.0, 210.0] {
                let px = cx + nx * along, py = cy + ny * along
                // The pixel whose centre is nearest, and its exact value there — the
                // test is that the 0 / ½ / 1 contour is where the line is drawn, so
                // compare against the ramp evaluated at that pixel centre's offset.
                let ix = Int(px), iy = Int(py)
                let ox = Double(ix) + 0.5 - cx, oy = Double(iy) + 0.5 - cy
                let shift = (ox * cos(ang) + oy * sin(ang)) / 300     // fraction of span
                let tt = Num.saturate(t + shift)
                let want = tt * tt * (3 - 2 * tt)
                let got = Double(plane[ix, iy])
                XCTAssertEqual(got, want, accuracy: 1e-6, "t \(t), along \(along)")   // Float plane
                XCTAssertEqual(got, expected, accuracy: 0.01, "t \(t), along \(along)")
            }
        }
    }

    // MARK: S9 — the radial alpha sits on the drawn rim and ring

    func testRadialAlphaSitsOnItsDrawnRimAndRing() {
        let w = 1500, h = 1000
        let centre = [0.45, 0.55], radii = [0.2, 0.18], rotation = 30.0, feather = 40.0
        let plane = MaskRaster.radialPlane(radial(centre: centre, radii: radii,
                                                  rotation: rotation, feather: feather), w, h)
        let ring = 1 - feather / 100
        for k in 0..<32 {
            let u = Double(k) / 32 * 2 * Double.pi
            // The exact points the canvas draws the rim and ring through.
            let rim = MaskRaster.radialOffset((x: radii[0] * cos(u), y: radii[1] * sin(u)),
                                              rotation: rotation, width: w, height: h)
            let inner = MaskRaster.radialOffset(
                (x: radii[0] * ring * cos(u), y: radii[1] * ring * sin(u)),
                rotation: rotation, width: w, height: h)
            // 1.5 px outward / inward along the ray from the centre, in pixels.
            func nudged(_ o: (x: Double, y: Double), _ px: Double) -> (Double, Double) {
                let dx = o.x * Double(w), dy = o.y * Double(h)
                let len = (dx * dx + dy * dy).squareRoot()
                let k = (len + px) / len
                return (centre[0] + o.x * k, centre[1] + o.y * k)
            }
            let out = nudged(rim, 1.5), inn = nudged(inner, -1.5)
            XCTAssertLessThanOrEqual(sample(plane, out.0, out.1)!, 0.01, "outside the rim, ray \(k)")
            XCTAssertGreaterThanOrEqual(sample(plane, inn.0, inn.1)!, 0.99, "inside the ring, ray \(k)")
        }
    }

    // MARK: S11 — the drawn outline is the rim at any zoom

    func testEllipseStepsKeepTheOutlineWithinAQuarterPoint() {
        for r in [5.0, 50, 300, 1000, 5000, 20000] {
            let n = MaskHandles.ellipseSteps(longestRadius: r)
            let sagitta = r * (1 - cos(Double.pi / Double(n)))
            XCTAssertLessThanOrEqual(sagitta, 0.25 + 1e-9, "r \(r), \(n) steps")
            XCTAssertGreaterThanOrEqual(n, 72)
        }
    }
}
