// GeometryStageTests.swift
// S16's CPU definition (`GeometryStage`, `GeometryMap`, `GeometryResample`) against
// WS-25's spec (docs/quality/lanes/WS-25/SPEC.md, lines 1-9). Every test prints the
// number its spec line is judged on, so a run of this file IS the lane's measurement.

import XCTest
@testable import LumenCore

final class GeometryStageTests: XCTestCase {

    // MARK: Fixtures

    private func textured(_ w: Int, _ h: Int) -> ImageBuffer {
        ImageBuffer(width: w, height: h) { u, v in
            RGB(0.2 + 0.15 * sin(23 * u) * cos(17 * v),
                0.3 + 0.1 * u - 0.05 * v,
                0.25 + 0.1 * cos(31 * v + 7 * u))
        }
    }

    /// A buffer whose pixel (i, j) is f evaluated at its centre (i + ½, j + ½).
    private func sampled(_ w: Int, _ h: Int, _ f: (Double, Double) -> Double) -> ImageBuffer {
        var b = ImageBuffer(width: w, height: h)
        for y in 0..<h {
            for x in 0..<w {
                let v = f(Double(x) + 0.5, Double(y) + 0.5)
                b[x, y] = RGB(v, v, v)
            }
        }
        return b
    }

    private func maxDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
        XCTAssertEqual(a.width, b.width)
        XCTAssertEqual(a.height, b.height)
        var d = 0.0
        for i in 0..<Swift.min(a.pixels.count, b.pixels.count) {
            d = Swift.max(d, Double(abs(a.pixels[i] - b.pixels[i])))
        }
        return d
    }

    // MARK: 1-3: identity, copies, one map

    func testDefaultGeometryIsAnExactIdentity() {
        let image = textured(97, 61)
        for upright in [nil, Upright()] {
            let out = GeometryStage.apply(image, geometry: Geometry(upright: upright))
            XCTAssertEqual(out.width, image.width)
            XCTAssertEqual(out.height, image.height)
            XCTAssertEqual(out.pixels, image.pixels, "spec 1: bit-for-bit")
        }
        XCTAssertEqual(UprightSolver.homography(Upright(), sourceWidth: 100, sourceHeight: 50),
                       .identity, "spec 12")
        var off = Upright(mode: .off)
        off.segments = [Upright.Segment(x0: 0.1, y0: 0.1, x1: 0.12, y1: 0.9)]
        XCTAssertEqual(UprightSolver.homography(off, sourceWidth: 100, sourceHeight: 50),
                       .identity, "spec 12: stored lines with mode off change nothing")
    }

    func testIntegerCropIsACopyAndFlipIsAMirror() {
        let image = textured(100, 80)
        let geometry = Geometry(crop: Crop(x: 0.1, y: 0.25, w: 0.5, h: 0.5))
        let out = GeometryStage.apply(image, geometry: geometry)
        XCTAssertEqual(out.width, 50)
        XCTAssertEqual(out.height, 40)
        var d = 0.0
        for y in 0..<40 {
            for x in 0..<50 {
                let a = out[x, y], b = image[x + 10, y + 20]
                d = Swift.max(d, a.maxAbsDifference(b))
            }
        }
        print("spec 2: integer crop max |Δ| = \(d)")
        XCTAssertLessThanOrEqual(d, 1e-6)

        let flipped = GeometryStage.apply(image, geometry: Geometry(flipH: true))
        var m = 0.0
        for y in 0..<80 {
            for x in 0..<100 {
                m = Swift.max(m, flipped[x, y].maxAbsDifference(image[99 - x, y]))
            }
        }
        print("spec 2: flip max |Δ| = \(m)")
        XCTAssertLessThanOrEqual(m, 1e-6)
    }

    /// The closed form of `PipelineRenderer.geometryRects` + `sourceNormalized`, written
    /// the way that function computes it (Core Image y-up, rotation about the origin),
    /// so the map can be checked against the GPU's convention on a machine with no GPU.
    private func legacySourcePoint(_ geo: Geometry, w: Double, h: Double,
                                   u: Double, v: Double) -> (Double, Double) {
        let theta = -geo.angle * .pi / 180
        // orientation(p) = flip(R(theta) p)
        func orient(_ p: (Double, Double)) -> (Double, Double) {
            let r = (cos(theta) * p.0 - sin(theta) * p.1, sin(theta) * p.0 + cos(theta) * p.1)
            return geo.flipH ? (-r.0, r.1) : r
        }
        func unorient(_ p: (Double, Double)) -> (Double, Double) {
            let f = geo.flipH ? (-p.0, p.1) : p
            return (cos(-theta) * f.0 - sin(-theta) * f.1, sin(-theta) * f.0 + cos(-theta) * f.1)
        }
        let corners = [(0.0, 0.0), (w, 0), (0, h), (w, h)].map(orient)
        let minX = corners.map(\.0).min()!, maxX = corners.map(\.0).max()!
        let minY = corners.map(\.1).min()!, maxY = corners.map(\.1).max()!
        let r = CropGeometry.resolve(sourceWidth: w, sourceHeight: h, geometry: geo)
        let usableMinX = (minX + maxX) / 2 - r.usableWidth / 2
        let usableMaxY = (minY + maxY) / 2 + r.usableHeight / 2
        let tMinX = usableMinX + r.x
        let tMaxY = usableMaxY - r.y
        let point = (tMinX + u * r.width, tMaxY - v * r.height)
        let s = unorient(point)
        return (s.0 / w, 1 - s.1 / h)
    }

    func testTheMapRoundTripsAndAgreesWithTheGPUConvention() {
        var rng = SplitMix(seed: 7)
        var worstRound = 0.0, worstLegacy = 0.0
        for _ in 0..<200 {
            let w = Double(Int(rng.next() * 3000) + 50), h = Double(Int(rng.next() * 3000) + 50)
            var geo = Geometry(crop: Crop(x: rng.next() * 0.3, y: rng.next() * 0.3,
                                          w: 0.3 + rng.next() * 0.6, h: 0.3 + rng.next() * 0.6),
                               angle: (rng.next() - 0.5) * 90, flipH: rng.next() > 0.5)
            let map = GeometryMap(geometry: geo, sourceWidth: Int(w), sourceHeight: Int(h))
            for _ in 0..<5 {
                let u = rng.next(), v = rng.next()
                let s = map.sourceNormalized(displayedX: u, displayedY: v)
                let back = map.displayedNormalized(sourceX: s.x, sourceY: s.y)
                worstRound = Swift.max(worstRound, abs(back.x - u) * map.targetWidth,
                                       abs(back.y - v) * map.targetHeight)
                let legacy = legacySourcePoint(geo, w: w, h: h, u: u, v: v)
                worstLegacy = Swift.max(worstLegacy, abs(legacy.0 - s.x) * w,
                                        abs(legacy.1 - s.y) * h)
            }
            // And with an Upright, the round trip still closes.
            geo.upright = Upright(vertical: (rng.next() - 0.5) * 100, horizontal: (rng.next() - 0.5) * 60,
                                  rotate: (rng.next() - 0.5) * 6, aspect: (rng.next() - 0.5) * 50)
            let mapU = GeometryMap(geometry: geo, sourceWidth: Int(w), sourceHeight: Int(h))
            let u = rng.next(), v = rng.next()
            let s = mapU.sourceNormalized(displayedX: u, displayedY: v)
            let back = mapU.displayedNormalized(sourceX: s.x, sourceY: s.y)
            worstRound = Swift.max(worstRound, abs(back.x - u) * mapU.targetWidth,
                                   abs(back.y - v) * mapU.targetHeight)
        }
        print("spec 3: round trip worst \(worstRound) px, vs geometryRects closed form \(worstLegacy) px")
        XCTAssertLessThan(worstRound, 1e-6)
        XCTAssertLessThan(worstLegacy, 1e-6)
    }

    // MARK: 4: MTF

    /// Rotates a grating of `f` cycles/px by `degrees` and returns the fitted amplitude
    /// over the true amplitude, against the analytic rotation.
    private func mtf(f: Double, degrees: Double, filter: GeometryResample.Filter) -> Double {
        let n = 192
        let amp = 0.3
        let phi = 0.3 // grating orientation, so no axis is special
        let (cx, cy) = (cos(phi), sin(phi))
        let grating: (Double, Double) -> Double = { x, y in
            0.5 + amp * cos(2 * .pi * f * (x * cx + y * cy))
        }
        let image = sampled(n, n, grating)
        let geo = Geometry(angle: degrees)
        let map = GeometryMap(geometry: geo, sourceWidth: n, sourceHeight: n)
        let out = GeometryResample.apply(image, map: map, filter: filter)
        // Least squares on [1, cos, sin] of the true phase.
        var ata = [[Double]](repeating: [0, 0, 0], count: 3)
        var atb = [0.0, 0.0, 0.0]
        let border = 8
        for y in border..<(out.height - border) {
            for x in border..<(out.width - border) {
                let p = map.outputToSource.apply(Double(x) + 0.5, Double(y) + 0.5)
                let ph = 2 * .pi * f * (p.x * cx + p.y * cy)
                let row = [1, cos(ph), sin(ph)]
                let value = out[x, y].g
                for i in 0..<3 {
                    atb[i] += row[i] * value
                    for j in 0..<3 { ata[i][j] += row[i] * row[j] }
                }
            }
        }
        let sol = solve3(ata, atb)
        return hypot(sol[1], sol[2]) / amp
    }

    private func solve3(_ a: [[Double]], _ b: [Double]) -> [Double] {
        let m = Mat3(a)
        let inv = m.inverse
        return [inv.m[0][0] * b[0] + inv.m[0][1] * b[1] + inv.m[0][2] * b[2],
                inv.m[1][0] * b[0] + inv.m[1][1] * b[1] + inv.m[1][2] * b[2],
                inv.m[2][0] * b[0] + inv.m[2][1] * b[1] + inv.m[2][2] * b[2]]
    }

    func testRotationMTFBeatsBicubic() {
        for degrees in [1.0, 10.0] {
            var line = "spec 4: rotation \(degrees)°  MTF (f cy/px: lanczos3 / bicubic / bilinear)"
            for f in [0.1, 0.2, 0.25, 0.3, 0.35, 0.4] {
                let l = mtf(f: f, degrees: degrees, filter: .lanczos3)
                let c = mtf(f: f, degrees: degrees, filter: .bicubic)
                let b = mtf(f: f, degrees: degrees, filter: .bilinear)
                line += String(format: "\n    %.2f: %.3f / %.3f / %.3f", f, l, c, b)
                if f == 0.25 {
                    XCTAssertGreaterThanOrEqual(l, c, "spec 4 at \(degrees)°")
                    XCTAssertGreaterThanOrEqual(l, 0.90, "spec 4 at \(degrees)°")
                }
                if f == 0.35 { XCTAssertGreaterThanOrEqual(l, 0.75, "spec 4 at \(degrees)°") }
            }
            print(line)
        }
    }

    // MARK: 5-6: zone plate

    private func zonePlate(_ n: Int) -> (ImageBuffer, (Double, Double) -> Double) {
        let r0 = Double(n) / 2
        let f: (Double, Double) -> Double = { x, y in
            let dx = x - r0, dy = y - r0
            return 0.18 * (1 + 0.8 * cos(.pi * (dx * dx + dy * dy) / (2 * r0)))
        }
        return (sampled(n, n, f), f)
    }

    func testZonePlateRotationErrorAgainstTruth() {
        let n = 512
        let (image, truth) = zonePlate(n)
        let map = GeometryMap(geometry: Geometry(angle: 10), sourceWidth: n, sourceHeight: n)
        var rms: [GeometryResample.Filter: Double] = [:]
        for filter in [GeometryResample.Filter.lanczos3, .bicubic, .bilinear] {
            let out = GeometryResample.apply(image, map: map, filter: filter)
            var sum = 0.0, count = 0.0
            for y in 0..<out.height {
                for x in 0..<out.width {
                    let p = map.outputToSource.apply(Double(x) + 0.5, Double(y) + 0.5)
                    let r = hypot(p.x - Double(n) / 2, p.y - Double(n) / 2)
                    guard r < 0.9 * Double(n) / 2 else { continue }
                    let e = out[x, y].g - truth(p.x, p.y)
                    sum += e * e; count += 1
                }
            }
            rms[filter] = (sum / count).squareRoot() / (0.18 * 0.8)
        }
        let l = rms[.lanczos3]!, c = rms[.bicubic]!, b = rms[.bilinear]!
        print(String(format: "spec 5: zone plate 10° RMS error / amplitude, r < 0.9R: "
                     + "lanczos3 %.4f  bicubic %.4f  bilinear %.4f  (L/C %.3f, L/B %.3f)",
                     l, c, b, l / c, l / b))
        XCTAssertLessThanOrEqual(l, 0.75 * c, "spec 5")
        XCTAssertLessThanOrEqual(l, 0.5 * b, "spec 5")
    }

    func testDownscaleDoesNotAlias() {
        let n = 1024
        let (image, _) = zonePlate(n)
        let geo = Geometry(crop: Crop(x: 0.05, y: 0.05, w: 0.9, h: 0.9), angle: 3)
        let map = GeometryMap(geometry: geo, sourceWidth: n, sourceHeight: n,
                              targetLongEdge: Int(Double(n) * 0.25 * 0.9 * 0.95))
        let out = GeometryResample.apply(image, map: map)
        // Output Nyquist is 0.5 cy/output px = 0.5 · scale cy/source px; the local
        // frequency of the plate is r / (2 R). Past 1.5× that frequency Lanczos has
        // removed the signal, so whatever is left there folded back.
        let sourcePerOutput = map.minification
        let nyquistSource = 0.5 / sourcePerOutput
        let r0 = Double(n) / 2
        var sum = 0.0, count = 0.0
        for y in 0..<out.height {
            for x in 0..<out.width {
                let p = map.outputToSource.apply(Double(x) + 0.5, Double(y) + 0.5)
                let r = hypot(p.x - r0, p.y - r0)
                let f = r / (2 * r0)
                guard f > 1.5 * nyquistSource, r < r0 * 0.98 else { continue }
                let e = out[x, y].g - 0.18
                sum += e * e; count += 1
            }
        }
        let alias = (sum / Swift.max(count, 1)).squareRoot() / (0.18 * 0.8)
        let plan = GeometryResample.plan(minification: sourcePerOutput)
        print(String(format: "spec 6: %.3f× downscale (%d halvings, σ %.2f): folded-back RMS "
                     + "%.4f of amplitude over %d px", 1 / sourcePerOutput, plan.halvings,
                     plan.sigma, alias, Int(count)))
        XCTAssertGreaterThan(count, 100)
        XCTAssertLessThanOrEqual(alias, 0.02, "spec 6")
    }

    // MARK: 7: edges

    func testRotatedFlatFieldHasNoRimAndHardEdgeRingsLittle() {
        let flat = ImageBuffer(width: 300, height: 200) { _, _ in RGB(0.4, 0.4, 0.4) }
        var worst = 0.0, alpha = 1.0
        for angle in [10.0, -10, 1, 37] {
            let out = GeometryStage.apply(flat, geometry: Geometry(angle: angle))
            for y in 0..<out.height {
                for x in 0..<out.width {
                    worst = Swift.max(worst, abs(out[x, y].g - 0.4))
                    alpha = Swift.min(alpha, out.alpha(x, y))
                }
            }
        }
        print("spec 7: flat field rotated, worst |Δ| \(worst), min alpha \(alpha)")
        XCTAssertLessThanOrEqual(worst, 1e-4)
        XCTAssertGreaterThanOrEqual(alpha, 1 - 1e-4)

        // Revised line 7b (SPEC.md, "Revisions"): the edge a lens and a demosaic can
        // deliver, σ = 0.5 px. An ideal pixel step is not a sampled band-limited
        // signal; it is reported, not judged.
        func edgeOvershoot(sigma: Double, filter: GeometryResample.Filter) -> Double {
            let edge = sampled(200, 200) { x, _ in
                let t = sigma > 0 ? 0.5 * (1 + erf((x - 100.3) / (sigma * 2.0.squareRoot())))
                    : (x < 100.3 ? 0 : 1)
                return 0.1 + 0.5 * t
            }
            let map = GeometryMap(geometry: Geometry(angle: 1), sourceWidth: 200, sourceHeight: 200)
            let out = GeometryResample.apply(edge, map: map, filter: filter)
            var lo = Double.infinity, hi = -Double.infinity
            for y in 0..<out.height { for x in 0..<out.width {
                lo = Swift.min(lo, out[x, y].g); hi = Swift.max(hi, out[x, y].g)
            } }
            return Swift.max(hi - 0.6, 0.1 - lo) / 0.5
        }
        let real = edgeOvershoot(sigma: 0.5, filter: .lanczos3)
        let realBicubic = edgeOvershoot(sigma: 0.5, filter: .bicubic)
        let ideal = edgeOvershoot(sigma: 0, filter: .lanczos3)
        let idealBicubic = edgeOvershoot(sigma: 0, filter: .bicubic)
        print(String(format: "spec 7: edge at 1°, overshoot of the step: σ 0.5 px lanczos3 %.2f%% "
                     + "(bicubic %.2f%%); ideal pixel step lanczos3 %.2f%% (bicubic %.2f%%)",
                     real * 100, realBicubic * 100, ideal * 100, idealBicubic * 100))
        // Spec 7b is FAILED, not loosened: see REPORT.md. This pins today's number so a
        // change that rings MORE is caught; the spec's 1% bar stays where it was set.
        XCTAssertLessThanOrEqual(real, 0.035, "regression guard for spec 7b")
    }

    // MARK: 8: continuity

    /// Revised line 8 (SPEC.md, "Revisions"): continuity, tested as continuity — halve
    /// the step and the largest change between neighbours halves with it. A fixed pixel
    /// bound contradicted the inscribed-frame definition, whose width runs at 9 px/° near
    /// 22° on a 3:2 frame (`CropGeometry.usableSize`, the pinned branch).
    func testAngleResponseIsContinuous() {
        // 480 × 320: at 240 × 160 the whole-pixel quantization alone reads 0.52% (one
        // column entering a 113 px frame), which says nothing about continuity.
        let image = textured(480, 320)
        func worst(step: Double) -> (size: Int, mean: Double) {
            var previous: (w: Int, h: Int, mean: Double)?
            var worstSize = 0, worstMean = 0.0
            var angle = -45.0
            while angle <= 45 {
                let out = GeometryStage.apply(image, geometry: Geometry(angle: angle))
                var sum = 0.0
                for y in 0..<out.height { for x in 0..<out.width { sum += out[x, y].r } }
                let mean = sum / Double(out.count)
                if let p = previous {
                    worstSize = Swift.max(worstSize, abs(out.width - p.w), abs(out.height - p.h))
                    worstMean = Swift.max(worstMean, abs(mean - p.mean) / p.mean)
                }
                previous = (out.width, out.height, mean)
                angle += step
            }
            return (worstSize, worstMean)
        }
        let coarse = worst(step: 0.5), fine = worst(step: 0.25)
        print(String(format: "spec 8: largest neighbour change, 0.5° steps: %d px, mean %.3f%%; "
                     + "0.25° steps: %d px, mean %.3f%%", coarse.size, coarse.mean * 100,
                     fine.size, fine.mean * 100))
        XCTAssertLessThanOrEqual(Double(fine.size), 0.5 * Double(coarse.size) + 2)
        XCTAssertLessThan(coarse.mean, 0.005)
        // The mean is bounded, not halved: the output size is whole pixels, so one column
        // entering a 113 px frame moves the mean by up to a third of a percent at any
        // step size. That is quantization, and it is the same at 0.25° as at 0.5°.
        XCTAssertLessThan(fine.mean, 0.005)
    }

    // MARK: 9: sizes

    /// The delivered size is the crop's bounds in the straightened frame rounded
    /// outward to its pixel grid — what Core Image's integral render of the old
    /// `applyGeometry` crop delivered, and what the vignette centres on (spec 9, as
    /// revised: SPEC.md).
    func testOutputSizeIsTheStraightenedFramesIntegralCrop() {
        var rng = SplitMix(seed: 3)
        for _ in 0..<300 {
            let w = Double(Int(rng.next() * 2000) + 40), h = Double(Int(rng.next() * 2000) + 40)
            let geo = Geometry(crop: Crop(x: rng.next() * 0.3, y: rng.next() * 0.3,
                                          w: 0.2 + rng.next() * 0.7, h: 0.2 + rng.next() * 0.7),
                               angle: (rng.next() - 0.5) * 90, flipH: rng.next() > 0.5)
            let map = GeometryMap(geometry: geo, sourceWidth: Int(w), sourceHeight: Int(h))
            // The legacy closed form: bounding box of the rotated source, usable frame
            // centred on it, crop measured from its top-left.
            let theta = -geo.angle * .pi / 180
            let corners = [(0.0, 0.0), (w, 0), (0, h), (w, h)].map { p -> (Double, Double) in
                let r = (cos(theta) * p.0 - sin(theta) * p.1, sin(theta) * p.0 + cos(theta) * p.1)
                return geo.flipH ? (-r.0, r.1) : r
            }
            let midX = (corners.map(\.0).min()! + corners.map(\.0).max()!) / 2
            let midY = (corners.map(\.1).min()! + corners.map(\.1).max()!) / 2
            let r = CropGeometry.resolve(sourceWidth: w, sourceHeight: h, geometry: geo)
            let minX = midX - r.usableWidth / 2 + r.x
            let maxY = midY + r.usableHeight / 2 - r.y
            let expectedW = Int((minX + r.width - 1e-7).rounded(.up) - (minX + 1e-7).rounded(.down))
            let expectedH = Int((maxY - 1e-7).rounded(.up) - (maxY - r.height + 1e-7).rounded(.down))
            XCTAssertEqual(map.outputWidth, expectedW)
            XCTAssertEqual(map.outputHeight, expectedH)
            // Outward rounding of both edges: ⌈w⌉ or ⌈w⌉ + 1, never below the rounded size.
            XCTAssertGreaterThanOrEqual(map.outputWidth, r.outputWidth)
            XCTAssertLessThanOrEqual(Double(map.outputWidth), r.width.rounded(.up) + 1)
        }
        let image = textured(400, 300)
        let geo = Geometry(crop: Crop(x: 0.1, y: 0.1, w: 0.7, h: 0.6), angle: 7)
        let out = GeometryStage.apply(image, geometry: geo, targetLongEdge: 200)
        let map = GeometryMap(geometry: geo, sourceWidth: 400, sourceHeight: 300, targetLongEdge: 200)
        XCTAssertEqual(out.width, map.outputWidth)
        XCTAssertEqual(out.height, map.outputHeight)
    }

    /// WS-01 for WS-25: the crop tool's uncropped view on the CPU path.
    /// `PipelineRenderer.renderReference(showingUncropped:)` reaches S16 as `skipCrop`,
    /// which must frame exactly what `GeometryMap(skipCrop:)` — the map the GPU's
    /// `applyGeometry(skipCrop:)` evaluates — frames: the straightened frame without its
    /// crop, the same pixels as a geometry whose crop is the whole frame.
    func testSkipCropRendersTheStraightenedFrameWithoutItsCrop() {
        let image = textured(120, 90)
        let geo = Geometry(crop: Crop(x: 0.2, y: 0.1, w: 0.5, h: 0.6), angle: 4)
        let cropped = GeometryStage.apply(image, geometry: geo)
        let whole = GeometryStage.apply(image, geometry: geo, skipCrop: true)
        var uncropped = geo
        uncropped.crop = Crop()
        let expected = GeometryStage.apply(image, geometry: uncropped)
        let map = GeometryMap(geometry: geo, sourceWidth: 120, sourceHeight: 90, skipCrop: true)
        XCTAssertEqual(whole.width, map.outputWidth)
        XCTAssertEqual(whole.height, map.outputHeight)
        XCTAssertGreaterThan(whole.width, cropped.width)
        XCTAssertEqual(whole.pixels, expected.pixels,
                       "skipCrop must be the same stage with the crop left off")
    }
}

/// Deterministic test randomness.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Double(z >> 11) / Double(1 << 53)
    }
}
