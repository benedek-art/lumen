#if os(macOS)
import Combine
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

final class FilesystemWorkflowTests: XCTestCase {
    @MainActor
    private func withState(_ run: (AppState, PhotoItem, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-filesystem-workflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let photoURL = root.appendingPathComponent("source.JPG")
        let context = try XCTUnwrap(CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(photoURL as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try XCTUnwrap(context.makeImage()), [
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["OldSource"]]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        // Export presets are an existing UserDefaults-backed property. Restore the
        // exact previous object so these isolated deliveries do not change preferences.
        let presetKey = "dev.lumenapp.exportRecipes"
        let original = UserDefaults.standard.object(forKey: presetKey)
        defer {
            state.prepareToQuit()
            if let original { UserDefaults.standard.set(original, forKey: presetKey) }
            else { UserDefaults.standard.removeObject(forKey: presetKey) }
            try? FileManager.default.removeItem(at: root)
        }
        let catalog = try XCTUnwrap(state.catalog)
        var photo = PhotoItem(id: photoURL)
        photo.catalogID = try XCTUnwrap(catalog.registerAndLoad(folder: root, files: [photoURL])[photoURL]?.catalogID)
        state.primarySelection = photo
        try await run(state, photo, root)
    }

    @MainActor
    private func finish(_ state: AppState) async throws {
        let deadline = Date().addingTimeInterval(30)
        while state.isExporting && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.isExporting, "the synthetic export did not finish")
    }

    @MainActor
    func testCancellationAfterDeliveredFilePreservesItAndLeavesRestNotAttempted() async throws {
        try await withState { state, photo, root in
            let original = try Data(contentsOf: photo.id)
            state.exportRecipes = [
                ExportRecipe(name: "First", filenameTemplate: "first"),
                ExportRecipe(name: "Second", filenameTemplate: "second"),
                ExportRecipe(name: "Third", filenameTemplate: "third")]
            // Synchronous publication notification: cancellation occurs after the
            // first settled delivery, before the exporter starts the next target.
            let subscription = state.$exportProgress.sink { progress in
                MainActor.assumeIsolated {
                    if progress > 0 && state.isExporting { state.cancelExport() }
                }
            }
            defer { subscription.cancel() }
            state.export(to: root)
            try await finish(state)
            let report = try XCTUnwrap(state.operationReports.first)
            XCTAssertEqual(report.state, .cancelled)
            XCTAssertEqual(report.records.map(\.outcome), [.delivered, .notAttempted, .notAttempted])
            XCTAssertEqual(report.records[0].actualDestination, root.appendingPathComponent("first.jpg").path)
            XCTAssertTrue(report.records.dropFirst().allSatisfy { $0.actualDestination == nil })
            try assertReadable(root.appendingPathComponent("first.jpg"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.jpg").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("third.jpg").path))
            XCTAssertEqual(try Data(contentsOf: photo.id), original)
            try await assertDurable(report, state: state)
            try assertNoStagingFiles(root)
        }
    }

    @MainActor
    func testBlockedSubfolderReportsFailureThenDeliversIndependentTarget() async throws {
        try await withState { state, photo, root in
            let original = try Data(contentsOf: photo.id)
            let blocked = root.appendingPathComponent("blocked")
            let sentinel = Data("existing destination object".utf8)
            try sentinel.write(to: blocked)
            state.exportRecipes = [
                ExportRecipe(name: "Blocked", filenameTemplate: "bad", subfolder: "blocked"),
                ExportRecipe(name: "Good", filenameTemplate: "good")]
            state.export(to: root)
            try await finish(state)
            let report = try XCTUnwrap(state.operationReports.first)
            XCTAssertEqual(report.state, .completed)
            XCTAssertEqual(report.records.map(\.outcome), [.failed, .delivered])
            XCTAssertNil(report.records[0].actualDestination)
            XCTAssertNotNil(report.records[0].detail)
            XCTAssertTrue(report.summary.contains("1 failed"))
            XCTAssertEqual(try Data(contentsOf: blocked), sentinel)
            try assertReadable(root.appendingPathComponent("good.jpg"))
            XCTAssertEqual(try Data(contentsOf: photo.id), original)
            try await assertDurable(report, state: state)
            try assertNoStagingFiles(root)
        }
    }

    private func assertReadable(_ url: URL) throws {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    @MainActor
    private func assertDurable(_ report: OperationReport, state: AppState) async throws {
        let file = try XCTUnwrap(state.operationReportFiles[report.id])
        let reopened = try await OperationReportStore(directory: file.deletingLastPathComponent()).load()
        XCTAssertEqual(reopened.reports.first?.report, report)
    }

    private func assertNoStagingFiles(_ root: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".part") || $0.hasPrefix(".lumen-export-") }, "\(files)")
    }
}
#endif
