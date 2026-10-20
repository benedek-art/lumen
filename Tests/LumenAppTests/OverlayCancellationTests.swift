#if os(macOS)
import Foundation
import XCTest
import LumenCore
@testable import LumenApp

/// The clipping, Visualize Spots and focus-peaking overlays build in a `Task.detached`,
/// which `.task(id:)` cancelling its wrapper never reaches. A drag queued one
/// full-frame pass per delivered frame. These pin both halves of the fix: the builds
/// stop when cancelled, and each view holds and cancels the handle.
final class OverlayCancellationTests: XCTestCase {

    private nonisolated static func frame() -> PixelSampler {
        let side = 64
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for p in 0..<(side * side) {
            let v: UInt8 = (p / side + p % side).isMultiple(of: 2) ? 255 : 0
            bytes[p * 4] = v
            bytes[p * 4 + 1] = v
            bytes[p * 4 + 2] = v
            bytes[p * 4 + 3] = 255
        }
        return PixelSampler(width: side, height: side, bytes: bytes)
    }

    private nonisolated static func buildAll() -> [Bool] {
        let sampler = frame()
        return [
            ClippingOverlayView.build(sampler: sampler, mode: .highlights,
                                      fullFrame: false) != nil,
            SpotVisualizationView.build(sampler: sampler, threshold: 50) != nil,
            FocusPeakingOverlayView.build(sampler: sampler, sensitivity: .normal,
                                          tint: .green) != nil,
        ]
    }

    func testOverlayBuildsStopWhenTheirTaskIsCancelled() async {
        let live = await Task.detached { OverlayCancellationTests.buildAll() }.value
        XCTAssertEqual(live, [true, true, true], "an uncancelled build still draws")
        let task = Task.detached { () -> [Bool] in
            while !Task.isCancelled { await Task.yield() }
            return OverlayCancellationTests.buildAll()
        }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled, [false, false, false],
                       "a superseded build must stop rather than run to completion")
    }

    func testEachOverlayViewCancelsTheBuildBeforeIt() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = blankingComments(in: try String(
            contentsOf: root.appendingPathComponent("Sources/LumenApp/ViewerOverlays.swift"),
            encoding: .utf8))
        for name in ["ClippingOverlayView", "SpotVisualizationView",
                     "FocusPeakingOverlayView", "MaskOverlayView"] {
            let body = try XCTUnwrap(
                text.components(separatedBy: "struct \(name):").dropFirst().first,
                "\(name) not found")
            let after = try XCTUnwrap(
                body.components(separatedBy: "func rebuild()").dropFirst().first,
                "\(name) has no rebuild")
            let rebuild = after.components(separatedBy: "static func build(").first ?? ""
            XCTAssertTrue(rebuild.contains("buildTask?.cancel()"),
                          "\(name) must cancel the detached build it started last")
            XCTAssertTrue(rebuild.contains("buildTask = task"),
                          "\(name) must hold the handle so the next rebuild can cancel it")
        }
    }
}
#endif
