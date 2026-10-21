// SkyDetectorTests.swift
// WS-49 SPEC S6-S11: the classical sky detector on synthetic scenes with known truth,
// and the picker roster that decides whether Sky is offered.

import XCTest
@testable import LumenCore

final class SkyDetectorTests: XCTestCase {

    static let W = 512, H = 384
    static func noise(_ x: Int, _ y: Int, _ s: UInt32 = 3) -> Float {
        MatteRefineTests.noise(x, y, s)
    }

    struct Scene {
        var guide: MatteGuide
        var sky: [Bool]
        var gaps: [Bool]
        var object: [Bool]
    }

    /// Blue gradient sky over a jagged textured horizon at ~55% height, with a tree
    /// canopy whose 8 px gap cells show the sky, and optionally a blue car low down.
    static func scene(overcast: Bool = false, blueObject: Bool = false) -> Scene {
        let n = W * H
        var r = [Float](repeating: 0, count: n), g = r, b = r
        var sky = [Bool](repeating: false, count: n), gaps = sky, object = sky
        for y in 0..<H {
            for x in 0..<W {
                let i = y * W + x
                let fx = Double(x) / Double(W)
                let horizon = 0.55 * Double(H) + 12 * sin(fx * 9) + 6 * sin(fx * 31)
                let t = Float(Double(y) / horizon)
                let fine = noise(x, y) * 0.006
                var sr: Float, sg: Float, sb: Float
                if overcast {
                    sr = 0.78 + 0.08 * t; sg = 0.79 + 0.08 * t; sb = 0.81 + 0.07 * t
                } else {
                    sr = 0.30 + 0.38 * t; sg = 0.50 + 0.30 * t; sb = 0.88 + 0.07 * t
                }
                sr += fine; sg += fine; sb += fine
                let dx = fx - 0.72, dy = Double(y) / Double(H) - 0.30
                let inCanopy = dx * dx * 1.8 + dy * dy < 0.17 * 0.17
                let inTrunk = abs(fx - 0.72) < 0.015 && Double(y) / Double(H) > 0.3
                if Double(y) < horizon && !inTrunk {
                    if inCanopy {
                        let cell = (x / 8 + 7 * (y / 8)) % 4 == 0
                        if cell {
                            gaps[i] = true; sky[i] = true
                            r[i] = sr; g[i] = sg; b[i] = sb
                        } else {
                            let tex = noise(x / 2, y / 2, 9) * 0.08
                            r[i] = 0.12 + tex; g[i] = 0.25 + tex; b[i] = 0.08 + tex
                        }
                    } else {
                        sky[i] = true
                        r[i] = sr; g[i] = sg; b[i] = sb
                    }
                } else {
                    let tex = noise(x / 2, y / 2, 11) * 0.10 + noise(x, y, 5) * 0.04
                    r[i] = 0.30 + tex; g[i] = 0.36 + tex; b[i] = 0.16 + tex
                    if inTrunk { r[i] = 0.20 + tex; g[i] = 0.14 + tex; b[i] = 0.08 + tex }
                }
                if blueObject, x > 60, x < 200, y > 300, y < 350 {
                    object[i] = true
                    r[i] = 0.25 + fine; g[i] = 0.45 + fine; b[i] = 0.90 + fine
                }
            }
        }
        return Scene(guide: MatteGuide(width: W, height: H, r: r, g: g, b: b),
                     sky: sky, gaps: gaps, object: object)
    }

    static func iou(_ p: Plane, _ truth: [Bool]) -> Double {
        var inter = 0.0, union = 0.0
        for i in 0..<truth.count {
            let a = Double(p.values[i]), t = truth[i] ? 1.0 : 0.0
            inter += Swift.min(a, t); union += Swift.max(a, t)
        }
        return inter / Swift.max(union, 1)
    }

    static func fraction(_ p: Plane, _ region: [Bool]) -> Double {
        var s = 0.0, k = 0.0
        for i in 0..<region.count where region[i] { s += Double(p.values[i]); k += 1 }
        return s / Swift.max(k, 1)
    }

    // S6
    func testFindsSkyThroughBranches() throws {
        let s = Self.scene()
        let p = try XCTUnwrap(SkyDetector.detect(guide: s.guide))
        let iou = Self.iou(p, s.sky), gap = Self.fraction(p, s.gaps)
        print("S6 IoU \(iou) gaps \(gap)")
        XCTAssertGreaterThanOrEqual(iou, 0.90)
        XCTAssertGreaterThanOrEqual(gap, 0.70)
    }

    // S7
    func testOvercastSky() throws {
        let s = Self.scene(overcast: true)
        let p = try XCTUnwrap(SkyDetector.detect(guide: s.guide))
        let iou = Self.iou(p, s.sky)
        print("S7 IoU \(iou)")
        XCTAssertGreaterThanOrEqual(iou, 0.90)
    }

    // S8
    func testNoSkyMeansNothing() {
        let n = Self.W * Self.H
        // Textured everywhere (an interior, a forest floor).
        var r = [Float](repeating: 0, count: n), g = r, b = r
        for y in 0..<Self.H {
            for x in 0..<Self.W {
                let i = y * Self.W + x
                let tex = Self.noise(x / 2, y / 2, 13) * 0.15
                r[i] = 0.45 + tex; g[i] = 0.35 + tex; b[i] = 0.25 + tex
                // A bright smooth white wall across the bottom third.
                if y > 2 * Self.H / 3 { r[i] = 0.92; g[i] = 0.92; b[i] = 0.90 }
            }
        }
        let textured = MatteGuide(width: Self.W, height: Self.H, r: r, g: g, b: b)
        let dark = MatteGuide(width: Self.W, height: Self.H,
                              r: [Float](repeating: 0.05, count: n),
                              g: [Float](repeating: 0.05, count: n),
                              b: [Float](repeating: 0.07, count: n))
        for (name, guide) in [("textured", textured), ("dark", dark)] {
            let coverage = SkyDetector.detect(guide: guide).map { p in
                Double(p.values.reduce(0, +)) / Double(n)
            } ?? 0
            print("S8 \(name) coverage \(coverage)")
            XCTAssertLessThan(coverage, 0.01, name)
        }
    }

    // S9
    func testBlueObjectBelowHorizonIsNotSky() throws {
        let s = Self.scene(blueObject: true)
        let p = try XCTUnwrap(SkyDetector.detect(guide: s.guide))
        let taken = Self.fraction(p, s.object)
        print("S9 blue object taken \(taken)")
        XCTAssertLessThan(taken, 0.05)
    }

    // S10
    func testSkyCost() {
        let s = Self.scene()
        // Upscale the scene 4× to a 2048 px guide.
        let f = 4, w = Self.W * f, h = Self.H * f
        var r = [Float](repeating: 0, count: w * h), g = r, b = r
        for y in 0..<h {
            for x in 0..<w {
                let j = (y / f) * Self.W + x / f
                r[y * w + x] = s.guide.r[j]; g[y * w + x] = s.guide.g[j]
                b[y * w + x] = s.guide.b[j]
            }
        }
        let big = MatteGuide(width: w, height: h, r: r, g: g, b: b)
        let start = Date()
        _ = SkyDetector.detect(guide: big)
        let seconds = Date().timeIntervalSince(start)
        print("S10 2048 px detect+refine \(seconds) s")
        #if DEBUG
        // Debug builds are an order of magnitude slower; the threshold is a release one.
        XCTAssertLessThan(seconds, 20)
        #else
        XCTAssertLessThan(seconds, 1.5)
        #endif
    }

    // S11
    func testSkyIsOfferedTheRestAreNot() {
        XCTAssertEqual(MaskKind.aiSky.matteProvider, .vision)
        for kind in [MaskKind.aiObject, .aiLandscape, .depthRange] {
            XCTAssertEqual(kind.matteProvider, .model, kind.rawValue)
        }
        for kind in [MaskKind.aiSubject, .aiBackground, .aiPerson] {
            XCTAssertEqual(kind.matteProvider, .vision, kind.rawValue)
        }
    }

    // MARK: - Corpus harness (V1)

    /// Runs the detector on every `*.ppm` in LUMEN_WS49_SKY_INPUTS and writes
    /// `<name>.sky.pgm` next to it. The PPMs are neutral lumen-render renditions.
    func testCorpusSkyHarness() throws {
        guard let dir = ProcessInfo.processInfo.environment["LUMEN_WS49_SKY_INPUTS"] else {
            throw XCTSkip("evidence harness only")
        }
        try Self.writePPM(Self.scene().guide, to: "\(dir)/syn-canopy.ppm")
        try Self.writePPM(Self.scene(overcast: true).guide, to: "\(dir)/syn-overcast.ppm")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".ppm") }.sorted()
        for file in files {
            let guide = try Self.readPPM("\(dir)/\(file)")
            let start = Date()
            let p = SkyDetector.detect(guide: guide)
                ?? Plane(width: guide.width, height: guide.height)
            let cover = Double(p.values.reduce(0, +)) / Double(p.values.count)
            print("SKY \(file) \(guide.width)x\(guide.height) coverage \(cover) "
                  + "\(Date().timeIntervalSince(start)) s")
            try Self.writePGM(p, to: "\(dir)/\(file.dropLast(4)).sky.pgm")
            if let low = SkyDetector.probability(guide: guide) {
                try Self.writePGM(low, to: "\(dir)/\(file.dropLast(4)).low.pgm")
            }
        }
    }

    static func readPPM(_ path: String) throws -> MatteGuide {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var fields: [String] = [], cursor = 0, token = ""
        while fields.count < 4 {
            let c = data[cursor]; cursor += 1
            if c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 {
                if !token.isEmpty { fields.append(token); token = "" }
            } else { token.append(Character(UnicodeScalar(c))) }
        }
        let w = Int(fields[1])!, h = Int(fields[2])!
        return data.withUnsafeBytes { raw in
            MatteGuide(width: w, height: h, bytesPerRow: w * 3, channels: 3,
                       bytes: UnsafeRawBufferPointer(rebasing: raw[cursor...]))
        }
    }

    static func writePGM(_ p: Plane, to path: String) throws {
        var data = Data("P5\n\(p.width) \(p.height)\n255\n".utf8)
        data.append(contentsOf: p.values.map {
            UInt8(Swift.min(Swift.max($0, 0), 1) * 255 + 0.5)
        })
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func writePPM(_ g: MatteGuide, to path: String) throws {
        var data = Data("P6\n\(g.width) \(g.height)\n255\n".utf8)
        for i in 0..<(g.width * g.height) {
            for v in [g.r[i], g.g[i], g.b[i]] {
                data.append(UInt8(Swift.min(Swift.max(v, 0), 1) * 255 + 0.5))
            }
        }
        try data.write(to: URL(fileURLWithPath: path))
    }
}
