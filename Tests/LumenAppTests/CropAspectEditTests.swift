#if os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import LumenCore
import LumenPipeline
@testable import LumenApp

final class CropAspectEditTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/crop-constraints-fixture/landscape.png")
    private let b = URL(fileURLWithPath: "/crop-constraints-fixture/portrait.png")

    @MainActor
    func testSessionLockBecomesInactiveAfterUndoWithoutChangingRecipe() {
        let tool = CropTool.shared
        defer { tool.setLock(nil, for: a) }
        let before = Crop(x: 0.1, y: 0.1, w: 0.8, h: 0.8)
        let after = CropGeometry.refit(before, aspect: 2, sourceWidth: 6000,
                                       sourceHeight: 4000, degrees: 0)
        tool.setLock(2, for: a)
        XCTAssertEqual(tool.effectiveLockedAspect(for: a, crop: after, frameAspect: 1.5), 2)
        XCTAssertNil(tool.effectiveLockedAspect(for: a, crop: before, frameAspect: 1.5))
        XCTAssertNil(tool.effectiveLockedAspect(for: b, crop: after, frameAspect: 1.5))
        XCTAssertEqual(tool.lockedAspect(for: a), 2, "Inspection does not mutate session state")
    }

    func testBatchUsesEachSourcesOwnAngleAndShape() throws {
        var landscape = Geometry(), portrait = Geometry()
        landscape.angle = 7; portrait.angle = -11
        let targets = [CropAspectEdit.Target(photo: a, geometry: landscape, source: nil),
                       CropAspectEdit.Target(photo: b, geometry: portrait, source: nil)]
        let sizes = [a: CGSize(width: 6000, height: 4000), b: CGSize(width: 4000, height: 6000)]
        let crops = try CropAspectEdit.plan(.ratio(3), targets: targets, sizes: sizes).get()
        for target in targets {
            let size = try XCTUnwrap(sizes[target.photo])
            XCTAssertEqual(CropGeometry.displayedAspect(try XCTUnwrap(crops[target.photo]),
                sourceWidth: size.width, sourceHeight: size.height, degrees: target.geometry.angle)!,
                3, accuracy: 1e-10)
        }
        XCTAssertNotEqual(crops[a], crops[b])
    }

    func testOneImpossibleOrUnknownTargetRejectsTheWholePlan() {
        let targets = [CropAspectEdit.Target(photo: a, geometry: Geometry(), source: nil),
                       CropAspectEdit.Target(photo: b, geometry: Geometry(), source: nil)]
        for sizes in [[a: CGSize(width: 6000, height: 4000), b: CGSize(width: 4000, height: 6000)],
                      [a: CGSize(width: 6000, height: 4000)]] {
            switch CropAspectEdit.plan(.ratio(20), targets: targets, sizes: sizes) {
            case .success: XCTFail("The first feasible crop must not make a partial batch")
            case .failure(let issue):
                XCTAssertTrue(issue.message.contains("portrait.png"))
                XCTAssertTrue(issue.message.contains("No selected photo was changed"))
            }
        }
    }

    func testDuplicateTargetsAreRejectedBeforeDictionaryConstructionOrOverwrite() throws {
        let identity = try XCTUnwrap(SourceFileIdentity.read(URL(fileURLWithPath: #filePath)))
        let first = CropAspectEdit.Target(photo: a, geometry: Geometry(), source: identity)
        let second = CropAspectEdit.Target(photo: b, geometry: Geometry(), source: identity)
        XCTAssertTrue(CropAspectEdit.stillCurrent([first, second], current: [second, first]))
        XCTAssertFalse(CropAspectEdit.stillCurrent([first, second], current: [first, first]))
        XCTAssertFalse(CropAspectEdit.stillCurrent([first, first], current: [first, second]))
        XCTAssertFalse(CropAspectEdit.stillCurrent([first, first], current: [first, first]))
        for action in [CropAspectEdit.Action.ratio(3), .swap] {
            switch CropAspectEdit.plan(action, targets: [first, first],
                                      sizes: [a: CGSize(width: 6000, height: 4000)]) {
            case .success: XCTFail("Duplicate entries must not silently collapse into one write")
            case .failure(let refusal): XCTAssertTrue(refusal.message.contains("duplicate photo entries"))
            }
        }
    }

    func testMetadataOrientationAndRangeCopyDoNotGuessDimensions() {
        for orientation in 1...8 {
            let actual = CropAspectEdit.sourceSize(metadata: PhotoMetadata(width: 6000,
                                                    height: 4000, orientation: orientation))
            XCTAssertEqual(actual, orientation >= 5 ? CGSize(width: 4000, height: 6000)
                                                    : CGSize(width: 6000, height: 4000))
        }
        for metadata in [nil, PhotoMetadata(), PhotoMetadata(width: 0, height: 4000),
                         PhotoMetadata(width: 6, height: 4, orientation: 9)] {
            XCTAssertNil(CropAspectEdit.sourceSize(metadata: metadata))
        }
        let description = CropAspectEdit.rangeDescription(size: CGSize(width: 6000, height: 4000), degrees: 0)
        for text in ["0.0°", "6000 × 4000", "0.075:1–30:1", "5%"] {
            XCTAssertTrue(description.contains(text), description)
        }
        XCTAssertNotEqual(description, CropAspectEdit.rangeDescription(
            size: CGSize(width: 6000, height: 4000), degrees: 7))
        XCTAssertTrue(CropAspectEdit.rangeDescription(size: nil, degrees: 0).contains("unavailable"))
    }

    func testBatchOrientationSwapPreservesEachTargetsOwnReciprocal() throws {
        let sizes = [a: CGSize(width: 6000, height: 4000), b: CGSize(width: 4000, height: 6000)]
        var first = Geometry(), second = Geometry()
        first.crop = Crop(x: 0.1, y: 0.2, w: 0.6, h: 0.7)
        second.crop = Crop(x: 0.3, y: 0.1, w: 0.4, h: 0.5); second.angle = 11
        let targets = [CropAspectEdit.Target(photo: a, geometry: first, source: nil),
                       CropAspectEdit.Target(photo: b, geometry: second, source: nil)]
        let result = try CropAspectEdit.plan(.swap, targets: targets, sizes: sizes).get()
        for target in targets {
            let size = try XCTUnwrap(sizes[target.photo])
            let old = try XCTUnwrap(CropGeometry.displayedAspect(target.geometry.crop,
                sourceWidth: size.width, sourceHeight: size.height, degrees: target.geometry.angle))
            let new = try XCTUnwrap(CropGeometry.displayedAspect(try XCTUnwrap(result[target.photo]),
                sourceWidth: size.width, sourceHeight: size.height, degrees: target.geometry.angle))
            XCTAssertEqual(new, 1 / old, accuracy: 1e-10)
        }
    }

    @MainActor
    func testProductionBatchAppliesDifferentShapesAndPreservesConcurrentToneEdit() async throws {
        try await withState { state, photos in
            let originalFiles = try photos.map { try Data(contentsOf: $0.id) }
            let result = await CropAspectEdit.apply(.ratio(3), in: state) { targets in
                let sizes = await CropAspectEdit.readSizes(targets)
                await MainActor.run {
                    state.updateRecipe { $0.develop.tone.exposure = 1.25 }
                }
                return sizes
            }
            try result.get()
            for photo in photos {
                let recipe = state.recipe(for: photo)
                let size = try XCTUnwrap(CropAspectEdit.sourceSize(metadata: CaptureMetadataReader.read(url: photo.id)))
                XCTAssertEqual(CropGeometry.displayedAspect(recipe.develop.geometry.crop,
                    sourceWidth: size.width, sourceHeight: size.height, degrees: 0)!, 3, accuracy: 1e-10)
                XCTAssertEqual(recipe.develop.tone.exposure, 1.25)
            }
            XCTAssertEqual(try photos.map { try Data(contentsOf: $0.id) }, originalFiles)
        }
    }

    @MainActor
    func testProductionBatchRefusalLeavesEveryRecipeAndHistoryUnchanged() async throws {
        try await withState { state, photos in
            let recipes = photos.map { state.recipe(for: $0) }
            let undo = state.commands.undoLabel
            let result = await CropAspectEdit.apply(.ratio(20), in: state)
            if case .success = result { XCTFail("Portrait target cannot represent 20:1") }
            XCTAssertEqual(photos.map { state.recipe(for: $0) }, recipes)
            XCTAssertEqual(state.commands.undoLabel, undo)
            let unavailable = await CropAspectEdit.apply(.ratio(3), in: state, loadSizes: { _ in [:] })
            if case .success = unavailable { XCTFail("Missing dimensions cannot authorize an edit") }
            XCTAssertEqual(photos.map { state.recipe(for: $0) }, recipes)
        }
    }

    @MainActor
    func testConcurrentFramingSelectionAndSourceChangesEachRejectDelayedRequest() async throws {
        for change in 0..<4 {
            try await withState { state, photos in
                let oldCrops = photos.map { state.recipe(for: $0).develop.geometry.crop }
                let result = await CropAspectEdit.apply(.ratio(3), in: state) { targets in
                    let sizes = await CropAspectEdit.readSizes(targets)
                    await MainActor.run {
                        if change == 0 { state.updateRecipe { $0.develop.geometry.angle = 7 } }
                        if change == 1 { state.selection = [photos[0].id] }
                        if change == 3 { state.primarySelection = photos[1] }
                    }
                    if change == 2 {
                        // Atomic same-path replacement of a test-owned image changes generation.
                        try? Data(contentsOf: photos[1].id).write(to: photos[1].id, options: .atomic)
                    }
                    return sizes
                }
                if case .success = result { XCTFail("Stale request committed after change \(change)") }
                XCTAssertEqual(photos.map { state.recipe(for: $0).develop.geometry.crop }, oldCrops)
            }
        }
    }

    @MainActor
    func testRealMetadataOrientedDimensionsMatchRenderedSourceAndRemainReadOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-crop-metadata-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for orientation in [1, 6, 8] {
            let file = root.appendingPathComponent("orientation-\(orientation).tiff")
            try image(file, width: 120, height: 80, orientation: orientation)
            let original = try Data(contentsOf: file)
            let source = try RenderedImageSource(url: file)
            let identity = try XCTUnwrap(SourceFileIdentity.read(file))
            let target = CropAspectEdit.Target(photo: file, geometry: Geometry(), source: identity)
            let sizes = await CropAspectEdit.readSizes([target])
            XCTAssertEqual(sizes[file], CGSize(width: source.nativePixelSize.width, height: source.nativePixelSize.height))
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertTrue(CropAspectEdit.stillCurrent([target], current: [target]))
        }
    }

    @MainActor
    func testReadingAnOldLockDoesNotRefitOrEraseSessionState() {
        let tool = CropTool.shared
        let previous = tool.activeLock
        defer {
            if let previous { tool.setLock(previous.aspect, for: previous.photo) }
            else { tool.setLock(nil, for: a) }
        }
        let crop = Crop(w: 1, h: 0.05)
        tool.setLock(60, for: a)
        let stored = tool.activeLock
        XCTAssertNil(tool.effectiveLockedAspect(for: a, crop: crop, frameAspect: 1.5))
        XCTAssertEqual(tool.activeLock, stored)
        XCTAssertEqual(crop, Crop(w: 1, h: 0.05))
        tool.setLock(30, for: a)
        XCTAssertEqual(tool.effectiveLockedAspect(for: a, crop: crop, frameAspect: 1.5), 30)
        XCTAssertNil(tool.effectiveLockedAspect(for: b, crop: crop, frameAspect: 1.5))
        XCTAssertNil(tool.effectiveLockedAspect(for: a, crop: crop, frameAspect: 2.0 / 3))
        XCTAssertNil(tool.effectiveLockedAspect(for: a, crop: crop, frameAspect: 0))
    }

    @MainActor
    func testCancellationPropagatesToMetadataWorkerBeforeTheNextFile() async throws {
        try await withState { _, photos in
            let targets = photos.map { CropAspectEdit.Target(photo: $0.id, geometry: Geometry(),
                                                             source: SourceFileIdentity.read($0.id)) }
            let entered = expectation(description: "first metadata read entered")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let visits = M12MetadataReadCounter()
            let task = Task {
                await CropAspectEdit.readSizes(targets, readMetadata: { _ in
                    visits.increment()
                    entered.fulfill()
                    _ = release.wait(timeout: .now() + 5)
                    return PhotoMetadata(width: 120, height: 80)
                })
            }
            await fulfillment(of: [entered], timeout: 3)
            task.cancel()
            release.signal()
            let result = await task.value
            XCTAssertTrue(result.isEmpty, "The canceled in-flight read must not publish dimensions")
            XCTAssertEqual(visits.value, 1, "No second file should be read after cancellation")
        }
    }

    @MainActor
    private func withState(_ run: (AppState, [PhotoItem]) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-crop-batch-\(UUID())")
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try image(folder.appendingPathComponent("landscape.tiff"), width: 120, height: 80)
        try image(folder.appendingPathComponent("portrait.tiff"), width: 80, height: 120)
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("previews") })
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) }
            try? FileManager.default.removeItem(at: root)
        }
        state.openFolder(folder)
        for _ in 0..<500 {
            if !state.isScanning { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.isScanning, "Isolated scan timed out")
        let photos = state.allPhotos.sorted { $0.filename < $1.filename }
        XCTAssertEqual(photos.count, 2)
        state.select(try XCTUnwrap(photos.first))
        state.selection = Set(photos.map(\.id))
        try await run(state, photos)
    }

    @MainActor
    private func image(_ path: URL, width: Int, height: Int, orientation: Int = 1) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let cg = try XCTUnwrap(bitmap.cgImage)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(path as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

private final class M12MetadataReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
#endif
