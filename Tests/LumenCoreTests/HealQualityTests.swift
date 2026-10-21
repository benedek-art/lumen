// HealQualityTests.swift
// WS-56/57: the quality of ONE heal, measured against ground truth (HealQualitySupport).
// The synthetic cases run everywhere and hold the SPEC's thresholds; the corpus cases run
// only when LUMEN_HEAL_EVIDENCE names an output directory (and corpus/ is populated), and
// write the crops and metrics the lane's evidence sheets are built from.

import XCTest
@testable import LumenCore

final class HealQualityTests: XCTestCase {

    struct Case {
        let name: String
        let frame: String          // corpus-relative path, or "synthetic:<scene>"
        let defect: String         // dust | blemish | speck
        let cx: Double
        let cy: Double
        let radius: Double         // the heal circle, pixels
    }

    /// The defect is drawn at 0.75 of the circle — a photographer sizes the circle a
    /// little larger than what it covers, as LR's own default does.
    static func damaged(_ image: ImageBuffer, _ c: Case) -> ImageBuffer {
        let r = 0.75 * c.radius
        switch c.defect {
        case "dust": return HealQuality.addDust(image, cx: c.cx, cy: c.cy, radius: r, depth: 0.45)
        case "blemish": return HealQuality.addBlemish(image, cx: c.cx, cy: c.cy, radius: r)
        default:
            let local = image.bilinear(c.cx, c.cy)
            return HealQuality.addSpeck(image, cx: c.cx, cy: c.cy, radius: r,
                                        value: local * 4 + RGB(0.05, 0.05, 0.04))
        }
    }

    static func load(_ frame: String) -> ImageBuffer? {
        if frame.hasPrefix("synthetic:") {
            switch frame.dropFirst(10) {
            case "sky": return HealQuality.sky()
            case "foliage": return HealQuality.foliage()
            default: return HealQuality.skin()
            }
        }
        let root = ProcessInfo.processInfo.environment["LUMEN_CORPUS"]
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("corpus").path
        return HealQuality.readLFI(root + "/" + frame)
    }

    static let synthetic: [Case] = [
        Case(name: "syn-sky-dust", frame: "synthetic:sky", defect: "dust", cx: 128, cy: 96, radius: 12),
        Case(name: "syn-sky-dust-big", frame: "synthetic:sky", defect: "dust", cx: 120, cy: 90, radius: 22),
        Case(name: "syn-foliage-speck", frame: "synthetic:foliage", defect: "speck", cx: 128, cy: 96, radius: 12),
        Case(name: "syn-skin-blemish", frame: "synthetic:skin", defect: "blemish", cx: 128, cy: 96, radius: 10),
    ]

    static let corpus: [Case] = [
        Case(name: "983-sky-dust-a", frame: "lfi/983_canon-eos-5d-mark-iv.lfi", defect: "dust", cx: 800, cy: 260, radius: 14),
        Case(name: "983-sky-dust-b", frame: "lfi/983_canon-eos-5d-mark-iv.lfi", defect: "dust", cx: 1300, cy: 120, radius: 24),
        Case(name: "983-sky-dust-treeline", frame: "lfi/983_canon-eos-5d-mark-iv.lfi", defect: "dust", cx: 560, cy: 330, radius: 16),
        Case(name: "1840-sky-dust-a", frame: "lfi/1840_nikon-d850.lfi", defect: "dust", cx: 900, cy: 160, radius: 14),
        Case(name: "1840-sky-dust-b", frame: "lfi/1840_nikon-d850.lfi", defect: "dust", cx: 1300, cy: 120, radius: 22),
        Case(name: "1840-field-speck", frame: "lfi/1840_nikon-d850.lfi", defect: "speck", cx: 1200, cy: 1300, radius: 14),
        Case(name: "1840-tree-dust", frame: "lfi/1840_nikon-d850.lfi", defect: "dust", cx: 1700, cy: 300, radius: 22),
        Case(name: "skin-blemish-light", frame: "synthetic/skin_tones.lfi", defect: "blemish", cx: 1140, cy: 140, radius: 16),
        Case(name: "skin-blemish-mid", frame: "synthetic/skin_tones.lfi", defect: "blemish", cx: 140, cy: 390, radius: 16),
        Case(name: "skin-blemish-edge", frame: "synthetic/skin_tones.lfi", defect: "blemish", cx: 1340, cy: 200, radius: 18),
        Case(name: "6929-foliage-speck", frame: "lfi/6929_sony-ilce-7m4.lfi", defect: "speck", cx: 600, cy: 400, radius: 14),
        Case(name: "6929-foliage-dust", frame: "lfi/6929_sony-ilce-7m4.lfi", defect: "dust", cx: 1800, cy: 600, radius: 18),
        Case(name: "6929-ivy-speck", frame: "lfi/6929_sony-ilce-7m4.lfi", defect: "speck", cx: 500, cy: 840, radius: 12),
        Case(name: "6929-wall-dust", frame: "lfi/6929_sony-ilce-7m4.lfi", defect: "dust", cx: 400, cy: 1300, radius: 16),
    ]

    struct StrokeCase {
        let name: String
        let frame: String
        let points: [(Double, Double)]
        let radius: Double        // the brush half-width, pixels; the wire is 0.6 of it
    }

    static let strokeCases: [StrokeCase] = [
        StrokeCase(name: "stroke-syn-sky-wire", frame: "synthetic:sky",
                   points: [(40, 60), (120, 80), (210, 70)], radius: 6),
        StrokeCase(name: "stroke-983-sky-wire", frame: "lfi/983_canon-eos-5d-mark-iv.lfi",
                   points: [(600, 150), (880, 220), (1150, 180)], radius: 7),
        StrokeCase(name: "stroke-1840-sky-wire", frame: "lfi/1840_nikon-d850.lfi",
                   points: [(500, 80), (800, 110), (1100, 140)], radius: 8),
        StrokeCase(name: "stroke-skin-scratch", frame: "synthetic/skin_tones.lfi",
                   points: [(1070, 90), (1140, 140), (1220, 170)], radius: 8),
        StrokeCase(name: "stroke-6929-foliage", frame: "lfi/6929_sony-ilce-7m4.lfi",
                   points: [(500, 300), (600, 330), (700, 360)], radius: 9),
        StrokeCase(name: "stroke-6929-wall", frame: "lfi/6929_sony-ilce-7m4.lfi",
                   points: [(250, 1250), (420, 1300), (600, 1280)], radius: 8),
    ]

    static func runStroke(_ c: StrokeCase, mode: HealMode = .heal)
        -> (truth: ImageBuffer, damaged: ImageBuffer, healed: ImageBuffer,
            stroke: BrushStroke, metrics: HealQuality.HealMetrics)? {
        guard let truth = load(c.frame) else { return nil }
        let bad = HealQuality.addWire(truth, points: c.points, halfWidth: 0.6 * c.radius,
                                      depth: 0.6)
        let (healed, stroke) = HealQuality.healStroke(bad, points: c.points,
                                                      radius: c.radius, mode: mode)
        let reach = StrokeHeal.reach(of: stroke, edge: Double(Swift.max(truth.width, truth.height)))
        let m = HealQuality.strokeMetrics(healed: healed, truth: truth, points: c.points,
                                          reach: reach)
        return (truth, bad, healed, stroke, m)
    }

    static func run(_ c: Case, mode: HealMode = .heal,
                    feather: Double = HealSpot.defaultFeather)
        -> (truth: ImageBuffer, damaged: ImageBuffer, healed: ImageBuffer,
            spot: HealSpot, metrics: HealQuality.HealMetrics)? {
        guard let truth = load(c.frame) else { return nil }
        let bad = damaged(truth, c)
        let (healed, spot) = HealQuality.heal(bad, cx: c.cx, cy: c.cy, radius: c.radius,
                                              mode: mode, feather: feather)
        let reach = SpotRetouch.reach(of: spot, edge: Double(Swift.max(truth.width, truth.height)))
        let m = HealQuality.metrics(healed: healed, truth: truth, cx: c.cx, cy: c.cy,
                                    radius: reach)
        return (truth, bad, healed, spot, m)
    }

    // MARK: - Evidence (opt-in)

    func testCorpusEvidence() throws {
        guard let dir = ProcessInfo.processInfo.environment["LUMEN_HEAL_EVIDENCE"] else {
            throw XCTSkip("set LUMEN_HEAL_EVIDENCE=<dir> to write the corpus heal evidence")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var report: [[String: Any]] = []
        for c in Self.synthetic + Self.corpus {
            for (mode, tag) in [(HealMode.heal, "heal"), (.clone, "clone")] {
                guard let r = Self.run(c, mode: mode) else {
                    print("SKIP \(c.name): frame not found")
                    break
                }
                let w = r.truth.width, h = r.truth.height
                let half = Int(Swift.max(4 * c.radius, 48))
                let x0 = Swift.min(Swift.max(Int(c.cx) - half, 0), Swift.max(w - 2 * half, 0))
                let y0 = Swift.min(Swift.max(Int(c.cy) - half, 0), Swift.max(h - 2 * half, 0))
                let side = 2 * half
                if mode == .heal {
                    HealQuality.writeLFI(HealQuality.crop(r.truth, x: x0, y: y0, width: side, height: side),
                                         "\(dir)/\(c.name)-truth.lfi")
                    HealQuality.writeLFI(HealQuality.crop(r.damaged, x: x0, y: y0, width: side, height: side),
                                         "\(dir)/\(c.name)-damaged.lfi")
                }
                HealQuality.writeLFI(HealQuality.crop(r.healed, x: x0, y: y0, width: side, height: side),
                                     "\(dir)/\(c.name)-\(tag).lfi")
                let natural = HealQuality.naturalVariation(
                    truth: r.truth, cx: c.cx, cy: c.cy,
                    radius: SpotRetouch.reach(of: r.spot, edge: Double(Swift.max(w, h))))
                print(String(format: "%-24@ %-5@ %@  | natural ΔE %.2f bl %.2f  src (%.0f,%.0f)",
                             c.name as NSString,
                             tag as NSString, r.metrics.description,
                             natural.colourError, natural.blotch,
                             r.spot.sourceX * Double(w), r.spot.sourceY * Double(h)))
                var row: [String: Any] = ["case": c.name, "mode": tag,
                                          "cropX": x0, "cropY": y0, "side": side,
                                          "cx": c.cx, "cy": c.cy, "radius": c.radius,
                                          "sourceX": r.spot.sourceX * Double(w),
                                          "sourceY": r.spot.sourceY * Double(h)]
                for (k, v) in r.metrics.json { row[k] = v }
                row["naturalColourError"] = natural.colourError
                row["naturalBlotch"] = natural.blotch
                report.append(row)
            }
        }
        for c in Self.strokeCases {
            for (mode, tag) in [(HealMode.heal, "heal"), (.clone, "clone")] {
                guard let r = Self.runStroke(c, mode: mode) else { break }
                let w = r.truth.width, h = r.truth.height
                let xs = c.points.map { $0.0 }, ys = c.points.map { $0.1 }
                let xLo: Double = xs.min() ?? 0, xHi: Double = xs.max() ?? 0
                let yLo: Double = ys.min() ?? 0, yHi: Double = ys.max() ?? 0
                let cx = (xLo + xHi) / 2, cy = (yLo + yHi) / 2
                let spanX: Double = (xHi - xLo) / 2 + 4 * c.radius
                let spanY: Double = (yHi - yLo) / 2 + 4 * c.radius
                let half = Int(Swift.max(spanX, spanY))
                let x0 = Swift.min(Swift.max(Int(cx) - half, 0), Swift.max(w - 2 * half, 0))
                let y0 = Swift.min(Swift.max(Int(cy) - half, 0), Swift.max(h - 2 * half, 0))
                let side = 2 * half
                if mode == .heal {
                    HealQuality.writeLFI(HealQuality.crop(r.truth, x: x0, y: y0, width: side, height: side),
                                         "\(dir)/\(c.name)-truth.lfi")
                    HealQuality.writeLFI(HealQuality.crop(r.damaged, x: x0, y: y0, width: side, height: side),
                                         "\(dir)/\(c.name)-damaged.lfi")
                }
                HealQuality.writeLFI(HealQuality.crop(r.healed, x: x0, y: y0, width: side, height: side),
                                     "\(dir)/\(c.name)-\(tag).lfi")
                let dx = (r.stroke.retouch?.dx ?? 0) * Double(w)
                let dy = (r.stroke.retouch?.dy ?? 0) * Double(h)
                print(String(format: "%-24@ %-5@ %@  offset (%.0f,%.0f)", c.name as NSString,
                             tag as NSString, r.metrics.description, dx, dy))
                var row: [String: Any] = ["case": c.name, "mode": tag, "cropX": x0, "cropY": y0,
                                          "side": side, "cx": cx, "cy": cy,
                                          "radius": Double(half) / 2.2, "dx": dx, "dy": dy]
                for (k, v) in r.metrics.json { row[k] = v }
                report.append(row)
            }
        }
        let data = try JSONSerialization.data(withJSONObject: report,
                                              options: [.prettyPrinted, .sortedKeys])
        FileManager.default.createFile(atPath: "\(dir)/metrics.json", contents: data)
    }
}

// MARK: - The SPEC's measurable lines on synthetic fixtures (docs/quality/lanes/WS-56/SPEC.md)

final class HealQualitySpecTests: XCTestCase {

    /// S2: dust on a noisy sky heals with the sky's own grain, colour and no seam.
    func testS2SkyDustHealsInvisibly() throws {
        for c in HealQualityTests.synthetic where c.frame == "synthetic:sky" {
            let r = try XCTUnwrap(HealQualityTests.run(c))
            let m = r.metrics
            XCTAssertLessThan(m.colourError, 0.1, "\(c.name): \(m)")
            XCTAssertLessThan(m.blotch, 0.2, "\(c.name): \(m)")
            XCTAssertLessThan(abs(m.seamStep), 0.05, "\(c.name): \(m)")
            XCTAssertGreaterThan(m.textureRatio, 0.85, "\(c.name): the patch is smoothed: \(m)")
            XCTAssertLessThan(m.textureRatio, 1.15, "\(c.name): \(m)")
        }
    }

    /// S3: the feather lies outside the circle — a defect that fills the WHOLE circle is
    /// gone inside it at every feather, where it used to be blended back in.
    func testS3TheCircleIsFullyReplacedAtEveryFeather() {
        let clean = HealQuality.sky(noise: 0)
        let bad = HealQuality.addSpeck(clean, cx: 128, cy: 96, radius: 12,
                                       value: RGB(0.9, 0.9, 0.85))
        for feather in [0.0, 50, 100] {
            let (out, _) = HealQuality.heal(bad, cx: 128, cy: 96, radius: 12, feather: feather)
            var worst = 0.0
            HealQuality.forEachPixel(clean, 128, 96, 12, 0, 1) { x, y, _ in
                worst = Swift.max(worst, abs(log2(out[x, y].g / clean[x, y].g)))
            }
            XCTAssertLessThan(worst, 0.01, "feather \(feather): \(worst) stops of the speck left")
        }
    }

    /// S4: a source at a fractional offset borrows real pixels, not bilinear means — a
    /// Clone of white noise keeps the noise's amplitude.
    func testS4TheBorrowedGrainIsRealPixels() {
        var image = ImageBuffer(width: 96, height: 64)
        for y in 0..<64 { for x in 0..<96 {
            image[x, y] = RGB(gray: 0.18 * (1 + 0.2 * (spotNoise(x, y, 7) - 0.5)))
        } }
        let spot = HealSpot(id: "n", mode: .clone, x: 30.0 / 96, y: 32.0 / 64,
                            sourceX: 66.5 / 96, sourceY: 32.37 / 64, radius: 10.0 / 96,
                            feather: 0, opacity: 100)
        let out = SpotRetouch.apply(image, spots: [spot])
        func std(_ img: ImageBuffer, _ cx: Double) -> Double {
            var v: [Double] = []
            HealQuality.forEachPixel(img, cx, 32, 10, 0, 0.9) { x, y, _ in v.append(img[x, y].g) }
            let m = v.reduce(0, +) / Double(v.count)
            return (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        }
        XCTAssertGreaterThan(std(out, 30) / std(image, 30), 0.95)
    }

    /// S5: Heal re-lights by multiplying — a source two stops darker comes back with the
    /// destination's RELATIVE texture, where an additive membrane kept the source's
    /// absolute (quarter-size) texture and left a flat disc.
    func testS5HealKeepsRelativeTextureAcrossALevelChange() {
        var image = ImageBuffer(width: 128, height: 64)
        for y in 0..<64 { for x in 0..<128 {
            let level = x < 64 ? 0.36 : 0.09
            image[x, y] = RGB(gray: level * (1 + 0.3 * (spotNoise(x, y, 9) - 0.5)))
        } }
        let truth = image
        let bad = HealQuality.addSpeck(image, cx: 24, cy: 32, radius: 6, value: RGB(0.01, 0.01, 0.01))
        let spot = HealSpot(id: "m", mode: .heal, x: 24.0 / 128, y: 32.0 / 64,
                            sourceX: 100.0 / 128, sourceY: 32.0 / 64, radius: 8.0 / 128,
                            feather: 0, opacity: 100)
        let out = SpotRetouch.apply(bad, spots: [spot])
        let m = HealQuality.metrics(healed: out, truth: truth, cx: 24, cy: 32, radius: 8)
        XCTAssertGreaterThan(m.textureRatio, 0.8, "\(m)")
        XCTAssertLessThan(m.colourError, 1.0, "\(m)")
    }

    /// S6: on texture, the search picks a textured source and the heal lands within the
    /// picture's own patch-to-patch variation.
    func testS6TextureHealsWithinNaturalVariation() throws {
        for c in HealQualityTests.synthetic where c.frame == "synthetic:foliage" {
            let r = try XCTUnwrap(HealQualityTests.run(c))
            let edge = Double(Swift.max(r.truth.width, r.truth.height))
            let natural = HealQuality.naturalVariation(
                truth: r.truth, cx: c.cx, cy: c.cy, radius: SpotRetouch.reach(of: r.spot, edge: edge))
            XCTAssertLessThan(r.metrics.colourError, natural.colourError, "\(r.metrics)")
            XCTAssertLessThan(r.metrics.blotch, natural.blotch, "\(r.metrics)")
            XCTAssertGreaterThan(r.metrics.textureRatio, 0.8, "\(r.metrics)")
            XCTAssertLessThan(r.metrics.textureRatio, 1.25, "\(r.metrics)")
        }
    }

    /// S7: a source that matches but holds a second defect is not chosen. Pits on a
    /// grid cover the frame except one clean band; the source must come from the band,
    /// and the healed disc must hold no pit.
    func testS7TheSearchDoesNotPasteASecondDefect() throws {
        var image = HealQuality.sky(width: 200, height: 160, noise: 0.002)
        let clean = image
        for gy in stride(from: 10, to: 160, by: 14) {
            for gx in stride(from: 10, to: 200, by: 14) where gy < 100 {
                image = HealQuality.addDust(image, cx: Double(gx), cy: Double(gy), radius: 2.5,
                                            depth: 0.5)
            }
        }
        // The destination sits over a grid pit; the only pit-free discs within the
        // search's reach are in the clean band below y = 100.
        let bad = HealQuality.addDust(image, cx: 94, cy: 66, radius: 7, depth: 0.5)
        let (out, spot) = HealQuality.heal(bad, cx: 94, cy: 66, radius: 9, feather: 0)
        // The core: near the rim the heal rightly meets the destination's own (pitted)
        // surroundings.
        var darkest = 1.0
        HealQuality.forEachPixel(out, 94, 66, 9, 0, 0.7) { x, y, _ in
            darkest = Swift.min(darkest, out[x, y].g / clean[x, y].g)
        }
        XCTAssertGreaterThan(darkest, 0.9,
                             "a pit was pasted in from (\(spot.sourceX * 200), \(spot.sourceY * 160))")
    }

    /// S8: a wire across a sky heals with a painted stroke as cleanly as a spot does.
    func testS8StrokeOnSkyHealsInvisibly() throws {
        let c = try XCTUnwrap(HealQualityTests.strokeCases.first { $0.frame == "synthetic:sky" })
        let r = try XCTUnwrap(HealQualityTests.runStroke(c))
        XCTAssertLessThan(r.metrics.colourError, 0.1, "\(r.metrics)")
        XCTAssertLessThan(r.metrics.blotch, 0.4, "\(r.metrics)")
        XCTAssertLessThan(abs(r.metrics.seamStep), 0.05, "\(r.metrics)")
        XCTAssertGreaterThan(r.metrics.textureRatio, 0.85, "\(r.metrics)")
        XCTAssertLessThan(r.metrics.textureRatio, 1.15, "\(r.metrics)")
    }
}
