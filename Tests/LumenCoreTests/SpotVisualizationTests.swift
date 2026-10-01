// SpotVisualizationTests.swift
// Visualize Spots: dust must show, a sky gradient must not, the threshold must move the
// line between them in the documented direction — and the view must never reach a
// render path, because it is a way of looking and not an edit.

import XCTest
@testable import LumenCore

final class SpotVisualizationTests: XCTestCase {

    private let width = 64
    private let height = 48

    /// A sky: a smooth diagonal gradient, in luma.
    private func sky() -> [Double] {
        var out = [Double](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                out[y * width + x] = 0.55 + 0.004 * Double(x) - 0.003 * Double(y)
            }
        }
        return out
    }

    /// `base` with a soft dust bunny of `depth` at (cx, cy), radius 3 px.
    private func dusty(_ base: [Double], cx: Int, cy: Int, depth: Double) -> [Double] {
        var out = base
        for y in 0..<height {
            for x in 0..<width {
                let d = hypot(Double(x - cx), Double(y - cy))
                if d < 3 { out[y * width + x] -= depth * (1 - d / 3) }
            }
        }
        return out
    }

    func testAFlatFieldIsWhite() {
        let flat = [Double](repeating: 0.4, count: width * height)
        let view = SpotVisualization.render(luma: flat, width: width, height: height)
        XCTAssertEqual(view.count, width * height)
        XCTAssertTrue(view.allSatisfy { $0 == 255 })
    }

    /// The gradient is exactly invisible away from the frame edge (equal box means at
    /// every scale), at the most sensitive setting.
    func testASmoothGradientVanishes() {
        let view = SpotVisualization.render(luma: sky(), width: width, height: height,
                                            threshold: 100)
        let r = SpotVisualization.coarseRadius
        for y in r..<(height - r) {
            for x in r..<(width - r) {
                XCTAssertGreaterThanOrEqual(view[y * width + x], 254, "(\(x), \(y))")
            }
        }
    }

    /// A 2% dust bunny in the sky turns black at its centre at the default threshold,
    /// while the sky a dozen pixels away stays white.
    func testDustShowsAgainstTheSky() {
        let picture = dusty(sky(), cx: 32, cy: 24, depth: 0.02)
        let view = SpotVisualization.render(luma: picture, width: width, height: height)
        XCTAssertLessThan(view[24 * width + 32], 40, "the dust centre is not dark")
        XCTAssertGreaterThanOrEqual(view[24 * width + 12], 254, "the clear sky is not white")
    }

    /// Higher threshold, fainter dust: a 0.5% speck is invisible at 0 and plain at 100,
    /// and darkness never decreases as the threshold rises.
    func testTheThresholdShowsFainterDustAsItRises() {
        let picture = dusty(sky(), cx: 32, cy: 24, depth: 0.005)
        var previous = 256
        for threshold in stride(from: 0.0, through: 100.0, by: 10.0) {
            let value = Int(SpotVisualization.render(luma: picture, width: width,
                                                     height: height,
                                                     threshold: threshold)[24 * width + 32])
            XCTAssertLessThanOrEqual(value, previous, "threshold \(threshold) shows less")
            previous = value
        }
        let low = SpotVisualization.render(luma: picture, width: width, height: height,
                                           threshold: 0)[24 * width + 32]
        let high = SpotVisualization.render(luma: picture, width: width, height: height,
                                            threshold: 100)[24 * width + 32]
        XCTAssertGreaterThan(low, 230)
        XCTAssertLessThan(high, 30)
        XCTAssertEqual(SpotVisualization.cutoff(threshold: .nan),
                       SpotVisualization.cutoff(threshold: SpotVisualization.defaultThreshold))
    }

    func testLumaReadsSamplerBytes() {
        let bytes: [UInt8] = [255, 255, 255, 255, 0, 0, 0, 255, 255, 0, 0, 255]
        let luma = SpotVisualization.luma(rgba: bytes, width: 3, height: 1)
        XCTAssertEqual(luma?[0] ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(luma?[1] ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(luma?[2] ?? -1, 0.2126, accuracy: 1e-12)
        XCTAssertNil(SpotVisualization.luma(rgba: bytes, width: 4, height: 1))
    }

    // MARK: Display-only

    private static var sources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
    }

    /// Code (line comments stripped) of every Swift file under `directory`.
    private static func code(under directory: URL) -> [(String, String)] {
        let files = FileManager.default.enumerator(at: directory,
                                                   includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        return files.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line -> Substring in
                    guard let r = line.range(of: "//") else { return line }
                    return line[..<r.lowerBound]
                }.joined(separator: "\n")
            return (url.lastPathComponent, code)
        }
    }

    /// Nothing that renders a photograph — the pipeline target, the CPU reference's
    /// engine, the export, the recipe — names the view, and the app names it only in the
    /// overlay and the tool that toggles it. A visualization that leaked into a renderer
    /// would be printed.
    func testTheViewNeverReachesARenderer() throws {
        let renderers = ["LumenPipeline", "LumenCore/Engine", "LumenCore/Export",
                         "LumenCore/Recipe"].map { Self.sources.appendingPathComponent($0) }
        var scanned = 0
        for directory in renderers {
            for (name, code) in Self.code(under: directory) {
                scanned += 1
                XCTAssertFalse(code.contains("SpotVisualization"),
                               "\(name) reaches the Visualize Spots view")
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the scan found no renderer sources")
        let app = Self.code(under: Self.sources.appendingPathComponent("LumenApp"))
        let users = Set(app.filter { $0.1.contains("SpotVisualization") }.map(\.0))
        XCTAssertFalse(users.isEmpty, "the app does not draw the view at all")
        XCTAssertTrue(users.isSubset(of: ["ViewerOverlays.swift", "HealCanvas.swift",
                                          "LoupeView.swift"]),
                      "the view is used outside the overlay: \(users.sorted())")
        // And nothing about it is in a recipe.
        let encoded = String(decoding: try JSONEncoder().encode(Recipe()), as: UTF8.self)
        XCTAssertFalse(encoded.lowercased().contains("visuali"))
    }
}
