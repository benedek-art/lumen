// MatteRefineTests.swift
// WS-49 SPEC S1-S5: the guided upsampling of an AI matte, measured against truth.
//
// The "model matte" is the ground truth box-downsampled 8× and bilinearly stretched
// back, which is what a ~256 px model scaled up to the picture looks like, and exactly
// what `MaskRaster.mattePlane` used to deliver with no refinement at all.

import XCTest
@testable import LumenCore

final class MatteRefineTests: XCTestCase {

    static let W = 512, H = 384

    /// Deterministic noise in [-1, 1].
    static func noise(_ x: Int, _ y: Int, _ seed: UInt32 = 1) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 374_761_393
            &+ UInt32(truncatingIfNeeded: y) &* 668_265_263 &+ seed &* 2_246_822_519
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 32767.5 - 1
    }

    /// Truth: a disc plus a fan of 1 px "hairs" out of its top.
    static func truth(hair: Bool = true) -> Plane {
        var p = Plane(width: W, height: H)
        let cx = 256.3, cy = 230.7, r = 90.0
        for y in 0..<H {
            for x in 0..<W {
                let dx = Double(x) + 0.5 - cx, dy = Double(y) + 0.5 - cy
                if dx * dx + dy * dy <= r * r { p.values[y * W + x] = 1 }
            }
        }
        if hair {
            for k in 0..<9 {
                let angle = -Double.pi / 2 + (Double(k) - 4) * 0.12
                for t in stride(from: r - 2, to: r + 70, by: 0.25) {
                    let x = Int(cx + cos(angle) * t), y = Int(cy + sin(angle) * t)
                    if x >= 0, x < W, y >= 0, y < H { p.values[y * W + x] = 1 }
                }
            }
        }
        return p
    }

    /// The picture: orange subject on a blue-grey textured background, both noisy.
    static func guide(for truth: Plane) -> MatteGuide {
        var r = [Float](repeating: 0, count: W * H), g = r, b = r
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                let n = noise(x, y) * 0.03
                let texture = noise(x / 3, y / 3, 7) * 0.06
                if truth.values[i] > 0.5 {
                    r[i] = 0.85 + n; g[i] = 0.55 + n; b[i] = 0.30 + n
                } else {
                    r[i] = 0.35 + n + texture; g[i] = 0.42 + n + texture
                    b[i] = 0.55 + n + texture
                }
            }
        }
        return MatteGuide(width: W, height: H, r: r, g: g, b: b)
    }

    /// The model's own buffer, at 1/`factor` of the picture.
    static func native(_ truth: Plane, factor: Int = 8) -> Plane {
        Plane(width: W / factor, height: H / factor,
              values: MatteRefine.boxDown(truth.values, W, H, factor))
    }

    /// That buffer bilinearly stretched to the picture: the old delivered matte.
    static func coarse(_ truth: Plane, factor: Int = 8) -> Plane {
        native(truth, factor: factor).resized(width: W, height: H)
    }

    /// The refinement under test, handed the stretched buffer plus its native size —
    /// the harder case, and the one Vision's foreground request presents.
    static func refine(_ truth: Plane, _ guide: MatteGuide) -> Plane {
        MatteRefine.guidedUpsample(matte: coarse(truth), guide: guide,
                                   nativeLongEdge: W / 8)
    }

    /// Pixels within `radius` of the truth's boundary.
    static func band(_ truth: Plane, radius: Int) -> [Bool] {
        let m = MatteRefine.boxMean(truth.values, W, H, radius)
        return m.map { $0 > 1e-6 && $0 < 1 - 1e-6 }
    }

    static func mae(_ a: Plane, _ b: Plane, where mask: [Bool]) -> Double {
        var s = 0.0, k = 0
        for i in 0..<a.values.count where mask[i] {
            s += Double(abs(a.values[i] - b.values[i])); k += 1
        }
        return s / Double(Swift.max(k, 1))
    }

    // S1
    func testRefinementHalvesEdgeError() {
        let t = Self.truth()
        let c = Self.coarse(t)
        let q = Self.refine(t, Self.guide(for: t))
        let edge = Self.band(t, radius: 6)
        let before = Self.mae(c, t, where: edge)
        let after = Self.mae(q, t, where: edge)
        print("S1 edge-band MAE bilinear \(before) refined \(after) ratio \(after / before)")
        XCTAssertLessThanOrEqual(after, before * 0.5)
    }

    // S2
    func testRefinedEdgeIsNarrow() {
        var t = Plane(width: Self.W, height: Self.H)
        for y in 0..<Self.H { for x in 203..<Self.W { t.values[y * Self.W + x] = 1 } }
        let c = Self.coarse(t)
        let q = Self.refine(t, Self.guide(for: t))
        func width(_ p: Plane) -> Double {
            var total = 0
            for y in 100..<300 {
                for x in 0..<Self.W {
                    let v = p.values[y * Self.W + x]
                    if v > 0.1 && v < 0.9 { total += 1 }
                }
            }
            return Double(total) / 200
        }
        print("S2 10-90 width bilinear \(width(c)) refined \(width(q))")
        XCTAssertGreaterThanOrEqual(width(c), 6)
        XCTAssertLessThanOrEqual(width(q), 3)
    }

    // S3
    func testNoHalo() {
        let t = Self.truth()
        let q = Self.refine(t, Self.guide(for: t))
        let near = MatteRefine.boxMean(t.values, Self.W, Self.H, 4)
        var outside = 0, lit = 0
        for i in 0..<t.values.count where near[i] == 0 {
            outside += 1
            if q.values[i] > 0.05 { lit += 1 }
        }
        let fraction = Double(lit) / Double(outside)
        print("S3 halo fraction \(fraction)")
        XCTAssertLessThan(fraction, 0.002)
    }

    // S4
    func testNoShiftAndOrientationEquivariant() {
        let t = Self.truth(hair: false)
        let g = Self.guide(for: t)
        let c = Self.coarse(t)
        let q = Self.refine(t, g)
        func centroid(_ p: Plane) -> (Double, Double) {
            var sx = 0.0, sy = 0.0, s = 0.0
            for y in 0..<Self.H {
                for x in 0..<Self.W {
                    let v = Double(p.values[y * Self.W + x])
                    sx += v * Double(x); sy += v * Double(y); s += v
                }
            }
            return (sx / s, sy / s)
        }
        let a = centroid(t), b = centroid(q)
        print("S4 centroid shift \(b.0 - a.0), \(b.1 - a.1)")
        XCTAssertEqual(a.0, b.0, accuracy: 0.5)
        XCTAssertEqual(a.1, b.1, accuracy: 0.5)

        func flip(_ v: [Float]) -> [Float] {
            var out = v
            for y in 0..<Self.H {
                for x in 0..<Self.W { out[y * Self.W + x] = v[y * Self.W + (Self.W - 1 - x)] }
            }
            return out
        }
        let fg = MatteGuide(width: Self.W, height: Self.H, r: flip(g.r), g: flip(g.g),
                            b: flip(g.b))
        let fq = MatteRefine.guidedUpsample(
            matte: Plane(width: Self.W, height: Self.H, values: flip(c.values)), guide: fg,
            nativeLongEdge: Self.W / 8)
        let back = flip(fq.values)
        var worst: Float = 0
        for i in 0..<back.count { worst = Swift.max(worst, abs(back[i] - q.values[i])) }
        print("S4 flip worst \(worst)")
        XCTAssertLessThan(worst, 1e-4)
    }

    // S5
    func testConstantMatteIsIdentity() {
        let t = Self.truth()
        let g = Self.guide(for: t)
        for fill in [0.0, 1.0] {
            let p = Plane(width: 64, height: 48, fill: fill)
            let q = MatteRefine.guidedUpsample(matte: p, guide: g)
            XCTAssertTrue(q.values.allSatisfy { Double($0) == fill }, "fill \(fill)")
        }
        let q = Self.refine(t, g)
        XCTAssertTrue(q.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
    }

    // S2b: the realistic edge. Low contrast (subject 0.08 from background), a wavy
    // boundary, and a 3 px anti-aliased edge in the guide itself — the case S2's
    // perfect step flatters (verifier round 1).
    func testRefinedEdgeIsNarrowOnARealisticEdge() {
        let W = Self.W, H = Self.H
        var t = Plane(width: W, height: H)
        var r = [Float](repeating: 0, count: W * H), g = r, b = r
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                let e = 203.5 + 6 * sin(Double(y) / 17)
                let a = Float(Swift.min(Swift.max((Double(x) + 0.5 - e) / 3 + 0.5, 0), 1))
                t.values[i] = a > 0.5 ? 1 : 0
                let n = Self.noise(x, y) * 0.03, tex = Self.noise(x / 3, y / 3, 7) * 0.06
                r[i] = a * 0.50 + (1 - a) * (0.42 + tex) + n
                g[i] = a * 0.48 + (1 - a) * (0.44 + tex) + n
                b[i] = a * 0.45 + (1 - a) * (0.50 + tex) + n
            }
        }
        let guide = MatteGuide(width: W, height: H, r: r, g: g, b: b)
        let c = Self.coarse(t)
        let q = MatteRefine.guidedUpsample(matte: c, guide: guide, nativeLongEdge: W / 8)
        func width(_ p: Plane) -> Double {
            var total = 0
            for y in 100..<300 {
                for x in 0..<W where p.values[y * W + x] > 0.1 && p.values[y * W + x] < 0.9 {
                    total += 1
                }
            }
            return Double(total) / 200
        }
        print("S2b 10-90 width bilinear \(width(c)) refined \(width(q))")
        XCTAssertLessThanOrEqual(width(q), 4.5)
        XCTAssertLessThanOrEqual(width(q), width(c) * 0.5)
    }

    // S13: a matte the model was uniformly unsure about stays what it was.
    func testSoftMatteIsNotCrushed() {
        let g = Self.guide(for: Self.truth())
        for level in [0.3, 0.6] {
            let q = MatteRefine.guidedUpsample(
                matte: Plane(width: 64, height: 48, fill: level), guide: g)
            let mean = Double(q.values.reduce(0, +)) / Double(q.values.count)
            print("S13 constant \(level) -> mean \(mean)")
            XCTAssertEqual(mean, level, accuracy: 0.02)
        }
    }

    // S14: hair strands keep their length. Mean alpha on the truth's strand pixels
    // 15-70 px out from the disc, for a model at 1/8 of the picture (a strand is 12%
    // of one model pixel: information-limited) and at 1/4 (nearer Vision's own
    // resolution against a 2048 px guide).
    func testHairTipsSurvive() {
        let t = Self.truth(), disc = Self.truth(hair: false)
        let g = Self.guide(for: t)
        let near = MatteRefine.boxMean(disc.values, Self.W, Self.H, 15)
        for factor in [8, 4] {
            let c = Self.coarse(t, factor: factor)
            let q = MatteRefine.guidedUpsample(matte: c, guide: g,
                                               nativeLongEdge: Self.W / factor)
            var s = 0.0, k = 0.0, old = 0.0
            for i in 0..<t.values.count where t.values[i] > 0.5 && near[i] == 0 {
                s += Double(q.values[i]); old += Double(c.values[i]); k += 1
            }
            print("S14 1/\(factor) model: strand tip alpha refined \(s / k) bilinear \(old / k)")
            XCTAssertGreaterThanOrEqual(s / k, (old / k) * 1.5, "1/\(factor)")
        }
    }

    // S15: a NaN stays local and never reaches the output.
    func testNaNIsContained() {
        let t = Self.truth(hair: false)
        let g = Self.guide(for: t)
        let c = Self.coarse(t)
        let clean = MatteRefine.guidedUpsample(matte: c, guide: g, nativeLongEdge: Self.W / 8)
        var poisoned = c
        poisoned.values[100 * Self.W + 100] = .nan
        var pg = g
        pg.r[50 * Self.W + 300] = .nan
        let q = MatteRefine.guidedUpsample(matte: poisoned, guide: pg,
                                           nativeLongEdge: Self.W / 8)
        XCTAssertTrue(q.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 })
        var worst: Float = 0
        for y in 0..<Self.H {
            for x in 0..<Self.W {
                let far = abs(x - 100) > 40 || abs(y - 100) > 40
                let farG = abs(x - 300) > 40 || abs(y - 50) > 40
                if far && farG {
                    let i = y * Self.W + x
                    worst = Swift.max(worst, abs(q.values[i] - clean.values[i]))
                }
            }
        }
        print("S15 worst change away from the NaNs \(worst)")
        XCTAssertLessThan(worst, 1e-5)
    }

    // V2 evidence: writes the hair-fan crop when LUMEN_WS49_EVIDENCE is set.
    func testWriteRefineEvidence() throws {
        guard let dir = ProcessInfo.processInfo.environment["LUMEN_WS49_EVIDENCE"] else {
            throw XCTSkip("evidence harness only")
        }
        let t = Self.truth()
        let g = Self.guide(for: t)
        let c = Self.coarse(t)
        let q = Self.refine(t, g)
        try SkyDetectorTests.writePGM(t, to: "\(dir)/refine-truth.pgm")
        try SkyDetectorTests.writePGM(c, to: "\(dir)/refine-bilinear.pgm")
        try SkyDetectorTests.writePGM(q, to: "\(dir)/refine-guided.pgm")
        try SkyDetectorTests.writePPM(g, to: "\(dir)/refine-guide.ppm")
    }
}

// S12: the 2048 → 1024 draft fit keeps a one-pixel strand's coverage.
final class MattePlaneFitTests: XCTestCase {
    func testShrinkingKeepsThinStrandCoverage() {
        var matte = Plane(width: 2048, height: 1366)
        // Vertical one-pixel strands on odd columns: a 2:1 bilinear resize samples
        // exactly between pixel pairs, a 2:1 box averages each pair.
        for y in 0..<1366 { for x in stride(from: 101, to: 1900, by: 40) {
            matte.values[y * 2048 + x] = 1
        } }
        let fitted = MaskRaster.mattePlane(.aiSubject, 1024, 683,
                                           [MaskKind.aiSubject.rawValue: matte])
        let before = matte.values.reduce(0, +) / Float(matte.values.count)
        let after = fitted.values.reduce(0, +) / Float(fitted.values.count)
        print("S12 coverage before \(before) after \(after)")
        XCTAssertEqual(Double(after), Double(before), accuracy: Double(before) * 0.02)
        // And each strand is still there on every row.
        for x in stride(from: 50, to: 950, by: 20) {
            XCTAssertGreaterThan(fitted[x, 300], 0.4, "strand at fitted column \(x)")
        }
    }
}
