// WS15DehazeAirlightCorpusTests.swift
//
// WS-15 SPEC U10 (gate for A1-A3): where the dehaze airlight comes from on the six real
// corpus frames, at 512 and 2048 px. Skipped when the corpus has not been fetched
// (`scripts/proof/fetch_corpus.sh`). Prints one `WS15AIRLIGHT {json}` line per frame in
// `docs/quality/lanes/WS-15/tools/airlight_probe.py --json`'s schema plus "id", which
// `tools/check_spec.py --swift` reads in place of the pre-fix emulation.

import Foundation
import XCTest
@testable import LumenCore

final class WS15DehazeAirlightCorpusTests: XCTestCase {

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let frames: [(id: String, file: String)] = [
        ("983", "983_canon-eos-5d-mark-iv"), ("1840", "1840_nikon-d850"),
        ("4213", "4213_nikon-z-7-2"), ("3437", "3437_canon-eos-rebel-t7i"),
        ("2545", "2545_panasonic-dmc-gx85"), ("6929", "6929_sony-ilce-7m4")]

    /// LFI1: 4-byte magic, UInt32 width, height, channels (3), then Float32 RGB.
    static func readLFI(_ url: URL) throws -> ImageBuffer {
        let data = try Data(contentsOf: url)
        func u32(_ o: Int) -> Int {
            Int(data[o]) | Int(data[o + 1]) << 8 | Int(data[o + 2]) << 16 | Int(data[o + 3]) << 24
        }
        guard data.count >= 16, data.prefix(4) == Data("LFI1".utf8), u32(12) == 3 else {
            throw NSError(domain: "LFI", code: 1)
        }
        let w = u32(4), h = u32(8)
        var pixels = [Float](repeating: 1, count: w * h * 4)
        data.withUnsafeBytes { raw in
            let src = raw.baseAddress!.advanced(by: 16).assumingMemoryBound(to: Float.self)
            pixels.withUnsafeMutableBufferPointer { dst in
                for i in 0..<(w * h) {
                    let r = src[i * 3], g = src[i * 3 + 1], b = src[i * 3 + 2]
                    dst[i * 4] = r.isFinite ? r : 0
                    dst[i * 4 + 1] = g.isFinite ? g : 0
                    dst[i * 4 + 2] = b.isFinite ? b : 0
                }
            }
        }
        return ImageBuffer(width: w, height: h, pixels: pixels)
    }

    /// `lumen-render`'s step 1: exact area average to a long edge, sizes rounded.
    static func downsample(_ image: ImageBuffer, longEdge: Int) -> ImageBuffer {
        let long = Swift.max(image.width, image.height)
        guard long > longEdge else { return image }
        let s = Double(longEdge) / Double(long)
        return DetailEngine.dehazeAreaDownsample(
            image, width: Swift.max(1, Int((Double(image.width) * s).rounded())),
            height: Swift.max(1, Int((Double(image.height) * s).rounded())))
    }

    static func round(_ x: Double, _ places: Double) -> Double {
        let p = pow(10, places); return (x * p).rounded() / p
    }

    func testCorpusAirlight() throws {
        let lfiDir = Self.root.appendingPathComponent("corpus/lfi")
        let present = Self.frames.allSatisfy {
            FileManager.default.fileExists(atPath: lfiDir.appendingPathComponent($0.file + ".lfi").path)
        }
        try XCTSkipUnless(present, "corpus/lfi not fetched (scripts/proof/fetch_corpus.sh)")
        let regionsURL = Self.root.appendingPathComponent("docs/quality/lanes/WS-15/tools/regions.json")
        let regions = (try? JSONSerialization.jsonObject(with: Data(contentsOf: regionsURL)))
            as? [String: Any] ?? [:]
        let weights = [0.2627, 0.6780, 0.0593]

        for frame in Self.frames {
            let full = try Self.readLFI(lfiDir.appendingPathComponent(frame.file + ".lfi"))
            let forbidden = ((regions[frame.id] as? [String: Any])?["airlight_forbidden"]
                as? [String: [Double]]) ?? [:]
            var record: [String: Any] = ["id": frame.id]
            var chroma: [Int: [Double]] = [:], luma: [Int: Double] = [:]
            for edge in [512, 2048] {
                let image = Self.downsample(full, longEdge: edge)
                let radius = Swift.max(Int(Double(Swift.max(image.width, image.height)) * 0.02), 3)
                let node = DetailEngine.Decomposition(image: image, workingRadius: radius)
                let field = node.dehazeField()
                let a = field.airlight, sel = field.selection
                var n = 0, sx = 0.0, sy = 0.0
                var inside = [String: Int](uniqueKeysWithValues: forbidden.keys.map { ($0, 0) })
                for y in 0..<sel.height {
                    for x in 0..<sel.width where sel[x, y] > 0.5 {
                        n += 1
                        // Selection pixel position as a fraction of the frame, the same
                        // convention airlight_probe.py uses for its box test.
                        let u = Double(x) / Double(sel.width), v = Double(y) / Double(sel.height)
                        sx += u; sy += v
                        for (name, b) in forbidden where u >= b[0] && u < b[2] && v >= b[1] && v < b[3] {
                            inside[name, default: 0] += 1
                        }
                    }
                }
                let sum = a.r + a.g + a.b
                let ch = [a.r / sum, a.g / sum, a.b / sum]
                let y = a.r * weights[0] + a.g * weights[1] + a.b * weights[2]
                chroma[edge] = ch; luma[edge] = y
                let fractions = inside.mapValues { Self.round(n > 0 ? Double($0) / Double(n) : 1, 3) }
                record["L\(edge)"] = [
                    "A": [a.r, a.g, a.b].map { Self.round($0, 4) },
                    "chroma": ch.map { Self.round($0, 4) },
                    "luma": Self.round(y, 4),
                    "centroid_xy": [Self.round(sx / Double(Swift.max(n, 1)), 3),
                                    Self.round(sy / Double(Swift.max(n, 1)), 3)],
                    "forbidden_fraction": fractions, "n": n] as [String: Any]

                for (name, share) in fractions {
                    XCTAssertLessThanOrEqual(share, 0.05,
                        "\(frame.id) L\(edge): \(share) of the airlight selection is on \(name) (A1)")
                }
                if frame.id == "3437" {
                    XCTAssertGreaterThanOrEqual(ch[1], 0.315, "3437 L\(edge) airlight is magenta (A2)")
                }
            }
            let c5 = chroma[512]!, c2 = chroma[2048]!
            let dist = hypot(c5[0] - c2[0], c5[1] - c2[1])
            let ratio = luma[512]! / luma[2048]!
            record["chroma_dist_512_2048"] = Self.round(dist, 4)
            record["luma_ratio_512_over_2048"] = Self.round(ratio, 3)
            let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("WS15AIRLIGHT " + String(decoding: json, as: UTF8.self))
            XCTAssertLessThanOrEqual(dist, 0.010, "\(frame.id) airlight chromaticity moves with size (A3)")
            XCTAssertEqual(ratio, 1, accuracy: 0.10, "\(frame.id) airlight luminance moves with size (A3)")
        }
    }
}
