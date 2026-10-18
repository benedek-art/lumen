#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import LumenCore
@testable import LumenApp

final class BatchRecipeSaveTests: XCTestCase {
    private func withCatalog(count: Int = 3, _ body: (CatalogService, CatalogStore, [URL], [Int64], URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-batch-save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = (0..<count).map { root.appendingPathComponent(String(format: "frame%06d.JPG", $0)) }
        for photo in photos { try Data([1]).write(to: photo) }
        let catalog = root.appendingPathComponent("catalog")
        let service = try CatalogService(directory: catalog)
        defer { service.close() }
        let loaded = service.registerAndLoad(folder: root, files: photos)
        let ids = try photos.map { try XCTUnwrap(loaded[$0]?.catalogID) }
        var old = Recipe(); old.develop.tone.exposure = 0.25
        for (photo, id) in zip(photos, ids) { service.saveRecipe(old, url: photo, catalogID: id) }
        _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
        service.flushSidecars()
        let store = try CatalogStore(path: catalog.appendingPathComponent("lumen.db").path)
        defer { store.close() }
        try await body(service, store, photos, ids, root)
    }

    private func requests(_ photos: [URL], _ ids: [Int64]) -> [CatalogService.RecipeSave] {
        zip(photos, ids).enumerated().map { index, item in
            var recipe = Recipe(); recipe.develop.tone.exposure = Double(index + 1)
            return CatalogService.RecipeSave(recipe: recipe, url: item.0, catalogID: item.1)
        }
    }

    func testRejectedMiddlePhotoKeepsOldEditAndCallbacksObserveCommittedOtherPhotos() async throws {
        try await withCatalog { service, store, photos, ids, root in
            let middle = try store.currentEdit(photoID: ids[1])
            let middleBytes = try Data(contentsOf: CatalogService.sidecarURL(for: photos[1]))
            try store.debugExecute("CREATE TRIGGER reject_middle BEFORE UPDATE OF recipe ON edit WHEN OLD.photo_id = \(ids[1]) BEGIN SELECT RAISE(ABORT, 'injected middle refusal'); END;")
            var callbackValues: [Double?] = []
            service.onFailure = { _ in callbackValues.append(try? store.currentRecipe(photoID: ids[0])?.develop.tone.exposure) }
            service.saveRecipes(Array(self.requests(photos, ids).reversed()))
            _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
            XCTAssertEqual(callbackValues, [1], "callbacks must run after the outer commit is visible to another connection")
            XCTAssertEqual(try store.currentEdit(photoID: ids[1]), middle)
            XCTAssertEqual(try store.currentRecipe(photoID: ids[2])?.develop.tone.exposure, 3)
            let debt = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
            XCTAssertEqual(Set(debt.compactMap(\.photoID)), [ids[0], ids[2]])
            service.flushSidecars()
            XCTAssertEqual(try Data(contentsOf: CatalogService.sidecarURL(for: photos[1])), middleBytes)
            XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
        }
    }

    func testJournalCommitFailureRollsBackAllRowsAndEnqueuesNoSidecarWrites() async throws {
        try await withCatalog { service, store, photos, ids, root in
            let before = try ids.map { try store.currentEdit(photoID: $0) }
            let bytes = try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }
            try store.debugExecute("CREATE TRIGGER reject_batch_journal BEFORE INSERT ON meta WHEN NEW.key = 'sidecar_unsaved' BEGIN SELECT RAISE(ABORT, 'injected final journal refusal'); END;")
            var failures: [String] = []
            service.onFailure = { failures.append($0) }
            service.saveRecipes(self.requests(photos, ids))
            _ = try await service.querySource(scope: .everywhere, folderPath: root.path)
            service.flushSidecars()
            XCTAssertEqual(try ids.map { try store.currentEdit(photoID: $0) }, before)
            XCTAssertEqual(try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }, bytes)
            XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures.first?.contains("rolled back") == true)
        }
    }

    func testSecondChunkJournalFailureRetainsFirstPrefixAndDoesNotAttemptTail() async throws {
        try await withCatalog(count: 130) { service, store, photos, ids, root in
            let before = try ids.map { try store.currentEdit(photoID: $0) }
            let bytes = try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }
            try store.debugExecute("CREATE TRIGGER reject_second_chunk BEFORE INSERT ON meta WHEN NEW.key = 'sidecar_unsaved' AND instr(NEW.value, 'frame000064.JPG') > 0 BEGIN SELECT RAISE(ABORT, 'injected second chunk refusal'); END;")
            var failures: [String] = []
            service.onFailure = { failures.append($0) }
            var changed = Recipe(); changed.develop.tone.exposure = 1.5
            service.saveRecipes(zip(photos, ids).map { .init(recipe: changed, url: $0.0, catalogID: $0.1) })
            try await service.requireAvailablePhoto(photoID: ids[0])
            for index in ids.indices {
                if index < 64 {
                    XCTAssertEqual(try store.currentRecipe(photoID: ids[index])?.develop.tone.exposure, 1.5)
                } else {
                    XCTAssertEqual(try store.currentEdit(photoID: ids[index]), before[index])
                }
            }
            let debt = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
            XCTAssertEqual(Set(debt.compactMap(\.photoID)), Set(ids.prefix(64)))
            XCTAssertEqual(failures.count, 1)
            XCTAssertTrue(failures[0].contains("64 earlier edits remain committed"))
            XCTAssertTrue(failures[0].contains("64 accepted edits were rolled back"))
            XCTAssertTrue(failures[0].contains("2 remaining photos were not attempted"))
            service.flushSidecars()
            for index in 64..<photos.count {
                XCTAssertEqual(try Data(contentsOf: CatalogService.sidecarURL(for: photos[index])), bytes[index])
            }
        }
    }

    func testLatchedUnreadableJournalReportsEntireUnattemptedCurrentChunk() async throws {
        try await withCatalog { seed, store, photos, ids, root in
            seed.close()
            let before = try ids.map { try store.currentEdit(photoID: $0) }
            let bytes = try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }
            let raw = "{unreadable journal: retain exact bytes}"
            try store.setMetaValue(UnsavedSidecarRecord.metaKey, raw)
            let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
            defer { service.close() }
            var failures: [String] = []
            service.onFailure = { failures.append($0) }
            service.saveRecipes(self.requests(photos, ids))
            do { try await service.requireAvailablePhoto(photoID: ids[0]); XCTFail("journal refusal must remain latched") }
            catch { }
            let warning = try XCTUnwrap(failures.first { $0.contains("Could not finish the edit batch") })
            XCTAssertTrue(warning.contains("0 earlier edits remain committed"))
            XCTAssertTrue(warning.contains("3 photos in this chunk were not committed"))
            XCTAssertTrue(warning.contains("0 accepted edits were rolled back"))
            XCTAssertTrue(warning.contains("0 remaining photos were not attempted"))
            XCTAssertEqual(try ids.map { try store.currentEdit(photoID: $0) }, before)
            service.flushSidecars(); service.close()
            XCTAssertEqual(try store.metaValue(UnsavedSidecarRecord.metaKey), raw)
            XCTAssertEqual(try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }, bytes)
        }
    }

    func testNoncanonicalAndUnavailablePhotosAreSkippedWhileValidPhotoCommits() async throws {
        try await withCatalog { service, store, photos, ids, root in
            try store.debugExecute("UPDATE edit SET pipeline_version = \(supportedPipelineVersion + 10) WHERE photo_id = \(ids[2]) AND is_current = 1;")
            let before = try ids.map { try store.currentEdit(photoID: $0) }
            var batch = self.requests(photos, ids)
            var invalid = batch[1].recipe; invalid.develop.tone.exposure = .nan
            batch[1] = CatalogService.RecipeSave(recipe: invalid, url: photos[1], catalogID: ids[1])
            var failures: [String] = []
            service.onFailure = { failures.append($0) }
            service.saveRecipes(batch)
            try await service.requireAvailablePhoto(photoID: ids[0])
            XCTAssertEqual(try store.currentRecipe(photoID: ids[0])?.develop.tone.exposure, 1)
            XCTAssertEqual(try store.currentEdit(photoID: ids[1]), before[1])
            XCTAssertEqual(try store.currentEdit(photoID: ids[2]), before[2])
            XCTAssertEqual(failures.count, 2)
            let debt = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
            XCTAssertEqual(debt.compactMap(\.photoID), [ids[0]])
        }
    }
    private static let childRootKey = "LUMEN_BATCH_PREFIX_CHILD_ROOT"

    func testChunkBoundaryChildFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment[Self.childRootKey] else {
            throw XCTSkip("subprocess fixture; exercised by killed-process parent")
        }
        let root = URL(fileURLWithPath: path)
        let photos = (0..<130).map { root.appendingPathComponent(String(format: "frame%06d.JPG", $0)) }
        for photo in photos { try Data([1]).write(to: photo) }
        let catalog = root.appendingPathComponent("catalog")
        let seed = try CatalogService(directory: catalog)
        let loaded = seed.registerAndLoad(folder: root, files: photos)
        let ids = try photos.map { try XCTUnwrap(loaded[$0]?.catalogID) }
        var old = Recipe(); old.develop.tone.exposure = 0.25
        for (photo, id) in zip(photos, ids) { seed.saveRecipe(old, url: photo, catalogID: id) }
        try await seed.requireAvailablePhoto(photoID: ids[0])
        seed.flushSidecars(); seed.close()
        let service = try CatalogService(directory: catalog)
        let store = try CatalogStore(path: catalog.appendingPathComponent("lumen.db").path)
        try store.debugExecute("CREATE TRIGGER stop_boundary BEFORE UPDATE OF recipe ON edit WHEN OLD.photo_id = \(ids[63]) BEGIN SELECT RAISE(ABORT, 'stop after first committed chunk'); END;")
        service.onFailure = { message in
            guard message.contains("stop after first committed chunk") else { return }
            // This callback is after the first chunk's commit and before the next
            // chunk on the same queue. Nothing can drain, close or debounce next.
            do {
                try JSONEncoder().encode(ids).write(to: root.appendingPathComponent("ready"), options: .atomic)
            } catch { XCTFail("could not publish child readiness: \(error)"); return }
            raise(SIGSTOP)
        }
        var changed = old; changed.develop.tone.exposure = 1.5
        service.saveRecipes(zip(photos, ids).map { .init(recipe: changed, url: $0.0, catalogID: $0.1) })
        try await service.requireAvailablePhoto(photoID: ids[0])
        XCTFail("parent must kill the stopped child without orderly cleanup")
    }

    func testKilledProcessBetweenChunksRetainsOnlyCommittedPrefixAndRecoveryIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lumen-batch-prefix-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("child.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: output.path, contents: nil))
        let log = try FileHandle(forWritingTo: output)
        defer { try? log.close() }
        let locator = Process(); locator.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        locator.arguments = ["--find", "xctest"]
        let location = Pipe(); locator.standardOutput = location
        try locator.run(); locator.waitUntilExit()
        XCTAssertEqual(locator.terminationStatus, 0)
        let executable = try XCTUnwrap(String(data: location.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable))
        let child = Process(); child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["-XCTest", "LumenAppTests.BatchRecipeSaveTests/testChunkBoundaryChildFixture", Bundle(for: Self.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment; environment[Self.childRootKey] = root.path
        child.environment = environment; child.standardOutput = log; child.standardError = log
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        let ready = root.appendingPathComponent("ready")
        let deadline = Date().addingTimeInterval(25)
        while !FileManager.default.fileExists(atPath: ready.path) && child.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let data = try? Data(contentsOf: ready) else {
            XCTFail("child never reached committed prefix: \((try? String(contentsOf: output, encoding: .utf8)) ?? "no log")")
            throw CocoaError(.fileReadUnknown)
        }
        let ids = try JSONDecoder().decode([Int64].self, from: data)
        XCTAssertEqual(kill(child.processIdentifier, SIGKILL), 0)
        child.waitUntilExit()
        XCTAssertEqual(child.terminationReason, .uncaughtSignal)
        XCTAssertEqual(child.terminationStatus, SIGKILL)
        let photos = (0..<130).map { root.appendingPathComponent(String(format: "frame%06d.JPG", $0)) }
        let store = try CatalogStore(path: root.appendingPathComponent("catalog/lumen.db").path)
        defer { store.close() }
        XCTAssertEqual(ids.count, 130)
        for index in ids.indices {
            XCTAssertEqual(try store.currentRecipe(photoID: ids[index])?.develop.tone.exposure, index < 63 ? 1.5 : 0.25)
        }
        let debt = try UnsavedSidecarRecord.decodeValidated(store.metaValue(UnsavedSidecarRecord.metaKey))
        XCTAssertEqual(Set(debt.compactMap(\.photoID)), Set(ids.prefix(63)))
        XCTAssertTrue(debt.allSatisfy { $0.generation != nil })
        let oldBytes = try photos.map { try Data(contentsOf: CatalogService.sidecarURL(for: $0)) }
        let service = try CatalogService(directory: root.appendingPathComponent("catalog"))
        defer { service.close() }
        // Startup reconstructs durable intent asynchronously on the catalog queue.
        // flushSidecars snapshots only already-enqueued writes; join recovery first,
        // just as release/undo probes join their queued saves before publication.
        try await service.requireAvailablePhoto(photoID: ids[0])
        service.flushSidecars()
        for index in photos.indices {
            let bytes = try Data(contentsOf: CatalogService.sidecarURL(for: photos[index]))
            if index < 63 {
                let content = try XCTUnwrap(XMPSidecar.parse(bytes))
                let json = try XCTUnwrap(content.recipeJSON)
                XCTAssertEqual(try CanonicalJSON.decodeRecipe(from: Data(json.utf8)).develop.tone.exposure, 1.5)
            } else { XCTAssertEqual(bytes, oldBytes[index]) }
        }
        XCTAssertNil(try store.metaValue(UnsavedSidecarRecord.metaKey))
    }

}
#endif
