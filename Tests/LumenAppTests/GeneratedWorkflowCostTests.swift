#if os(macOS)
import AppKit
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

/// Opt-in CPU bookkeeping probe, not a claim about UI display or RAW decode latency.
/// Uses independent generated PNG files and isolated catalog/preview directories.
@MainActor
final class GeneratedWorkflowCostTests: XCTestCase {
    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    private func describe(_ name: String, count: Int, samples: [Double]) {
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)]
        }
        print(String(format: "WORKFLOWBENCH count=%d %@ p50=%.4f p95=%.4f p99=%.4f ms", count,
                     name as NSString, percentile(0.50), percentile(0.95), percentile(0.99)))
    }

    private func residentBytes() throws -> Int64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "rss=", "-p", String(ProcessInfo.processInfo.processIdentifier)]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8),
              let kib = Int64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "WorkflowBench", code: 1)
        }
        return kib * 1024
    }

    func testGeneratedLargeRollBookkeepingLatencyAndMemory() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LUMEN_APP_BENCH"] == "1",
                          "set LUMEN_APP_BENCH=1 for isolated generated 5k/20k workflow measurements")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-workflow-bench-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let remembered = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, remembered) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 12,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<12 { for x in 0..<16 { bitmap.setColor(.gray, atX: x, y: y) } }
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for count in [5_000, 20_000] {
            let directory = root.appendingPathComponent("roll-\(count)")
            let folder = directory.appendingPathComponent("photos")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try await Task.detached(priority: .utility) {
                for index in 0..<count {
                    try bytes.write(to: folder.appendingPathComponent(String(format: "F%05d.png", index)))
                }
            }.value
            let state = AppState(catalogDirectory: { directory.appendingPathComponent("catalog") },
                                 previewDirectory: { directory.appendingPathComponent("previews") })
            let rssBefore = try residentBytes()
            let scanStart = DispatchTime.now().uptimeNanoseconds
            state.openFolder(folder)
            for _ in 0..<12_000 {
                if !state.isScanning { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(state.isScanning, "generated scan must finish")
            XCTAssertEqual(state.allPhotos.count, count)
            guard state.allPhotos.count == count else { state.prepareToQuit(); continue }
            print(String(format: "WORKFLOWBENCH count=%d open=%.2f ms", count,
                         Double(DispatchTime.now().uptimeNanoseconds - scanStart) / 1e6))
            let items = state.allPhotos
            var samples: [Double] = []
            for _ in 0..<11 {
                samples.append(milliseconds { state.invalidatePhotoCache(); _ = state.photos })
            }
            describe("cold-photo-order", count: count, samples: samples)
            samples = []
            for index in 0..<301 {
                let photo = items[(index * 7919) % count]
                samples.append(milliseconds {
                    state.select(photo)
                    _ = state.selectedPhotos
                    _ = state.photos
                    _ = state.rollIndex(of: photo)
                })
                await Task.yield()
            }
            describe("cursor-selection-bookkeeping", count: count, samples: samples)
            for selectedCount in [1, 40] {
                state.selection = Set(items.suffix(selectedCount).map(\.id))
                state.primarySelection = items.last
                _ = state.selectedPhotos
                let before = state.history.position
                state.sliderGesture(active: true)
                samples = []
                for index in 0..<120 {
                    samples.append(milliseconds {
                        state.updateRecipe(coalescingKey: "tone.exposure") {
                            $0.develop.tone.exposure = Double(index + 1) / 100
                        }
                    })
                }
                describe("drag-selected-\(selectedCount)", count: count, samples: samples)
                XCTAssertEqual(state.history.position, before + 1)
                print(String(format: "WORKFLOWBENCH count=%d release-selected=%d %.4f ms", count,
                             selectedCount, milliseconds { state.sliderGesture(active: false) }))
                print(String(format: "WORKFLOWBENCH count=%d undo-selected=%d %.4f ms", count,
                             selectedCount, milliseconds { state.undo() }))
            }
            print("WORKFLOWBENCH count=\(count) rss-before=\(rssBefore) rss-after=\(try residentBytes()) bytes")
            state.prepareToQuit()
            XCTAssertEqual(try Data(contentsOf: items[0].id), bytes, "original bytes must be preserved")
            XCTAssertEqual(try Data(contentsOf: items[count - 1].id), bytes)
        }
    }
}
#endif
