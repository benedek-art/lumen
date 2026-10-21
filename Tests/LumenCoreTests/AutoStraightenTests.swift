import XCTest
@testable import LumenCore

/// Auto straighten (lane C1, SPEC M6): synthetic frames drawn at a known tilt, and the
/// estimate must level them within 0.25°.
final class AutoStraightenTests: XCTestCase {

    private struct Rng {
        var state: UInt64
        mutating func next() -> Float {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float(state >> 40) / Float(1 << 24)
        }
    }

    /// A scene rendered with its content turned by `tilt` degrees (y downward, so a
    /// positive tilt dips the right-hand end), 2×2 supersampled, plus noise.
    private func scene(width: Int = 512, height: Int = 340, tilt: Double,
                       kind: String, seed: UInt64 = 7) -> [Float] {
        var rng = Rng(state: seed)
        let r = tilt * .pi / 180
        let c = cos(r), s = sin(r)
        let cx = Double(width) / 2, cy = Double(height) / 2
        func value(_ x: Double, _ y: Double) -> Float {
            // Undo the tilt: sample the level scene at the rotated-back point.
            let dx = x - cx, dy = y - cy
            let u = dx * c + dy * s
            let v = -dx * s + dy * c
            switch kind {
            case "horizon":
                // Sky above, sea below, a soft cloud band — the tilt lives in one line.
                if v < 10 { return 0.75 - Float(v + cy) / Float(height) * 0.2 }
                return 0.3 + 0.03 * Float(sin(u * 0.05))
            case "buildings":
                // Three towers: strong verticals, short horizontals.
                for (left, right, top) in [(-200.0, -120.0, -120.0), (-40.0, 40.0, -150.0),
                                           (100.0, 190.0, -90.0)] {
                    if u > left && u < right && v > top { return 0.25 }
                }
                return 0.7
            default:
                return 0.5
            }
        }
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var sum: Float = 0
                for (ox, oy) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
                    sum += value(Double(x) + ox, Double(y) + oy)
                }
                out[y * width + x] = sum / 4 + (rng.next() - 0.5) * 0.04
            }
        }
        return out
    }

    func testHorizonsAtKnownTiltsAreLevelled() {
        for tilt in [-12.0, -6.5, -2.0, -0.6, 0.0, 1.3, 4.0, 9.0, 12.0] {
            let luma = scene(tilt: tilt, kind: "horizon")
            guard let e = AutoStraighten.estimate(luma: luma, width: 512, height: 340) else {
                XCTFail("no estimate at \(tilt)°"); continue
            }
            XCTAssertEqual(e.angle, -tilt, accuracy: 0.25, "horizon at \(tilt)°")
        }
    }

    func testBuildingVerticalsAtKnownTiltsAreLevelled() {
        for tilt in [-8.0, -3.0, 2.5, 7.0] {
            let luma = scene(tilt: tilt, kind: "buildings")
            guard let e = AutoStraighten.estimate(luma: luma, width: 512, height: 340) else {
                XCTFail("no estimate at \(tilt)°"); continue
            }
            XCTAssertEqual(e.angle, -tilt, accuracy: 0.25, "buildings at \(tilt)°")
        }
    }

    /// The same frame mirrored: the plate is drawn flipped, and the answer must still
    /// level the SOURCE (`Straighten`'s derivation).
    func testAMirroredPlateGivesTheSameLevellingAngle() {
        let w = 512, h = 340
        let luma = scene(tilt: 5, kind: "horizon")
        var mirrored = luma
        for y in 0..<h { for x in 0..<w { mirrored[y * w + x] = luma[y * w + (w - 1 - x)] } }
        let plain = AutoStraighten.estimate(luma: luma, width: w, height: h)!
        let flipped = AutoStraighten.estimate(luma: mirrored, width: w, height: h,
                                              plateIsFlipped: true)!
        XCTAssertEqual(plain.angle, flipped.angle, accuracy: 0.1)
        // And the answer levels the line on the mirrored display:
        // displayed = −(angle + s) with s = 5 must be ~0.
        XCTAssertEqual(Straighten.displayedDirection(sourceDegrees: 5, angle: flipped.angle,
                                                     flipped: true), 0, accuracy: 0.25)
    }

    func testNoiseAndFlatFramesChangeNothing() {
        var rng = Rng(state: 99)
        let noise = (0..<(512 * 340)).map { _ in rng.next() }
        XCTAssertNil(AutoStraighten.estimate(luma: noise, width: 512, height: 340))
        let flat = [Float](repeating: 0.4, count: 512 * 340)
        XCTAssertNil(AutoStraighten.estimate(luma: flat, width: 512, height: 340))
        XCTAssertNil(AutoStraighten.estimate(luma: [], width: 0, height: 0))
    }

    /// The corpus report, not a gate: with `LUMEN_AUTOSTRAIGHTEN_PGM` pointing at a
    /// folder of binary PGMs (`<name>_r<deg>.pgm`, made by REPORT.md's recipe — each
    /// photo as shot and turned by +3° and −5°), prints what Auto would set. The turned
    /// copies must move the answer by the turn; what the as-shot frame gets is for a
    /// human to judge against the picture.
    func testCorpusReport() throws {
        guard let dir = ProcessInfo.processInfo.environment["LUMEN_AUTOSTRAIGHTEN_PGM"] else {
            throw XCTSkip("set LUMEN_AUTOSTRAIGHTEN_PGM to run the corpus report")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".pgm") }.sorted()
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(file))
            // P5\n<w> <h>\n255\n<bytes>
            var fields: [String] = []
            var index = 0
            var token = ""
            while fields.count < 4, index < data.count {
                let c = Character(UnicodeScalar(data[index]))
                index += 1
                if c.isWhitespace {
                    if !token.isEmpty { fields.append(token); token = "" }
                } else {
                    token.append(c)
                }
            }
            guard fields.count == 4, let w = Int(fields[1]), let h = Int(fields[2]),
                  data.count - index >= w * h else { continue }
            let luma = data[index..<(index + w * h)].map { Float($0) / 255 }
            let start = Date()
            let e = AutoStraighten.estimate(luma: luma, width: w, height: h)
            let ms = Date().timeIntervalSince(start) * 1000
            print(String(format: "AUTO %@ %dx%d angle %@ confidence %@ (%.0f ms)", file, w, h,
                         e.map { String(format: "%+.2f", $0.angle) } ?? "nil",
                         e.map { String(format: "%.2f", $0.confidence) } ?? "-", ms))
        }
    }
}
