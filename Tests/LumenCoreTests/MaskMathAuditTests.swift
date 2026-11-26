// MaskMathAuditTests.swift
// The arithmetic of masks, checked against the closed forms docs/08 gives for it.

import XCTest
@testable import LumenCore

final class MaskMathAuditTests: XCTestCase {

    // MARK: - Fixtures

    private func constant(_ v: Double, _ w: Int, _ h: Int) -> Plane {
        var p = Plane(width: w, height: h)
        for i in 0..<(w * h) { p.values[i] = Float(v) }
        return p
    }

    private func radial(center: [Double], radii: [Double], rotation: Double,
                        feather: Double) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .radial)
        c.center = center
        c.radii = radii
        c.rotation = rotation
        c.feather = feather
        return c
    }

    private func linear(_ line: [Double]) -> MaskComponent {
        var c = MaskComponent(op: .add, kind: .linear)
        c.line = line
        return c
    }

    /// Bilinear read of a plane at a source-normalized point.
    private func sample(_ p: Plane, _ u: Double, _ v: Double) -> Double {
        let x = u * Double(p.width) - 0.5, y = v * Double(p.height) - 0.5
        let x0 = Int(Swift.max(0, Swift.min(Double(p.width - 1), x.rounded(.down))))
        let y0 = Int(Swift.max(0, Swift.min(Double(p.height - 1), y.rounded(.down))))
        let x1 = Swift.min(x0 + 1, p.width - 1), y1 = Swift.min(y0 + 1, p.height - 1)
        let fx = Num.saturate(x - Double(x0)), fy = Num.saturate(y - Double(y0))
        let a = Double(p[x0, y0]) * (1 - fx) + Double(p[x1, y0]) * fx
        let b = Double(p[x0, y1]) * (1 - fx) + Double(p[x1, y1]) * fx
        return a * (1 - fy) + b * fy
    }

    private let frames: [(String, Int, Int)] = [
        ("landscape 3:2", 300, 200), ("portrait 2:3", 200, 300), ("square", 240, 240),
        ("panorama 3:1", 360, 120),
    ]

    // MARK: - Handles land where the raster is

    /// Every resize dot `radialOffset` places on the rim reads alpha 0 just outside and
    /// more than 0 just inside, on every frame shape and at every turn.
    func testRadialHandlesSitOnTheRenderedRimOnEveryFrameShape() {
        for (name, w, h) in frames {
            for rotation in [0.0, 30, 45, 90, 135, -60] {
                let c = radial(center: [0.45, 0.55], radii: [0.3, 0.18],
                               rotation: rotation, feather: 0)
                let p = MaskRaster.rasterize(component: c, size: (width: w, height: h))
                for (ox, oy) in [(0.3, 0.0), (-0.3, 0.0), (0.0, 0.18), (0.0, -0.18)] {
                    let rim = MaskRaster.radialOffset((x: ox, y: oy), rotation: rotation,
                                                      width: w, height: h)
                    let out = MaskRaster.radialOffset((x: ox * 1.08, y: oy * 1.08),
                                                      rotation: rotation,
                                                      width: w, height: h)
                    let inn = MaskRaster.radialOffset((x: ox * 0.92, y: oy * 0.92),
                                                      rotation: rotation,
                                                      width: w, height: h)
                    let at = { (d: (x: Double, y: Double)) in
                        self.sample(p, 0.45 + d.x, 0.55 + d.y)
                    }
                    guard [rim, out, inn].allSatisfy({ d in
                        let u = 0.45 + d.x, v = 0.55 + d.y
                        return u > 0.02 && u < 0.98 && v > 0.02 && v < 0.98
                    }) else { continue }
                    XCTAssertLessThan(at(out), 0.05,
                                      "\(name) @\(rotation)°: alpha past the drawn rim")
                    XCTAssertGreaterThan(at(inn), 0.95,
                                         "\(name) @\(rotation)°: alpha inside the drawn rim")
                }
            }
        }
    }

    /// A linear gradient reads 0 at its start handle, 1 at its end, ½ halfway, and is
    /// constant along every line perpendicular to the drawn axis in PIXELS, on every
    /// frame shape.
    func testLinearHandlesBoundTheRampAndTheIsoLinesArePerpendicularInPixels() {
        for (name, w, h) in frames {
            for angle in [0.0, 20, 45, 77, 90, 160] {
                // A 0.3-long-edge axis through the centre, at `angle` in pixel space.
                let long = Double(Swift.max(w, h))
                let a = angle * .pi / 180
                let half = 0.15 * long
                let cx = Double(w) / 2, cy = Double(h) / 2
                let sx = cx - cos(a) * half, sy = cy - sin(a) * half
                let ex = cx + cos(a) * half, ey = cy + sin(a) * half
                let line = [sx / Double(w), sy / Double(h), ex / Double(w), ey / Double(h)]
                let p = MaskRaster.rasterize(component: linear(line),
                                             size: (width: w, height: h))
                func at(_ px: Double, _ py: Double) -> Double {
                    sample(p, px / Double(w), py / Double(h))
                }
                XCTAssertEqual(at(sx, sy), 0, accuracy: 0.02, "\(name) @\(angle)°: start")
                XCTAssertEqual(at(ex, ey), 1, accuracy: 0.02, "\(name) @\(angle)°: end")
                XCTAssertEqual(at(cx, cy), 0.5, accuracy: 0.02, "\(name) @\(angle)°: middle")
                // Walk the perpendicular through the middle: the value must not move.
                for k in [-0.1, -0.05, 0.05, 0.1] {
                    let px = cx - sin(a) * k * long, py = cy + cos(a) * k * long
                    guard px > 1, py > 1, px < Double(w) - 1, py < Double(h) - 1 else { continue }
                    XCTAssertEqual(at(px, py), 0.5, accuracy: 0.02,
                                   "\(name) @\(angle)°: iso-line bent at \(k)")
                }
            }
        }
    }

    // MARK: - Feather is smooth

    /// No step and no kink: along a gradient's axis neither the value nor its slope may
    /// jump between neighbouring pixels by more than a smooth curve of that span allows.
    func testGradientFalloffsHaveNoStepInValueOrSlope() {
        let w = 1200, h = 4
        // Linear: ramp spans 600 px, smoothstep max slope 1.5/600 per px.
        let lp = MaskRaster.rasterize(component: linear([0.25, 0.5, 0.75, 0.5]),
                                      size: (width: w, height: h))
        let lrow = (0..<w).map { Double(lp[$0, 1]) }
        assertSmooth(lrow, span: 600, "linear")

        // Radial, feather 50 / 100 / 10: falloff along the major axis.
        for feather in [10.0, 50, 100] {
            let c = radial(center: [0.5, 0.5], radii: [0.45, 0.45 * 1200 / 4],
                           rotation: 0, feather: feather)
            let rp = MaskRaster.rasterize(component: c, size: (width: w, height: h))
            let row = (0..<w).map { Double(rp[$0, 1]) }
            assertSmooth(row, span: 540 * feather / 100, "radial feather \(feather)")
        }
    }

    private func assertSmooth(_ row: [Double], span: Double, _ what: String) {
        let maxSlope = 1.5 / span            // smoothstep's peak slope over `span`
        let maxCurve = 6 / (span * span)     // its peak curvature
        var worstStep = 0.0, worstKink = 0.0
        for i in 1..<row.count {
            worstStep = Swift.max(worstStep, abs(row[i] - row[i - 1]))
        }
        for i in 1..<(row.count - 1) {
            worstKink = Swift.max(worstKink, abs(row[i + 1] - 2 * row[i] + row[i - 1]))
        }
        // Float32 storage quantizes at ~6e-8; allow that over the closed form.
        XCTAssertLessThanOrEqual(worstStep, maxSlope * 1.05 + 1e-6, "\(what): a step")
        XCTAssertLessThanOrEqual(worstKink, maxCurve * 1.1 + 1e-6, "\(what): a kink")
    }

    /// A luminance range over an EV ramp: fully selected inside the band, no step or
    /// kink at the shoulders, and the shoulder as wide as Smoothness says (50 → 1 EV).
    func testALuminanceRangeFallsOffSmoothlyOverItsShoulders() {
        let w = 1400
        // One column per 0.01 EV across the fixed −10…+4 EV axis.
        let src = ImageBuffer(width: w, height: 2) { u, _ in RGB(gray: pow(2, -10 + 14 * u)) }
        var c = MaskComponent(op: .add, kind: .lumaRange)
        c.lo = 6.0 / 14          // −4 EV
        c.hi = 10.0 / 14         // 0 EV
        c.smooth = 50
        let p = MaskRaster.rasterize(component: c, size: (width: w, height: 2), source: src)
        let row = (0..<w).map { Double(p[$0, 0]) }
        func at(_ ev: Double) -> Double { row[Int(((ev + 10) * 100).rounded())] }
        XCTAssertEqual(at(-4), 1, accuracy: 0.02)
        XCTAssertEqual(at(-2), 1, accuracy: 1e-6)
        XCTAssertEqual(at(0), 1, accuracy: 0.02)
        XCTAssertEqual(at(-5.5), 0, accuracy: 1e-6, "shoulder wider than 1 EV")
        XCTAssertEqual(at(1.5), 0, accuracy: 1e-6, "shoulder wider than 1 EV")
        XCTAssertEqual(at(-4.5), 0.5, accuracy: 0.02)
        XCTAssertEqual(at(0.5), 0.5, accuracy: 0.02)
        assertSmooth(row, span: 100, "luminance range")
    }

    /// Mask Feather (the Gaussian) is smooth too, and leaves no seam where a hard edge
    /// was.
    func testMaskFeatherLeavesNoStep() {
        let w = 400, h = 8
        var mask = Mask(name: "hard", components: [linear([0.5, 0.5, 0.5001, 0.5])])
        mask.refine.blur = 50                    // σ = 0.5% × 400 = 2 px
        let p = MaskRaster.combine(mask: mask, size: (width: w, height: h))
        let row = (0..<w).map { Double(p[$0, 4]) }
        let sigma = 0.005 * Double(w)
        let peak = 1 / (sigma * (2 * Double.pi).squareRoot())
        for i in 1..<w {
            XCTAssertLessThanOrEqual(abs(row[i] - row[i - 1]), peak * 1.05 + 1e-4,
                                     "feather stepped at \(i)")
        }
    }

    // MARK: - The algebra the fixture pins, through the real fold

    private struct MaskFixture: Decodable {
        struct Case: Decodable {
            struct Comp: Decodable { let op: String; let alpha: Double; let invert: Bool; let amount: Double }
            let name: String
            let stack: [Comp]
            let expected: Double
        }
        let cases: [Case]
    }

    /// `maskalgebra.json` was only ever checked against `MaskAlgebra.combined`, which no
    /// renderer calls. `MaskRaster.alpha` carries its own copy of the fold; this runs the
    /// fixture through that copy, with each component a constant matte.
    func testTheRasterFoldMatchesTheAlgebraFixture() throws {
        let fixture = try Fixtures.load("maskalgebra", as: MaskFixture.self)
        let kinds: [MaskKind] = [.aiSubject, .aiSky, .aiBackground]
        for c in fixture.cases {
            var mattes: [String: Plane] = [:]
            var comps: [MaskComponent] = []
            for (i, s) in c.stack.enumerated() {
                var comp = MaskComponent(op: MaskOp(rawValue: s.op)!, kind: kinds[i])
                comp.invert = s.invert
                comp.amount = s.amount
                comps.append(comp)
                mattes[kinds[i].rawValue] = constant(s.alpha, 6, 4)
            }
            let mask = Mask(name: c.name, components: comps)
            let p = MaskRaster.combine(mask: mask, size: (width: 6, height: 4),
                                       aiMattes: mattes)
            for i in 0..<(6 * 4) {
                XCTAssertEqual(Double(p.values[i]), c.expected, accuracy: 1e-6,
                               "fixture case \(c.name)")
            }
        }
    }

    // MARK: - A mask and its inverse

    private func softStack() -> [MaskComponent] {
        var sub = radial(center: [0.6, 0.4], radii: [0.2, 0.3], rotation: 25, feather: 60)
        sub.op = .subtract
        sub.amount = 70
        return [radial(center: [0.45, 0.5], radii: [0.35, 0.25], rotation: -10, feather: 40),
                sub, linear([0.1, 0.9, 0.9, 0.1])].enumerated().map { i, c in
            var c = c
            if i == 2 { c.op = .intersect; c.invert = true }
            return c
        }
    }

    /// Without a refinement, a mask and the same mask inverted add to exactly 1.
    func testAMaskPlusItsInverseIsOneEverywhere() {
        let w = 90, h = 60
        var mask = Mask(name: "m", components: softStack())
        let a = MaskRaster.combine(mask: mask, size: (width: w, height: h))
        mask.invert = true
        let b = MaskRaster.combine(mask: mask, size: (width: w, height: h))
        for i in 0..<(w * h) {
            XCTAssertEqual(Double(a.values[i] + b.values[i]), 1, accuracy: 1e-6, "pixel \(i)")
        }
    }

    /// Feather (the Gaussian) is linear, so it keeps the pair complementary too.
    func testAFeatheredMaskPlusItsInverseIsStillOne() {
        let w = 90, h = 60
        var mask = Mask(name: "m", components: softStack())
        mask.refine.blur = 80
        let a = MaskRaster.combine(mask: mask, size: (width: w, height: h))
        mask.invert = true
        let b = MaskRaster.combine(mask: mask, size: (width: w, height: h))
        var worst = 0.0
        for i in 0..<(w * h) { worst = Swift.max(worst, abs(Double(a.values[i] + b.values[i]) - 1)) }
        XCTAssertLessThan(worst, 1e-4, "feathered mask + inverse departs from 1 by \(worst)")
    }

    /// An inverted reference to a refined mask is its exact complement, whatever the
    /// refinement — unlike a copy with `invert` toggled, which re-runs Edge and Levels
    /// on the inverted fold (measured: sum − 1 spans −0.25…+0.41 at Levels/Edge).
    func testAnInvertedReferenceIsTheComplementOfARefinedMask() {
        let w = 120, h = 80
        let src = ImageBuffer(width: w, height: h) { u, v in
            RGB(gray: 0.18 * pow(2, -3 + 6 * u + sin(v * 9)))
        }
        for refine in [MaskRefine(edge: 30), MaskRefine(edge: -30),
                       MaskRefine(levelsLo: 20), MaskRefine(levelsGamma: 2),
                       MaskRefine(feather: 30, edge: 10, blur: 20)] {
            var subject = Mask(name: "subject", components: softStack())
            subject.refine = refine
            var ref = MaskComponent(op: .add, kind: .maskRef)
            ref.maskRef = subject.id
            ref.invert = true
            let rest = Mask(name: "everything else", components: [ref])
            let masks = [subject, rest]
            let a = MaskRaster.combine(mask: subject, size: (width: w, height: h),
                                       source: src, masks: masks)
            let b = MaskRaster.combine(mask: rest, size: (width: w, height: h),
                                       source: src, masks: masks)
            var worst = 0.0
            for i in 0..<(w * h) {
                worst = Swift.max(worst, abs(Double(a.values[i] + b.values[i]) - 1))
            }
            XCTAssertLessThan(worst, 1e-6, "\(refine): pair departs from 1 by \(worst)")
        }
    }

    /// Duplicate-and-Invert's copy is the source's complement under every Refine, and
    /// stays one when the source's Refine is edited afterwards.
    func testDuplicateAndInvertIsTheComplementAndStaysLinked() {
        let w = 120, h = 80
        let src = ImageBuffer(width: w, height: h) { u, v in
            RGB(gray: 0.18 * pow(2, -3 + 6 * u + sin(v * 9)))
        }
        func worstDeparture(_ a: Mask, _ b: Mask) -> Double {
            let masks = [a, b]
            let pa = MaskRaster.combine(mask: a, size: (width: w, height: h), source: src, masks: masks)
            let pb = MaskRaster.combine(mask: b, size: (width: w, height: h), source: src, masks: masks)
            var worst = 0.0
            for i in 0..<(w * h) { worst = Swift.max(worst, abs(Double(pa.values[i] + pb.values[i]) - 1)) }
            return worst
        }
        for refine in [MaskRefine(edge: 30), MaskRefine(levelsGamma: 2)] {
            var subject = Mask(name: "subject", components: softStack())
            subject.refine = refine
            var toggled = subject
            toggled.id = UUID().uuidString
            toggled.invert.toggle()
            XCTAssertGreaterThan(worstDeparture(subject, toggled), 0.05,
                                 "\(refine): the toggled copy was expected to show the seam")
            var copy = Mask.invertedReference(to: subject)
            copy.id = UUID().uuidString
            XCTAssertEqual(copy.adjust, subject.adjust)
            XCTAssertLessThan(worstDeparture(subject, copy), 1e-6, "\(refine)")
            subject.refine = MaskRefine(feather: 30, edge: -20, blur: 10)
            XCTAssertLessThan(worstDeparture(subject, copy), 1e-6, "\(refine): not linked")
        }
    }

    // MARK: - Brush

    private func stroke(_ pts: [(Double, Double)], size: Double = 0.06, feather: Double = 50,
                        flow: Double = 100, density: Double = 100,
                        erase: Bool = false) -> BrushStroke {
        BrushStroke(points: pts.map { BrushPoint(x: $0.0, y: $0.1) }, size: size,
                    feather: feather, flow: flow, density: density, erase: erase)
    }

    private func brushMask(_ strokes: [BrushStroke], _ w: Int, _ h: Int) -> Plane {
        var c = MaskComponent(op: .add, kind: .brush)
        c.strokesRef = "s"
        let mask = Mask(name: "b", components: [c])
        return MaskRaster.combine(mask: mask, size: (width: w, height: h),
                                  strokeSets: ["s": BrushStrokeSet(strokes: strokes)])
    }

    /// The same stored stroke at a fit-view raster and at a 4× zoomed raster selects the
    /// same region once both are seen at the same scale.
    func testABrushStrokeRasterisesTheSameAtEveryViewScale() {
        let s = [stroke([(0.2, 0.3), (0.4, 0.6), (0.7, 0.5), (0.8, 0.7)], flow: 40)]
        let small = brushMask(s, 600, 400)
        let large = brushMask(s, 2400, 1600)
        var worst = 0.0
        for y in 0..<400 {
            for x in 0..<600 {
                var sum = 0.0
                for fy in 0..<4 { for fx in 0..<4 { sum += Double(large[x * 4 + fx, y * 4 + fy]) } }
                worst = Swift.max(worst, abs(sum / 16 - Double(small[x, y])))
            }
        }
        XCTAssertLessThan(worst, 0.03, "a stroke at 1× and 4× disagree by \(worst)")
    }

    /// The END of a stroke agrees across view scales too. The arc-length walk used to
    /// stop up to one spacing short of the last point, and a spacing is 1 px at a small
    /// radius, so the cap sat up to a raster pixel short and moved with resolution.
    func testAStrokesEndCapIsTheSameAtEveryViewScale() {
        for flow in [40.0, 100] {
            let s = [stroke([(0.2, 0.3), (0.4, 0.6), (0.7, 0.5), (0.8, 0.7)], flow: flow)]
            let small = brushMask(s, 300, 200)
            let large = brushMask(s, 1200, 800)
            var worst = 0.0
            // The window round the last point, (0.8, 0.7).
            for y in 125..<155 {
                for x in 225..<255 {
                    var sum = 0.0
                    for fy in 0..<4 { for fx in 0..<4 { sum += Double(large[x * 4 + fx, y * 4 + fy]) } }
                    worst = Swift.max(worst, abs(sum / 16 - Double(small[x, y])))
                }
            }
            XCTAssertLessThan(worst, 0.06, "Flow \(flow): the end cap at 1× and 4× disagrees by \(worst)")
        }
    }

    /// Density is a ceiling no number of passes crosses; Flow accumulates toward it.
    func testPassesAccumulateTowardDensityAndNeverPastIt() {
        let w = 200, h = 100
        let line = [(0.2, 0.5), (0.8, 0.5)]
        let one = brushMask([stroke(line, feather: 0, flow: 5, density: 60)], w, h)
        let five = brushMask(Array(repeating: stroke(line, feather: 0, flow: 5, density: 60),
                                   count: 5), w, h)
        let many = brushMask(Array(repeating: stroke(line, feather: 0, flow: 5, density: 60),
                                   count: 60), w, h)
        let c1 = Double(one[100, 50]), c5 = Double(five[100, 50]), cN = Double(many[100, 50])
        XCTAssertGreaterThan(c1, 0)
        XCTAssertGreaterThan(c5, c1, "a second pass added nothing")
        XCTAssertLessThanOrEqual(c5, 0.6 + 1e-6)
        XCTAssertEqual(cN, 0.6, accuracy: 0.01, "many passes did not converge on Density")
        // Same path, the passes compose: 1 − (1 − c1/D)^5 of Density after five.
        XCTAssertEqual(c5, 0.6 * (1 - pow(1 - c1 / 0.6, 5)), accuracy: 1e-4)
        for i in 0..<(w * h) { XCTAssertLessThanOrEqual(Double(many.values[i]), 0.6 + 1e-6) }
    }

    /// A Flow 100, Feather 0 eraser clears what it covers, leaves the rest, and painting
    /// again afterwards works.
    func testEraseClearsUnderItAndRepaintingAfterwardsWorks() {
        let w = 200, h = 100
        let paint = stroke([(0.1, 0.5), (0.9, 0.5)], size: 0.2, feather: 0)
        let eraser = stroke([(0.5, 0.2), (0.5, 0.8)], size: 0.1, feather: 0, erase: true)
        let p = brushMask([paint, eraser], w, h)
        XCTAssertEqual(Double(p[100, 50]), 0, accuracy: 1e-6, "eraser left paint")
        XCTAssertEqual(Double(p[40, 50]), 1, accuracy: 1e-6, "eraser reached past itself")
        let again = brushMask([paint, eraser, paint], w, h)
        XCTAssertEqual(Double(again[100, 50]), 1, accuracy: 1e-6, "repaint after erase")
        // A low-flow eraser takes away a fraction, never adds.
        let soft = stroke([(0.5, 0.2), (0.5, 0.8)], size: 0.1, feather: 0, flow: 10, erase: true)
        let q = brushMask([paint, soft], w, h)
        XCTAssertGreaterThan(Double(q[100, 50]), 0)
        XCTAssertLessThan(Double(q[100, 50]), 1)
    }

    // MARK: - Local adjustments

    private func rampImage(_ w: Int = 32, _ h: Int = 20) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            let level = 0.18 * pow(2, -4 + 7 * u)
            return RGB(level * (1.1 - 0.3 * v), level, level * (0.8 + 0.4 * v))
        }
    }

    private func everything() -> LocalAdjust {
        var a = LocalAdjust()
        a.exposure = 1.3; a.contrast = 40; a.highlights = -50; a.shadows = 60
        a.whites = 30; a.blacks = -20; a.temp = 40; a.tint = -25; a.hue = 30
        a.sat = 50; a.vibrance = -30; a.texture = 40; a.clarity = -30; a.dehaze = 25
        a.sharpness = 60; a.colorTint = [0.9, 0.4, 0.2]; a.colorTintStrength = 50
        a.curve = CurveSet(point: [[0, 0], [0.5, 0.72], [1, 1]])
        var wheels = GradingWheels()
        wheels.shadows = Wheel(hue: 210, sat: 60, lum: 20)
        wheels.high = Wheel(hue: 40, sat: 40, lum: -10)
        a.wheels = wheels
        a.pointColors = [PointColor(sample: [0.3, 0.2, 0.1], range: 80,
                                    shift: HSLShift(h: 30, s: 40, l: 20))]
        return a
    }

    private func fullFrame() -> (MaskComponent, [String: Plane]) {
        (MaskComponent(op: .add, kind: .aiSubject), ["aiSubject": constant(1, 32, 20)])
    }

    /// Amount 0 is a no-op whatever the sliders say.
    func testAMaskAtAmountZeroLeavesThePictureExactlyAlone() {
        let image = rampImage()
        let (c, mattes) = fullFrame()
        var recipe = Recipe()
        var mask = Mask(name: "m", components: [c], adjust: everything())
        mask.amount = 0
        recipe.masks = [mask]
        let plain = ReferenceRenderer.render(image, plan: RenderPlan(recipe: Recipe()))
        let zero = ReferenceRenderer.render(image, plan: RenderPlan(recipe: recipe),
                                            inputs: .init(aiMattes: mattes))
        var worst = 0.0
        for y in 0..<20 { for x in 0..<32 {
            let a = plain[x, y], b = zero[x, y]
            worst = Swift.max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
        } }
        XCTAssertLessThan(worst, 1e-9, "Amount 0 moved the picture by \(worst)")
    }

    /// Inside a full mask at Amount 100, a local Exposure / Contrast / Saturation is the
    /// global control of the same value.
    func testAFullMaskAtAmountHundredIsTheGlobalControl() {
        // Uniform frames, so the global tone stage's guided mask equals the pixel and
        // the comparison is of the controls, not of the spatial filter.
        let frames = stride(from: -5.0, through: 3.0, by: 1.0).flatMap { ev in
            [RGB(1, 1, 1), RGB(1.2, 0.9, 0.6), RGB(0.5, 0.8, 1.3)].map { tint in
                ImageBuffer(width: 8, height: 4) { _, _ in tint * (0.18 * pow(2, ev)) }
            }
        }
        let c = MaskComponent(op: .add, kind: .aiSubject)
        let mattes = ["aiSubject": constant(1, 8, 4)]
        let cases: [(String, (inout LocalAdjust) -> Void, (inout Recipe) -> Void)] = [
            ("exposure", { $0.exposure = 1 }, { $0.develop.tone.exposure = 1 }),
            ("contrast", { $0.contrast = 50 }, { $0.develop.tone.contrast = 50 }),
            ("highlights", { $0.highlights = -60 }, { $0.develop.tone.highlights = -60 }),
            ("shadows", { $0.shadows = 60 }, { $0.develop.tone.shadows = 60 }),
            ("saturation", { $0.sat = 40 }, { $0.develop.color.saturation = 40 }),
            ("vibrance", { $0.vibrance = 40 }, { $0.develop.color.vibrance = 40 }),
        ]
        for (name, setMaskAdjust, global) in cases {
            var adjust = LocalAdjust()
            setMaskAdjust(&adjust)
            var masked = Recipe()
            masked.masks = [Mask(name: name, components: [c], adjust: adjust)]
            var globalRecipe = Recipe()
            global(&globalRecipe)
            var worst = 0.0
            for image in frames {
                let l = ReferenceRenderer.render(image, plan: RenderPlan(recipe: masked),
                                                 inputs: .init(aiMattes: mattes))
                let g = ReferenceRenderer.render(image, plan: RenderPlan(recipe: globalRecipe))
                let a = l[3, 2], b = g[3, 2]
                worst = Swift.max(worst, abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
            }
            XCTAssertLessThan(worst, 0.01, "local \(name) differs from global by \(worst)")
        }
    }
}
