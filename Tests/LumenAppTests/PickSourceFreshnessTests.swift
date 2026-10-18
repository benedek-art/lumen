#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import XCTest
import LumenCore
@testable import LumenApp

private actor PickSourceBarrier {
    private var entered = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func stop() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func waitForSampleCompletion() async throws {
        let deadline = Date().addingTimeInterval(5)
        while !entered {
            guard Date() < deadline else { throw PickSourceFixtureError.sampleDidNotFinish }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
    enum PickSourceFixtureError: Error { case sampleDidNotFinish }
}

@MainActor
final class PickSourceFreshnessTests: XCTestCase {
    private enum NoCatalog: Error { case fixture }
    private func write(_ url: URL, width: Int = 24) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 16,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 16))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
            "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
    private func withState(_ body: (AppState, [PhotoItem]) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let urls = ["first.png", "second.png"].map { folder.appendingPathComponent($0) }
        for url in urls { try write(url) }
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { throw NoCatalog.fixture }, previewDirectory: { nil })
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        state.openFolder(folder, restrictedTo: urls)
        let deadline = Date().addingTimeInterval(5)
        while state.isScanning && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(state.isScanning)
        let photos = try urls.map { url in try XCTUnwrap(state.allPhotos.first { $0.id == url }) }
        state.primarySelection = photos[0]
        state.selection = Set(urls)
        for url in urls { state.recipes[url] = Recipe() }
        try await body(state, photos)
    }
    private func picked(_ state: AppState, photo: PhotoItem, target: PickTarget,
                        whileSuspended: () throws -> Void) async throws {
        let barrier = PickSourceBarrier()
        defer { Task { await barrier.release() } }
        state.pickResolutionBarrier = { await barrier.stop() }
        state.beginPick(target)
        state.resolvePick(on: photo, sourceX: 0.5, sourceY: 0.5)
        let task = try XCTUnwrap(state.pickResolutionTask)
        try await barrier.waitForSampleCompletion() // AFTER the actual renderer sample/neutral solve.
        try whileSuspended()
        await barrier.release()
        await task.value
    }
    func testPrimaryReplacementRejectsSampleAndNeutralWithoutRecipeOrHistoryWrites() async throws {
        for target: PickTarget in [.newPointColor, .neutral] {
            try await withState { state, photos in
                let before = state.recipes
                let steps = state.history.steps.count
                let position = state.history.position
                let sourceRevision = state.sourceRevision
                let identity = try XCTUnwrap(SourceFileIdentity.read(photos[0].id))
                try await picked(state, photo: photos[0], target: target) {
                    try write(photos[0].id, width: 48)
                    XCTAssertNotEqual(SourceFileIdentity.read(photos[0].id), identity)
                    XCTAssertEqual(state.sourceRevision, sourceRevision,
                                   "external replacement must bypass the old app-revision guard")
                }
                XCTAssertEqual(state.recipes, before)
                XCTAssertEqual(state.history.steps.count, steps)
                XCTAssertEqual(state.history.position, position)
                XCTAssertTrue(state.statusMessage?.contains("Pick discarded") == true)
            }
        }
    }
    func testPrimaryRemovalRejectsSampleWithoutRecipeOrHistoryWrites() async throws {
        try await withState { state, photos in
            let before = state.recipes
            let steps = state.history.steps.count
            try await picked(state, photo: photos[0], target: .newPointColor) {
                try FileManager.default.removeItem(at: photos[0].id)
            }
            XCTAssertEqual(state.recipes, before)
            XCTAssertEqual(state.history.steps.count, steps)
            XCTAssertTrue(state.statusMessage?.contains("Pick discarded") == true)
        }
    }
    func testSecondaryBatchReplacementRejectsEntirePick() async throws {
        try await withState { state, photos in
            let before = state.recipes
            let steps = state.history.steps.count
            try await picked(state, photo: photos[0], target: .newPointColor) {
                try write(photos[1].id, width: 48)
            }
            XCTAssertEqual(state.recipes, before)
            XCTAssertEqual(state.history.steps.count, steps)
            XCTAssertTrue(state.statusMessage?.contains("Pick discarded") == true)
        }
    }
    func testUnchangedSourcesRetainSampleNeutralAndBatchHistoryBehavior() async throws {
        for target: PickTarget in [.newPointColor, .neutral] {
            try await withState { state, photos in
                let before = state.recipes
                let steps = state.history.steps.count
                var known = photos[0]
                known.sourceIdentity = try XCTUnwrap(SourceFileIdentity.read(known.id))
                state.primarySelection = known
                try await picked(state, photo: known, target: target) {}
                for photo in photos { XCTAssertNotEqual(state.recipe(for: photo), before[photo.id]) }
                XCTAssertEqual(state.history.steps.count, steps + 1)
                XCTAssertFalse(state.statusMessage?.contains("Pick discarded") == true)
            }
        }
    }
    func testKnownPhotoGenerationReplacementBeforeClickRefusesWithoutSamplingOrWrites() async throws {
        try await withState { state, photos in
            var known = photos[0]
            known.sourceIdentity = try XCTUnwrap(SourceFileIdentity.read(known.id))
            state.primarySelection = known
            let before = state.recipes
            let steps = state.history.steps.count
            try write(known.id, width: 48)
            XCTAssertNil(state.pickResolutionTask)
            state.beginPick(.newPointColor)
            state.resolvePick(on: known, sourceX: 0.5, sourceY: 0.5)
            XCTAssertNil(state.pickResolutionTask, "known stale source must refuse before sampling")
            XCTAssertEqual(state.recipes, before)
            XCTAssertEqual(state.history.steps.count, steps)
            XCTAssertTrue(state.statusMessage?.contains("Pick discarded") == true)
        }
    }

}
#endif
