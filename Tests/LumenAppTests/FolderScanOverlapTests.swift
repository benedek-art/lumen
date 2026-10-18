#if os(macOS)
import CoreGraphics
import ImageIO
import XCTest
@testable import LumenCore
@testable import LumenApp

@MainActor
final class FolderScanOverlapTests: XCTestCase {
    private func settle(_ state: AppState) async throws {
        let deadline = Date().addingTimeInterval(10)
        while state.isScanning && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.isScanning)
    }

    private func fixture(_ body: (AppState, CatalogService, URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-scan-overlap-\(UUID())")
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("fixture.JPG")
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 0.5, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(bitmap.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let keys = ["lumen.lastFolder.bookmark", "lumen.lastFolder.files"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let state = AppState(catalogDirectory: { root.appendingPathComponent("catalog") },
                             previewDirectory: { root.appendingPathComponent("preview") })
        defer {
            state.prepareToQuit()
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: root)
        }
        state.openFolder(folder, restrictedTo: [file])
        try await settle(state)
        let catalog = try XCTUnwrap(state.catalog)
        state.select(try XCTUnwrap(state.allPhotos.first))
        state.updateRecipe { $0.develop.tone.exposure = 1 }
        _ = try await catalog.querySource(scope: .everywhere, folderPath: folder.path)
        catalog.flushSidecars()
        try await body(state, catalog, folder, file)
    }

    /// Pause the real registration queue before it reads recipes. There is no new
    /// loader seam: production's preview invalidation callback provides the barrier.
    private func pausedScan(_ state: AppState, catalog: CatalogService, folder: URL, file: URL,
                            edit: () throws -> Void) async throws {
        let entered = expectation(description: "registration paused before recipe reads")
        let release = DispatchSemaphore(value: 0)
        let previous = catalog.onInvalidatedPreviews
        catalog.onInvalidatedPreviews = { rows in
            catalog.onInvalidatedPreviews = previous
            previous?(rows)
            entered.fulfill()
            _ = release.wait(timeout: .now() + 10)
        }
        defer { release.signal(); catalog.onInvalidatedPreviews = previous }
        state.openFolder(folder, restrictedTo: [file])
        await fulfillment(of: [entered], timeout: 5)
        try edit()
        release.signal()
        try await settle(state)
    }

    func testDeferredRecipeSurvivesOverlapAndLaterWholeRecipeWriteReopenAndSidecar() async throws {
        try await fixture { state, catalog, folder, file in
            let original = try XCTUnwrap(state.allPhotos.first)
            try await pausedScan(state, catalog: catalog, folder: folder, file: file) {
                state.select(original)
                state.sliderGesture(active: true)
                state.updateRecipe { $0.develop.tone.exposure = 2 }
                XCTAssertEqual(state.currentRecipe.develop.tone.exposure, 2)
            }
            state.select(try XCTUnwrap(state.allPhotos.first))
            XCTAssertEqual(state.currentRecipe.develop.tone.exposure, 2,
                           "applying the scan must not replace the live deferred recipe with its catalog snapshot")
            state.updateRecipe { $0.develop.tone.contrast = 0.25 }
            let entries = try await catalog.querySource(scope: .everywhere, folderPath: folder.path)
            catalog.flushSidecars()
            let persisted = try XCTUnwrap(entries.first { $0.url == file }?.state.recipe)
            XCTAssertEqual(persisted.develop.tone.exposure, 2)
            XCTAssertEqual(persisted.develop.tone.contrast, 0.25)
            state.openFolder(folder, restrictedTo: [file])
            try await settle(state)
            state.select(try XCTUnwrap(state.allPhotos.first))
            XCTAssertEqual(state.currentRecipe.develop.tone.exposure, 2)
            let sidecar = try XCTUnwrap(XMPSidecar.parse(Data(contentsOf: CatalogService.sidecarURL(for: file))))
            let portable = try CanonicalJSON.decodeRecipe(from: Data(try XCTUnwrap(sidecar.recipeJSON).utf8))
            XCTAssertEqual(portable.develop.tone.exposure, 2)
            XCTAssertEqual(portable.develop.tone.contrast, 0.25)
        }
    }

    func testUnmodifiedOverlapStillImportsFreshExternalRecipe() async throws {
        try await fixture { state, catalog, folder, file in
            var incoming = state.currentRecipe
            incoming.develop.tone.exposure = 3
            let bytes = Data(XMPSidecar.serialize(SidecarContent(
                recipeJSON: try CanonicalJSON.canonicalRecipeJSON(incoming))).utf8)
            try bytes.write(to: CatalogService.sidecarURL(for: file), options: .atomic)
            try await pausedScan(state, catalog: catalog, folder: folder, file: file, edit: {})
            state.select(try XCTUnwrap(state.allPhotos.first))
            XCTAssertEqual(state.currentRecipe.develop.tone.exposure, 3)
        }
    }

    func testFutureExternalRecipeRemainsUnavailableDespitePendingLocalEdit() async throws {
        try await fixture { state, catalog, folder, file in
            let original = try XCTUnwrap(state.allPhotos.first)
            var incoming = state.currentRecipe
            incoming.pipelineVersion = supportedPipelineVersion + 1
            let bytes = Data(XMPSidecar.serialize(SidecarContent(
                pipelineVersion: supportedPipelineVersion + 1,
                recipeJSON: try CanonicalJSON.canonicalRecipeJSON(incoming))).utf8)
            let sidecar = CatalogService.sidecarURL(for: file)
            try bytes.write(to: sidecar, options: .atomic)
            try await pausedScan(state, catalog: catalog, folder: folder, file: file) {
                state.select(original)
                state.sliderGesture(active: true)
                state.updateRecipe { $0.develop.tone.exposure = 2 }
            }
            XCTAssertFalse(state.allPhotos.contains { $0.id == file })
            catalog.flushSidecars()
            XCTAssertEqual(try Data(contentsOf: sidecar), bytes)
            state.openFolder(folder, restrictedTo: [file])
            try await settle(state)
            XCTAssertFalse(state.allPhotos.contains { $0.id == file })
        }
    }

    func testLocalCullingFieldsSurviveOverlapWithoutReplacingUntouchedExternalRecipe() async throws {
        try await fixture { state, catalog, folder, file in
            let original = try XCTUnwrap(state.allPhotos.first)
            var incoming = state.currentRecipe
            incoming.develop.tone.exposure = 3
            try Data(XMPSidecar.serialize(SidecarContent(
                recipeJSON: try CanonicalJSON.canonicalRecipeJSON(incoming))).utf8)
                .write(to: CatalogService.sidecarURL(for: file), options: .atomic)
            try await pausedScan(state, catalog: catalog, folder: folder, file: file) {
                state.select(original)
                state.setFlag(.pick)
                state.setRating(4)
                state.setLabel(.red)
            }
            let current = try XCTUnwrap(state.allPhotos.first)
            XCTAssertEqual(current.flag, .pick)
            XCTAssertEqual(current.rating, 4)
            XCTAssertEqual(current.label, .red)
            state.select(current)
            XCTAssertEqual(state.currentRecipe.develop.tone.exposure, 3)
        }
    }
}
#endif
