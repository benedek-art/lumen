// DustDetectionTests.swift
// WS-56: dust auto-detect (`DustDetection`) — finds the specks on smooth areas, leaves
// texture and edges alone, sizes the circle to cover the speck, and the windowed
// whole-frame search finds the same specks as a whole-buffer one.

import XCTest
@testable import LumenCore

final class DustDetectionTests: XCTestCase {

    /// Ten dust shadows of radius 4–20 px and depth 8–40 % on a noisy sky.
    static let specks: [(x: Double, y: Double, r: Double, depth: Double)] = [
        (60, 60, 4, 0.12), (160, 70, 6, 0.08), (270, 60, 9, 0.25), (400, 80, 14, 0.4),
        (520, 70, 5, 0.15), (90, 250, 20, 0.2), (230, 260, 7, 0.3), (350, 300, 11, 0.1),
        (470, 280, 16, 0.12), (560, 330, 4, 0.35),
    ]

    static func dustySky() -> (ImageBuffer, ImageBuffer) {
        let clean = HealQuality.sky(width: 600, height: 400, noise: 0.003)
        var image = clean
        for s in specks {
            image = HealQuality.addDust(image, cx: s.x, cy: s.y, radius: s.r, depth: s.depth)
        }
        return (clean, image)
    }

    func testFindsEveryDustSpeckOnASkyAndNothingElse() {
        let (clean, dusty) = Self.dustySky()
        let found = DustDetection.find(in: dusty)
        for s in Self.specks {
            let hit = found.first { hypot($0.x - s.x, $0.y - s.y) < Swift.max(s.r * 0.5, 2) }
            XCTAssertNotNil(hit, "missed the speck at (\(s.x), \(s.y)) r \(s.r) depth \(s.depth)")
            if let hit {
                // The circle covers the shadow and is not wildly bigger than it.
                XCTAssertGreaterThanOrEqual(hit.radius, s.r * 0.95, "too small for r \(s.r)")
                XCTAssertLessThanOrEqual(hit.radius, s.r * 2.6, "too big for r \(s.r)")
            }
        }
        XCTAssertLessThanOrEqual(found.count, Self.specks.count, "false positives: \(found)")
        XCTAssertEqual(DustDetection.find(in: clean).count, 0, "dust found on a clean sky")
    }

    func testLeavesTextureAndEdgesAlone() {
        XCTAssertEqual(DustDetection.find(in: HealQuality.foliage(width: 400, height: 300)).count,
                       0, "foliage is not dust")
        // A hard edge and a thin dark line: neither is round.
        var edge = HealQuality.sky(width: 300, height: 200, noise: 0.003)
        for y in 0..<200 { for x in 150..<300 { edge[x, y] = edge[x, y] * 0.5 } }
        for x in 0..<300 { for y in 60..<62 { edge[x, y] = edge[x, y] * 0.6 } }
        XCTAssertEqual(DustDetection.find(in: edge).count, 0)
    }

    /// A noisy, high-ISO sky (3.5 % per-pixel noise at the working size) still gives up
    /// its clear specks, and invents none.
    func testANoisySkyStillGivesUpItsDust() {
        let clean = HealQuality.sky(width: 600, height: 400, noise: 0.006)
        var dusty = clean
        let specks: [(Double, Double, Double)] = [(150, 120, 8), (420, 100, 12), (300, 300, 6)]
        for s in specks { dusty = HealQuality.addDust(dusty, cx: s.0, cy: s.1, radius: s.2, depth: 0.3) }
        let found = DustDetection.find(in: dusty)
        for s in specks {
            XCTAssertTrue(found.contains { hypot($0.x - s.0, $0.y - s.1) < s.2 },
                          "missed the speck at (\(s.0), \(s.1)) on a noisy sky")
        }
        XCTAssertLessThanOrEqual(found.count, specks.count)
        XCTAssertEqual(DustDetection.find(in: clean).count, 0)
    }

    func testSensitivityFindsFainterDust() {
        let clean = HealQuality.sky(width: 300, height: 200, noise: 0.003)
        let faint = HealQuality.addDust(clean, cx: 150, cy: 100, radius: 8, depth: 0.05)
        XCTAssertTrue(DustDetection.find(in: faint, sensitivity: 0).isEmpty)
        XCTAssertFalse(DustDetection.find(in: faint, sensitivity: 100).isEmpty)
    }

    /// The probes' windows cover the frame, and merging what each finds gives every
    /// speck once.
    func testTheWindowedSearchFindsEachSpeckOnce() {
        let (_, dusty) = Self.dustySky()
        // Pretend the frame is 4× bigger than the working size so it is windowed.
        let probes = DustDetection.probes(sourceWidth: 600, sourceHeight: 400)
        XCTAssertGreaterThanOrEqual(probes.count, 1)
        var windows: [(specks: [DustDetection.Speck], window: SpotSourceSearch.Window,
                       bufferWidth: Int, bufferHeight: Int)] = []
        for probe in probes {
            let window = SpotSourceSearch.window(for: probe, sourceWidth: 600, sourceHeight: 400)
            let cut = HealQuality.crop(dusty, x: window.x, y: window.y, width: window.width,
                                       height: window.height)
            windows.append((DustDetection.find(in: cut), window, cut.width, cut.height))
        }
        let merged = DustDetection.merge(windows, sourceWidth: 600, sourceHeight: 400)
        for s in Self.specks {
            let hits = merged.filter { hypot($0.x * 600 - s.x, $0.y * 400 - s.y) < Swift.max(s.r, 3) }
            XCTAssertEqual(hits.count, 1, "speck at (\(s.x), \(s.y)) found \(hits.count) times")
        }
        XCTAssertLessThanOrEqual(merged.count, Self.specks.count)
    }

    func testProbesTileALargeFrame() {
        let probes = DustDetection.probes(sourceWidth: 7008, sourceHeight: 4672)
        var covered = 0, total = 0
        for gy in stride(from: 0, to: 4672, by: 97) {
            for gx in stride(from: 0, to: 7008, by: 97) {
                total += 1
                if probes.contains(where: {
                    let w = SpotSourceSearch.window(for: $0, sourceWidth: 7008, sourceHeight: 4672)
                    return gx >= w.x && gx < w.x + w.width && gy >= w.y && gy < w.y + w.height
                }) { covered += 1 }
            }
        }
        XCTAssertEqual(covered, total, "part of the frame is never searched")
        let scale = SpotSourceSearch.window(for: probes[0], sourceWidth: 7008,
                                            sourceHeight: 4672).scale
        XCTAssertEqual(scale * 7008, DustDetection.workingLongEdge, accuracy: 1)
        XCTAssertLessThan(probes.count, 40, "a click renders every window")
    }

    // MARK: Corpus (opt-in)

    func testCorpusDustEvidence() throws {
        guard let dir = ProcessInfo.processInfo.environment["LUMEN_HEAL_EVIDENCE"] else {
            throw XCTSkip("set LUMEN_HEAL_EVIDENCE=<dir>")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let frames: [(String, [(Double, Double, Double, Double)])] = [
            ("lfi/983_canon-eos-5d-mark-iv.lfi",
             [(300, 120, 6, 0.15), (700, 200, 10, 0.25), (1100, 90, 4, 0.2), (1500, 60, 14, 0.12),
              (900, 330, 8, 0.1), (400, 1300, 9, 0.2), (1900, 1400, 7, 0.3)]),
            ("lfi/1840_nikon-d850.lfi",
             [(300, 60, 6, 0.15), (900, 120, 12, 0.2), (1500, 80, 5, 0.1), (2000, 150, 9, 0.3),
              (1200, 1200, 8, 0.25)]),
            ("lfi/6929_sony-ilce-7m4.lfi", []),
            ("lfi/2545_panasonic-dmc-gx85.lfi", []),
            ("lfi/4694_canon-eos-r5.lfi", []),
            ("lfi/832_nikon-d7200.lfi", []),
            ("lfi/6933_sony-ilce-7m4.lfi", []),
            ("lfi/7881_canon-eos-r5-mark-ii.lfi", []),
            ("lfi/3582_nikon-z-6.lfi", []),
            ("lfi/1192_fujifilm-x-t10.lfi", []),
        ]
        var lines: [String] = []
        for (frame, specks) in frames {
            guard let clean = HealQualityTests.load(frame) else { continue }
            var dusty = clean
            for s in specks { dusty = HealQuality.addDust(dusty, cx: s.0, cy: s.1, radius: s.2, depth: s.3) }
            let found = DustDetection.find(in: dusty)
            let hits = specks.filter { s in found.contains { hypot($0.x - s.0, $0.y - s.1) < Swift.max(s.2, 3) } }
            let falses = found.filter { f in !specks.contains { hypot(f.x - $0.0, f.y - $0.1) < Swift.max($0.2, 3) } }
            let line = "\(frame): \(hits.count)/\(specks.count) found, \(falses.count) other detections"
                + falses.prefix(8).map { String(format: " (%.0f,%.0f r%.0f d%.2f)", $0.x, $0.y, $0.radius, $0.depth) }.joined()
            print("DUST " + line)
            lines.append(line)
            // A before/after of one-click removal: every detection healed with an auto source.
            var healed = dusty
            for f in found {
                healed = HealQuality.heal(healed, cx: f.x, cy: f.y, radius: f.radius).0
            }
            let name = (frame as NSString).lastPathComponent.replacingOccurrences(of: ".lfi", with: "")
            HealQuality.writeLFI(dusty, "\(dir)/dust-\(name)-dusty.lfi")
            HealQuality.writeLFI(healed, "\(dir)/dust-\(name)-removed.lfi")
            let marks = found.map { ["x": $0.x, "y": $0.y, "r": $0.radius] }
            let data = try JSONSerialization.data(withJSONObject: ["found": marks,
                                                                   "planted": specks.map { [$0.0, $0.1, $0.2] }])
            FileManager.default.createFile(atPath: "\(dir)/dust-\(name).json", contents: data)
        }
        FileManager.default.createFile(atPath: "\(dir)/dust.txt",
                                       contents: Data(lines.joined(separator: "\n").utf8))
    }
}
